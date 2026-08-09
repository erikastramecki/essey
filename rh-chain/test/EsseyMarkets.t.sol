// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {StaleFeedGuard} from "../src/StaleFeedGuard.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed, MockStock} from "./RiskModules.t.sol";

contract EsseyMarketsTest is Test {
    EsseyMarkets mk;
    LivenessOracle liv;
    MockFeed seq;
    MockFeed px;
    MockStock tok;

    address ADMIN;
    address KEEPER;
    address GUARDIAN;

    // 2025-07-21 15:00 UTC — a Monday, 11:00 ET, inside the US equity session.
    uint256 constant MON_IN_SESSION = 1_753_110_000;
    uint256 constant MAX_AGE = 15 minutes;
    uint256 constant GRACE = 30 minutes;
    uint256 constant GAP = 10 minutes; // ~2 missed beats at a 5-minute cadence

    // The conservative v1 stance: 35% LTV / 55% liquidation = a 20pp gap.
    function _conservative() internal pure returns (EsseyMarkets.Market memory) {
        return EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6
        });
    }

    function setUp() public {
        ADMIN = makeAddr("admin");
        KEEPER = makeAddr("keeper");
        GUARDIAN = makeAddr("guardian");
        vm.warp(MON_IN_SESSION);

        seq = new MockFeed(0, 0);
        seq.setStartedAt(block.timestamp - 2 days);
        px = new MockFeed(200e8, 8); // $200
        tok = new MockStock();
        liv = new LivenessOracle(KEEPER, GUARDIAN, MAX_AGE, GRACE, GAP);
        mk = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, ADMIN, 6); // USDG is 6dp

        _enable(_conservative());
        _bringLivenessOnline();
    }

    function _enable(EsseyMarkets.Market memory m) internal {
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp); // keep the feed fresh across the warp
        mk.commitMarket(address(tok));
        vm.stopPrank();
    }

    function _beat() internal { vm.prank(KEEPER); liv.heartbeat(); }

    function _advanceLive(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes);
            px.set(200e8, block.timestamp);
            _beat();
        }
        vm.warp(end);
        px.set(200e8, block.timestamp);
        _beat();
    }

    function _bringLivenessOnline() internal {
        _beat();
        _advanceLive(GRACE);
        assertTrue(liv.liquidationsAllowed());
    }

    // ---------------------------------------------------------------- risk math

    function test_collateralValueUsesTheLiveMultiplier() public {
        (uint256 v,) = mk.collateralValue(address(tok), 10e18); // 10 shares @ $200
        // Values are in the BORROW asset (USDG, 6dp), not the collateral's 18dp.
        // Asserting 2000e18 is what the 1e12 valuation bug looked like from the test side.
        assertEq(v, 2000e6, "$2000 in USDG units");
        tok.setMultiplier(4e18); // 4:1 split
        px.set(50e8, block.timestamp); // price adjusts
        (uint256 v2,) = mk.collateralValue(address(tok), 10e18);
        assertEq(v2, 2000e6, "a split must not change economic value");
    }

    function test_maxBorrowAppliesLtv() public view {
        // 10 shares @ $200 = $2000; 35% LTV = $700
        assertEq(mk.maxBorrow(address(tok), 10e18), 700e6);
    }

    function test_underwaterUsesTheThresholdNotTheLtv() public view {
        // $2000 collateral, 55% threshold = $1100 trigger (USDG units)
        assertFalse(mk.isUnderwater(address(tok), 10e18, 1_099e6));
        assertTrue(mk.isUnderwater(address(tok), 10e18, 1_101e6));
        // a loan at max LTV ($700) is comfortably healthy — that gap is the whole point
        assertFalse(mk.isUnderwater(address(tok), 10e18, 700e6));
    }

    /// The gap must absorb an unliquidatable adverse move. At max LTV, how far can price fall
    /// before the position is underwater? $700 debt vs 55% of collateral value.
    function test_gapAbsorbsRoughlyA30PercentDrop() public {
        uint256 debt = mk.maxBorrow(address(tok), 10e18); // $700 in USDG units
        px.set(140e8, block.timestamp); // -30%: $1400 collateral
        assertFalse(mk.isUnderwater(address(tok), 10e18, debt), "must survive a 30% gap");
        px.set(125e8, block.timestamp); // -37.5%: $1250, threshold $687.50
        assertTrue(mk.isUnderwater(address(tok), 10e18, debt), "and break somewhere past that");
    }

    // ---------------------------------------------------------------- gating

    function test_borrowAllowedInSessionOnly() public {
        assertTrue(mk.canBorrow(address(tok)));
        // Out of session (~03:00 UTC), computed from NOW (setUp warped +2d for the timelock, so deriving
        // from a fixed constant would warp backward and underflow the keeper age). Off-hours blocks new
        // borrows — the invariant here. (The liveness + corporate-action gates canBorrow now also applies
        // have their own dedicated tests below.)
        uint256 night = (block.timestamp / 86400) * 86400 + 1 days + 3 hours;
        vm.warp(night);
        px.set(200e8, night);
        assertFalse(mk.canBorrow(address(tok)), "no new borrows off-hours");
    }

    /// Mainnet-config: canBorrow now also gates on chain liveness (not just liquidation). With a stale
    /// keeper (sequencer-restart proxy), no new borrows even in session, on a fresh price.
    function test_borrowGatedOnChainLiveness() public {
        assertTrue(mk.canBorrow(address(tok)), "borrow open when live + in session");
        vm.warp(block.timestamp + 2 hours); // keeper now stale (> maxHeartbeatAge), still in-session
        px.set(200e8, block.timestamp);
        assertFalse(mk.canBorrow(address(tok)), "no new borrow while chain liveness is unproven");
    }

    /// Mainnet-config: refuse new borrows within the guard window of a scheduled uiMultiplier change
    /// (the corporate-action feed<->multiplier desync window).
    function test_borrowBlockedNearScheduledCorporateAction() public {
        assertTrue(mk.canBorrow(address(tok)));
        tok.schedule(2e18, block.timestamp + 20 minutes); // a split scheduled inside the 1h guard window
        assertFalse(mk.canBorrow(address(tok)), "no borrow near a scheduled multiplier change");
        // once the action is far enough away (outside the window), borrowing reopens
        tok.schedule(2e18, block.timestamp + 5 hours);
        assertTrue(mk.canBorrow(address(tok)), "borrow reopens outside the guard window");
    }

    /// Mainnet-config (HIGH, symmetry): the corporate-action desync guard must gate LIQUIDATION too, or a
    /// liquidator could seize healthy positions at the mispriced-low feed during the window.
    function test_liquidationBlockedDuringCorporateActionWindow() public {
        assertTrue(mk.canLiquidate(address(tok)), "liquidation open at baseline");
        tok.schedule(2e18, block.timestamp + 20 minutes); // split scheduled inside the window
        assertFalse(mk.canLiquidate(address(tok)), "liquidation declines during the desync window");
    }

    /// Mainnet-config (residual): if the token CLEARS newUIMultiplier at the flip, only the observed-move
    /// guard can catch the post-flip window. A live uiMultiplier move (with no schedule) must block BOTH
    /// borrow and liquidation once observed via syncMultiplier (the pool calls it on both paths).
    function test_observedMultiplierMoveBlocksBothPaths() public {
        assertTrue(mk.canBorrow(address(tok)));
        assertTrue(mk.canLiquidate(address(tok)));
        tok.setMultiplier(2e18); // the split APPLIES: uiMultiplier flips, newUIMultiplier stays (0,0)
        mk.syncMultiplier(address(tok)); // as the pool does on the borrow/liquidate path
        assertFalse(mk.canBorrow(address(tok)), "observed post-flip move blocks borrow (no schedule needed)");
        assertFalse(mk.canLiquidate(address(tok)), "and blocks liquidation");
    }

    /// Mainnet-config (HIGH): a market's price feed is APPEND-ONLY — a later commit cannot swap it (rug edge).
    function test_feedCannotBeSwappedOnRecommit() public {
        MockFeed evilFeed = new MockFeed(1e8, 8); // attacker-controlled $1 feed
        EsseyMarkets.Market memory m = _conservative();
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(evilFeed)), 90_000, 8, m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.FeedIsImmutable.selector, address(tok)));
        mk.commitMarket(address(tok));
        vm.stopPrank();
    }

    /// Liquidation needs chain liveness as well as a live market. This is the outage protection.
    function test_liquidationBlockedWhenLivenessIsStale() public {
        assertTrue(mk.canLiquidate(address(tok)));
        vm.warp(block.timestamp + 4 hours); // chain halt: no heartbeat possible
        px.set(200e8, block.timestamp); // price would be fine
        assertFalse(mk.canLiquidate(address(tok)), "outage must block liquidation");
    }

    function test_liquidationBlockedDuringPostOutageGrace() public {
        // Keep the whole scenario inside one trading session: a 1h outage plus a 1h grace must
        // still land before the 21:00 UTC close, or this would be testing market hours rather
        // than liveness. (The first draft used a 4h outage and drifted past the close.)
        vm.warp(block.timestamp + 1 hours); // outage
        px.set(200e8, block.timestamp);
        _beat(); // chain is back
        assertFalse(mk.canLiquidate(address(tok)), "grace period must still block");
        _advanceLive(GRACE);
        assertTrue(mk.isUsMarketHours(block.timestamp), "fixture must still be in session");
        assertTrue(mk.canLiquidate(address(tok)), "and reopen after it");
    }

    function test_silentOracleBlocksBothBorrowAndLiquidation() public {
        vm.warp(block.timestamp + 100_000); // past heartbeat + grace
        assertFalse(mk.canBorrow(address(tok)));
        assertFalse(mk.canLiquidate(address(tok)));
    }

    function test_disabledMarketBlocksEverything() public {
        vm.prank(ADMIN);
        mk.disableMarket(address(tok));
        assertFalse(mk.canBorrow(address(tok)));
        assertFalse(mk.canLiquidate(address(tok)));
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.MarketNotEnabled.selector, address(tok)));
        mk.maxBorrow(address(tok), 1e18);
    }

    // ---------------------------------------------------------------- risk-param invariants

    function test_narrowRiskGapIsRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.ltvBps = 5_000;
        m.liqThresholdBps = 5_500; // only a 5pp gap
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "risk gap too narrow"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
    }

    function test_ltvAboveThresholdIsRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.ltvBps = 6_000;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "ltv must be below threshold"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
    }

    function test_excessiveBonusIsRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.liqBonusBps = 2_000;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "bonus too high"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
    }

    function test_zeroCapIsRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.cap = 0;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "cap must be set"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
    }

    // ------------------------------------------------- guards found by mutation sweep

    function test_collateralValueOnADisabledMarketReverts() public {
        vm.prank(ADMIN);
        mk.disableMarket(address(tok));
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.MarketNotEnabled.selector, address(tok)));
        mk.collateralValue(address(tok), 1e18);
    }

    function test_onlyAdminCanCommit() public {
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, _conservative());
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        mk.commitMarket(address(tok));
    }

    function test_disabledMarketCannotBeProposed() public {
        EsseyMarkets.Market memory m = _conservative();
        m.enabled = false;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "market must be enabled"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
    }

    function test_thresholdAboveCeilingIsRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.liqThresholdBps = 9_500; // above MAX_LIQ_THRESHOLD_BPS
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "threshold too high"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
    }

    /// The decimals field is what makes valuation correct across USDG(6)/token(18)/feed(8).
    /// A zero or absurd value would silently misprice every position.
    function test_badCollateralDecimalsAreRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.collateralDecimals = 0;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "bad collateral decimals"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
        m.collateralDecimals = 37;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "bad collateral decimals"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
    }

    /// Borrow-path fix #3: the operator-typed decimals must MATCH the token's / feed's real decimals(),
    /// so a one-char typo can't silently reproduce the 1e12 mispricing. tok is 18-dec, px feed is 8-dec.
    function test_decimalsMustMatchRealTokenAndFeed() public {
        EsseyMarkets.Market memory m = _conservative(); // collateralDecimals: 18 (correct for tok)
        // wrong collateral decimals (token is really 18)
        m.collateralDecimals = 6;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "collateral decimals mismatch"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
        // wrong feed decimals (feed is really 8)
        m.collateralDecimals = 18;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "feed decimals mismatch"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 6, m);
        // matching decimals are accepted
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
    }

    // ---------------------------------------------------------------- timelock

    function test_paramChangeCannotBeCommittedImmediately() public {
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, _conservative());
        vm.expectRevert();
        mk.commitMarket(address(tok));
        vm.stopPrank();
    }

    function test_commitWithoutProposalReverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.NoPendingChange.selector, address(0xDEAD)));
        mk.commitMarket(address(0xDEAD));
    }

    function test_onlyAdminCanChangeMarkets() public {
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, _conservative());
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        mk.disableMarket(address(tok));
    }

    /// Disabling is immediate BY DESIGN: it only stops new borrows, and delaying a shutdown would
    /// be the dangerous choice.
    function test_disableNeedsNoTimelock() public {
        vm.prank(ADMIN);
        mk.disableMarket(address(tok));
        assertFalse(mk.market(address(tok)).enabled);
    }

    // ---------------------------------------------------------------- fix #9: pin boundaries + constants
    // (kills mutation survivors on PARAM_TIMELOCK and MIN_RISK_GAP_BPS — a shortened timelock or narrowed
    //  gap passed a green suite because nothing asserted the exact edge or the exact value.)

    /// The timelock boundary is exact: locked at effectiveAt-1, open at effectiveAt.
    function test_timelockBoundaryIsExact() public {
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, _conservative());
        uint256 effectiveAt = block.timestamp + mk.PARAM_TIMELOCK();
        vm.warp(effectiveAt - 1);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.TimelockNotElapsed.selector, 1));
        mk.commitMarket(address(tok));
        vm.warp(effectiveAt); // exactly elapsed
        mk.commitMarket(address(tok));
        vm.stopPrank();
        assertTrue(mk.market(address(tok)).enabled, "commits exactly at the timelock boundary");
    }

    /// The risk gap boundary is exact: a gap of exactly MIN_RISK_GAP_BPS is allowed, one bp narrower is not.
    function test_riskGapBoundaryIsExact() public {
        uint16 gap = mk.MIN_RISK_GAP_BPS();
        EsseyMarkets.Market memory m = _conservative();
        m.ltvBps = 3_000;
        m.liqThresholdBps = 3_000 + gap; // gap exactly at the minimum -> allowed
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
        m.liqThresholdBps -= 1; // one bp narrower -> rejected
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "risk gap too narrow"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
    }

    /// Pin the value-carrying constants so a mutation that shrinks them can't survive a green suite.
    function test_riskConstantsArePinned() public view {
        assertEq(mk.MIN_RISK_GAP_BPS(), 2_000, "the lender-protecting risk gap");
        assertEq(mk.PARAM_TIMELOCK(), 2 days, "the parameter-change timelock");
        assertEq(mk.MAX_LIQ_THRESHOLD_BPS(), 9_000, "the liquidation-threshold ceiling");
    }
}
