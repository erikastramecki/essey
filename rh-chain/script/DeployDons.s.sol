// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {Don} from "../src/market/Don.sol";
import {DonDistributor} from "../src/market/DonDistributor.sol";
import {DonReserve} from "../src/market/DonReserve.sol";
import {DonExchange, IDonFloor} from "../src/market/DonExchange.sol";
import {DonFeeRouter, ISwapRouter, IWETH} from "../src/market/DonFeeRouter.sol";
import {DonLoan} from "../src/market/DonLoan.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {EsseyToken} from "../src/market/EsseyToken.sol";

/// DeployDons — the full Dons v3 market layer, in dependency order:
///
///   DonDistributor -> Don -> DonReserve -> Bell(5-tier 666-ladder) -> [DonFeeRouter] -> DonExchange -> DonLoan
///
/// then the one-shot wiring (initDon, hook=Bell, bell, lienManager=DonLoan, feeSink). Passed a 3-agent
/// adversarial clean round (rounds recorded in the audit trail) BEFORE this script existed; the script
/// only arranges audited pieces.
///
/// DELIBERATELY NOT DONE HERE (post-deploy, founder-approved ops, logged at the end):
///   - funding DonReserve (2,666,666,666 $ESSEY -> the 300k floor) and the DonLoan pot (size = founder call)
///   - mintReserved of the 2,222 AMM float to the seeder + seeding the exchange (reserveCap covers it: 2,722)
///   - committing the allowlist root (timelocked) and opening stages
///   - Don.setArt (no DonArt renderer exists yet -- tokenURI is empty until #79 ships one)
///
/// ENV (testnet defaults in brackets): ADMIN [broadcaster], TREASURY [admin], SEEDER [admin], ESSEY (req),
/// USDG (req), CONVERTER [0 = base-only], DEFAULT_PAYOUT [0], MIN_RING [10 USDG in reward decimals],
/// RESERVE_CAP [2722], REROLL_FEE_WEI [~$3], CUSTOM_FEE_WEI [~$10], DON_PRICE [300_000e18],
/// WETH/ETH_FEED/USDG_FEED [0 = skip DonFeeRouter, feeSink=treasury interim], SWAP_ROUTER [0 = ditto],
/// SEQUENCER_FEED [0 — none on RH-chain].
contract DeployDons is Script {
    uint256 constant MAX_SUPPLY = 8888;
    uint256 constant ROOT_TIMELOCK = 2 days;
    uint256 constant TIP_BPS = 0; // founder: no ring tip — a protocol keeper rings

    // AMM: softened the reference desk Anvil fees, 70% of every fee -> stock for staked Dons.
    uint256 constant SWAP_FEE_BPS = 800;
    uint256 constant SNIPE_FEE_BPS = 1200;
    uint256 constant STOCK_SHARE_BPS = 7000;

    // Borrow: the proven desk numbers on Essey's provable floor.
    uint256 constant LTV_BPS = 5000;
    uint256 constant LIQ_THRESHOLD_BPS = 7000;
    uint256 constant RATE_BPS = 1500;
    uint256 constant LIQ_TIP_BPS = 100;
    uint256 constant LOAN_STOCK_SHARE_BPS = 7000; // interest: 70% -> feeSink (stock), 30% -> floor

    uint256 constant MIN_OUT_BPS = 9700; // DonFeeRouter slippage floor (>= 9000 enforced)

    /// The 5-tier 666-motif ladder (founder: match the reference desk's 5 rungs + 1.25x, 66,666-scaled fees).
    function _ladder() internal pure returns (uint256[] memory fees, uint256[] memory weights) {
        fees = new uint256[](5);
        weights = new uint256[](5);
        (fees[0], weights[0]) = (66_666e18, 100);
        (fees[1], weights[1]) = (166_666e18, 125);
        (fees[2], weights[2]) = (366_666e18, 160);
        (fees[3], weights[3]) = (666_666e18, 200);
        (fees[4], weights[4]) = (1_666_666e18, 333);
    }

    struct Config {
        address admin;
        address treasury;
        address seeder;
        address guardian;
        IERC20 essey;
        IERC20 usdg;
        IConverter converter;
        address defaultPayout;
        uint256 minRing;
        uint256 reserveCap; // 500 team/partners + 2,222 AMM float
        uint256 rerollFee; // wei, ~$3
        uint256 customFee; // wei, ~$10
        uint256 donPrice; // exchange price minimum (= the 300k floor at full funding)
        address weth; // 0 = skip the fee router for now
        address ethFeed;
        address usdgFeed;
        address swapRouter;
        address sequencerFeed;
    }

    struct Deployed {
        DonDistributor distributor;
        Don don;
        DonReserve reserve;
        Bell bell;
        DonFeeRouter feeRouter; // address(0) if the route env isn't wired yet
        DonExchange exchange;
        DonLoan loan;
    }

    function _configFromEnv() internal view returns (Config memory c) {
        c.admin = vm.envOr("ADMIN", msg.sender);
        c.treasury = vm.envOr("TREASURY", c.admin);
        c.seeder = vm.envOr("SEEDER", c.admin);
        c.guardian = vm.envOr("GUARDIAN", c.admin); // the freeze-only multisig; 0 = deploy immutable
        c.essey = IERC20(vm.envOr("ESSEY", address(0))); // 0 = deploy a FRESH 8.888B EsseyToken (the Dons-era supply)
        c.usdg = IERC20(vm.envAddress("USDG"));
        c.converter = IConverter(vm.envOr("CONVERTER", address(0)));
        c.defaultPayout = vm.envOr("DEFAULT_PAYOUT", address(0));
        c.minRing = vm.envOr("MIN_RING", uint256(10e6));
        c.reserveCap = vm.envOr("RESERVE_CAP", uint256(2722));
        c.rerollFee = vm.envOr("REROLL_FEE_WEI", uint256(0.00075 ether));
        c.customFee = vm.envOr("CUSTOM_FEE_WEI", uint256(0.0025 ether));
        c.donPrice = vm.envOr("DON_PRICE", uint256(300_000e18));
        c.weth = vm.envOr("WETH", address(0));
        c.ethFeed = vm.envOr("ETH_FEED", address(0));
        c.usdgFeed = vm.envOr("USDG_FEED", address(0));
        c.swapRouter = vm.envOr("SWAP_ROUTER", address(0));
        c.sequencerFeed = vm.envOr("SEQUENCER_FEED", address(0));
    }

    /// The whole sequence, callable from tests for a broadcast-free dry run.
    function deployAll(Config memory c) public returns (Deployed memory d) {
        // The Dons era ships its own token generation: fresh 8,888,888,888e18 supply, minted to treasury.
        if (address(c.essey) == address(0)) c.essey = IERC20(address(new EsseyToken(c.treasury)));
        d.distributor = new DonDistributor(c.admin, c.reserveCap, ROOT_TIMELOCK, c.rerollFee, c.customFee, 0);
        d.don = new Don("Essey Dons", "DON", MAX_SUPPLY, address(d.distributor));
        d.reserve = new DonReserve(c.essey, IERC721(address(d.don)));
        (uint256[] memory fees, uint256[] memory weights) = _ladder();
        d.bell = new Bell(
            ISeatLike(address(d.don)), c.essey, c.usdg, c.treasury, c.minRing, TIP_BPS, fees, weights,
            c.converter, c.defaultPayout
        );

        bool routeWired = c.weth != address(0) && c.ethFeed != address(0) && c.usdgFeed != address(0)
            && c.swapRouter != address(0);
        if (routeWired) {
            d.feeRouter = new DonFeeRouter(
                DonFeeRouter.Config({
                    essey: c.essey,
                    usdg: c.usdg,
                    weth: IWETH(c.weth),
                    bell: address(d.bell),
                    admin: c.admin,
                    router: ISwapRouter(c.swapRouter),
                    ethPoolFee: 3000,
                    esseyPoolFee: 3000,
                    minOutBps: MIN_OUT_BPS,
                    ethFeed: AggregatorV3Interface(c.ethFeed),
                    usdgFeed: AggregatorV3Interface(c.usdgFeed),
                    sequencerUptimeFeed: AggregatorV3Interface(c.sequencerFeed)
                })
            );
        }
        // feeSink: the router when wired, else the treasury as a LOUD interim (admin re-points later —
        // setFeeSink is not one-shot precisely for this).
        address sink = routeWired ? address(d.feeRouter) : c.treasury;

        d.exchange = new DonExchange(
            IERC721(address(d.don)), c.essey, IDonFloor(address(d.reserve)), sink, c.treasury, c.seeder,
            c.donPrice, SWAP_FEE_BPS, SNIPE_FEE_BPS, STOCK_SHARE_BPS, c.guardian
        );
        d.loan = new DonLoan(c.essey, d.don, d.reserve, sink, c.treasury, LTV_BPS, LIQ_THRESHOLD_BPS, RATE_BPS, LIQ_TIP_BPS, LOAN_STOCK_SHARE_BPS, c.guardian);

        // One-shot wiring (broadcaster must be admin; on a multisig deploy these are ITS txs).
        d.distributor.initDon(d.don);
        d.distributor.setDonHook(address(d.bell));
        d.distributor.setBell(address(d.bell));
        d.distributor.setDonLienManager(address(d.loan));
        d.distributor.setFeeSink(sink);
        d.distributor.setTreasury(c.treasury);
    }

    function run() external {
        Config memory c = _configFromEnv();
        require(msg.sender == c.admin, "broadcaster must be ADMIN (one-shot wiring runs in-script)");
        vm.startBroadcast();
        Deployed memory d = deployAll(c);
        vm.stopBroadcast();

        console.log("essey       ", address(c.essey));
        console.log("distributor ", address(d.distributor));
        console.log("don         ", address(d.don));
        console.log("reserve     ", address(d.reserve));
        console.log("bell        ", address(d.bell));
        console.log("feeRouter   ", address(d.feeRouter));
        console.log("exchange    ", address(d.exchange));
        console.log("loan        ", address(d.loan));
        console.log("");
        console.log("POST-DEPLOY (founder-approved ops, in order):");
        console.log(" 1. essey.approve(reserve) + reserve.fund(2_666_666_666e18)  -> 300k floor");
        console.log(" 2. distributor.mintReserved(seeder, combos[2222]) in batches + exchange.seed(ids)");
        console.log(" 3. essey.approve(loan) + loan.fund(<founder-sized pot>)");
        console.log(" 4. distributor.proposeRoot(stage, 0x836f5ce5...) ; commitRoot after the 2-day timelock");
        console.log(" 5. distributor.setPublicOpen(true) when the mint goes live");
        if (address(d.feeRouter) == address(0)) {
            console.log("NOTE: fee route env unset -> feeSink=TREASURY (interim). Wire DonFeeRouter, then");
            console.log("      distributor.setFeeSink(router). The exchange AND loan feeSinks are IMMUTABLE = treasury");
            console.log("      until a redeploy - wire WETH/ETH_FEED/USDG_FEED/SWAP_ROUTER before mainnet.");
        }
    }
}
