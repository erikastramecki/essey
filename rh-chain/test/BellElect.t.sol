// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Don} from "../src/market/Don.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {StockConverter} from "../src/market/StockConverter.sol";
import {IConverter, ISwapRouter} from "../src/market/IConverter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "./RiskModules.t.sol";
import {MockRouter} from "./StockConverter.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// Clock-In 2.0 — the elect-up-to-3-stocks payout path, proven on the REAL Don (the ISeatLike
/// generalization) with the REAL StockConverter enforcing oracle fairness per slice.
contract BellElectTest is Test {
    // Monday 15:00 UTC — inside the conservative US session window.
    uint256 constant MON_IN_SESSION = 1_753_110_000;

    Don don;
    Bell bell;
    StockConverter conv;
    MockRouter router;
    ERC20Mock usdg;
    ERC20Mock essey;
    ERC20Mock stockA;
    ERC20Mock stockB;
    ERC20Mock stockC;
    MockFeed feedA;
    MockFeed feedB;
    MockFeed feedC;

    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256[] fees = [100e18, 250e18, 500e18, 1500e18];
    uint256[] weights = [100, 160, 200, 333];

    function setUp() public {
        vm.warp(MON_IN_SESSION);

        usdg = new ERC20Mock();
        essey = new ERC20Mock();
        stockA = new ERC20Mock();
        stockB = new ERC20Mock();
        stockC = new ERC20Mock();
        MockFeed baseFeed = new MockFeed(1e8, 8); // $1
        feedA = new MockFeed(200e8, 8); // all three stocks $200, so one fair router rate serves all
        feedB = new MockFeed(200e8, 8);
        feedC = new MockFeed(200e8, 8);

        router = new MockRouter(5e15); // 1 USDG -> 1/200 share
        stockA.mint(address(router), 1_000_000e18);
        stockB.mint(address(router), 1_000_000e18);
        stockC.mint(address(router), 1_000_000e18);

        conv = new StockConverter(
            router, usdg, AggregatorV3Interface(address(baseFeed)), AggregatorV3Interface(address(0)), 100, address(this)
        );
        conv.listStock(address(stockA), AggregatorV3Interface(address(feedA)), 3000);
        conv.listStock(address(stockB), AggregatorV3Interface(address(feedB)), 3000);
        conv.listStock(address(stockC), AggregatorV3Interface(address(feedC)), 3000);

        don = new Don("Essey Don", "DON", 8888, address(this)); // test = minter
        bell = new Bell(ISeatLike(address(don)), essey, usdg, treasury, 100e18, 100, fees, weights, conv, address(0));
        don.setHook(address(bell));

        essey.mint(alice, 10_000e18);
        vm.prank(alice);
        essey.approve(address(bell), type(uint256).max);
    }

    function _activatedDon() internal returns (uint256 id) {
        id = don.mint(alice, keccak256(abi.encode(don.totalMinted() + 1)));
        vm.prank(alice);
        bell.activate(id, 1);
    }

    /// One activated Don, 1000 USDG rung: tip 10, pending 990.
    function _rungDon() internal returns (uint256 id) {
        id = _activatedDon();
        usdg.mint(address(bell), 1000e18);
        bell.ring();
        assertEq(bell.pendingOf(id), 990e18);
    }

    function _elect3(uint256 id) internal {
        address[] memory toks = new address[](3);
        toks[0] = address(stockA);
        toks[1] = address(stockB);
        toks[2] = address(stockC);
        uint16[] memory bps = new uint16[](3);
        bps[0] = 3333;
        bps[1] = 3333;
        bps[2] = 3334;
        vm.prank(alice);
        bell.setPayout(id, toks, bps);
    }

    // ---------------------------------------------------------------- validation

    function test_SetPayoutValidation() public {
        uint256 id = _activatedDon();

        address[] memory toks = new address[](1);
        toks[0] = address(stockA);
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;

        vm.prank(bob); // not the owner
        vm.expectRevert(Bell.NotSeatOwner.selector);
        bell.setPayout(id, toks, bps);

        // length mismatch
        uint16[] memory bps2 = new uint16[](2);
        bps2[0] = 5000;
        bps2[1] = 5000;
        vm.prank(alice);
        vm.expectRevert(Bell.TooManyElections.selector);
        bell.setPayout(id, toks, bps2);

        // more than 3 elections
        address[] memory toks4 = new address[](4);
        uint16[] memory bps4 = new uint16[](4);
        for (uint256 i = 0; i < 4; i++) {
            toks4[i] = address(stockA);
            bps4[i] = 2500;
        }
        vm.prank(alice);
        vm.expectRevert(Bell.TooManyElections.selector);
        bell.setPayout(id, toks4, bps4);

        // unsupported token
        address[] memory badTok = new address[](1);
        badTok[0] = address(essey);
        vm.prank(alice);
        vm.expectRevert(Bell.UnsupportedPayoutToken.selector);
        bell.setPayout(id, badTok, bps);

        // zero-weight slice
        bps[0] = 0;
        vm.prank(alice);
        vm.expectRevert(Bell.BadElectionWeights.selector);
        bell.setPayout(id, toks, bps);

        // weights must sum to exactly 10000
        bps[0] = 9999;
        vm.prank(alice);
        vm.expectRevert(Bell.BadElectionWeights.selector);
        bell.setPayout(id, toks, bps);
    }

    function test_SetPayoutRequiresConverter() public {
        Bell bare = new Bell(
            ISeatLike(address(don)), essey, usdg, treasury, 100e18, 100, fees, weights, IConverter(address(0)), address(0)
        );
        uint256 id = don.mint(alice, keccak256("bare"));
        address[] memory toks = new address[](1);
        toks[0] = address(stockA);
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        vm.prank(alice);
        vm.expectRevert(Bell.UnsupportedPayoutToken.selector);
        bare.setPayout(id, toks, bps);
    }

    function test_DefaultPayoutMustBeSupportedAtDeploy() public {
        vm.expectRevert(Bell.BadConfig.selector);
        new Bell(
            ISeatLike(address(don)), essey, usdg, treasury, 100e18, 100, fees, weights, conv, address(essey)
        ); // essey is not a listed payout target — caught at deploy, not silently at claim
    }

    // ---------------------------------------------------------------- the 3-way split

    function test_ClaimSplitsAcrossThreeStocksExactly() public {
        uint256 id = _rungDon();
        _elect3(id);
        assertEq(bell.electionCount(id), 3);

        bell.claim(id);
        address vault = don.vaultOf(id);

        // 990 split 3333/3333/3334; last slice takes the remainder, all at $200/share.
        uint256 sliceA = (990e18 * 3333) / 10_000;
        uint256 sliceB = (990e18 * 3333) / 10_000;
        uint256 sliceC = 990e18 - sliceA - sliceB;
        assertEq(stockA.balanceOf(vault), (sliceA * 5e15) / 1e18);
        assertEq(stockB.balanceOf(vault), (sliceB * 5e15) / 1e18);
        assertEq(stockC.balanceOf(vault), (sliceC * 5e15) / 1e18);
        assertEq(usdg.balanceOf(vault), 0, "everything delivered as stock");
        assertEq(bell.reserved(), 0, "claim fully settled");
        assertEq(usdg.balanceOf(address(bell)), 0, "tip left at ring, the rest converted - nothing stranded");
        assertEq(usdg.allowance(address(bell), address(conv)), 0, "no standing allowance");
    }

    /// Per-slice fail-open: one stale stock leaves THAT slice paid in base; the other two still convert.
    function test_OneStaleSliceFallsBackAlone() public {
        uint256 id = _rungDon();
        _elect3(id);

        feedB.set(200e8, block.timestamp - 2 days); // B's feed goes silent

        bell.claim(id);
        address vault = don.vaultOf(id);

        uint256 sliceA = (990e18 * 3333) / 10_000;
        uint256 sliceC = 990e18 - sliceA - sliceA;
        assertEq(stockA.balanceOf(vault), (sliceA * 5e15) / 1e18, "A converted");
        assertEq(stockB.balanceOf(vault), 0, "B declined");
        assertEq(usdg.balanceOf(vault), sliceA, "B's slice fell back to base - payout never blocked");
        assertEq(stockC.balanceOf(vault), (sliceC * 5e15) / 1e18, "C converted");
    }

    /// Whole-router outage: every slice falls back; the claim still settles in full, in base.
    function test_RouterDownFallsBackEverySlice() public {
        uint256 id = _rungDon();
        _elect3(id);
        router.setFail(true);

        bell.claim(id);
        assertEq(usdg.balanceOf(don.vaultOf(id)), 990e18, "full amount in base - never blocked");
        assertEq(bell.reserved(), 0);
    }

    // ---------------------------------------------------------------- wrapper + default

    function test_SetPayoutTokenWrapperAndClear() public {
        uint256 id = _activatedDon();

        vm.prank(alice);
        bell.setPayoutToken(id, address(stockA));
        assertEq(bell.electionCount(id), 1);
        assertEq(bell.payoutTokenOf(id), address(stockA));

        vm.prank(bob);
        vm.expectRevert(Bell.NotSeatOwner.selector);
        bell.setPayoutToken(id, address(0)); // clearing is owner-gated too

        vm.prank(alice);
        bell.setPayoutToken(id, address(0));
        assertEq(bell.electionCount(id), 0);
        assertEq(bell.payoutTokenOf(id), address(0));
    }

    function test_DefaultPayoutPaysStockWhenUnset() public {
        Bell defBell = new Bell(
            ISeatLike(address(don)), essey, usdg, treasury, 100e18, 100, fees, weights, conv, address(stockA)
        );
        uint256 id = don.mint(alice, keccak256("default"));
        vm.startPrank(alice);
        essey.approve(address(defBell), type(uint256).max);
        defBell.activate(id, 1);
        vm.stopPrank();
        usdg.mint(address(defBell), 1000e18);
        defBell.ring();

        defBell.claim(id);
        address vault = don.vaultOf(id);
        assertEq(stockA.balanceOf(vault), (990e18 * 5e15) / 1e18, "unset election -> the BUNDLE/default stock");
        assertEq(usdg.balanceOf(vault), 0);
    }

    // ---------------------------------------------------------------- per-owner lifecycle

    function test_ElectionClearsOnTransfer() public {
        uint256 id = _rungDon();
        _elect3(id);

        vm.prank(alice);
        don.transferFrom(alice, bob, id);
        assertEq(bell.electionCount(id), 0, "payout preference is per-owner, like the tier");

        // rewards persist and now pay base (no election, no defaultPayout)
        bell.claim(id);
        assertEq(usdg.balanceOf(don.vaultOf(id)), 990e18, "earned rewards unaffected by the clear");
    }

    /// Slices always conserve the claim: for ANY 2-way weight split, converted value + base fallback
    /// equals the full amount (remainder-to-last kills rounding leaks).
    function testFuzz_SliceConservation(uint16 w) public {
        uint16 wA = uint16(bound(w, 1, 9999));
        uint256 id = _rungDon();
        address[] memory toks = new address[](2);
        toks[0] = address(stockA);
        toks[1] = address(stockB);
        uint16[] memory bps = new uint16[](2);
        bps[0] = wA;
        bps[1] = 10_000 - wA;
        vm.prank(alice);
        bell.setPayout(id, toks, bps);

        bell.claim(id);
        address vault = don.vaultOf(id);
        uint256 sliceA = (990e18 * uint256(wA)) / 10_000;
        uint256 sliceB = 990e18 - sliceA;
        // stock is delivered at exactly amount/200 with this router, so invert to USDG terms
        assertEq(stockA.balanceOf(vault) * 200 + stockB.balanceOf(vault) * 200, sliceA + sliceB, "no value lost to slicing");
        assertEq(bell.reserved(), 0);
    }
}
