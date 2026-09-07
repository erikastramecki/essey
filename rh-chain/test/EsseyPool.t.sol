// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {CollateralReconciler} from "../src/CollateralReconciler.sol";
import {MockFeed, MockStock} from "./RiskModules.t.sol";
import {Note} from "../src/market/Note.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// Real USDG on Robinhood Chain has SIX decimals (verified by eth_call against mainnet).
/// The first version of this mock used 18, which made a 1e12 collateral-valuation error
/// invisible to the entire suite. Mocks that differ from production hide exactly the bugs
/// production has.
contract MockUSDG is ERC20 {
    constructor() ERC20("Global Dollar", "USDG") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    // Borrow-asset pause (fix #5): the pool suspends accrual only while the BORROW ASSET is paused.
    // Stored as a raw word so a test can also feed a NON-boolean value (fix #1 — must not panic accrue()).
    uint256 private _pausedWord;
    function setPausedWord(uint256 w) external { _pausedWord = w; }
    function paused() external view returns (uint256) { return _pausedWord; }
}

contract EsseyPoolTest is Test {
    EsseyPool pool;
    EsseyMarkets mk;
    LivenessOracle liv;
    MarketHealthOracle hox;
    MockFeed seq;
    MockFeed px;
    MockStock tok;
    MockUSDG usdg;

    address ADMIN;
    address KEEPER;
    address GUARDIAN;
    address LENDER;
    address ALICE;
    address LIQUIDATOR;

    uint256 constant MON_IN_SESSION = 1_753_110_000;
    uint256 constant GRACE = 30 minutes;
    uint256 constant GAP = 10 minutes; // ~2 missed beats at a 5-minute cadence

    function setUp() public virtual {
        ADMIN = makeAddr("admin"); KEEPER = makeAddr("keeper"); GUARDIAN = makeAddr("guardian");
        LENDER = makeAddr("lender"); ALICE = makeAddr("alice"); LIQUIDATOR = makeAddr("liquidator");
        vm.warp(MON_IN_SESSION);

        seq = new MockFeed(0, 0); seq.setStartedAt(block.timestamp - 2 days);
        px = new MockFeed(200e8, 8); // $200/share
        tok = new MockStock();
        usdg = new MockUSDG();
        liv = new LivenessOracle(KEEPER, GUARDIAN, makeAddr("livenessRotator"), GAP, GRACE);
        hox = new MarketHealthOracle(KEEPER, GUARDIAN, ADMIN);
        mk = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, ADMIN, GUARDIAN, 6); // USDG is 6dp
        vm.prank(ADMIN);
        hox.wireMarkets(address(mk));
        // zero-rate pool: isolates the invariants under test from accrual drift
        pool = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));

        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
        });
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        vm.stopPrank();

        _beat(); _advanceLive(GRACE);
        _seedOracle();

        usdg.mint(LENDER, 1_000_000e6);
        usdg.mint(ALICE, 100_000e6);
        usdg.mint(LIQUIDATOR, 100_000e6);
        tok.mint(ALICE, 1_000e18);

        vm.startPrank(LENDER);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e6, LENDER);
        vm.stopPrank();

        vm.startPrank(ALICE);
        tok.approve(address(pool), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.prank(LIQUIDATOR);
        usdg.approve(address(pool), type(uint256).max);
    }

    function _beat() internal { vm.prank(KEEPER); liv.heartbeat(); }

    /// The deployed keeper BEATS AND OBSERVES on the same 300s tick (keeper/liveness-keeper.mjs).
    /// R4 LOW-5: this used to beat only, so every `_corroborate()` step landed at baselineAge one
    /// second past MAX_BASELINE_AGE and took the early return in `_breaker` — 140 tests set their
    /// scenario up with the deviation check switched off, and any future test folding a >2,000bps
    /// move into `_walkPriceAndSettle` would silently not arm and look correct.
    function _observe() internal virtual { mk.syncMultiplier(address(tok)); }

    /// Beats on the keeper's 5-minute tick and OBSERVES every sixth one. The deployed keeper does
    /// both on the same tick; simulating that over the 30-day advances this fixture also runs costs
    /// more gas than a test may spend, and half an hour is well inside both MAX_BASELINE_AGE and
    /// CONFIRM_STEP, so the states under test are the same ones.
    function _advanceLive(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        uint256 tick;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes); px.set(px.answer(), block.timestamp); _beat(); _postD();
            if (++tick % 6 == 0) _observe();
        }
        vm.warp(end); px.set(px.answer(), block.timestamp); _beat(); _postD(); _observe();
    }

    /// The keeper beating but NOT observing — R4 HIGH-2's world, and the one every stale-baseline
    /// test is actually about. It has to be asked for by name now: `_advanceLive` models the
    /// deployed keeper, which does both.
    function _advanceQuiet(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes); px.set(px.answer(), block.timestamp); _beat(); _postD();
        }
        vm.warp(end); px.set(px.answer(), block.timestamp); _beat(); _postD();
    }

    uint128 constant SEED_DEPTH = 4_000_000e6; // target 1_333_200e6 > Market.cap: min() = the static cap

    function _postD() internal {
        vm.prank(KEEPER); hox.postDepth(address(tok), SEED_DEPTH, uint64(block.number), "fork-swap-v1");
    }

    /// Arm the depth cap and ride raiseDelay + the full from-zero slew ramp on a live keeper
    /// cadence — a silent warp past MAX_READING_AGE resets the ramp. The base clamps to
    /// Market.cap, so the 1_333_200e6 target needs ~15.4 days; 21 keeps the day-of-week.
    function _seedOracle() internal {
        _postD();
        for (uint256 i = 0; i < 41; i++) { vm.warp(block.timestamp + 12 hours); _postD(); }
        _beat(); _advanceLive(GRACE);
        // The 42nd step of the ramp, but LIVE: the same 12 hours, spent beating and observing, so
        // the delay line is full and the fixture still lands on the day and hour it always did.
        _fillDelayLine(12 hours - GRACE);
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }

    /// R4 HIGH-1: a market has no corroborated price until the delay line has been observed for
    /// PRICE_CONFIRM_DELAY, so nothing can be liquidated or written off in its first six hours. That
    /// is the fail-closed direction and it is deliberate, but every fixture that seizes has to serve
    /// it out the way the deployed keeper would.
    /// Ride the keeper's cadence to the next open US session. Needed since R4 HIGH-1 made the
    /// settle nine hours rather than one: two settles in a row now cross the close.
    function _intoSession() internal {
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }

    function _fillDelayLine(uint256 secs) internal {
        require(secs >= mk.PRICE_CONFIRM_DELAY() + 2 * mk.CONFIRM_STEP(), "fixture: too short to fill");
        _advanceLive(secs);
    }

    /// Warp through the 2-day timelock on a live keeper cadence — a silent warp past
    /// MAX_READING_AGE resets the depth ramp.
    function _warpTimelock() internal {
        for (uint256 i = 0; i < 3; i++) { vm.warp(block.timestamp + 12 hours); _postD(); }
        // The last 12 hours OBSERVED, so a pipeline that has to be re-filled after the change (an
        // _activate, a resolver install) is filled by the time the caller acts, and the elapsed
        // time is the 48 hours PARAM_TIMELOCK needs either way.
        _beat(); _fillDelayLine(12 hours);
    }

    /// Make `p` the token's active pool through the real timelocked pipeline (F1: only the
    /// active pool opens new borrows, so a test pool must succeed `pool` before it can lend).
    function _activate(EsseyPool p) internal {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
        });
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(p), m);
        _warpTimelock();
        px.set(px.answer(), block.timestamp);
        mk.commitMarket(address(tok));
        _beat(); _advanceLive(GRACE);
        _fillDelayLine(12 hours - GRACE);
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }

    /// Walk the feed to `target` in observed steps inside EsseyMarkets.MAX_PRICE_DEVIATION_BPS.
    ///
    /// A market MOVES; a corporate action GAPS. Since G-LEND R2 HIGH-1 a single step past the bound
    /// arms the desync breaker and holds both gates for PRICE_DESYNC_HOLD, because at the instant it
    /// happens a split's feed leg and a crash of the same size are the same evidence. A test that
    /// wants an underwater position wants the market; the tests that want the gap assert on it
    /// directly (DesyncBreaker.t.sol). No time passes here, so accrual and session are untouched.
    function _walkPrice(int256 target) internal {
        int256 cur = px.answer();
        while (cur != target) {
            int256 next = target < cur ? (cur * 85) / 100 : (cur * 115) / 100;
            if (target < cur ? next < target : next > target) next = target;
            if (next == cur) next = target; // integer floor at tiny values
            cur = next;
            px.set(cur, block.timestamp);
            mk.syncMultiplier(address(tok));
        }
        px.set(target, block.timestamp); // re-stamp even when already there: some callers want freshness
    }

    /// G-LEND R3 HIGH-1, rebuilt for R4 HIGH-1. A seizure needs the move CORROBORATED: EsseyMarkets
    /// values it against the OLDEST slot of a delay line, which is at least PRICE_CONFIRM_DELAY old
    /// however the caller times the observations. That is the separation the desync bound could not
    /// make — a real move stands, a corporate action's feed leg is joined by its other leg.
    ///
    /// It warps PRICE_CONFIRM_DELAY + 2 x CONFIRM_STEP, not the delay itself: the whole ring has to
    /// have been observed AT the new level before the oldest slot holds it. The old one-second
    /// margin was enough only because the old rule promoted whatever the previous observation was.
    function _corroborate() internal {
        _advanceLive(mk.PRICE_CONFIRM_DELAY() + 2 * mk.CONFIRM_STEP());
        _observe();
    }

    /// Walk the market to a new level and let that level stand long enough to justify a seizure.
    function _walkPriceAndSettle(int256 target) internal {
        _walkPrice(target);
        _corroborate();
    }

    /// 10 shares at $200 = $2000 collateral; 35% LTV = $700 max.
    function _borrow(uint256 debt) internal returns (uint256 id) {
        vm.prank(ALICE);
        id = pool.borrow(10e18, debt);
    }

    // ---------------------------------------------------------------- basics

    function test_lenderDepositMintsShares() public view {
        assertGt(pool.balanceOf(LENDER), 0);
        assertEq(pool.totalAssets(), 500_000e6);
    }

    function test_borrowWithinLtv() public {
        uint256 id = _borrow(700e6);
        assertEq(usdg.balanceOf(ALICE), 100_700e6);
        assertEq(pool.debtOf(id), 700e6);
        assertEq(pool.marketBorrows(address(tok)), 700e6);
    }

    /// M-1: a PARTIAL close (one of several open positions) must release the closed position's
    /// PRINCIPAL from the per-market cap ledger, not its interest-inflated `owed`. Once interest has
    /// accrued the two diverge, so subtracting `owed` would under-count marketBorrows and silently
    /// free market cap the surviving position still occupies. Full-close tests can't see this (owed
    /// and principal both floor to the same value at zero rate / immediate repay).
    function test_marketBorrowsReleasesPrincipalNotOwedOnPartialClose() public {
        EsseyPool rp = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        _activate(rp);
        usdg.mint(LENDER, 500_000e6);
        vm.startPrank(LENDER);
        usdg.approve(address(rp), type(uint256).max);
        rp.deposit(500_000e6, LENDER);
        vm.stopPrank();

        vm.startPrank(ALICE);
        tok.approve(address(rp), type(uint256).max);
        usdg.approve(address(rp), type(uint256).max);
        uint256 id1 = rp.borrow(10e18, 700e6);
        uint256 id2 = rp.borrow(10e18, 500e6);
        vm.stopPrank();
        assertEq(rp.marketBorrows(address(tok)), 1_200e6, "sum of the two principals at open");

        _advanceLive(30 days);
        rp.accrue();
        uint256 owed1 = rp.debtOf(id1);
        assertGt(owed1, 700e6, "interest must have accrued so owed != principal");

        vm.startPrank(ALICE);
        usdg.mint(ALICE, owed1);
        rp.repay(id1, owed1); // full close of position 1
        vm.stopPrank();

        // The cap ledger must drop by id1's PRINCIPAL (700e6), leaving EXACTLY id2's principal.
        assertEq(rp.marketBorrows(address(tok)), 500e6, "released principal not owed: remaining == id2 principal");
        assertGt(rp.debtOf(id2), 500e6, "id2 still open and carrying its own accrued interest");
    }

    function test_borrowBeyondLtvReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.Undercollateralised.selector, 701e6, 700e6));
        pool.borrow(10e18, 701e6);
    }

    function test_borrowBlockedOffHours() public {
        uint256 night = (block.timestamp / 86400) * 86400 + 1 days + 3 hours;
        vm.warp(night); px.set(200e8, night);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.borrow(10e18, 100e18);
    }

    // ---------------------------------------------------------------- F5: repay

    /// Overpaying must NOT be an error, and must not overcharge. The Sui version demanded exact
    /// equality against a debt that grows every second — a race the borrower could lose.
    function test_repayAcceptsMoreThanOwedAndChargesOnlyTheDebt() public {
        uint256 id = _borrow(700e6);
        uint256 before_ = usdg.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.repay(id, 1_000e6); // deliberately generous
        assertEq(before_ - usdg.balanceOf(ALICE), 700e6, "must charge exactly the debt");
        assertEq(tok.balanceOf(ALICE), 1_000e18, "collateral fully returned");
        assertEq(pool.debtOf(id), 0);
    }

    function test_repayBelowOwedReverts() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        vm.expectRevert();
        pool.repay(id, 699e6);
    }

    function test_onlyBorrowerCanRepay() public {
        uint256 id = _borrow(700e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.repay(id, 700e6);
    }

    // ---------------------------------------------------------------- R5/R6: exposure release

    /// Closing a position must free its slot — exactly once. On Sui this leaked and eventually
    /// bricked all borrowing, then a second release path made the cap stop binding entirely.
    function test_repayFreesTheMarketCapSlotExactlyOnce() public {
        uint256 id = _borrow(700e6);
        assertEq(pool.marketBorrows(address(tok)), 700e6);
        vm.prank(ALICE);
        pool.repay(id, 700e6);
        assertEq(pool.marketBorrows(address(tok)), 0, "slot must be freed");
        // and borrowing the same size again must fit
        uint256 id2 = _borrow(700e6);
        assertEq(pool.marketBorrows(address(tok)), 700e6, "must not double-count or double-free");
        assertGt(id2, id);
    }

    // ---------------------------------------------------------------- F3: liquidation

    function test_healthyPositionCannotBeLiquidated() public {
        uint256 id = _borrow(700e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.PositionHealthy.selector);
        pool.liquidate(id);
    }

    /// THE F3 CASE. An underwater position is liquidated, but the liquidator takes only the debt
    /// plus the bonus — the SURPLUS goes back to the borrower. Seizing everything punished a
    /// borrower fractionally underwater.
    function test_liquidationRefundsSurplusToBorrower() public {
        uint256 id = _borrow(700e6);
        // drop to $125: collateral $1250, threshold 55% = $687.50 < $700 debt
        _walkPriceAndSettle(125e8);
        assertEq(tok.balanceOf(ALICE), 990e18); // 10 posted

        vm.prank(LIQUIDATOR);
        pool.liquidate(id);

        // debt 700 + 8% bonus = 756 of value; at $125 exactly 6.048 shares. Exact, not approx:
        // the old 1e15 window hid a bonus-magnitude error.
        assertEq(tok.balanceOf(LIQUIDATOR), 6.048e18, "liquidator takes debt+bonus, not everything");
        assertEq(tok.balanceOf(ALICE), 990e18 + 3.952e18, "the rest returns to Alice, to the wei");
    }

    /// ROUNDING DIRECTION on the seizure. `_rawWorth` converts the debt+bonus VALUE back into raw
    /// collateral; rounding UP hands the liquidator collateral the bonus did not buy, out of the
    /// borrower's refund. Every other liquidation fixture prices at a whole dollar, where a ceil is
    /// invisible. unitValue = 120_000_007; seize = 756e6 x 1e18 / 120_000_007 = ...437.5
    function test_liquidationSeizureRoundsDownNotUp() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(12_000_000_700); // $120.000007/share: $1200.000007 backing $700
        assertTrue(mk.isUnderwater(address(tok), 10e18, 700e6), "fixture must actually be liquidatable");

        vm.prank(LIQUIDATOR);
        pool.liquidate(id);

        assertEq(tok.balanceOf(LIQUIDATOR), 6_299_999_632_500_021_437, "seizure truncates against the borrower");
        assertEq(tok.balanceOf(ALICE), 990e18 + 3_700_000_367_499_978_563, "and the remainder stays in the refund");
    }

    function test_liquidationBlockedWithoutChainLiveness() public {
        uint256 id = _borrow(700e6);
        _walkPrice(125e8);
        vm.warp(block.timestamp + 4 hours); // outage: no heartbeat possible
        _walkPrice(125e8);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.LiquidationNotAllowed.selector, address(tok)));
        pool.liquidate(id);
    }

    // ---------------------------------------------------------------- adminBurn

    /// The issuer destroys collateral out of the live pool. The ledger must notice, and repayment
    /// must still work — returning whatever survived rather than reverting and trapping the rest.
    function test_adminBurnIsAbsorbedAndRepaymentStillWorks() public {
        uint256 id = _borrow(700e6);
        tok.adminBurn(address(pool), 4e18); // Robinhood burns 4 of Alice's 10 posted shares

        vm.prank(ALICE);
        pool.repay(id, 700e6);

        assertEq(pool.shortfallRaw(address(tok)), 4e18, "shortfall recorded");
        assertEq(tok.balanceOf(ALICE), 990e18 + 6e18, "returns what survived, does not revert");
        assertEq(pool.debtOf(id), 0, "debt still cleared");
    }

    // ---------------------------------------------------------------- end-to-end lifecycle

    /// Composes fixes #2/#4/#5 in one realistic flow: borrow with interest -> a partial adminBurn -> a
    /// borrower who arrives AFTER the burn is insulated -> the pre-burn borrower is liquidated on her
    /// haircut collateral -> the post-burn borrower repays and recovers his FULL deposit, having
    /// subsidised neither the burn nor the liquidation.
    function test_fullLifecycle_burnInsulationAccrualLiquidation() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        _activate(p2);
        usdg.mint(LENDER, 500_000e6); // harness-independent liquidity
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(500_000e6, LENDER); vm.stopPrank();

        // Alice borrows at max LTV against 10 AAPL @ $200 (in session from setUp)
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 aliceId = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        // the issuer burns half of Alice's collateral out of the pool
        tok.adminBurn(address(p2), 5e18); // 10 -> 5 for the tok cohort (only Alice so far)

        // Bob borrows FRESH after the burn — his snapshot is the post-burn index, so he is insulated
        address BOB = makeAddr("bob_lifecycle");
        tok.mint(BOB, 10e18); usdg.mint(BOB, 100_000e6);
        vm.startPrank(BOB);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 bobId = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        // a little time passes (still in session): interest accrues on both debts. _advanceLive keeps the
        // keeper heartbeat fresh (5-min beats < gapThreshold, so no grace) so liquidation stays enabled.
        _advanceLive(2 hours);
        p2.accrue();
        assertGt(p2.debtOf(aliceId), 700e6, "interest accrued on Alice");
        assertGt(p2.debtOf(bobId), 700e6, "interest accrued on Bob");

        // price drops: Alice's HAIRCUT collateral (5 @ $120 = $600) is now below her debt -> liquidate her
        _walkPrice(120e8);
        vm.prank(LIQUIDATOR); usdg.approve(address(p2), type(uint256).max); // approve THIS pool
        vm.prank(LIQUIDATOR);
        p2.liquidate(aliceId);
        assertEq(p2.debtOf(aliceId), 0, "Alice liquidated on her haircut collateral");

        // Bob repays and recovers his FULL 10 AAPL — insulated from both the burn and Alice's liquidation
        uint256 bobOwed = p2.debtOf(bobId);
        vm.startPrank(BOB); usdg.mint(BOB, bobOwed); p2.repay(bobId, bobOwed); vm.stopPrank();
        assertEq(p2.debtOf(bobId), 0, "Bob's debt cleared");
        assertEq(tok.balanceOf(BOB), 10e18, "post-burn borrower recovered his FULL deposit (insulated)");
    }

    // ---------------------------------------------------------------- accrual

    function test_interestAccruesAndLenderEarns() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // flat 10% APR
        _activate(p2);
        vm.startPrank(LENDER);
        usdg.approve(address(p2), type(uint256).max);
        p2.deposit(100_000e6, LENDER);
        vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max);
        usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        // Exact, not 1% relative: a 1% window swallows a wrong year length (360 days is 0.126%
        // off) — every borrower overcharged ~1.4% of all interest, permanently, on a green suite.
        assertEq(p2.debtOf(id), 770e6, "10% APR on 700, to the wei");
        assertEq(p2.totalAssets(), 100_070e6, "lenders earn the whole 70 at reserveBps 0");
    }

    /// The year-length constant over a dt that is neither a whole year nor a divisor of one. The
    /// whole-year case pins the ratio; this pins the division, so a wrong SECONDS_PER_YEAR cannot
    /// hide behind a fixture that happens to cancel.
    function test_accrualOverANonRoundIntervalIsExact() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        _activate(p2);
        vm.startPrank(LENDER);
        usdg.approve(address(p2), type(uint256).max);
        p2.deposit(100_000e6, LENDER);
        vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max);
        usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 1_000_000);
        p2.accrue();
        assertEq(p2.borrowIndex(), 1_003_170_979_198_376_458, "index truncates at the stated year length");
        assertEq(p2.debtOf(id), 702_219_685, "and the debt with it");
        assertEq(p2.totalBorrows(), 702_219_685);
    }

    /// reserveBps MAGNITUDE. The one "lenders earn" assertion runs on a reserveBps 0 pool and the
    /// writeOff fixtures only assert `reserves > 30e6` against a true 35e6, so doubling the
    /// protocol's cut survives — which on a 5_000bps pool pays lenders nothing at all.
    function test_reserveSplitIsExactBothWays() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 5_000, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        _activate(p2);
        vm.startPrank(LENDER);
        usdg.approve(address(p2), type(uint256).max);
        p2.deposit(100_000e6, LENDER);
        vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max);
        usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
        vm.stopPrank();
        assertEq(p2.totalAssets(), 100_000e6, "lender claim before accrual");

        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        assertEq(p2.debtOf(id), 770e6, "70 of interest charged");
        assertEq(p2.totalReserves(), 35e6, "the protocol takes exactly half");
        assertEq(p2.totalAssets(), 100_035e6, "and lenders keep exactly the other half");
        assertEq(p2.previewRedeem(p2.balanceOf(LENDER)), 100_034_999_999, "the share price carries it");
    }

    /// R1-AUDIT: an adminBurn must make a position MORE liquidatable, not less. Reading the
    /// stored collateralRaw made a fully-unsecured position read as healthy — permanently
    /// unliquidatable while backing nothing.
    function test_burnedCollateralMakesPositionLiquidatableNotStuck() public {
        uint256 id = _borrow(700e6);
        tok.adminBurn(address(pool), 9e18); // 10 posted -> 1 survives, $200 backing $700
        vm.prank(LIQUIDATOR);
        pool.liquidate(id); // must NOT revert PositionHealthy
        assertEq(pool.debtOf(id), 0, "position closed");
    }

    /// R1-AUDIT: the ordering bug. Two borrowers, one burn — each loses their share, in either
    /// order. Previously whoever repaid first was made whole out of the other's collateral.
    function test_burnLossIsSharedNotAllocatedByRepaymentOrder() public {
        uint256 aliceId = _borrow(700e6);
        address BOB = makeAddr("bob");
        tok.mint(BOB, 100e18); usdg.mint(BOB, 10_000e6);
        vm.startPrank(BOB);
        tok.approve(address(pool), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        uint256 bobId = pool.borrow(10e18, 700e6);
        vm.stopPrank();

        tok.adminBurn(address(pool), 10e18); // 20 posted -> 10 survive

        uint256 aliceBefore = tok.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.repay(aliceId, 700e6);
        assertEq(tok.balanceOf(ALICE) - aliceBefore, 5e18, "Alice gets HER half, not all of it");

        uint256 bobBefore = tok.balanceOf(BOB);
        vm.prank(BOB);
        pool.repay(bobId, 700e6);
        assertEq(tok.balanceOf(BOB) - bobBefore, 5e18, "Bob is not left with zero");
    }

    /// R1-AUDIT: a zero-debt position could never be repaid nor liquidated — collateral trapped.
    function test_zeroDebtBorrowIsRejected() public {
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.borrow(10e18, 0);
    }

    /// R1-AUDIT + fix #5: a COLLATERAL-token pause must NOT forgive interest pool-wide — watching
    /// collateral tokens let an unrelated pause hand every borrower a free loan.
    function test_aCollateralPauseDoesNotForgiveInterest() public {
        (EsseyPool p2, uint256 id) = _pausePoolWithABorrower();
        tok.setPaused(true);
        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        assertGt(p2.debtOf(id), 700e6, "a collateral pause must NOT hand a free loan");
    }

    /// R8 MED-1. The property ranges over TWO dimensions — pause state AND time — and the test this
    /// replaced varied one: it set the pause BEFORE the warp, so pause state was constant across the
    /// interval and the fixture passed identically against the defect and against the fix.
    ///
    /// Here the pause lands INSIDE the interval. A year in which repayment was possible on every one
    /// of its seconds must still be charged, however the last second reads.
    function test_aPauseAtTheCallInstantCannotEraseAnUnpausedInterval() public {
        (EsseyPool p2, uint256 id) = _pausePoolWithABorrower();
        uint256 snap = vm.snapshotState();

        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        uint256 honest = p2.debtOf(id);
        uint256 honestAssets = p2.totalAssets();
        vm.revertToState(snap);

        vm.warp(block.timestamp + 365 days);
        usdg.setPausedWord(1); // the issuer pauses in the final second; a STRANGER calls accrue()
        vm.prank(address(0xBAD));
        p2.accrue();

        assertGt(honest, 700e6, "the control really accrued, so this is not vacuous");
        assertEq(p2.debtOf(id), honest, "an unpaused year is charged whatever the closing read says");
        assertEq(p2.totalAssets(), honestAssets, "and no lender interest is destroyed");
    }

    /// The pause moves in BOTH directions inside one measured span, against a control that varies
    /// only time. The witnessed paused window must contribute exactly nothing and the two unpaused
    /// days must contribute exactly what they would have with no pause at all.
    ///
    /// R9 LOW-1: this test used to forgive a 365-day window from TWO accrue() calls, which is the
    /// defect — it asserted that an interval nothing bounds costs nothing, so the bounded fix turned
    /// it red. Rewritten to witness at the cadence a witness is actually good for; the property it was
    /// named for survives, and the straddle it permitted is pinned by the test below.
    function test_onlyTheWitnessedPausedWindowIsForgiven() public {
        (EsseyPool p2, uint256 id) = _pausePoolWithABorrower();
        uint256 snap = vm.snapshotState();

        vm.warp(block.timestamp + 1 days); p2.accrue();
        vm.warp(block.timestamp + 1 days); p2.accrue();
        uint256 twoUnpausedDays = p2.debtOf(id);
        vm.revertToState(snap);

        vm.warp(block.timestamp + 1 days);
        usdg.setPausedWord(1);
        p2.accrue(); // charges day one, and WITNESSES the pause
        for (uint256 i = 0; i < 12; i++) {
            vm.warp(block.timestamp + 1 hours);
            p2.accrue(); // both endpoints paused, and no witness is stretched past what it vouches for
        }
        usdg.setPausedWord(0);
        vm.warp(block.timestamp + 1 days);
        p2.accrue(); // charges day two

        assertGt(twoUnpausedDays, 700e6, "the control really accrued, so this is not vacuous");
        assertEq(p2.debtOf(id), twoUnpausedDays, "the witnessed paused window cost the borrower nothing");
    }

    /// R9 LOW-1. TWO unrelated pause episodes, bracketing a year in which repayment was possible on
    /// every second. The contract cannot tell this world from a year that was genuinely paused
    /// throughout and witnessed only at its two ends — which is the whole reason a pair of reads may
    /// not buy the interval between them. Only MAX_FORGIVEN_GAP is forgiven, so the straddled world
    /// must charge EXACTLY what an unpaused world charges over a span one gap shorter.
    function test_aStraddlingPausePairCannotForgiveTheUnpausedYearBetween() public {
        (EsseyPool p2, uint256 id) = _pausePoolWithABorrower();
        uint256 t0 = block.timestamp;
        uint256 snap = vm.snapshotState();

        vm.warp(t0 + 365 days - 1 hours);
        p2.accrue();
        uint256 chargedLessOneGap = p2.debtOf(id);
        uint256 lenderAssets = p2.totalAssets();
        vm.revertToState(snap);

        usdg.setPausedWord(1);
        vm.prank(address(0xBAD));
        p2.accrue(); // episode one: a stranger witnesses, and pays only gas
        usdg.setPausedWord(0); // the pause lifts; every second of the next year is repayable
        vm.warp(t0 + 365 days);
        usdg.setPausedWord(1); // episode two, a year later and unrelated
        vm.prank(address(0xBAD));
        p2.accrue();

        assertGt(chargedLessOneGap, 700e6, "the control really accrued, so this is not vacuous");
        assertEq(p2.debtOf(id), chargedLessOneGap, "a straddled year is charged but for the one gap witnessed");
        assertEq(p2.totalAssets(), lenderAssets, "and no lender interest is destroyed");
    }

    /// The bound is a comparison on a money path, so its boundary is pinned rather than left to the
    /// magnitude tests: exactly MAX_FORGIVEN_GAP is forgiven whole, one second more is charged for
    /// that one second and not for the gap.
    ///
    /// Every span below is a LITERAL, deliberately. Written against `p2.MAX_FORGIVEN_GAP()` these
    /// fixtures rescaled with the constant, so the bound could be moved to 0, to 1 second or to 24
    /// hours with all three tests still green — the fixture co-varied with the thing it existed to
    /// pin, and the gate caught it as M49/M50/M51 surviving. A test parameterised by the value under
    /// test cannot see that value change.
    function test_theForgivenGapBoundaryIsExact() public {
        (EsseyPool p2, uint256 id) = _pausePoolWithABorrower();
        uint256 t0 = block.timestamp;
        uint256 snap = vm.snapshotState();

        assertEq(p2.MAX_FORGIVEN_GAP(), 1 hours, "the bound is a chosen magnitude, pinned here directly");

        usdg.setPausedWord(1);
        p2.accrue();
        vm.warp(t0 + 1 hours);
        p2.accrue();
        assertEq(p2.debtOf(id), 700e6, "exactly one gap is forgiven whole");
        vm.revertToState(snap);

        vm.warp(t0 + 1);
        p2.accrue();
        uint256 oneSecond = p2.debtOf(id);
        vm.revertToState(snap);

        usdg.setPausedWord(1);
        p2.accrue();
        vm.warp(t0 + 1 hours + 1);
        p2.accrue();
        assertGt(oneSecond, 700e6, "one second really does accrue, so this is not vacuous");
        assertEq(p2.debtOf(id), oneSecond, "one second past the gap is charged for one second");
    }

    /// The accepted residual, pinned so a later "fix" that forgives it goes red. `paused()` is a bare
    /// boolean and the live USDG proxy exposes no timestamp variant, so a window nobody called
    /// accrue() inside leaves no on-chain trace. Forgiving it on the strength of the closing read is
    /// exactly the erasure above. Witnessing costs one permissionless call, which anyone may make.
    function test_anUnwitnessedPausedWindowIsCharged() public {
        (EsseyPool p2, uint256 id) = _pausePoolWithABorrower();
        usdg.setPausedWord(1);
        vm.warp(block.timestamp + 365 days);
        usdg.setPausedWord(0);
        p2.accrue();
        assertGt(p2.debtOf(id), 700e6, "no witness, no record, no forgiveness");
    }

    /// An idle pool has nothing to accrue, which is NOT the same as a suspended one: its clock must
    /// still advance, or the first borrower is billed for the wait. This is what rules out the
    /// minimal fix for MED-1 — moving the clock below the early return conflates the three reasons
    /// `_growth` can report no growth. No borrower here, so it asserts on the clock and nothing else.
    function test_anIdlePoolKeepsItsAccrualClockCurrent() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        p2.accrue();
        assertEq(p2.totalBorrows(), 0, "the pool is idle: nothing to accrue");
        vm.warp(block.timestamp + 30 days);
        p2.accrue();
        assertEq(p2.lastAccrual(), block.timestamp, "an idle clock still runs");
    }

    function _pausePoolWithABorrower() internal returns (EsseyPool p2, uint256 id) {
        p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        id = p2.borrow(10e18, 700e6);
        vm.stopPrank();
    }

    /// CRITICAL (fix #1): a BORROW ASSET whose paused() returns a NON-boolean word must not freeze the pool.
    /// Pre-fix, abi.decode(ret,(bool)) panicked (0x21) inside accrue() — run by every entry point —
    /// bricking deposit/borrow/repay/liquidate.
    function test_nonBooleanPausedWordDoesNotFreezeThePool() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();

        usdg.setPausedWord(2); // a NON-boolean word on the borrow asset
        vm.warp(block.timestamp + 1 days);
        p2.accrue(); // pre-fix: reverts Panic(0x21); post-fix: nonzero word treated as paused, no revert

        // an entry point still works despite the non-bool word (deposit runs accrue() first)
        usdg.mint(LENDER, 1_000e6);
        vm.startPrank(LENDER); uint256 sh = p2.deposit(1_000e6, LENDER); vm.stopPrank();
        assertGt(sh, 0, "not frozen by a non-boolean paused() word on the borrow asset");
    }

    /// HIGH (borrow-path fix #4): interest pending between accruals must NOT be extractable by an atomic
    /// deposit->redeem. Pre-fix, OZ priced the deposit against stale (pre-accrual) totalAssets, so the
    /// depositor captured interest owed to existing lenders. Post-fix, accrue() runs before the preview,
    /// so the attacker buys shares at the current price and redeems at the same price — no free interest.
    function test_pendingInterestNotExtractableByDepositRedeem() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        p2.borrow(10e18, 700e6); // a borrower generating interest (max LTV on 10 @ $200)
        vm.stopPrank();

        // interest accrues but is NOT yet booked (no accrue() call in the interim)
        vm.warp(block.timestamp + 30 days);

        address ATTACKER = makeAddr("attacker4");
        usdg.mint(ATTACKER, 100_000e6);
        vm.startPrank(ATTACKER);
        usdg.approve(address(p2), type(uint256).max);
        uint256 shares = p2.deposit(100_000e6, ATTACKER); // pre-fix: priced at stale low totalAssets
        uint256 got = p2.redeem(shares, ATTACKER, ATTACKER); // pre-fix: redeems after interest booked -> profit
        vm.stopPrank();

        assertLe(got, 100_000e6, "attacker cannot skim pending interest owed to existing lenders");
    }

    /// R1-AUDIT: THE FIRST-DEPOSITOR INFLATION ATTACK, run as an actual attack rather than
    /// asserted as prevented. Deposit 1 wei, donate directly to inflate the share price, and the
    /// victim's deposit rounds to zero shares while the attacker redeems everything.
    ///
    /// This test exists because setting _decimalsOffset() to 0 previously left the whole suite
    /// green — the mitigation was present but nothing proved it worked.
    function test_firstDepositorInflationAttackFails() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        address ATTACKER = makeAddr("attacker");
        address VICTIM = makeAddr("victim");
        usdg.mint(ATTACKER, 200_000e6);
        usdg.mint(VICTIM, 100_000e6);

        vm.startPrank(ATTACKER);
        usdg.approve(address(p2), type(uint256).max);
        p2.deposit(1, ATTACKER);                    // 1. one wei
        usdg.transfer(address(p2), 100_000e6);      // 2. donate to inflate share price
        vm.stopPrank();

        vm.startPrank(VICTIM);
        usdg.approve(address(p2), type(uint256).max);
        uint256 victimShares = p2.deposit(100_000e6, VICTIM);  // 3. must NOT round to zero
        vm.stopPrank();
        assertGt(victimShares, 0, "victim must receive shares");

        // 4. attacker redeems everything they hold and must not profit at the victim's expense
        vm.startPrank(ATTACKER);
        uint256 got = p2.redeem(p2.balanceOf(ATTACKER), ATTACKER, ATTACKER);
        vm.stopPrank();
        assertLe(got, 100_000e6 + 1, "attacker must not extract the victim's deposit");

        // and the victim can still get materially all of their money back
        vm.startPrank(VICTIM);
        uint256 back = p2.redeem(victimShares, VICTIM, VICTIM);
        vm.stopPrank();
        assertGe(back, 99_000e6, "victim recovers substantially all of their deposit");
    }


    // ------------------------------------------------- MED-1: the collateral-pause exit

    /// G-LEND MED-1. repay() used to END in a collateral transfer, so the Robinhood issuer's
    /// PAUSER_ROLE pinned a borrower inside a position that kept accruing: repay, addCollateral and
    /// removeCollateral all reverted and only repayPartial survived, which cannot close (UseFullRepay
    /// at amount >= owed). The DEBT must settle regardless of whether the collateral can move.
    function test_repayClosesTheDebtUnderACollateralPause() public {
        uint256 id = _borrow(700e6);
        uint256 stockBefore = tok.balanceOf(ALICE);
        tok.setPaused(true);

        // the trap that remains, and is now merely a delay: the collateral cannot physically move
        vm.prank(ALICE);
        vm.expectRevert(bytes("token paused"));
        pool.addCollateral(id, 1e18);

        vm.prank(ALICE);
        pool.repay(id, 700e6);
        assertEq(pool.debtOf(id), 0, "the debt settles even though the collateral cannot move");
        assertEq(pool.totalBorrows(), 0, "and is released from the pool's books");
        assertEq(pool.marketBorrows(address(tok)), 0, "and from the market's exposure");
        assertEq(tok.balanceOf(ALICE), stockBefore, "the collateral is still held by the pool");
        assertEq(pool.note().ownerOf(id), ALICE, "the Note survives as the claim ticket");

        tok.setPaused(false);
        vm.prank(ALICE);
        assertEq(pool.claimCollateral(id), 10e18, "the full collateral comes back on the unpause");
        assertEq(tok.balanceOf(ALICE), stockBefore + 10e18);
        Note spent = pool.note(); // hoisted: an inline call would be what expectRevert catches
        vm.expectRevert();
        spent.ownerOf(id); // the deed is spent
    }

    /// The other way an ERC-20 declines — `return false`, revert nothing. A caller that only handled
    /// the revert would treat this as delivery and burn the Note against collateral it never sent.
    function test_aSilentlyFailingTransferEscrowsRatherThanBurningTheDeed() public {
        uint256 id = _borrow(700e6);
        uint256 stockBefore = tok.balanceOf(ALICE);
        tok.setTransferReturnsFalse(true);

        vm.prank(ALICE);
        pool.repay(id, 700e6);
        assertEq(tok.balanceOf(ALICE), stockBefore, "nothing was delivered");
        assertEq(pool.note().ownerOf(id), ALICE, "so the deed must NOT have been burned");

        tok.setTransferReturnsFalse(false);
        vm.prank(ALICE);
        assertEq(pool.claimCollateral(id), 10e18);
    }

    /// The escrow keeps bearer semantics: the claim follows the Note, not the original borrower.
    function test_theEscrowedClaimFollowsTheNote() public {
        uint256 id = _borrow(700e6);
        tok.setPaused(true);
        vm.prank(ALICE);
        pool.repay(id, 700e6);
        tok.setPaused(false);

        Note deed = pool.note(); // hoisted: an inline call would eat the prank
        vm.prank(ALICE);
        deed.transferFrom(ALICE, LIQUIDATOR, id);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.claimCollateral(id); // the former holder has no claim left
        vm.prank(LIQUIDATOR);
        assertEq(pool.claimCollateral(id), 10e18, "the new holder collects");
        assertEq(tok.balanceOf(LIQUIDATOR), 10e18);
    }

    /// An OPEN position is not an escrow, and a spent one is not either. Both must be refused by
    /// name — `claimCollateral` is the only path that can touch a principal-zero position, so a
    /// wrong guard here is a way to walk collateral out of a live loan.
    function test_claimCollateralRefusesOpenAndSpentPositions() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.DebtOutstanding.selector, id));
        pool.claimCollateral(id);

        vm.prank(ALICE);
        pool.repay(id, 700e6); // unpaused: the normal path, which closes fully
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.NothingToClaim.selector, id));
        pool.claimCollateral(id);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.NothingToClaim.selector, uint256(999)));
        pool.claimCollateral(999);
    }

    /// The escrowed collateral stays ON THE BOOKS under its own index snapshot, so an adminBurn
    /// during the freeze is shared exactly as it would have been before the repay. Holding it off
    /// the reconciler instead would have made the surviving balance look larger than it is and
    /// masked the burn for everyone still open.
    function test_anAdminBurnDuringTheEscrowIsStillShared() public {
        uint256 idA = _borrow(700e6);
        vm.prank(LIQUIDATOR);
        tok.approve(address(pool), type(uint256).max);
        tok.mint(LIQUIDATOR, 10e18);
        vm.prank(LIQUIDATOR);
        uint256 idB = pool.borrow(10e18, 700e6); // same cohort, both pre-burn

        tok.setPaused(true);
        vm.prank(ALICE);
        pool.repay(idA, 700e6); // escrowed, still booked
        tok.setPaused(false);

        tok.adminBurn(address(pool), 10e18); // the issuer destroys half of the pool's stock
        vm.prank(ALICE);
        uint256 claimed = pool.claimCollateral(idA);
        assertEq(claimed, 5e18, "the escrowed claim takes its pro-rata share of the burn");
        assertEq(pool.recordedRaw(address(tok)), 10e18, "and B's nominal collateral is untouched");
        vm.prank(LIQUIDATOR);
        pool.repay(idB, 700e6);
        assertEq(tok.balanceOf(LIQUIDATOR), 5e18, "B takes the other half of the loss, not all of it");
    }

    // ------------------------------------------------- guards found by mutation sweep

    /// G-LEND LOW-1. The pool's cash constraint has to be visible in maxWithdraw/maxRedeem, or a
    /// spec-following 4626 router asks for the advertised figure and reverts — measured at cash
    /// 148355994889 against maxWithdraw 150000000000. Three assertions, because "it reverts" was
    /// what the old test settled for and it is the weakest of the three: the advertised figure
    /// EQUALS the cash, handing it straight back SUCCEEDS, and one wei more is refused by the 4626
    /// max gate. Assert the SPECIFIC error — a bare expectRevert() also matches the SafeERC20
    /// failure that would happen anyway, which is how the deleted-guard mutant used to survive.
    function test_maxWithdrawIsCappedAtCashAndRoundTrips() public {
        _borrow(700e6);
        uint256 cash = usdg.balanceOf(address(pool));
        assertGt(pool.convertToAssets(pool.balanceOf(LENDER)), cash, "fixture must be cash-constrained");
        assertEq(pool.maxWithdraw(LENDER), cash, "maxWithdraw must not advertise past the cash");

        vm.prank(LENDER);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, LENDER, cash + 1, cash)
        );
        pool.withdraw(cash + 1, LENDER, LENDER);

        uint256 advertised = pool.maxWithdraw(LENDER); // hoisted: an inline call would eat the prank
        vm.prank(LENDER);
        pool.withdraw(advertised, LENDER, LENDER);
        assertEq(usdg.balanceOf(address(pool)), 0, "the advertised figure must be exactly withdrawable");
    }

    /// The redeem side is the one that needed the ACCRUED price. redeem() accrues before it previews,
    /// and accrual raises the share price — so shares sized at today's cheaper price redeem for MORE
    /// assets than the pool holds, and the advertised figure reverts.
    ///
    /// This runs on its own INTEREST-BEARING pool on purpose. The suite's shared fixture is
    /// deliberately zero-rate, which means `_accruedAssets()` and `totalAssets()` are always equal
    /// there and the distinction under test is invisible — the mutation that swaps one for the other
    /// survives every zero-rate test in this file.
    function test_maxRedeemIsCappedAtTheACCRUEDPriceNotTodays() public {
        EsseyPool ip = _interestPool();
        uint256 cash = usdg.balanceOf(address(ip));
        assertGt(ip.balanceOf(LENDER), 0);
        vm.warp(block.timestamp + 3650 days); // a decade at 10%: the share price moves materially

        uint256 shares = ip.maxRedeem(LENDER);
        assertLt(shares, ip.balanceOf(LENDER), "fixture must be cash-constrained");
        vm.prank(LENDER);
        uint256 got = ip.redeem(shares, LENDER, LENDER); // the whole property: it must NOT revert
        assertLe(got, cash, "and it must not pay out more than the pool held");
        assertGt(got, 0);
    }

    /// The assets side of the same claim, on the same interest-bearing pool.
    function test_maxWithdrawIsCappedAtTheACCRUEDPriceNotTodays() public {
        EsseyPool ip = _interestPool();
        uint256 cash = usdg.balanceOf(address(ip));
        vm.warp(block.timestamp + 3650 days);
        uint256 advertised = ip.maxWithdraw(LENDER);
        assertEq(advertised, cash, "still capped at the cash");
        vm.prank(LENDER);
        ip.withdraw(advertised, LENDER, LENDER);
        assertEq(usdg.balanceOf(address(ip)), 0, "every advertised wei was withdrawable");
    }

    /// The OTHER direction of the same choice, and the one the cash clamp hides: when the pool is
    /// NOT cash-constrained, maxWithdraw is the lender's whole claim — and pricing it at today's
    /// assets rather than the post-accrual ones UNDERSTATES it by every second of pending interest.
    /// A 4626 router that withdraws the advertised maximum would then leave shares behind and call
    /// the position closed. Two lenders, so one lender's claim sits inside the cash.
    function test_maxWithdrawAdvertisesTheWholeClaimWhenCashIsNotTheBinding() public {
        EsseyPool ip = _interestPool();
        usdg.mint(LIQUIDATOR, 100_000e6);
        vm.startPrank(LIQUIDATOR);
        usdg.approve(address(ip), type(uint256).max);
        ip.deposit(100_000e6, LIQUIDATOR);
        vm.stopPrank();
        vm.warp(block.timestamp + 3650 days); // a decade of pending, un-accrued interest

        uint256 advertised = ip.maxWithdraw(LENDER);
        assertLt(advertised, usdg.balanceOf(address(ip)), "fixture must NOT be cash-constrained");

        // What the lender is owed once the pending interest is booked — which is precisely what
        // `withdraw` will price against, because it accrues first.
        uint256 snap = vm.snapshotState();
        ip.accrue();
        uint256 trueClaim = ip.convertToAssets(ip.balanceOf(LENDER));
        vm.revertToState(snap);
        assertEq(advertised, trueClaim, "maxWithdraw must quote the ACCRUED claim, not today's");

        vm.prank(LENDER);
        ip.withdraw(advertised, LENDER, LENDER); // and it is executable, not merely quotable
        assertLt(ip.maxWithdraw(LENDER), 1, "nothing withdrawable is left behind");
    }

    /// A pool that actually charges interest, funded and drawn so the cash constraint binds.
    function _interestPool() internal returns (EsseyPool ip) {
        ip = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        vm.startPrank(LENDER);
        usdg.approve(address(ip), type(uint256).max);
        ip.deposit(100_000e6, LENDER);
        vm.stopPrank();
        _activate(ip);
        vm.startPrank(ALICE);
        tok.approve(address(ip), type(uint256).max);
        ip.borrow(10e18, 700e6);
        vm.stopPrank();
    }

    /// F-5 sweep survivor: the withdraw liquidity guard is `>`, not `>=` — draining the pool's
    /// idle cash to exactly zero is a legitimate withdrawal, not an error.
    function test_withdrawExactlyAllIdleCashSucceeds() public {
        uint256 cash = usdg.balanceOf(address(pool));
        vm.prank(LENDER);
        pool.withdraw(cash, LENDER, LENDER);
        assertEq(usdg.balanceOf(address(pool)), 0, "every idle wei is withdrawable");
    }

    /// F-5 sweep survivor: accrue over a borrow-free stretch must not move borrowIndex. With the
    /// early return deleted the index idles upward at baseBps — invisible to debtOf (ratios cancel)
    /// but wrong to every keeper and UI reading the public index.
    function test_accrueWithoutBorrowsLeavesTheIndexAlone() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% base APR
        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        assertEq(p2.borrowIndex(), 1e18, "no borrows, no one to charge, no index movement");
        assertEq(p2.totalBorrows(), 0);
    }

    function test_borrowBeyondMarketCapReverts() public {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 500e6, maxPositionBps: 10_000 // cap below one max-LTV loan
        });
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool), m);
        _warpTimelock();
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        _beat(); _advanceLive(GRACE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.ExceedsMarketCap.selector, 700e6, 500e6));
        pool.borrow(10e18, 700e6);
    }

    function test_borrowBeyondPoolLiquidityReverts() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // empty pool: no cash at all
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.InsufficientLiquidity.selector, 700e6, 0));
        p2.borrow(10e18, 700e6);
        vm.stopPrank();
    }

    function test_repayOnAClosedPositionReverts() public {
        uint256 id = _borrow(700e6);
        vm.startPrank(ALICE);
        pool.repay(id, 700e6);
        // The position is deleted, so borrower is address(0) and the ownership check fires first.
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.repay(id, 700e6);
        vm.stopPrank();
    }

    function test_liquidatingAClosedPositionReverts() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        pool.repay(id, 700e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.liquidate(id);
    }

    function test_curveSumIsBounded() public {
        vm.expectRevert(EsseyPool.BadCurve.selector);
        new EsseyPool(usdg, address(tok), mk, 90_000, 90_000, 90_000, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // legs individually ok, sum is not
    }

    /// Mainnet-config fix: the pool's markets.assetDecimals must MATCH the real borrow-asset decimals(), so a
    /// mis-set value (e.g. 18 against mainnet USDG's 6) can't reintroduce the 1e12 LTV over-valuation. usdg is
    /// 6-dec; a markets built with assetDecimals=18 must be un-poolable against it.
    function test_assetDecimalsMustMatchTheBorrowAsset() public {
        EsseyMarkets wrong = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, ADMIN, GUARDIAN, 18); // 18 != usdg's 6
        vm.expectRevert(EsseyPool.AssetDecimalsMismatch.selector);
        new EsseyPool(usdg, address(tok), wrong, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
    }

    // ---------------------------------------------------------------- F-3: addCollateral

    function test_addCollateralAfterLiquidationReverts() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(125e8); // $1250 backing, 55% threshold = $687.50 < $700
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.addCollateral(id, 1e18);
    }

    function test_addCollateralRestoresHealthAndBlocksLiquidation() public {
        uint256 id = _borrow(700e6);
        _walkPrice(125e8); // underwater at 10 shares
        vm.prank(ALICE);
        pool.addCollateral(id, 5e18); // 15 @ $125 = $1875; 55% = $1031.25 > $700
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.PositionHealthy.selector);
        pool.liquidate(id);
    }

    /// F-3 conservation: a top-up adds EXACTLY `amount` to the payer's entitlement and moves
    /// nobody else's. Also the pin that addCollateral reconciles first — without it, Alice's
    /// pre-burn raw would be re-credited whole and dilute Bob.
    function test_addCollateralConservesEntitlementsAcrossABurn() public {
        uint256 aliceId = _borrow(700e6);
        address BOB = makeAddr("bob_topup");
        tok.mint(BOB, 10e18); usdg.mint(BOB, 10_000e6);
        vm.startPrank(BOB);
        tok.approve(address(pool), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        uint256 bobId = pool.borrow(10e18, 700e6);
        vm.stopPrank();

        tok.adminBurn(address(pool), 10e18); // 20 posted -> 10 survive: 5 each

        vm.prank(ALICE);
        pool.addCollateral(aliceId, 2e18); // Alice: 5 surviving + 2 fresh = 7

        uint256 bobBefore = tok.balanceOf(BOB);
        vm.prank(BOB);
        pool.repay(bobId, 700e6);
        assertEq(tok.balanceOf(BOB) - bobBefore, 5e18, "Bob untouched by Alice's top-up");

        uint256 aliceBefore = tok.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.repay(aliceId, 700e6);
        assertEq(tok.balanceOf(ALICE) - aliceBefore, 7e18, "eff_after == eff_before + amount");
    }

    /// F-3: the ABSENCE of gates is the invariant (LivenessOracle.sol:109-111). Liveness dead,
    /// off-session, market disabled, caller a stranger — the top-up must still land.
    function test_addCollateralWorksUngatedByAnyone() public {
        uint256 id = _borrow(700e6);
        vm.prank(GUARDIAN);
        mk.disableMarket(address(tok));
        uint256 night = (block.timestamp / 86400) * 86400 + 1 days + 3 hours;
        vm.warp(night); // hours past the last heartbeat, off-session
        assertFalse(liv.liquidationsAllowed(), "liveness gate is genuinely closed");
        assertFalse(mk.canBorrow(address(tok)), "borrow gate is genuinely closed");

        address STRANGER = makeAddr("stranger_topup");
        tok.mint(STRANGER, 3e18);
        vm.startPrank(STRANGER);
        tok.approve(address(pool), type(uint256).max);
        pool.addCollateral(id, 3e18);
        vm.stopPrank();
        (, uint256 raw,,,) = pool.positions(id);
        assertEq(raw, 13e18, "top-up landed while every gate was closed");
    }

    function test_addCollateralZeroReverts() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.ZeroAmount.selector);
        pool.addCollateral(id, 0);
    }

    function test_addCollateralOnWipedCohortReverts() public {
        uint256 aliceId = _borrow(700e6);
        address BOB = makeAddr("bob_wiped");
        tok.mint(BOB, 10e18); usdg.mint(BOB, 10_000e6);
        vm.startPrank(BOB);
        tok.approve(address(pool), type(uint256).max);
        pool.borrow(10e18, 700e6);
        vm.stopPrank();
        tok.adminBurn(address(pool), 20e18); // total burn: index -> 0 with the cohort still open

        vm.prank(ALICE);
        tok.approve(address(pool), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(CollateralReconciler.CollateralCohortWiped.selector, address(tok)));
        pool.addCollateral(aliceId, 1e18);
    }

    // ---------------------------------------------------------------- F-4: repayPartial

    function testFuzz_repayPartialReducesDebtExactly(uint256 elapsed, uint256 x) public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        elapsed = bound(elapsed, 1 hours, 3 * 365 days);
        vm.warp(block.timestamp + elapsed);
        p2.accrue();
        uint256 owedBefore = p2.debtOf(id);
        x = bound(x, 1, owedBefore - 1);

        vm.prank(ALICE);
        p2.repayPartial(id, x);
        assertEq(p2.debtOf(id), owedBefore - x, "debt falls by exactly the payment");
    }

    function test_repayPartialOfFullOwedRevertsToRepay() public {
        uint256 id = _borrow(700e6);
        uint256 owed = pool.debtOf(id);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.UseFullRepay.selector, owed, owed));
        pool.repayPartial(id, owed);
    }

    function test_repayPartialZeroReverts() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.ZeroAmount.selector);
        pool.repayPartial(id, 0);
    }

    function test_repayPartialOnClosedPositionReverts() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        pool.repay(id, 700e6);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.repayPartial(id, 1);
    }

    /// F-4: the cap gates NEW borrows only. When an interest rebase carries principal past the
    /// market cap, the paydown must never revert ExceedsMarketCap — that would brick paydowns
    /// exactly when the market is most stressed.
    function test_repayPartialNeverRevertsExceedsMarketCap() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 500e6, maxPositionBps: 10_000
        });
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(p2), m);
        _warpTimelock();
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        _beat(); _advanceLive(GRACE);

        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 500e6); // exactly at the cap
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        assertGt(p2.debtOf(id), 500e6, "interest carried the debt past the cap");

        vm.prank(ALICE);
        p2.repayPartial(id, 1e6); // must NOT revert ExceedsMarketCap
        assertEq(p2.marketBorrows(address(tok)), p2.debtOf(id), "marketBorrows tracks the rebased principal");
    }

    function test_fullRepayAfterPartialClosesNormally() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        pool.repayPartial(id, 300e6);
        assertEq(pool.debtOf(id), 400e6);
        uint256 before_ = usdg.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.repay(id, 400e6);
        assertEq(before_ - usdg.balanceOf(ALICE), 400e6, "charges only the remainder");
        assertEq(tok.balanceOf(ALICE), 1_000e18, "collateral fully returned");
        assertEq(pool.marketBorrows(address(tok)), 0, "slot freed exactly once");
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.liquidate(id);
    }

    /// F-4: a 1-wei stranger paydown is PERMISSIONLESS and changes nothing but the debt.
    function test_strangerPartialRepayChangesOnlyDebt() public {
        uint256 id = _borrow(700e6);
        uint256 aliceUsdg = usdg.balanceOf(ALICE);
        uint256 aliceTok = tok.balanceOf(ALICE);
        uint256 assetsBefore = pool.totalAssets();

        vm.prank(LIQUIDATOR); // not the Note holder
        pool.repayPartial(id, 1);

        assertEq(pool.debtOf(id), 700e6 - 1, "debt down by exactly the wei");
        assertEq(pool.marketBorrows(address(tok)), 700e6 - 1);
        assertEq(pool.note().ownerOf(id), ALICE, "deed untouched");
        (, uint256 raw,,,) = pool.positions(id);
        assertEq(raw, 10e18, "collateral untouched");
        assertEq(usdg.balanceOf(ALICE), aliceUsdg);
        assertEq(tok.balanceOf(ALICE), aliceTok);
        assertEq(pool.totalAssets(), assetsBefore, "cash up, borrows down, in lockstep");
    }

    // ------------------------------------------------- AD-1 step 3: per-position cap

    function _setPositionCap(uint16 bps, EsseyPool p) internal {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: bps
        });
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(p), m);
        _warpTimelock();
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        _beat(); _advanceLive(GRACE);
    }

    function test_borrowPositionCapBoundaryIsExact() public {
        _setPositionCap(5, pool); // limit = 1_000_000e6 x 5bp = 500e6, inside the 700e6 LTV headroom
        vm.prank(ALICE);
        pool.borrow(10e18, 500e6); // exactly at the limit
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.ExceedsPositionCap.selector, 500e6 + 1, 500e6));
        pool.borrow(10e18, 500e6 + 1);
    }

    /// ROUNDING DIRECTION on the floating per-position limit. Every other cap fixture uses a
    /// remainder-free (cap, bps) pair, so a ceil reads identically — while a ceil lets one position
    /// hold more of a thin market than the depth oracle says the venue can absorb.
    ///   cap 90_000_000_004 x 3_333 / 1e4 = 29_997_000_001.3332 -> posLimit 9_998_000_100.3333
    function test_positionLimitTruncatesAgainstTheLiveCap() public {
        _setPositionCap(3_333, pool);
        vm.prank(KEEPER);
        hox.postDepth(address(tok), 90_000_000_004, uint64(block.number), "fork-swap-v1"); // ratchets down same block
        assertEq(mk.borrowCap(address(tok)), 29_997_000_001, "the depth target truncates too");

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.ExceedsPositionCap.selector, 9_998_000_101, 9_998_000_100));
        pool.borrow(200e18, 9_998_000_101);
        vm.prank(ALICE);
        pool.borrow(200e18, 9_998_000_100); // exactly at the FLOORED limit
    }

    /// The position cap gates NEW borrows only: an interest rebase may carry a position past it,
    /// and the paydown must never revert for it (mirror of the market-cap rule above).
    function test_repayPartialIgnoresPositionCap() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        _setPositionCap(7, p2); // limit = 700e6: a max-LTV borrow sits exactly at it
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        uint256 owed = p2.debtOf(id);
        assertGt(owed, 700e6, "interest carried the debt past the position limit");

        vm.prank(ALICE);
        p2.repayPartial(id, 1e6); // must NOT revert ExceedsPositionCap
        assertEq(p2.debtOf(id), owed - 1e6, "paydown lands while past the limit");
    }

    // ------------------------------------------------- AD-1 step 4: writeOff (F-1)

    function _installResolver() internal returns (address R) {
        R = makeAddr("resolver");
        vm.prank(ADMIN);
        mk.proposeResolver(R);
        _warpTimelock();
        px.set(200e8, block.timestamp);
        vm.prank(ADMIN);
        mk.commitResolver();
        _beat(); _advanceLive(GRACE);
        usdg.mint(R, 100_000e6);
        vm.prank(R);
        usdg.approve(address(pool), type(uint256).max);
    }

    function test_writeOffOnlyResolver() public {
        uint256 id = _borrow(700e6);
        vm.prank(LIQUIDATOR); // resolver still unset: nobody may write off
        vm.expectRevert(EsseyPool.NotResolver.selector);
        pool.writeOff(id, 0);
        _installResolver();
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.NotResolver.selector);
        pool.writeOff(id, 0);
    }

    /// Merely-underwater is the LIQUIDATOR's territory, at market. Write-off demands strictly
    /// beyond-recovery — including the value == owed edge.
    function test_writeOffMerelyUnderwaterReverts() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(125e8); // underwater (threshold $687.50) yet worth $1250 > $700
        vm.prank(R);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.NotInsolvent.selector, 1250e6, 700e6));
        pool.writeOff(id, 0);
        _walkPriceAndSettle(70e8); // worth EXACTLY the debt: still not beyond recovery
        vm.prank(R);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.NotInsolvent.selector, 700e6, 700e6));
        pool.writeOff(id, 0);
    }

    function test_writeOffNeedsLiquidatableWhenCollateralSurvives() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        _walkPrice(60e8); // beyond recovery on value
        vm.warp(block.timestamp + 2 hours); // but chain liveness is unproven
        _walkPrice(60e8); // price itself fresh — the liveness gate must still hold
        assertFalse(mk.canLiquidate(address(tok)), "fixture: gate closed by liveness alone");
        vm.prank(R);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.LiquidationNotAllowed.selector, address(tok)));
        pool.writeOff(id, 0);
    }

    function test_writeOffRecoveredAboveOwedReverts() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(60e8); // $600 backing $700: beyond recovery
        vm.prank(R);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.RecoveredExceedsOwed.selector, 700e6 + 1, 700e6));
        pool.writeOff(id, 700e6 + 1);
    }

    /// The AD-1 accounting core: the lender loss is EXACTLY residual - fromReserves, taken as a
    /// share-price markdown at the moment of write-off, with exposure released and the residual
    /// collateral swept to the resolver.
    function test_writeOffSharePriceDeltaIsExact() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(60e8);
        uint256 assetsBefore = pool.totalAssets();
        uint256 sharesBefore = pool.balanceOf(LENDER);

        vm.expectEmit(true, true, true, true);
        emit EsseyPool.WrittenOff(id, 700e6, 600e6, 0, 100e6, 10e18);
        vm.prank(R);
        pool.writeOff(id, 600e6); // the $600 collateral-value floor (A-M1)

        assertEq(pool.totalAssets(), assetsBefore - 100e6, "loss == residual - fromReserves, exactly");
        assertEq(pool.balanceOf(LENDER), sharesBefore, "the markdown moves price, never shares");
        assertEq(pool.totalBorrows(), 0, "debt released");
        assertEq(pool.marketBorrows(address(tok)), 0, "cap slot released");
        assertEq(tok.balanceOf(R), 10e18, "residual collateral swept to the resolver");
        Note n = pool.note();
        vm.expectRevert();
        n.ownerOf(id); // deed burned
    }

    function test_writeOffReservesAbsorbBeforeLenders() public {
        address R = _installResolver();
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 5_000, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR, half to reserves
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        _beat(); _advanceLive(GRACE);
        _walkPriceAndSettle(1e8); // $10 backing ~$770: beyond recovery
        // Read the book AFTER the corroboration hour: this pool actually charges interest (10% APR,
        // unlike the zero-rate main fixture), so a figure taken before it is stale by an hour and the
        // residual would no longer be the 30e6 the assertions below are about.
        p2.accrue();
        uint256 owed = p2.debtOf(id);
        uint256 reserves = p2.totalReserves();
        assertGt(reserves, 30e6, "fixture: a year of reserves to absorb with");
        uint256 assetsBefore = p2.totalAssets();
        vm.startPrank(R);
        usdg.approve(address(p2), type(uint256).max);
        p2.writeOff(id, owed - 30e6); // residual 30e6, fully inside reserves
        vm.stopPrank();

        assertEq(p2.totalAssets(), assetsBefore, "reserves absorb first; lender value untouched");
        assertEq(p2.totalReserves(), reserves - 30e6, "reserves down by exactly the residual");
    }

    function test_writeOffAccruesFirst() public {
        address R = _installResolver();
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 5_000, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        _beat(); _advanceLive(GRACE);
        _walkPriceAndSettle(1e8);
        vm.startPrank(R);
        usdg.approve(address(p2), type(uint256).max);
        p2.writeOff(id, 10e6); // 10 shares @ $1 = the $10 floor; no accrue() since the warp except writeOff's own
        vm.stopPrank();
        assertEq(p2.lastAccrual(), block.timestamp, "writeOff settles against accrued debt");
        assertEq(p2.totalBorrows(), 0);
    }

    function test_writeOffTwiceReverts() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(60e8);
        vm.prank(R);
        pool.writeOff(id, 600e6);
        vm.prank(R);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.writeOff(id, 600e6);
    }

    /// The wiped-cohort path must work with NO price read: when the issuer has destroyed the
    /// collateral outright the feed may be silent and liveness dead — exactly then the loss
    /// must still be recognisable.
    function test_writeOffWipedCohortNeedsNoPrice() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        tok.adminBurn(address(pool), 10e18); // issuer wipes the whole cohort
        vm.warp(block.timestamp + 200_000); // feed silent, liveness dead
        assertFalse(mk.canLiquidate(address(tok)), "fixture: every gate is closed");
        vm.prank(R);
        pool.writeOff(id, 0);
        assertEq(pool.totalBorrows(), 0, "written off with nothing readable but the balance");
        assertEq(pool.shortfallRaw(address(tok)), 10e18, "the burn was reconciled on the way");
    }

    function test_writeOffDepositSandwichCannotProfit() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(60e8);
        address ATT = makeAddr("sandwich");
        usdg.mint(ATT, 100_000e6);
        vm.startPrank(ATT);
        usdg.approve(address(pool), type(uint256).max);
        uint256 sh = pool.deposit(100_000e6, ATT); // front-run the pending write-off
        vm.stopPrank();
        vm.prank(R);
        pool.writeOff(id, 600e6); // pays the floor; residual loss = 100e6
        vm.startPrank(ATT);
        uint256 got = pool.redeem(sh, ATT, ATT);
        vm.stopPrank();
        assertLt(got, 100_000e6, "front-running a write-off buys a share of the loss, not a profit");
    }

    /// A-M1: the resolver pays AT LEAST the market value of the collateral it sweeps — without
    /// the floor it could pay 0 and sweep collateral worth ~owed. Boundary exact in both
    /// directions: floor-1 reverts, floor itself lands.
    function test_writeOffRecoveredBelowCollateralFloorReverts() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(60e8); // 10 shares @ $60 = $600 floor against $700 owed
        vm.prank(R);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.RecoveredBelowFloor.selector, 600e6 - 1, 600e6));
        pool.writeOff(id, 600e6 - 1);
        vm.prank(R);
        pool.writeOff(id, 600e6);
        assertEq(tok.balanceOf(R), 10e18, "collateral sweeps only once paid for at value");
    }

    // ------------------------------------------------- C-M2/B-L1: disable must not freeze positions

    function test_liquidateSucceedsOnADisabledMarket() public {
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(125e8); // underwater: $1250 backing, threshold $687.50 < $700
        vm.prank(GUARDIAN);
        mk.disableMarket(address(tok));
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        assertEq(pool.debtOf(id), 0, "existing positions stay liquidatable after a disable");
    }

    function test_writeOffSucceedsOnADisabledMarket() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        _walkPriceAndSettle(60e8); // $600 backing $700: beyond recovery
        vm.prank(GUARDIAN);
        mk.disableMarket(address(tok));
        vm.prank(R);
        pool.writeOff(id, 600e6);
        assertEq(pool.totalBorrows(), 0, "surviving dust stays write-off-able after a disable");
    }

    function test_repayStillWorksOnADisabledMarket() public {
        uint256 id = _borrow(700e6);
        vm.prank(GUARDIAN);
        mk.disableMarket(address(tok));
        vm.prank(ALICE);
        pool.repay(id, 700e6);
        assertEq(tok.balanceOf(ALICE), 1_000e18, "repay + collateral return survive a disable");
    }

    // ------------------------------------------------- B-M2: Notes are bearer deeds

    /// Repay authority follows the deed: after a transfer the buyer repays and takes the
    /// collateral; the original borrower is a stranger to the position.
    function test_transferredNoteMovesRepayAuthorityAndCollateral() public {
        uint256 id = _borrow(700e6);
        address BUYER = makeAddr("note_buyer");
        Note deed = pool.note(); // read BEFORE the prank: the getter call would consume it
        vm.prank(ALICE);
        deed.transferFrom(ALICE, BUYER, id);

        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.repay(id, 700e6);

        usdg.mint(BUYER, 1_000e6);
        vm.startPrank(BUYER);
        usdg.approve(address(pool), type(uint256).max);
        pool.repay(id, 700e6);
        vm.stopPrank();
        assertEq(tok.balanceOf(BUYER), 10e18, "collateral goes to the deed holder, not the opener");
    }

    /// Liquidation surplus routes to the CURRENT holder — the read-before-burn in liquidate().
    function test_transferredNoteRoutesLiquidationSurplusToHolder() public {
        uint256 id = _borrow(700e6);
        address BUYER = makeAddr("note_buyer2");
        Note deed = pool.note();
        vm.prank(ALICE);
        deed.transferFrom(ALICE, BUYER, id);

        _walkPriceAndSettle(125e8); // underwater: $1250 backing, threshold $687.50 < $700
        uint256 aliceTokBefore = tok.balanceOf(ALICE);
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);

        uint256 seized = tok.balanceOf(LIQUIDATOR);
        assertLt(seized, 10e18, "fixture: a surplus exists to route");
        assertEq(tok.balanceOf(BUYER), 10e18 - seized, "surplus goes to the holder at liquidation time");
        assertEq(tok.balanceOf(ALICE), aliceTokBefore, "the original borrower gets none of it");
    }

    function test_transferredNoteKeepsRepayPartialPermissionless() public {
        uint256 id = _borrow(700e6);
        Note deed = pool.note();
        vm.prank(ALICE);
        deed.transferFrom(ALICE, makeAddr("note_buyer3"), id);
        vm.prank(LIQUIDATOR); // any stranger
        pool.repayPartial(id, 100e6);
        assertEq(pool.debtOf(id), 600e6, "stranger paydown still lands after a transfer");
    }

    // ------------------------------------------------- AD-1: single-collateral binding

    function test_identityAndCollateralAreConstructorBound() public {
        EsseyPool p2 = new EsseyPool(
            usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0,
            EsseyPool.Identity("Essey AAPL Pool Share", "aAAPL", "Essey AAPL Note", "nAAPL")
        );
        assertEq(p2.name(), "Essey AAPL Pool Share");
        assertEq(p2.symbol(), "aAAPL");
        assertEq(p2.note().name(), "Essey AAPL Note");
        assertEq(p2.note().symbol(), "nAAPL");
        assertEq(p2.collateralToken(), address(tok));
    }

    function test_withdrawBeyondCashReverts() public {
        _borrow(700e6);
        vm.prank(LENDER);
        vm.expectRevert();
        pool.withdraw(500_000e6, LENDER, LENDER);
    }
}
