// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EsseyPool} from "../src/EsseyPool.sol";
import {EsseyPoolTest} from "./EsseyPool.t.sol";
import {Seat} from "../src/market/Seat.sol";
import {Bell} from "../src/market/Bell.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// Loan-interest -> Bell routing: the third fee engine. Inherits the full pool harness and swaps in
/// a rate-bearing pool with a real Bell wired (reward == pool asset, proven by the constructor).
contract EsseyPoolSkimTest is EsseyPoolTest, IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector; // the e2e test mints a Seat to this contract
    }

    EsseyPool rpool; // the rate-bearing, Bell-wired pool under test (parent pool left untouched)
    Seat seat;
    ERC20Mock essey;
    Bell bell;
    address TREASURY;
    address BOB;

    uint256 constant BELL_SHARE = 5_000; // 50% of skimmed reserves -> the pot

    function setUp() public override {
        super.setUp();
        TREASURY = makeAddr("reserveTreasury");
        BOB = makeAddr("bob");

        seat = new Seat("Essey Seat", "SEAT", 2222, address(this));
        essey = new ERC20Mock();
        uint256[] memory fees = new uint256[](1);
        fees[0] = 100e18;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;
        // Bell rewards in USDG — the same asset the pool lends, so the skim is a plain pot-growing
        // transfer (the coherence the pool constructor enforces).
        bell = new Bell(seat, essey, usdg, TREASURY, 1e4, 100, fees, weights, IConverter(address(0))); // minRing 0.01 USDG

        // A second pool alongside the parent's zero-rate one (so inherited tests still pass
        // untouched): 10% APR base PLUS a real slope — a flat curve would make the rate-invariance
        // assertion vacuous (audit R2 note: the rate leg must actually depend on utilization).
        rpool = new EsseyPool(usdg, mk, 1_000, 2_000, 0, 2_000, address(bell), TREASURY, BELL_SHARE);
        vm.startPrank(LENDER);
        usdg.approve(address(rpool), type(uint256).max);
        rpool.deposit(400_000e6, LENDER); // parent already deposited 500k of LENDER's 1M elsewhere
        vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(rpool), type(uint256).max);
        usdg.approve(address(rpool), type(uint256).max);
        vm.stopPrank();
    }

    function _rborrow(uint256 debt) internal returns (uint256 id) {
        vm.prank(ALICE);
        id = rpool.borrow(address(tok), 10e18, debt);
    }

    /// Borrow, let a month of interest accrue, then skim from an uninvolved address.
    function _accrueReserves() internal returns (uint256 reserves) {
        _rborrow(700e6);
        _advanceLive(30 days);
        rpool.accrue();
        reserves = rpool.totalReserves();
        assertGt(reserves, 0, "a month at 10% APR must reserve something");
    }

    function test_SkimSplitsToBellAndTreasury() public {
        uint256 reserves = _accrueReserves();
        uint256 potBefore = bell.pot();
        uint256 treBefore = usdg.balanceOf(TREASURY);

        vm.prank(BOB); // permissionless, like ringing the Bell
        (uint256 toBell, uint256 toTreasury) = rpool.skimReserves();

        assertEq(toBell + toTreasury, reserves, "whole reserve routed, no dust left behind");
        assertEq(toBell, (reserves * BELL_SHARE) / 10_000, "half to the pot");
        assertEq(bell.pot() - potBefore, toBell, "the Bell counts it");
        assertEq(usdg.balanceOf(TREASURY) - treBefore, toTreasury);
        assertEq(rpool.totalReserves(), 0, "claim fully settled");
    }

    /// The lender-safety property, asserted directly: a skim moves cash and totalReserves in
    /// lockstep, so totalAssets — and therefore the share price — cannot move.
    function test_SkimLeavesSharePriceUntouched() public {
        _accrueReserves();
        uint256 assetsBefore = rpool.totalAssets();
        uint256 shareValueBefore = rpool.convertToAssets(1e6);
        rpool.skimReserves();
        assertEq(rpool.totalAssets(), assetsBefore, "lender claim untouched");
        assertEq(rpool.convertToAssets(1e6), shareValueBefore, "share price untouched");
    }

    /// Reserves are a claim on cash + borrows; only the cash part can move today. The rest waits
    /// for repayments like any other claim on a levered pool.
    function test_SkimIsCashBounded() public {
        uint256 reserves = _accrueReserves();
        // Lender pulls almost all idle cash so reserves exceed what's skimmable.
        uint256 cash = usdg.balanceOf(address(rpool));
        vm.prank(LENDER);
        rpool.withdraw(cash - reserves / 3, LENDER, LENDER);

        uint256 cashNow = usdg.balanceOf(address(rpool));
        assertLt(cashNow, reserves, "reserves now exceed cash");
        // Rate invariance must hold in THIS regime too (reserves > cash: u pins at 100% both sides).
        uint256 uBefore = rpool.utilizationBps();
        uint256 rateBefore = rpool.borrowRateBps();
        (uint256 toBell, uint256 toTreasury) = rpool.skimReserves();
        assertEq(rpool.utilizationBps(), uBefore, "u invariant across a cash-bounded skim");
        assertEq(rpool.borrowRateBps(), rateBefore, "rate invariant across a cash-bounded skim");
        assertEq(toBell + toTreasury, cashNow, "took exactly the cash");
        assertEq(rpool.totalReserves(), reserves - cashNow, "remainder still owed to the protocol");
    }

    function test_SkimWithNoReservesIsNoop() public {
        (uint256 toBell, uint256 toTreasury) = rpool.skimReserves();
        assertEq(toBell, 0);
        assertEq(toTreasury, 0);
    }

    /// No Bell wired (pre-market-layer deploys): the whole skim goes to the treasury, even with a
    /// nonzero share configured.
    function test_NoBellMeansAllToTreasury() public {
        EsseyPool p2 = new EsseyPool(usdg, mk, 1_000, 0, 0, 2_000, address(0), TREASURY, BELL_SHARE);
        usdg.mint(address(this), 1_000e6);
        usdg.approve(address(p2), type(uint256).max);
        p2.deposit(1_000e6, address(this));
        // Manufacture reserves without a borrow: accrual needs borrows, so borrow via ALICE.
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max);
        p2.borrow(address(tok), 10e18, 300e6);
        vm.stopPrank();
        _advanceLive(30 days);
        p2.accrue();
        uint256 reserves = p2.totalReserves();
        assertGt(reserves, 0);
        uint256 treBefore = usdg.balanceOf(TREASURY);
        (uint256 toBell, uint256 toTreasury) = p2.skimReserves();
        assertEq(toBell, 0, "no sink, no Bell leg");
        assertEq(toTreasury, reserves);
        assertEq(usdg.balanceOf(TREASURY) - treBefore, reserves);
    }

    function test_ConstructorGuards() public {
        // Zero treasury rejected.
        vm.expectRevert(EsseyPool.BadSink.selector);
        new EsseyPool(usdg, mk, 0, 0, 0, 0, address(0), address(0), 0);
        // Share above 100% rejected.
        vm.expectRevert(EsseyPool.BadSink.selector);
        new EsseyPool(usdg, mk, 0, 0, 0, 0, address(bell), TREASURY, 10_001);
        // A Bell whose reward is NOT the pool asset is un-deployable — fees would vanish from its pot.
        Bell wrongReward;
        {
            uint256[] memory f = new uint256[](1);
            f[0] = 1e18;
            uint256[] memory w = new uint256[](1);
            w[0] = 1;
            wrongReward = new Bell(seat, usdg, essey, TREASURY, 1e18, 100, f, w, IConverter(address(0)));
        }
        vm.expectRevert(EsseyPool.BadSink.selector);
        new EsseyPool(usdg, mk, 0, 0, 0, 0, address(wrongReward), TREASURY, BELL_SHARE);
    }

    /// The F-1 fix, asserted directly: the borrow rate is skim-timing-invariant, because
    /// utilization never counted the skimmable reserve cash as lendable in the first place.
    function test_BorrowRateInvariantAcrossSkim() public {
        _accrueReserves();
        uint256 rateBefore = rpool.borrowRateBps();
        uint256 uBefore = rpool.utilizationBps();
        rpool.skimReserves();
        assertEq(rpool.borrowRateBps(), rateBefore, "skim must not move the rate");
        assertEq(rpool.utilizationBps(), uBefore, "skim must not move utilization");
    }

    /// Boundary shares: 0 (all treasury even with a sink) and 10_000 (all Bell) through a real skim.
    function test_BoundaryShareConfigs() public {
        EsseyPool allBell = new EsseyPool(usdg, mk, 1_000, 0, 0, 2_000, address(bell), TREASURY, 10_000);
        EsseyPool noBell = new EsseyPool(usdg, mk, 1_000, 0, 0, 2_000, address(bell), TREASURY, 0);
        for (uint256 i = 0; i < 2; i++) {
            EsseyPool p = i == 0 ? allBell : noBell;
            usdg.mint(address(this), 10_000e6);
            usdg.approve(address(p), type(uint256).max);
            p.deposit(10_000e6, address(this));
            vm.startPrank(ALICE);
            tok.approve(address(p), type(uint256).max);
            p.borrow(address(tok), 10e18, 300e6);
            vm.stopPrank();
        }
        _advanceLive(30 days);
        (uint256 b1, uint256 t1) = allBell.skimReserves();
        assertGt(b1, 0);
        assertEq(t1, 0, "share=BPS: everything to the Bell");
        (uint256 b2, uint256 t2) = noBell.skimReserves();
        assertEq(b2, 0, "share=0: nothing to the Bell");
        assertGt(t2, 0);
    }

    /// Partial skim settles its remainder once repayments replenish cash; the event reports honestly.
    function test_SecondSkimSettlesRemainder() public {
        uint256 reserves = _accrueReserves();
        uint256 cash = usdg.balanceOf(address(rpool));
        vm.prank(LENDER);
        rpool.withdraw(cash - reserves / 3, LENDER, LENDER);
        rpool.skimReserves(); // cash-bounded partial
        uint256 owed = rpool.totalReserves();
        assertGt(owed, 0, "remainder outstanding");

        // Borrower repays -> cash returns -> the remainder settles. Expect the event with real values.
        usdg.mint(ALICE, 1_000e6);
        uint256 debt = rpool.debtOf(1) + 1e6; // outside the prank — the view call would consume it
        vm.prank(ALICE);
        rpool.repay(1, debt);
        vm.expectEmit(true, false, false, true);
        emit EsseyPool.ReservesSkimmed(address(this), (owed * BELL_SHARE) / 10_000, owed - (owed * BELL_SHARE) / 10_000);
        (uint256 toBell, uint256 toTreasury) = rpool.skimReserves();
        assertEq(toBell + toTreasury, owed, "remainder fully settled");
        assertEq(rpool.totalReserves(), 0);
    }

    /// End-to-end: borrower interest becomes a ringable pot becomes stock-denominated Payouts —
    /// the engine that outlasts launch trade-fees, exercised whole.
    function test_LoanInterestReachesSeatVaults() public {
        _accrueReserves();
        rpool.skimReserves();
        uint256 pot = bell.pot();
        assertGt(pot, 0, "interest landed in the pot");

        uint256 seatId = seat.mint(address(this));
        essey.mint(address(this), 1_000e18);
        essey.approve(address(bell), type(uint256).max);
        bell.activate(seatId, 1);
        bell.ring();
        bell.claim(seatId);
        assertGt(usdg.balanceOf(seat.vaultOf(seatId)), 0, "borrower interest reached a Seat's Vault");
    }
}
