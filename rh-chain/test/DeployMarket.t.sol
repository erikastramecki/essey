// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployMarket} from "../script/DeployMarket.s.sol";
import {Seat} from "../src/market/Seat.sol";
import {SeatArt} from "../src/market/SeatArt.sol";
import {MintDistributor} from "../src/market/MintDistributor.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "./RiskModules.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// The launch dry run: execute the REAL deploy script's sequence (no broadcast), then live one full
/// protocol day against the freshly-wired system — whitelist mint, float seed, a trade feeding the
/// pot, a Case open, a ring, a claim into a Vault, and the art rendering the earned tier. If any
/// wiring guard or launch constant is wrong, this is where it fails — not on Robinhood Chain.
contract DeployMarketTest is Test, IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    DeployMarket script;
    DeployMarket.Deployed d;
    SeatArt art;
    ERC20Mock usdg;
    MockFeed usdgFeed;

    address alice = address(0xA11CE);

    // Wednesday in-session (the Cases leg needs a live equity session for sell-backs only; buys and
    // opens are session-free — but keep the clock realistic anyway).
    uint256 constant IN_SESSION_TS = 1_736_348_400;

    function setUp() public {
        vm.warp(IN_SESSION_TS);
        vm.roll(1000);
        usdg = new ERC20Mock();
        usdgFeed = new MockFeed(1e8, 8);

        script = new DeployMarket();
        DeployMarket.Config memory c;
        c.admin = address(this);
        c.treasury = address(0x7EA);
        c.seeder = address(this);
        c.bankroll = address(this);
        c.usdg = IERC20(address(usdg));
        c.usdgFeed = AggregatorV3Interface(address(usdgFeed));
        c.sequencerFeed = AggregatorV3Interface(address(0));
        c.converter = IConverter(address(0));
        c.reserveCap = 1311;
        c.minRing = 10e18; // mock USDG is 18-dec
        c.seatPrice = 500e18;
        c.swapFee = 10e18;
        c.snipeFee = 15e18;
        c.sellFee = 8e18;
        c.casePrice = 100e18;
        c.caseBuyFee = 5e18;

        d = script.deployAll(c);
        // The wiring one-shots act on contracts whose admin/minter is THIS test (c.admin), but the
        // script contract would be msg.sender if it called them — replicate the multisig path: the
        // admin executes the wiring itself.
        d.distributor.initSeat(d.seat);
        d.distributor.setSeatHook(address(d.bell));
        art = new SeatArt(d.seat, d.bell);
        d.distributor.setSeatArt(address(art));
    }

    function test_WiringGuardsAllHold() public view {
        assertEq(d.seat.minter(), address(d.distributor), "distributor is the only minter, forever");
        assertEq(d.seat.hook(), address(d.bell), "the Bell clears tiers on resale");
        assertEq(d.seat.art(), address(art), "on-chain art wired");
        assertEq(address(d.bell.seat()), address(d.seat), "bell serves this collection");
        assertEq(address(d.exchange.bell()), address(d.bell), "exchange fees feed this pot");
        assertEq(d.essey.balanceOf(address(0x7EA)), d.essey.totalSupply(), "all supply at treasury");
        assertEq(d.seat.maxSupply(), 2222);
    }

    function test_ArtBeforeHookRefusesToDeploy() public {
        // The guard that caught the script's own first draft: art cannot exist pre-hook.
        DeployMarket.Config memory c;
        c.admin = address(this);
        c.treasury = address(0x7EA);
        c.seeder = address(this);
        c.bankroll = address(this);
        c.usdg = IERC20(address(usdg));
        c.usdgFeed = AggregatorV3Interface(address(usdgFeed));
        c.reserveCap = 10;
        c.minRing = 1e18;
        c.seatPrice = 1e18;
        c.snipeFee = 1e18;
        c.casePrice = 1e18;
        DeployMarket.Deployed memory d2 = script.deployAll(c);
        vm.expectRevert(SeatArt.BellIsNotTheHook.selector);
        new SeatArt(d2.seat, d2.bell);
    }

    /// One full protocol day on the freshly-deployed system.
    function test_LaunchDayEndToEnd() public {
        address treasury = address(0x7EA);

        // 1. Float: admin mints reserved Seats to the seeder and seeds the Exchange.
        d.distributor.mintReserved(address(this), 5);
        uint256[] memory ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = i + 1;
        }
        d.seat.setApprovalForAll(address(d.exchange), true);
        d.exchange.seed(ids);
        assertEq(d.exchange.inventoryCount(), 5);

        // 2. Whitelist: root proposed, reviewed for the timelock, committed; alice claims her Seat.
        bytes32 leaf = d.distributor.leafOf(alice, 0, 1);
        d.distributor.proposeRoot(0, leaf); // single-leaf tree: root == leaf
        vm.warp(block.timestamp + 2 days);
        d.distributor.commitRoot(0);
        d.distributor.setStageOpen(0, true);
        vm.prank(alice);
        uint256 aliceSeat = d.distributor.claim(0, 1, new bytes32[](0));
        assertEq(d.seat.ownerOf(aliceSeat), alice, "earned, not bought");

        // 3. Funding: treasury distributes $ESSEY; alice buys a Case and a Seat off the float.
        vm.prank(treasury);
        d.essey.transfer(alice, 10_000e18);
        usdg.mint(alice, 1_000e18);
        vm.startPrank(alice);
        d.essey.approve(address(d.exchange), type(uint256).max);
        usdg.approve(address(d.exchange), type(uint256).max);
        d.essey.approve(address(d.cases_), type(uint256).max);
        usdg.approve(address(d.cases_), type(uint256).max);
        d.essey.approve(address(d.bell), type(uint256).max);
        vm.stopPrank();

        // Case inventory backing first (provably-solvent bankroll).
        ERC20Mock aapl = new ERC20Mock();
        MockFeed aaplFeed = new MockFeed(200e8, 8);
        d.cases_.listStock(address(aapl), AggregatorV3Interface(address(aaplFeed)), 5e17);
        aapl.mint(address(this), 10e18);
        aapl.approve(address(d.cases_), type(uint256).max);
        d.cases_.seedUnits(address(aapl), 3);

        vm.startPrank(alice);
        uint256 bought = d.exchange.buy(); // fee -> the pot
        uint256 caseId = d.cases_.buy(); // fee -> the pot
        vm.stopPrank();
        vm.roll(block.number + 2);
        vm.prank(alice);
        (address wonToken,) = d.cases_.open(caseId);
        assertEq(wonToken, address(aapl), "real stock delivered");

        // 4. Tier + the Bell: alice stakes her bought Seat, anyone rings, payout lands in the Vault.
        vm.prank(alice);
        d.bell.activate(bought, 1);
        assertGt(d.bell.pot(), 0, "trading and cases funded the pot");
        vm.prank(address(0xBEEF)); // the ring is anyone's
        d.bell.ring();
        d.bell.claim(bought);
        assertGt(usdg.balanceOf(d.seat.vaultOf(bought)), 0, "fees became a Payout in the Seat's Vault");

        // 5. The art tells the truth: the staked Seat renders its tier; alice's unstaked one is Base.
        assertTrue(
            keccak256(bytes(d.seat.tokenURI(bought))) != keccak256(bytes(d.seat.tokenURI(aliceSeat))),
            "staked and unstaked Seats render differently"
        );
    }
}
