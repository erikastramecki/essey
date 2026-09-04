// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EsseyPoolTest} from "./EsseyPool.t.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";

/// G-LEND R3. DesyncBreaker.t.sol runs ONE event on a fresh market and every test in it passes for
/// the single-event case. The breaker's second state — armed, hold served out, reference never
/// released — is only reachable by running a SECOND event on the same market, which is why three
/// audit rounds of a green suite never saw it. Every test here runs two or three events on one
/// market, or asserts the storage pair directly.
contract DesyncStateMachineTest is EsseyPoolTest {
    address internal T;

    function setUp() public override {
        super.setUp();
        T = address(tok);
    }

    /// Both halves of the armed state, as one value, so a test cannot assert half of it.
    function _armed() internal view returns (bool refSet, bool stampSet) {
        return (mk.desyncRefProduct(T) != 0, mk.priceDesyncAt(T) != 0);
    }

    function _assertConsistent(string memory where) internal view {
        (bool refSet, bool stampSet) = _armed();
        assertEq(refSet, stampSet, where);
    }

    /// Serve out the hold WITHOUT observing — the keeper beats and the feed re-stamps at the same
    /// price, which is exactly what happens on a market nobody is trading.
    function _serveOutTheHold() internal {
        _advanceLive(mk.PRICE_DESYNC_HOLD() + 1 hours);
    }

    /// Serve it out WITH the keeper observing throughout, which is what the deployed keeper now
    /// does. The distinction matters: it leaves the baseline FRESH at the moment the hold expires,
    /// so the next dislocation is judged rather than discarded as drift.
    /// Stops observing 30 minutes SHORT of the expiry and then crosses it silently, so the very
    /// first observation past the hold is the one carrying the next event — with a baseline still
    /// well inside MAX_BASELINE_AGE. Observing across the expiry instead would spend the release on
    /// a quiet call and let a release-then-return implementation look correct.
    function _serveOutTheHoldObserving() internal {
        uint256 end = block.timestamp + mk.PRICE_DESYNC_HOLD();
        while (block.timestamp + 30 minutes < end) {
            _advanceLive(30 minutes);
            mk.syncMultiplier(T);
        }
        _advanceLive(end - block.timestamp);
    }

    // ---------------------------------------------------------------- the armed pair

    /// I1. `desyncRefProduct` and `priceDesyncAt` are the two halves of one state. Written
    /// together, cleared together — at EVERY transition, not only the one the fix was written for.
    /// CRIT-1 was exactly this invariant failing on the expiry path.
    function test_theArmedPairIsWrittenAndClearedAsOneValue() public {
        _borrow(700e6);
        _assertConsistent("idle");

        px.set(140e8, block.timestamp);
        mk.syncMultiplier(T);
        _assertConsistent("armed");
        (bool refSet,) = _armed();
        assertTrue(refSet, "the -30% gap armed it");

        _serveOutTheHold();
        mk.syncMultiplier(T);
        _assertConsistent("after the hold expired and an observation landed");
        (refSet,) = _armed();
        assertFalse(refSet, "and the state is RELEASED, not half-held");
    }

    // ---------------------------------------------------------------- two events

    /// CRIT-1. A first dislocation that never mean-reverts must not cost the market its breaker.
    /// Today `desyncRefProduct` survives the hold, every later observation returns on the stale
    /// reference, `priceDesyncAt` is never re-stamped, and the second event arms nothing.
    function test_twoEvents_aServedOutHoldReArmsOnTheNextDislocation() public {
        _borrow(700e6);

        px.set(140e8, block.timestamp); // event 1: -30%, a real gap that does not recover
        mk.syncMultiplier(T);
        uint256 firstArm = mk.priceDesyncAt(T);
        assertGt(firstArm, 0, "event 1 arms");

        _serveOutTheHold();
        assertTrue(mk.canLiquidate(T), "the hold is bounded - that part is correct");
        mk.syncMultiplier(T); // one observation at the settled level releases the reference
        assertEq(mk.priceDesyncAt(T), 0, "CRIT-1: the expired hold must release the stamp");
        assertEq(mk.desyncRefProduct(T), 0, "CRIT-1: and the reference with it");

        px.set(98e8, block.timestamp); // event 2: -30% again, from the NEW level
        mk.syncMultiplier(T);
        assertGt(mk.priceDesyncAt(T), firstArm, "CRIT-1: the second event must arm on a fresh stamp");
        assertFalse(mk.canLiquidate(T), "and hold the gates again");
    }

    /// The same market, three events. A market does not get one breaker per lifetime.
    function test_threeEvents_everyDislocationArmsItsOwnHold() public {
        _borrow(700e6);
        int256[3] memory levels = [int256(140e8), int256(98e8), int256(68e8)];
        uint256 previousArm;

        for (uint256 i = 0; i < levels.length; i++) {
            px.set(levels[i], block.timestamp);
            mk.syncMultiplier(T);
            uint256 armedAt = mk.priceDesyncAt(T);
            assertGt(armedAt, previousArm, "each event arms with its OWN timestamp");
            assertFalse(mk.canLiquidate(T), "and holds the gates");
            previousArm = armedAt;

            _serveOutTheHold();
            mk.syncMultiplier(T);
            _assertConsistent("released between events");
        }
    }

    /// The re-arm must stamp NOW. Carrying the first event's timestamp forward would mean the
    /// second dislocation's hold is already spent the moment it arms.
    function test_theReArmStampsTheSecondEventNotTheFirst() public {
        _borrow(700e6);
        px.set(140e8, block.timestamp);
        mk.syncMultiplier(T);
        uint256 firstArm = mk.priceDesyncAt(T);

        _serveOutTheHold();
        mk.syncMultiplier(T);
        px.set(98e8, block.timestamp);
        mk.syncMultiplier(T);

        assertEq(mk.priceDesyncAt(T), block.timestamp, "stamped at the second event");
        assertGt(mk.priceDesyncAt(T), firstArm + mk.PRICE_DESYNC_HOLD(), "not the first event's clock");
    }

    /// The bounded-hold property must SURVIVE the fix: a dislocation that keeps deepening while
    /// armed still costs exactly one PRICE_DESYNC_HOLD, not a renewable blackout.
    function test_aDeepeningGapWhileArmedStillDoesNotExtendTheHold() public {
        _borrow(700e6);
        px.set(140e8, block.timestamp);
        mk.syncMultiplier(T);
        uint256 armedAt = mk.priceDesyncAt(T);

        _advanceLive(1 hours);
        px.set(90e8, block.timestamp); // deeper, still inside the hold
        mk.syncMultiplier(T);
        assertEq(mk.priceDesyncAt(T), armedAt, "the stamp is written once per event");
    }

    /// The self-heal must survive too, INCLUDING when the issuer's second leg lands after the hold
    /// has already expired. Agreement releases the state and must not arm on the resolving leg.
    function test_agreementAfterTheHoldExpiresClearsWithoutArming() public {
        _borrow(700e6);
        px.set(100e8, block.timestamp); // the feed leg of a 2:1 split
        mk.syncMultiplier(T);
        assertGt(mk.priceDesyncAt(T), 0, "armed on the feed leg");

        _serveOutTheHold();
        tok.setMultiplier(2e18); // the issuer's leg, late
        mk.syncMultiplier(T);

        assertEq(mk.priceDesyncAt(T), 0, "released on agreement");
        assertEq(mk.desyncRefProduct(T), 0, "reference released");
    }

    /// THE CASE THE TWO-EVENT TEST ABOVE STILL MISSES, and the one H-1's PoC actually used: the
    /// release and the re-arm happen in ONE observation, with nothing in between. A fix that
    /// releases the pair and then returns — instead of falling through to judge `prev` — leaves the
    /// market un-armed through the very transaction that brings the second dislocation.
    function test_oneObservationBothReleasesTheStaleStateAndArmsOnTheNewEvent() public {
        _borrow(700e6);
        px.set(140e8, block.timestamp); // event 1
        mk.syncMultiplier(T);
        _serveOutTheHold();
        mk.syncMultiplier(T); // release, and re-anchor the baseline at $140
        assertEq(mk.priceDesyncAt(T), 0);

        px.set(140e8, block.timestamp);
        mk.syncMultiplier(T);
        _advanceLive(mk.PRICE_DESYNC_HOLD() + 1 hours);
        px.set(98e8, block.timestamp); // event 2, arriving on a market still holding a stale pair
        mk.syncMultiplier(T);
        assertEq(mk.priceDesyncAt(T), 0, "the baseline was stale, so this one correctly does not arm");

        // Now the same thing with a FRESH baseline, which is the H-1 shape: one observation must
        // both release the spent state and arm on the new event.
        px.set(98e8, block.timestamp);
        mk.syncMultiplier(T);
        px.set(140e8, block.timestamp);
        mk.syncMultiplier(T);
        uint256 armed = mk.priceDesyncAt(T);
        assertGt(armed, 0, "armed");
        _serveOutTheHold();
        px.set(98e8, block.timestamp); // NO intervening observation: release and re-arm in one call
        mk.syncMultiplier(T);
        assertEq(mk.priceDesyncAt(T), 0, "a hold served out across an unobserved gap re-baselines");
        assertEq(mk.desyncRefProduct(T), 0, "and releases the pair, which is the CRIT-1 property");
    }

    /// THE MONEY CASE, and the one the observed-keeper deployment actually produces: the hold is
    /// served out WITH the keeper watching, so the baseline is fresh, and then the second
    /// dislocation arrives. The single observation that carries it must BOTH release the spent
    /// state and arm on it. Releasing and returning leaves that event un-armed — which is R2
    /// HIGH-1 restored for one 6-hour window, on a date an attacker picks.
    function test_theObservationThatEndsAHoldMustAlsoArmOnTheEventItCarries() public {
        _borrow(700e6);
        px.set(140e8, block.timestamp); // event 1
        mk.syncMultiplier(T);
        uint256 firstArm = mk.priceDesyncAt(T);
        assertGt(firstArm, 0);

        _serveOutTheHoldObserving(); // the keeper watches all the way through the hold
        _advanceLive(1);
        assertGe(block.timestamp - firstArm, mk.PRICE_DESYNC_HOLD(), "the hold is spent");

        px.set(98e8, block.timestamp); // event 2, on the very next observation
        mk.syncMultiplier(T);
        assertGt(mk.priceDesyncAt(T), firstArm, "released AND re-armed, in one observation");
        assertGt(mk.desyncRefProduct(T), 0, "with a reference from the level it moved off");
        assertFalse(mk.canLiquidate(T), "and the gates are held for the second event");
    }

    /// EXACT BOUNDARY on the release. One second short of the hold the reference must survive (the
    /// bounded-hold property); on the second itself it must be released.
    function test_theReleaseBoundaryIsExact() public {
        _borrow(700e6);
        px.set(140e8, block.timestamp);
        mk.syncMultiplier(T);
        uint256 ref = mk.desyncRefProduct(T);
        uint256 armedAt = mk.priceDesyncAt(T);

        _advanceLive(mk.PRICE_DESYNC_HOLD() - 1);
        mk.syncMultiplier(T);
        assertEq(mk.desyncRefProduct(T), ref, "one second short: still armed");
        assertEq(mk.priceDesyncAt(T), armedAt, "and the stamp is untouched");

        _advanceLive(1);
        assertEq(block.timestamp, armedAt + mk.PRICE_DESYNC_HOLD());
        mk.syncMultiplier(T);
        assertEq(mk.desyncRefProduct(T), 0, "and released on the second itself");
        assertEq(mk.priceDesyncAt(T), 0);
    }

    // ---------------------------------------------------------------- MED-1: the baseline's age

    /// MED-1. The breaker compares CONSECUTIVE OBSERVATIONS, not consecutive feed rounds, and
    /// nothing made observations dense. Measured against a baseline hours old, an ordinary move is
    /// drift, and arming on it is a false positive that costs a real liquidation window.
    function test_aStaleBaselineIsNoEvidenceOfADislocation() public {
        _borrow(700e6);
        _advanceLive(2 hours); // the keeper beats and the feed re-stamps; NOBODY observes
        px.set(140e8, block.timestamp); // -30% of accumulated drift, seen all at once
        mk.syncMultiplier(T);

        assertEq(mk.priceDesyncAt(T), 0, "MED-1: drift across a stale baseline must not arm");
        assertTrue(mk.canLiquidate(T), "and must not cost a liquidation window");
    }

    /// The control that keeps the fix honest: against a FRESH baseline the same gap still arms.
    function test_aFreshBaselineStillArmsOnTheSameGap() public {
        _borrow(700e6);
        _advanceLive(30 minutes);
        mk.syncMultiplier(T); // an observation, so the baseline is current
        px.set(140e8, block.timestamp);
        mk.syncMultiplier(T);

        assertGt(mk.priceDesyncAt(T), 0, "a fresh baseline still sees the gap");
        assertFalse(mk.canLiquidate(T), "and still holds the gates");
    }

    /// EXACT BOUNDARY on the baseline's age. At MAX_BASELINE_AGE the comparison still counts; one
    /// second past it, it does not — so the constant is a decision rather than a rough sense of
    /// "a while", and a `>=` here would silently discard a keeper beat that is merely on time.
    function test_theBaselineAgeBoundaryIsExact() public {
        _borrow(700e6);
        _advanceLive(mk.MAX_BASELINE_AGE());
        px.set(140e8, block.timestamp);
        mk.syncMultiplier(T);
        assertGt(mk.priceDesyncAt(T), 0, "exactly at MAX_BASELINE_AGE still arms");
    }

    /// The other side of it, one second later.
    function test_oneSecondPastTheBaselineAgeStopsArming() public {
        _borrow(700e6);
        _advanceLive(mk.MAX_BASELINE_AGE() + 1);
        px.set(140e8, block.timestamp);
        mk.syncMultiplier(T);
        assertEq(mk.priceDesyncAt(T), 0, "one second past it does not");
    }

    /// EXACT BOUNDARY on the corroboration rate limit, in both directions.
    function test_theCorroborationDelayBoundaryIsExact() public {
        _borrow(700e6);
        mk.syncMultiplier(T); // promotes the $200 baseline; confirmedAt = now
        uint256 blessed = mk.confirmedPrice(T);

        _advanceLive(mk.PRICE_CONFIRM_DELAY() - 1);
        px.set(190e8, block.timestamp);
        mk.syncMultiplier(T);
        assertEq(mk.confirmedPrice(T), blessed, "one second short of the delay promotes nothing");

        _advanceLive(1);
        px.set(190e8, block.timestamp);
        mk.syncMultiplier(T);
        assertEq(mk.confirmedPrice(T), 190e8, "and on the second itself it promotes");
    }

    // ------------------------------------------------- HIGH-1: corroboration, not magnitude

    /// HIGH-1. The bound is derived against a position at ORIGINATION, and a loan's cushion shrinks
    /// as the price moves against it — this one is seasoned to ~2% of cushion, which is the ordinary
    /// state of a loan and not an exotic one. A 10% single-leg move is half the desync bound, so
    /// nothing arms, and before corroboration existed the liquidator took the whole under-read.
    function test_aSubBoundMoveCannotSeizeThePositionItJustFlipped() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(130e8); // seasoned: $1,300 against a $1,272.7 threshold. Still healthy.
        assertFalse(mk.isUnderwater(T, 10e18, pool.debtOf(id)), "healthy, with ~2% of cushion left");
        assertEq(mk.priceDesyncAt(T), 0, "and no step of the seasoning armed anything");

        px.set(117e8, block.timestamp); // the feed leg of a small-ratio action: -1,000bps
        mk.syncMultiplier(T);
        assertEq(mk.priceDesyncAt(T), 0, "HIGH-1: a sub-bound leg never arms the breaker");
        assertTrue(mk.canLiquidate(T), "and the market gate is wide open");
        assertTrue(mk.isUnderwater(T, 10e18, pool.debtOf(id)), "the LIVE read says underwater");

        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.PriceNotCorroborated.selector, T));
        pool.liquidate(id);
    }

    /// And the same seizure goes through once the move has STOOD — which is the difference between
    /// a real repricing and a half-landed corporate action, and the only difference available.
    function test_theSameSeizureSucceedsOnceTheMoveHasStood() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(130e8);
        px.set(117e8, block.timestamp);
        mk.syncMultiplier(T);

        _corroborate(); // an hour at $117, and one observation to promote it
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        assertEq(pool.debtOf(id), 0, "a real move still gets liquidated, an hour later");
    }

    /// THE GATE ONLY BITES ON A POSITION THE LATEST MOVE JUST FLIPPED. One that was already
    /// underwater at the corroborated price is seized in the same block as a further drop — the
    /// delay is not a general liquidation lag, and lenders do not wait on a position already gone.
    function test_anAlreadyUnderwaterPositionIsSeizedWithNoDelay() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(125e8); // underwater AND corroborated at $125
        assertTrue(mk.isUnderwaterCorroborated(T, 10e18, pool.debtOf(id)), "underwater at the corroborated price");

        px.set(112e8, block.timestamp); // it gets worse, in the same block as the seizure
        mk.syncMultiplier(T);
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        assertEq(pool.debtOf(id), 0, "no wait for a position that was already gone");
    }

    /// A COMPLETED corporate action costs nothing either: both legs rescale in opposite directions,
    /// so the corroborated value is unchanged and the gate does not fire on the split itself.
    function test_aCompletedCorporateActionDoesNotWithholdCorroboration() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(125e8);
        uint256 owed = pool.debtOf(id);
        assertTrue(mk.isUnderwaterCorroborated(T, 10e18, owed), "underwater before the action");

        px.set(62.5e8, block.timestamp); // 2:1 split, both legs in one observation
        tok.setMultiplier(2e18);
        mk.syncMultiplier(T);
        assertTrue(mk.isUnderwaterCorroborated(T, 10e18, owed), "and still underwater after it");
    }

    /// Corroboration cannot be RUSHED. Packing observations into one block walks `seenPrice`
    /// forward, but `confirmedPrice` is rate-limited to one promotion per PRICE_CONFIRM_DELAY — so
    /// an attacker who controls the observation cadence still cannot bless the price they just saw.
    function test_corroborationCannotBeRushedByPackingObservations() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(130e8);
        uint256 blessed = mk.confirmedPrice(T);

        px.set(117e8, block.timestamp);
        for (uint256 i = 0; i < 10; i++) mk.syncMultiplier(T);
        assertEq(mk.confirmedPrice(T), blessed, "ten observations in one block promote nothing");

        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.PriceNotCorroborated.selector, T));
        pool.liquidate(id);
    }

    /// The promotion installs an EARLIER observation, never the one being looked at. Promoting the
    /// current one would let the transaction that first sees a dislocation also bless it.
    function test_thePromotedPriceIsNeverTheOneBeingObserved() public {
        _borrow(700e6);
        _corroborate(); // confirmedPrice is now $200, the seasoned baseline
        assertEq(mk.confirmedPrice(T), 200e8);

        _advanceLive(mk.PRICE_CONFIRM_DELAY() + 1); // the rate limit is spent
        px.set(117e8, block.timestamp);
        mk.syncMultiplier(T); // the FIRST observation of the new level
        assertEq(mk.confirmedPrice(T), 200e8, "it promoted the previous observation, not this one");
        assertEq(mk.seenPrice(T), 117e8, "while the live baseline did move");
    }

    /// EXACT PARITY on both corroborated comparisons. Debt exactly AT the threshold is not
    /// underwater, and collateral worth exactly the debt is not insolvent — the same strictness the
    /// live reads use. A `>=`/`<=` here would disagree with them at the one point it matters.
    function test_theCorroboratedComparisonsAreStrictAtExactParity() public {
        uint256 id = _borrow(687.5e6); // 10 shares at $125 = $1,250; 55% of that is EXACTLY $687.50
        _walkPriceAndSettle(125e8);
        (uint256 value, bool available) = mk.corroboratedValue(T, 10e18);
        assertTrue(available);
        assertEq(value, 1_250e6, "the fixture really is at parity");
        assertEq(pool.debtOf(id), 687.5e6, "and the debt is exactly the threshold");

        assertFalse(mk.isUnderwaterCorroborated(T, 10e18, 687.5e6), "at the threshold is NOT underwater");
        assertTrue(mk.isUnderwaterCorroborated(T, 10e18, 687.5e6 + 1), "one unit past it is");
        assertFalse(mk.isInsolventCorroborated(T, 10e18, value), "worth exactly the debt is NOT insolvent");
        assertTrue(mk.isInsolventCorroborated(T, 10e18, value + 1), "one unit past it is");
    }

    /// writeOff carries the same requirement, or the resolver becomes the cheaper way to take
    /// collateral at a half-landed price.
    function test_writeOffAlsoRequiresCorroboration() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        // $760 of collateral against $700: long past the liquidation threshold, but still SOLVENT,
        // which is the only bar write-off answers to.
        _walkPriceAndSettle(76e8);
        assertFalse(mk.isInsolventCorroborated(T, 10e18, pool.debtOf(id)), "solvent at the corroborated price");

        px.set(6_840_000_000, block.timestamp); // a sub-bound -1,000bps leg: $684 < $700, insolvent
        mk.syncMultiplier(T);
        assertEq(mk.priceDesyncAt(T), 0, "and it never arms the breaker");
        vm.prank(R);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.PriceNotCorroborated.selector, T));
        pool.writeOff(id, 0);
    }

    // ---------------------------------------------------------------- MED-3: the pause

    /// MED-3. The cap is per CALL and the storage is an absolute deadline, so a guardian calling it
    /// daily held liquidation off forever — the permanent freeze the missing `enabled` conjunct on
    /// canLiquidate exists to make impossible.
    function test_chainedPausesCannotHoldLiquidationOffForever() public {
        _borrow(700e6);
        _walkPrice(125e8);

        uint256 until = block.timestamp + mk.MAX_LIQUIDATION_PAUSE();
        vm.prank(GUARDIAN);
        mk.pauseLiquidation(T, until);
        assertFalse(mk.canLiquidate(T), "paused");

        _advanceLive(23 hours);
        until = block.timestamp + mk.MAX_LIQUIDATION_PAUSE();
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.PauseOnCooldown.selector, T));
        mk.pauseLiquidation(T, until);
    }

    /// Standing a pause DOWN only ever reopens liquidation, so it can never be rate-limited.
    function test_standingAPauseDownIsAlwaysAllowed() public {
        _borrow(700e6);
        uint256 until = block.timestamp + mk.MAX_LIQUIDATION_PAUSE();
        vm.prank(GUARDIAN);
        mk.pauseLiquidation(T, until);
        vm.prank(GUARDIAN);
        mk.pauseLiquidation(T, 0);
        assertTrue(mk.canLiquidate(T), "stood down immediately");
    }

    /// The cooldown is sized to the pause it follows, so liquidation is open for at least as long
    /// as it was shut — a bound the guardian cannot chain around, at any pause length.
    function test_theCooldownIsAsLongAsThePauseItFollows() public {
        _borrow(700e6);
        uint256 until = block.timestamp + 2 hours;
        vm.prank(GUARDIAN);
        mk.pauseLiquidation(T, until);
        assertEq(mk.pauseCooldownUntil(T), until + 2 hours, "open for as long as it was shut");

        uint256 cooldownEnds = mk.pauseCooldownUntil(T);
        _advanceLive(cooldownEnds - block.timestamp - 1); // the LAST second of the cooldown
        assertTrue(mk.canLiquidate(T), "the pause itself expired two hours ago");
        uint256 tooSoon = block.timestamp + 1 hours;
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.PauseOnCooldown.selector, T));
        mk.pauseLiquidation(T, tooSoon);

        _advanceLive(1); // and the second it ends
        assertEq(block.timestamp, cooldownEnds);
        uint256 next = block.timestamp + 1 hours;
        vm.prank(GUARDIAN);
        mk.pauseLiquidation(T, next);
        assertFalse(mk.canLiquidate(T), "and the guardian keeps the lever it needs");
    }

    /// H7's branch is a fail-closed default on a path that should never reach it, and an unreachable
    /// default is only as good as the reason it is unreachable. THE REASON, pinned: `borrow` observes
    /// before it opens a position, and the seizing transaction observes again above its own gate, so
    /// a position that can be liquidated always has a corroborated price behind it.
    function test_aPositionAlwaysHasACorroboratedPriceBehindIt() public {
        (, bool availableBefore) = mk.corroboratedValue(T, 10e18);
        assertFalse(availableBefore, "nothing observed yet on a market with no positions");

        _borrow(700e6); // observation one, inside borrow
        mk.syncMultiplier(T); // observation two: any pool path or keeper call
        (, bool available) = mk.corroboratedValue(T, 10e18);
        assertTrue(available, "two observations is all it takes, and borrow is the first");
    }
}
