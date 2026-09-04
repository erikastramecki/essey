// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EsseyPoolTest} from "./EsseyPool.t.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {Note} from "../src/market/Note.sol";

/// G-LEND R2 HIGH-1 and LOW-1.
///
/// The fixture is EsseyPoolTest's: 10 shares at $200 = $2,000 of collateral, ltv 3,500 /
/// liqThreshold 5,500 / bonus 800, so $700 is the max borrow and the position sits at 35% LTV
/// against a 55% threshold — unambiguously healthy, and the shape the round-2 PoC used.
contract DesyncBreakerTest is EsseyPoolTest {
    /// A split's ex-date reprices the Chainlink feed before the issuer's uiMultiplier transaction
    /// lands. `multiplierMovedAt` is 0 (nothing moved) and the token publishes no schedule, so the
    /// two guards that existed both answered "no desync" and a HEALTHY position was liquidated at
    /// half its true value plus the bonus.
    function test_feedFirstSplitCannotLiquidateAHealthyPosition() public {
        uint256 id = _borrow(700e6);
        assertFalse(mk.isUnderwater(address(tok), 10e18, pool.debtOf(id)), "healthy before");

        px.set(100e8, block.timestamp); // the feed halves, in one step, as at a 2:1 ex-date
        assertEq(mk.multiplierMovedAt(address(tok)), 0, "branch (b) has nothing to see");
        assertTrue(mk.isUnderwater(address(tok), 10e18, pool.debtOf(id)), "and it now READS underwater");

        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.LiquidationNotAllowed.selector, address(tok)));
        pool.liquidate(id);
    }

    /// The same gap closes new borrows, which is where the mis-valuation runs the other way.
    function test_theGapAlsoClosesBorrowing() public {
        _borrow(700e6);
        px.set(100e8, block.timestamp);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.borrow(10e18, 1e6);
    }

    /// A reverse split moves the feed UP, which over-values collateral and lets a borrower draw more
    /// than the true price allows. The breaker is absolute, not one-sided.
    function test_theBreakerFiresInTheUpDirectionToo() public {
        _borrow(100e6);
        px.set(400e8, block.timestamp);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.borrowMore(1, 100e6);
    }

    /// THE ARMING PROPERTY. There is no free first mover: the transaction that first observes the
    /// dislocation is the one refused by it, because syncMultiplier runs above the gate on every
    /// pool path. The stamp rolls back with the revert — which is also why an attacker cannot
    /// arm-and-bypass inside a single transaction.
    function test_theArmingTransactionIsItselfRefusedAndCommitsNothing() public {
        uint256 id = _borrow(700e6);
        px.set(100e8, block.timestamp);
        // The VIEW is optimistic until an observation commits; the pool's gate is not, because the
        // pool syncs first. This is the honest statement of what canLiquidate answers.
        assertTrue(mk.canLiquidate(address(tok)), "the view has not observed the gap yet");

        vm.prank(LIQUIDATOR);
        vm.expectRevert();
        pool.liquidate(id);
        assertEq(mk.priceDesyncAt(address(tok)), 0, "the arm rolled back with the revert");
    }

    /// And the observation is a permissionless act of its own, which is what starts the hold.
    function test_aStandaloneSyncCommitsTheArmAndTheHoldExpires() public {
        uint256 id = _borrow(700e6);
        px.set(100e8, block.timestamp);
        mk.syncMultiplier(address(tok));
        assertEq(mk.priceDesyncAt(address(tok)), block.timestamp, "armed");
        assertFalse(mk.canLiquidate(address(tok)), "and now the view agrees");

        _advanceLive(mk.PRICE_DESYNC_HOLD() - 1 hours);
        vm.prank(LIQUIDATOR);
        vm.expectRevert();
        pool.liquidate(id); // still held

        _advanceLive(2 hours); // past PRICE_DESYNC_HOLD
        vm.prank(LIQUIDATOR);
        pool.liquidate(id); // the bound is deliberate: it does not hold forever
        assertEq(pool.debtOf(id), 0);
    }

    /// IT CLEARS ON AGREEMENT, not only on the timer. When the issuer's second leg lands the product
    /// returns to its pre-jump value and both gates re-open in that same observation — and the
    /// position is correctly healthy again, because nothing about it actually changed.
    function test_theBreakerClearsWhenTheSecondLegLands() public {
        uint256 id = _borrow(700e6);
        px.set(100e8, block.timestamp);
        mk.syncMultiplier(address(tok));
        assertFalse(mk.canLiquidate(address(tok)));

        tok.setMultiplier(2e18); // the issuer's uiMultiplier transaction
        mk.syncMultiplier(address(tok));
        assertEq(mk.priceDesyncAt(address(tok)), 0, "cleared on agreement");
        assertEq(mk.desyncRefProduct(address(tok)), 0, "and the reference is released");
        assertFalse(mk.isUnderwater(address(tok), 10e18, pool.debtOf(id)), "healthy, as it always was");

        // Branch (b) still holds its own hour on the multiplier move itself — the two guards settle
        // independently, and the LONGER of them is what a borrower actually gets.
        assertFalse(mk.canLiquidate(address(tok)), "MULTIPLIER_GUARD_WINDOW still running");
        _advanceLive(mk.MULTIPLIER_GUARD_WINDOW());
        assertTrue(mk.canLiquidate(address(tok)), "and then both gates are open");
    }

    /// A market MOVE is not a gap. Steps inside the bound never arm, so ordinary volatility does not
    /// cost a liquidation window — the walk in _walkPrice is what every other suite relies on.
    function test_stepsInsideTheBoundNeverArm() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(60e8); // $2,000 -> $600 in observed steps
        assertEq(mk.priceDesyncAt(address(tok)), 0, "no arm from a walked move");
        assertTrue(mk.canLiquidate(address(tok)));
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        assertEq(pool.debtOf(id), 0);
    }

    /// The bound is DERIVED, and this is the exact claim it supports: it sits below the smallest
    /// under-read that can flip a position AT ORIGINATION, for the most fragile market _validate can
    /// admit. R3 HIGH-1: that is a statement about a NEW position and nothing more. A loan's cushion
    /// shrinks as the price moves against it and is zero by definition at the threshold, so for ANY
    /// bound there are open positions inside it — the previous name of this test ("no listable market
    /// can be flipped un-armed") asserted something no bound can deliver. What protects a seasoned
    /// position is isUnderwaterCorroborated, pinned in DesyncStateMachine.t.sol.
    function test_theBoundSitsBelowTheHarmThresholdOfAFRESHLYOPENEDPosition() public view {
        uint256 worstLtv = mk.MAX_LIQ_THRESHOLD_BPS() - mk.MIN_RISK_GAP_BPS();
        uint256 harmBps = 10_000 - (worstLtv * 10_000) / mk.MAX_LIQ_THRESHOLD_BPS();
        assertEq(harmBps, 2_223, "9,000 threshold over 7,000 ltv");
        assertLt(mk.MAX_PRICE_DEVIATION_BPS(), harmBps, "at origination, and only at origination");
        assertEq(mk.MAX_PRICE_DEVIATION_BPS(), 2_000);
    }

    /// The other half of the same honesty: a position seasoned to inside the bound really is
    /// flippable by a sub-bound move, and the breaker really does stay silent through it. Stated as
    /// a measurement so the residual the bound leaves is a number, not a footnote.
    function test_aSeasonedPositionSitsInsideTheBoundAndTheBreakerStaysSilent() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(130e8);
        uint256 threshold = mk.market(address(tok)).liqThresholdBps;
        uint256 flipBps = 10_000 - (700e6 * 10_000) / ((1_300e6 * threshold) / 10_000);
        assertLt(flipBps, mk.MAX_PRICE_DEVIATION_BPS(), "its cushion is now INSIDE the bound");

        px.set(117e8, block.timestamp);
        mk.syncMultiplier(address(tok));
        assertEq(mk.priceDesyncAt(address(tok)), 0, "so the breaker sees nothing");
        assertTrue(mk.isUnderwater(address(tok), 10e18, pool.debtOf(id)), "while the position reads underwater");
    }

    /// EXACT BOUNDARY on the bound itself. 2,000bps must NOT arm and one wei past it must, or the
    /// derivation above is a slogan rather than a rule — and a `>=` here silently reclassifies every
    /// 5:4 split as a corporate action.
    function test_theDeviationBoundaryIsExact() public {
        _borrow(700e6);
        // $200 -> $160 is exactly -2,000bps: diff * 10_000 == ref * 2_000, and the test is STRICTLY
        // greater, so this is the largest step that is still a market move.
        px.set(160e8, block.timestamp);
        mk.syncMultiplier(address(tok));
        assertEq(mk.priceDesyncAt(address(tok)), 0, "exactly at the bound does not arm");

        // One feed unit past it, from the $160 baseline that sync installed: 20% of 160e8 is 32e8.
        px.set(12_799_999_999, block.timestamp);
        mk.syncMultiplier(address(tok));
        assertGt(mk.priceDesyncAt(address(tok)), 0, "one unit past the bound arms");
    }

    /// EXACT BOUNDARY on the hold. The last guarded second and the first free one.
    function test_theHoldBoundaryIsExact() public {
        _borrow(700e6);
        px.set(100e8, block.timestamp);
        mk.syncMultiplier(address(tok));
        uint256 armedAt = mk.priceDesyncAt(address(tok));

        _advanceLive(mk.PRICE_DESYNC_HOLD() - 1);
        assertEq(block.timestamp, armedAt + mk.PRICE_DESYNC_HOLD() - 1);
        assertFalse(mk.canLiquidate(address(tok)), "one second short: still held");
        _advanceLive(1);
        assertEq(block.timestamp, armedAt + mk.PRICE_DESYNC_HOLD());
        assertTrue(mk.canLiquidate(address(tok)), "and free on the second itself");
    }

    /// The hold is a NUMBER, and it is the whole cost of a false positive: a genuine >20% gap costs
    /// this much unliquidatable time. Reading it from the contract inside a test proves nothing, so
    /// it is pinned against the window the design already accepts — the ~65h of a weekend that
    /// MIN_RISK_GAP_BPS is sized to absorb (see the EsseyMarkets header).
    function test_theHoldIsPinnedAndSitsInsideTheWeekendItAlreadyAbsorbs() public view {
        assertEq(mk.PRICE_DESYNC_HOLD(), 6 hours, "one US session");
        assertLt(mk.PRICE_DESYNC_HOLD(), 65 hours, "inside the unliquidatable window already carried");
        assertGt(mk.PRICE_DESYNC_HOLD(), mk.MULTIPLIER_GUARD_WINDOW(), "longer than the post-flip window");
        assertEq(mk.MAX_LIQUIDATION_PAUSE(), 24 hours);
    }

    // ---------------------------------------------------------------- the guardian's lever

    function test_guardianPauseStopsLiquidationAndExpiresOnItsOwn() public {
        uint256 id = _borrow(700e6);
        _walkPrice(60e8);
        vm.prank(GUARDIAN);
        mk.pauseLiquidation(address(tok), block.timestamp + 4 hours);
        assertFalse(mk.canLiquidate(address(tok)));
        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.LiquidationNotAllowed.selector, address(tok)));
        pool.liquidate(id);

        uint256 until = block.timestamp + 4 hours;
        _advanceLive(4 hours - 1);
        assertEq(block.timestamp, until - 1);
        assertFalse(mk.canLiquidate(address(tok)), "the last paused second");
        _advanceLive(1);
        assertEq(block.timestamp, until);
        assertTrue(mk.canLiquidate(address(tok)), "it expires without anyone lifting it");
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
    }

    /// Bounded per call, and standable-down by the same key. THIS TESTS ONE CALL, and R3 MED-3 was
    /// the gap between that and the property the old name claimed: the per-call cap said nothing
    /// about chaining, and daily calls held liquidation off forever. What makes the permanent freeze
    /// impossible is the cooldown, pinned in DesyncStateMachine.t.sol.
    function test_thePauseIsBoundedAndClearableWithinASingleCall() public {
        uint256 ceiling = block.timestamp + mk.MAX_LIQUIDATION_PAUSE();
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.PauseTooLong.selector, ceiling + 1, ceiling));
        mk.pauseLiquidation(address(tok), ceiling + 1);

        vm.startPrank(GUARDIAN);
        mk.pauseLiquidation(address(tok), ceiling); // exactly at the ceiling is allowed
        assertFalse(mk.canLiquidate(address(tok)));
        mk.pauseLiquidation(address(tok), 0); // and stood down without waiting
        vm.stopPrank();
        assertTrue(mk.canLiquidate(address(tok)));
    }

    function test_onlyAdminOrGuardianCanPause() public {
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        mk.pauseLiquidation(address(tok), block.timestamp + 1 hours);
        vm.prank(ADMIN);
        mk.pauseLiquidation(address(tok), block.timestamp + 1 hours);
        assertFalse(mk.canLiquidate(address(tok)));
    }

    /// A pause stops liquidation and NOTHING else: the borrower's exits stay open, which is the
    /// whole reason it is safe to give a hot key.
    function test_aPauseNeverBlocksTheBorrowersExit() public {
        uint256 id = _borrow(700e6);
        vm.prank(GUARDIAN);
        mk.pauseLiquidation(address(tok), block.timestamp + 4 hours);
        vm.prank(ALICE);
        pool.addCollateral(id, 1e18);
        vm.prank(ALICE);
        pool.repay(id, 700e6);
        assertEq(pool.debtOf(id), 0);
    }

    // ---------------------------------------------------------------- LOW-1: the lender's side

    /// MED-1's escrow reached repay only. A collateral-token pause left liquidate reverting outright
    /// while interest compounded, so the one path that manages risk died exactly when the issuer
    /// froze the asset.
    function test_liquidationEscrowsWhenTheCollateralCannotMove() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(60e8); // $600 backing $700: seizure takes everything, refund is 0
        tok.setPaused(true);

        vm.expectEmit(true, true, false, true, address(pool));
        emit EsseyPool.CollateralEscrowed(id, LIQUIDATOR, 10e18);
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);

        assertEq(pool.debtOf(id), 0, "the debt is settled, so it stops compounding");
        assertEq(pool.totalBorrows(), 0);
        assertEq(pool.note().ownerOf(id), LIQUIDATOR, "the deed is re-issued to the liquidator");
        assertEq(tok.balanceOf(address(pool)), 10e18, "collateral still held");
        assertEq(pool.recordedRaw(address(tok)), 10e18, "and still on the books");

        tok.setPaused(false);
        vm.prank(LIQUIDATOR);
        assertEq(pool.claimCollateral(id), 10e18);
        assertEq(pool.recordedRaw(address(tok)), 0, "books cleared on the claim");
    }

    /// The borrower must not keep a claim on a position that was fully seized.
    function test_theBorrowerCannotClaimAnEscrowedLiquidation() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(60e8);
        tok.setPaused(true);
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        tok.setPaused(false);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.claimCollateral(id);
    }

    /// THE DOCUMENTED RESIDUAL. A surplus means two claimants and one deed, so the pool declines
    /// rather than inventing a second one. That band is exactly the not-at-risk band: a refund
    /// exists only while the collateral is worth more than 1.08x the debt.
    function test_aLiquidationWithASurplusStillRefusesUnderAFreeze() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(100e8); // $1,000 backing $700: underwater, but $756 of seizure leaves a refund
        tok.setPaused(true);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(bytes("token paused"));
        pool.liquidate(id);

        tok.setPaused(false);
        uint256 aliceBefore = tok.balanceOf(ALICE);
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        assertGt(tok.balanceOf(ALICE) - aliceBefore, 0, "the surplus is real, hence two claimants");
    }

    /// Write-off matters more than liquidate here: it is how a loss is RECOGNISED, and a frozen
    /// token used to stop the resolver settling a position at all.
    function test_writeOffEscrowsUnderAFreeze() public {
        uint256 id = _borrow(700e6);
        address R = _installResolver(); // before the walk: it re-stamps the price to $200
        _walkPriceAndSettle(60e8);
        tok.setPaused(true);

        vm.prank(R);
        pool.writeOff(id, 600e6);
        assertEq(pool.debtOf(id), 0, "the loss is recognised");
        assertEq(pool.note().ownerOf(id), R, "the resolver holds the claim");

        tok.setPaused(false);
        vm.prank(R);
        assertEq(pool.claimCollateral(id), 10e18);
    }

    /// And a position whose collateral is already burned to nothing closes cleanly under the freeze —
    /// it used to end in a zero-value transfer that a paused token reverts just the same.
    function test_writeOffWithNoCollateralLeftClosesUnderAFreeze() public {
        uint256 id = _borrow(700e6);
        address R = _installResolver();
        tok.adminBurn(address(pool), 10e18);
        tok.setPaused(true);
        vm.prank(R);
        pool.writeOff(id, 0);
        assertEq(pool.debtOf(id), 0);
        Note n = pool.note();
        vm.expectRevert();
        n.ownerOf(id); // fully closed, no escrow needed
    }

    /// Solvency across the escrow: a second borrower opening against the same token must not be
    /// diluted, and the pool's books must keep matching its balance.
    function test_theLiquidationEscrowKeepsTheBooksMatchingTheBalance() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(60e8);
        tok.setPaused(true);
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        tok.setPaused(false);

        _walkPriceAndSettle(200e8); // back to a borrowable price
        address BOB = makeAddr("bob");
        tok.mint(BOB, 10e18);
        usdg.mint(BOB, 10_000e6);
        vm.startPrank(BOB);
        tok.approve(address(pool), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        uint256 id2 = pool.borrow(10e18, 700e6);
        vm.stopPrank();

        assertEq(pool.recordedRaw(address(tok)), tok.balanceOf(address(pool)), "books match the balance");
        vm.prank(LIQUIDATOR);
        assertEq(pool.claimCollateral(id), 10e18, "the escrow pays in full");
        uint256 owed2 = pool.debtOf(id2); // outside the prank: a call argument consumes it
        vm.prank(BOB);
        pool.repay(id2, owed2);
        assertEq(tok.balanceOf(address(pool)), 0, "nothing stranded");
        assertEq(pool.recordedRaw(address(tok)), 0);
    }

    /// The escrow must not become a way to pay for a delivery that actually happened. A token that
    /// returns FALSE without reverting is the other way an ERC-20 declines, and it must route to the
    /// escrow rather than be read as delivery.
    function test_aFalseReturningTransferEscrowsRatherThanCountingAsDelivery() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(60e8);
        tok.setTransferReturnsFalse(true);
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        assertEq(tok.balanceOf(LIQUIDATOR), 0, "nothing was delivered");
        assertEq(pool.note().ownerOf(id), LIQUIDATOR, "so the claim survives");
    }
}
