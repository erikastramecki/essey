// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {Seat} from "../src/market/Seat.sol";
import {SeatArt} from "../src/market/SeatArt.sol";
import {Bell} from "../src/market/Bell.sol";
import {EsseyToken} from "../src/market/EsseyToken.sol";
import {EsseyExchange} from "../src/market/EsseyExchange.sol";
import {EsseyCases} from "../src/market/EsseyCases.sol";
import {MintDistributor} from "../src/market/MintDistributor.sol";
import {IConverter} from "../src/market/IConverter.sol";

/// The Market layer deploy — the ONE place the wiring order lives as code.
///
/// Order is forced by immutables and verified by constructor guards; a mistake reverts the broadcast
/// rather than shipping a brick (each guard below was earned in an audit round):
///
///   1. MintDistributor            (admin, reserveCap, rootTimelock)
///   2. Seat                       minter = the distributor, IMMUTABLE — nothing else can ever mint
///   3. distributor.initSeat       reverts unless seat.minter() == distributor (one-shot)
///   4. EsseyToken                 all supply to treasury, adminless
///   5. Bell                       seat + $ESSEY (tier fees) + reward stable + tier ladder
///   6. distributor.setSeatHook    the ONLY caller of the minter-gated Seat.setHook (one-shot)
///   7. SeatArt                    reverts if the bell is codeless OR isn't the seat's hook
///   8. distributor.setSeatArt     one-shot; rejects zero and codeless renderers
///   9. EsseyExchange              reverts unless bell.seat()==seat and price token != fee token
///  10. EsseyCases                 reverts unless spread within [150,2000] bps and reward coherent
///
/// NOT done here (operational, post-deploy): mintReserved -> seed the Exchange float; listStock +
/// seedUnits + fundBuyback on Cases; proposeRoot/commitRoot for the whitelist; redeploy EsseyPool
/// with BELL_SINK=<bell> so loan interest joins the pot (script/Deploy.s.sol takes it via env).
contract DeployMarket is Script {
    // ---------------------------------------------------------------- launch constants
    // These are LAUNCH DECISIONS, kept in code (not env) so review sees them next to the wiring.
    // Sources: docs/TOKENOMICS.md + the internal economics model.
    uint256 constant MAX_SUPPLY = 2222;
    uint256 constant ROOT_TIMELOCK = 2 days;
    uint256 constant TIP_BPS = 100; // 1% to whoever rings the Bell
    uint256 constant BOOSTER_SHARE_BPS = 7000; // 70% of every trade/case fee to the pot
    uint256 constant CASE_SPREAD_BPS = 500; // 5% sell-back discount (floor 150 enforced on-chain)

    /// Tier ladder: weights are the payout multiplier vs Base=100; fees are the $ESSEY activation
    /// sink (half burned by the Bell). Four rungs at launch.
    function _ladder() internal pure returns (uint256[] memory fees, uint256[] memory weights) {
        fees = new uint256[](4);
        weights = new uint256[](4);
        (fees[0], weights[0]) = (1_000e18, 100);
        (fees[1], weights[1]) = (1_600e18, 160);
        (fees[2], weights[2]) = (2_000e18, 200);
        (fees[3], weights[3]) = (3_330e18, 333);
    }

    struct Config {
        address admin; // the curating multisig: whitelist roots, reserved mints, hook/art wiring
        address treasury; // receives $ESSEY supply, protocol fee shares, case prices
        address seeder; // Exchange float manager (add-only role)
        address bankroll; // Cases inventory/buyback funder (add-only role)
        IERC20 usdg; // the reward/fee stable (6 decimals on Robinhood Chain)
        AggregatorV3Interface usdgFeed; // USDG/USD Chainlink feed (Cases sell-back base leg)
        AggregatorV3Interface sequencerFeed; // address(0) on this chain; see StaleFeedGuard
        IConverter converter; // optional stock-payout converter; address(0) = base-only at launch
        uint256 reserveCap; // admin's hard mint ceiling: Exchange float + partner tranche
        uint256 minRing; // pot floor before the Bell can ring (reward units)
        uint256 seatPrice; // Exchange flat price, $ESSEY
        uint256 swapFee; // Exchange fees, reward units
        uint256 snipeFee;
        uint256 sellFee;
        uint256 casePrice; // Cases price, $ESSEY
        uint256 caseBuyFee; // Cases buy fee, reward units
    }

    struct Deployed {
        MintDistributor distributor;
        Seat seat;
        EsseyToken essey;
        Bell bell;
        SeatArt art;
        EsseyExchange exchange;
        EsseyCases cases_;
    }

    function _configFromEnv() internal view returns (Config memory c) {
        c.admin = vm.envOr("ADMIN", msg.sender);
        c.treasury = vm.envOr("TREASURY", c.admin);
        c.seeder = vm.envOr("SEEDER", c.admin);
        c.bankroll = vm.envOr("BANKROLL", c.admin);
        c.usdg = IERC20(vm.envAddress("USDG"));
        c.usdgFeed = AggregatorV3Interface(vm.envAddress("USDG_FEED"));
        c.sequencerFeed = AggregatorV3Interface(vm.envOr("SEQUENCER_FEED", address(0)));
        c.converter = IConverter(vm.envOr("CONVERTER", address(0)));
        c.reserveCap = vm.envOr("RESERVE_CAP", uint256(1311)); // ~1111 float + 200 partners
        c.minRing = vm.envOr("MIN_RING", uint256(10e6)); // 10 USDG
        c.seatPrice = vm.envOr("SEAT_PRICE", uint256(500e18));
        c.swapFee = vm.envOr("SWAP_FEE", uint256(10e6));
        c.snipeFee = vm.envOr("SNIPE_FEE", uint256(15e6));
        c.sellFee = vm.envOr("SELL_FEE", uint256(8e6));
        c.casePrice = vm.envOr("CASE_PRICE", uint256(100e18));
        c.caseBuyFee = vm.envOr("CASE_BUY_FEE", uint256(5e6));
    }

    /// The whole sequence, callable from tests for a broadcast-free dry run.
    function deployAll(Config memory c) public returns (Deployed memory d) {
        d.distributor = new MintDistributor(c.admin, c.reserveCap, ROOT_TIMELOCK);
        d.seat = new Seat("Essey Seat", "SEAT", MAX_SUPPLY, address(d.distributor));
        d.essey = new EsseyToken(c.treasury);
        (uint256[] memory fees, uint256[] memory weights) = _ladder();
        d.bell = new Bell(d.seat, d.essey, c.usdg, c.treasury, c.minRing, TIP_BPS, fees, weights, c.converter);
        // SeatArt is deliberately NOT constructed here: its constructor asserts seat.hook() == bell,
        // so it can only exist after the admin's setSeatHook — see wireAll. (The first draft of this
        // script constructed it here and the guard correctly refused to deploy.)
        d.exchange = new EsseyExchange(
            IERC721(address(d.seat)), d.essey, d.bell, c.treasury, c.seeder,
            c.seatPrice, c.swapFee, c.snipeFee, c.sellFee, BOOSTER_SHARE_BPS
        );
        d.cases_ = new EsseyCases(
            d.essey, d.bell, c.usdgFeed, c.sequencerFeed, c.treasury, c.bankroll,
            c.casePrice, c.caseBuyFee, CASE_SPREAD_BPS, BOOSTER_SHARE_BPS
        );
    }

    /// Admin wiring — separated because when ADMIN is a multisig, these are ITS transactions, not
    /// the deployer's; the script executes them only when the broadcaster IS the admin.
    function wireAll(Deployed memory d) public returns (SeatArt art) {
        d.distributor.initSeat(d.seat);
        d.distributor.setSeatHook(address(d.bell));
        // Art can only exist once the hook points at the bell (constructor guard) — construct here.
        art = new SeatArt(d.seat, d.bell);
        d.distributor.setSeatArt(address(art));
    }

    function run() external {
        Config memory c = _configFromEnv();
        vm.startBroadcast();
        Deployed memory d = deployAll(c);
        if (msg.sender == c.admin) {
            d.art = wireAll(d);
        } else {
            console.log("ADMIN != broadcaster: run initSeat/setSeatHook/(new SeatArt)/setSeatArt from the multisig");
        }
        vm.stopBroadcast();

        console.log("distributor ", address(d.distributor));
        console.log("seat        ", address(d.seat));
        console.log("essey       ", address(d.essey));
        console.log("bell        ", address(d.bell));
        console.log("art         ", address(d.art));
        console.log("exchange    ", address(d.exchange));
        console.log("cases       ", address(d.cases_));
        console.log("");
        console.log("NEXT (operational):");
        console.log(" 1. distributor.mintReserved(seeder, float) then exchange.seed(ids)");
        console.log(" 2. cases: listStock + seedUnits + fundBuyback (bankroll)");
        console.log(" 3. whitelist: proposeRoot -> 2d review -> commitRoot -> setStageOpen");
        console.log(" 4. redeploy EsseyPool with BELL_SINK=<bell> (script/Deploy.s.sol env)");
        console.log(" 5. indexer: RPC_URL + ADDR_* from the addresses above");
    }
}
