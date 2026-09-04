// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {StaleFeedGuard} from "../src/StaleFeedGuard.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed, MockStock, PoolStub} from "./RiskModules.t.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";

/// The shared registry fixture. Extracted so the shape tests below live in their OWN contract:
/// solc's via_ir pipeline (FOUNDRY_PROFILE=script) hits an assembly tag limit on a single contract
/// this large, and the script profile has to build the whole tree.
abstract contract MarketsFixture is Test {
    EsseyMarkets mk;
    LivenessOracle liv;
    MarketHealthOracle hox;
    MockFeed seq;
    MockFeed px;
    MockStock tok;
    PoolStub stub;

    address ADMIN;
    address KEEPER;
    address GUARDIAN;

    // 2025-07-21 15:00 UTC — a Monday, 11:00 ET, inside the US equity session.
    uint256 constant MON_IN_SESSION = 1_753_110_000;
    uint256 constant GRACE = 30 minutes;
    uint256 constant GAP = 10 minutes; // ~2 missed beats at a 5-minute cadence

    // The conservative v1 stance: 35% LTV / 55% liquidation = a 20pp gap.
    function _conservative() internal pure returns (EsseyMarkets.Market memory) {
        return EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
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
        liv = new LivenessOracle(KEEPER, GUARDIAN, makeAddr("livenessRotator"), GAP, GRACE);
        hox = new MarketHealthOracle(KEEPER, GUARDIAN, ADMIN);
        mk = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, ADMIN, GUARDIAN, 6); // USDG is 6dp
        vm.prank(ADMIN);
        hox.wireMarkets(address(mk));
        stub = new PoolStub(address(tok), address(mk));

        _enable(_conservative());
        _bringLivenessOnline();
        _seedOracle();
    }

    function _enable(EsseyMarkets.Market memory m) internal {
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
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
            _postD();
        }
        vm.warp(end);
        px.set(200e8, block.timestamp);
        _beat();
        _postD();
    }

    function _postD() internal {
        vm.prank(KEEPER); hox.postDepth(address(tok), 4_000_000e6, uint64(block.number), "fork-swap-v1");
    }

    function _seedOracle() internal {
        _postD();
        for (uint256 i = 0; i < 42; i++) { vm.warp(block.timestamp + 12 hours); _postD(); } // ride the full ramp
        _beat(); _advanceLive(GRACE);
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }

    function _bringLivenessOnline() internal {
        _beat();
        _advanceLive(GRACE);
        assertTrue(liv.liquidationsAllowed());
    }
}

contract EsseyMarketsTest is MarketsFixture {
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

    /// L-1: the isUnderwater trigger is STRICT (`debt > value*threshold`). $2000 collateral at 55%
    /// is exactly $1100; debt == $1100 is NOT underwater, one wei past it IS. Pins the exact boundary
    /// so a `>`->`>=` flip (which would liquidate a position sitting precisely at the threshold) fails.
    function test_isUnderwaterThresholdBoundaryIsExact() public view {
        assertFalse(mk.isUnderwater(address(tok), 10e18, 1_100e6), "debt == threshold is NOT underwater");
        assertTrue(mk.isUnderwater(address(tok), 10e18, 1_100e6 + 1), "one wei past the threshold IS underwater");
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

    /// ROUNDING DIRECTION at all three valuation sites. Every other price here is a whole dollar, so
    /// nothing truncates and a ceil reads identically — while a ceil over-values collateral in the
    /// UNSAFE direction: maxBorrow over-lends, isUnderwater under-reports, the pool eats the rest.
    ///   value 10e18 x 20_000_000_011 x 1e6 / (1e18 x 1e8) = 2_000_000_001.1
    ///   LTV 35% = 700_000_000.35 · liq 55% = 1_100_000_000.55
    function test_valuationRoundsDownAtEveryStage() public {
        px.set(20_000_000_011, block.timestamp); // $200.00000011/share, 8dp
        (uint256 v,) = mk.collateralValue(address(tok), 10e18);
        assertEq(v, 2_000_000_001, "collateral value truncates, never rounds up");
        assertEq(mk.maxBorrow(address(tok), 10e18), 700_000_000, "the LTV cut truncates too");
        assertFalse(mk.isUnderwater(address(tok), 10e18, 1_100_000_000), "debt == the FLOORED threshold is healthy");
        assertTrue(mk.isUnderwater(address(tok), 10e18, 1_100_000_001), "one unit past the FLOORED threshold is not");
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
        vm.warp(block.timestamp + 2 hours); // keeper now stale (> gapThreshold), still in-session
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
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(evilFeed)), 86_400, 90_000, 8, address(tok), address(stub), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.FeedIsImmutable.selector, address(tok)));
        mk.commitMarket(address(tok));
        vm.stopPrank();
    }

    /// Round-6 A/B: the freshness pair latches with the feed. Loosening re-widens the
    /// stale-liquidation window; tightening below the feed's cadence freezes liquidation
    /// AND writeOff while debt accrues.
    function test_freshnessPairIsImmutableOnRecommit() public {
        EsseyMarkets.Market memory m = _conservative();
        vm.startPrank(ADMIN);
        // heartbeat change refused
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 3_600, 7_200, 8, address(tok), address(stub), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.FreshnessIsImmutable.selector, address(tok)));
        mk.commitMarket(address(tok));
        // maxStaleness change alone refused
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 89_000, 8, address(tok), address(stub), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.FreshnessIsImmutable.selector, address(tok)));
        mk.commitMarket(address(tok));
        // identical pair + a risk-param change still commits
        m.ltvBps = 3_000;
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        vm.stopPrank();
        assertEq(mk.market(address(tok)).ltvBps, 3_000, "risk retune must survive the latch");
    }

    /// The ceiling fires where _setFeed runs — at commit, same as the staleness bounds.
    function test_heartbeatCeilingIsExact() public {
        address t2 = address(new MockStock());
        PoolStub stubT2 = new PoolStub(t2, address(mk));
        EsseyMarkets.Market memory m = _conservative();
        vm.startPrank(ADMIN);
        mk.proposeMarket(t2, AggregatorV3Interface(address(px)), uint32(2 days + 1), uint32(2 days + 60), 8, t2, address(stubT2), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(StaleFeedGuard.HeartbeatTooLong.selector, uint32(2 days + 1), uint32(2 days))
        );
        mk.commitMarket(t2);
        mk.proposeMarket(t2, AggregatorV3Interface(address(px)), uint32(2 days), uint32(2 days + 60), 8, t2, address(stubT2), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(t2);
        vm.stopPrank();
        assertTrue(mk.market(t2).enabled, "exact-ceiling heartbeat must commit");
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

    /// C-M2/B-L1: disable stops NEW borrows only. Liquidation-side reads keep working, or a
    /// disabled market's existing positions would be frozen until a 2-day re-commit.
    function test_disabledMarketBlocksBorrowNotLiquidation() public {
        vm.prank(GUARDIAN);
        mk.disableMarket(address(tok));
        assertFalse(mk.canBorrow(address(tok)), "no new borrows");
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.MarketNotEnabled.selector, address(tok)));
        mk.maxBorrow(address(tok), 1e18);
        assertTrue(mk.canLiquidate(address(tok)), "liquidation survives the disable (fresh price)");
        assertTrue(mk.isUnderwater(address(tok), 1e18, 200e6), "health checks survive it too");
    }

    /// B round-2: an emergency disable must be sticky. A ripe pending proposal left in place
    /// would let the next commitMarket re-enable with no fresh notice.
    function test_disableClearsThePendingProposalSoReenableRepaysTheTimelock() public {
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _conservative());
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        vm.stopPrank();
        vm.prank(GUARDIAN);
        mk.disableMarket(address(tok));
        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.NoPendingChange.selector, address(tok)));
        mk.commitMarket(address(tok));
        assertFalse(mk.market(address(tok)).enabled, "disable held through the ripe proposal");

        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _conservative());
        vm.expectRevert();
        mk.commitMarket(address(tok));
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        vm.stopPrank();
        // enabled flag, not canBorrow: the warps land off-session with a stale heartbeat, and
        // those gates are pinned elsewhere. This test owns only the flag and its timelock.
        assertTrue(mk.market(address(tok)).enabled, "re-enable works, at full timelock price");
    }

    function test_neverCommittedMarketDeclinesEverything() public {
        address ghost = makeAddr("ghost-token");
        assertFalse(mk.canBorrow(ghost));
        assertFalse(mk.canLiquidate(ghost));
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.MarketNotEnabled.selector, ghost));
        mk.collateralValue(ghost, 1e18);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.MarketNotEnabled.selector, ghost));
        mk.isUnderwater(ghost, 1e18, 1);
    }

    // ---------------------------------------------------------------- risk-param invariants

    function test_narrowRiskGapIsRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.ltvBps = 5_000;
        m.liqThresholdBps = 5_500; // only a 5pp gap
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "risk gap too narrow"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    function test_ltvAboveThresholdIsRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.ltvBps = 6_000;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "ltv must be below threshold"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    function test_excessiveBonusIsRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.liqBonusBps = 2_000;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "bonus too high"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    function test_zeroCapIsRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.cap = 0;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "cap must be set"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    // ------------------------------------------------- guards found by mutation sweep

    /// C-M2: valuation keys on `configured`, not `enabled` — liquidation and write-off of a
    /// disabled market's existing positions still need a price.
    function test_collateralValueSurvivesADisabledMarket() public {
        vm.prank(GUARDIAN);
        mk.disableMarket(address(tok));
        (uint256 v,) = mk.collateralValue(address(tok), 10e18);
        assertEq(v, 2000e6, "disabled market still prices for the liquidation path");
    }

    // ---------------------------------------------------------------- WS2: permissionless execution

    /// A ripe proposal is executable by ANYONE — no executor privilege exists at all. Commit
    /// re-validates everything, so a stranger can only enact what the admin proposed.
    function test_strangerCanCommitARipeProposal() public {
        EsseyMarkets.Market memory m = _conservative();
        m.ltvBps = 3_000;
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        vm.prank(makeAddr("stranger"));
        mk.commitMarket(address(tok));
        assertEq(mk.market(address(tok)).ltvBps, 3_000, "the stranger enacted exactly the proposed payload");
    }

    /// The other direction: permissionless never means premature. An unripe proposal reverts
    /// TimelockNotElapsed for a stranger exactly as it does for the admin.
    function test_strangerCommitUnripeStillRevertsTimelockNotElapsed() public {
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _conservative());
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.TimelockNotElapsed.selector, mk.PARAM_TIMELOCK()));
        mk.commitMarket(address(tok));
    }

    function test_strangerCanCommitARipeResolver() public {
        address R = makeAddr("resolver");
        vm.prank(ADMIN);
        mk.proposeResolver(R);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.TimelockNotElapsed.selector, mk.PARAM_TIMELOCK()));
        mk.commitResolver();
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        vm.prank(makeAddr("stranger"));
        mk.commitResolver();
        assertEq(mk.resolver(), R, "ripe resolver payload executable by anyone");
    }

    // ---------------------------------------------------------------- WS2: cancelMarketProposal

    /// The non-emergency sibling of disableMarket: removes only the pending change, immediately.
    function test_cancelDeletesThePendingProposalAndNothingElse() public {
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _conservative());
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        vm.expectEmit(true, false, false, true, address(mk));
        emit EsseyMarkets.MarketProposalCancelled(address(tok));
        vm.prank(ADMIN);
        mk.cancelMarketProposal(address(tok));
        assertEq(mk.pendingMarket(address(tok)).effectiveAt, 0, "pending gone");
        assertTrue(mk.market(address(tok)).enabled, "the installed market is untouched - safe direction");
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.NoPendingChange.selector, address(tok)));
        mk.commitMarket(address(tok));
    }

    function test_cancelWithoutAPendingProposalReverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.NoPendingChange.selector, address(tok)));
        mk.cancelMarketProposal(address(tok));
    }

    function test_onlyAdminCanCancel() public {
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _conservative());
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        mk.cancelMarketProposal(address(tok));
        vm.prank(GUARDIAN);
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        mk.cancelMarketProposal(address(tok));
    }

    // ---------------------------------------------------------------- WS2: full-payload MarketProposed

    /// Every field of the pending config is decodable from the log alone — a permissionless
    /// executor (or any watcher) needs no eth_call to know what a proposal will install.
    function test_marketProposedEmitsTheFullPendingPayload() public {
        EsseyMarkets.Market memory m = _conservative();
        vm.expectEmit(true, false, false, true, address(mk));
        emit EsseyMarkets.MarketProposed(
            address(tok), m, AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub),
            block.timestamp + mk.PARAM_TIMELOCK()
        );
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    // ---------------------------------------------------------------- WS2: guardian

    function test_guardianCanDisableAMarket() public {
        vm.prank(GUARDIAN);
        mk.disableMarket(address(tok));
        assertFalse(mk.market(address(tok)).enabled, "guardian's one power: turn a market off");
    }

    /// Negative sweep: the guardian holds NOTHING beyond disableMarket. Every propose/cancel path
    /// refuses it; the commit paths are permissionless by design, so "guardian can commit" is
    /// exactly the no-privilege stranger case pinned above.
    function test_guardianHasNoOtherPower() public {
        vm.startPrank(GUARDIAN);
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _conservative());
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        mk.proposeResolver(makeAddr("resolver"));
        vm.stopPrank();
    }

    function test_zeroGuardianIsRejectedAtConstruction() public {
        vm.expectRevert(EsseyMarkets.ZeroGuardian.selector);
        new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, ADMIN, address(0), 6);
    }

    // ---------------------------------------------------------------- WS3: deprecation

    function _stage(uint16 lt) internal pure returns (EsseyMarkets.Market memory m) {
        m = _conservative();
        m.ltvBps = 0;
        m.liqThresholdBps = lt;
    }

    /// Stage 1 (ltv -> 0, threshold kept): the market must stop ADVERTISING borrowable — maxBorrow
    /// is 0, so without the canBorrow gate every borrow would pass the gate and then revert.
    function test_stage1MarketRefusesNewBorrowsButServicesOldOnes() public {
        _enable(_stage(5_500));
        assertTrue(mk.isUsMarketHours(block.timestamp), "fixture in session: the refusal is the ltv, not the clock");
        _bringLivenessOnline();
        assertFalse(mk.canBorrow(address(tok)), "stage 1 refuses new borrows");
        assertEq(mk.maxBorrow(address(tok), 10e18), 0, "and offers zero credit");
        assertTrue(mk.canLiquidate(address(tok)), "liquidation-side paths stay alive");
        assertFalse(mk.isUnderwater(address(tok), 10e18, 1_099e6), "kept threshold still judges health");
        assertTrue(mk.isUnderwater(address(tok), 10e18, 1_101e6));
    }

    /// Deprecation mode: ltv == 0 lifts the ordering and gap checks (no borrower left to protect)
    /// while every other bound still binds — including cap != 0, the AD-2 ceiling the depth oracle
    /// moves under, which must survive retirement.
    function test_deprecationModeLiftsOnlyTheGapAndOrderingChecks() public {
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _stage(100));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _stage(0));

        EsseyMarkets.Market memory m = _stage(9_500);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "threshold too high"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        m = _stage(100);
        m.cap = 0;
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "cap must be set"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        m = _stage(100);
        m.liqBonusBps = 2_000;
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "bonus too high"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        m = _stage(100);
        m.maxPositionBps = 0;
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "bad position cap"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        vm.stopPrank();
    }

    /// The stage-order guard: a dust threshold force-liquidates every open position, so stage 2
    /// commits only over an INSTALLED stage 1. Skipping straight there reverts.
    function test_stage2RequiresAnInstalledStage1() public {
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _stage(100));
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.DeprecationOrderViolated.selector, address(tok)));
        mk.commitMarket(address(tok)); // installed market still has ltv 35% — stage 2 refused
        vm.stopPrank();

        _enable(_stage(5_500)); // stage 1 through its own full timelock
        _enable(_stage(100)); // now stage 2 commits
        assertEq(mk.market(address(tok)).liqThresholdBps, 100, "two timelocks, then dust");
    }

    /// Empty storage also reads ltvBps == 0 — the guard must key on `configured`, or a FRESH
    /// listing at dust threshold would slip through in a single commit.
    function test_freshListingAtDustThresholdIsRejected() public {
        MockStock fresh = new MockStock();
        MockFeed freshPx = new MockFeed(200e8, 8);
        PoolStub stubFresh = new PoolStub(address(fresh), address(mk));
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(fresh), AggregatorV3Interface(address(freshPx)), 86_400, 90_000, 8, address(fresh), address(stubFresh), _stage(100));
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        freshPx.set(200e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.DeprecationOrderViolated.selector, address(fresh)));
        mk.commitMarket(address(fresh));
        vm.stopPrank();
    }

    /// The dust boundary is exact: threshold == MIN_RISK_GAP_BPS needs no stage 1, one bp below does.
    function test_dustThresholdBoundaryIsExact() public {
        _enable(_stage(mk.MIN_RISK_GAP_BPS())); // installed ltv is 35% — still allowed at the boundary
        assertEq(mk.market(address(tok)).liqThresholdBps, mk.MIN_RISK_GAP_BPS());

        MockStock fresh = new MockStock();
        MockFeed freshPx = new MockFeed(200e8, 8);
        PoolStub stubFresh = new PoolStub(address(fresh), address(mk));
        vm.startPrank(ADMIN);
        mk.proposeMarket(
            address(fresh), AggregatorV3Interface(address(freshPx)), 86_400, 90_000, 8, address(fresh), address(stubFresh),
            _stage(mk.MIN_RISK_GAP_BPS() - 1)
        );
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        freshPx.set(200e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.DeprecationOrderViolated.selector, address(fresh)));
        mk.commitMarket(address(fresh));
        vm.stopPrank();
    }

    function test_disabledMarketCannotBeProposed() public {
        EsseyMarkets.Market memory m = _conservative();
        m.enabled = false;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "market must be enabled"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    function test_thresholdAboveCeilingIsRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.liqThresholdBps = 9_500; // above MAX_LIQ_THRESHOLD_BPS
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "threshold too high"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    /// The decimals field is what makes valuation correct across USDG(6)/token(18)/feed(8).
    /// A zero or absurd value would silently misprice every position.
    function test_badCollateralDecimalsAreRejected() public {
        EsseyMarkets.Market memory m = _conservative();
        m.collateralDecimals = 0;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "bad collateral decimals"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        m.collateralDecimals = 37;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "bad collateral decimals"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    /// Borrow-path fix #3: the operator-typed decimals must MATCH the token's / feed's real decimals(),
    /// so a one-char typo can't silently reproduce the 1e12 mispricing. tok is 18-dec, px feed is 8-dec.
    function test_decimalsMustMatchRealTokenAndFeed() public {
        EsseyMarkets.Market memory m = _conservative(); // collateralDecimals: 18 (correct for tok)
        // wrong collateral decimals (token is really 18)
        m.collateralDecimals = 6;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "collateral decimals mismatch"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        // wrong feed decimals (feed is really 8)
        m.collateralDecimals = 18;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "feed decimals mismatch"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 6, address(tok), address(stub), m);
        // matching decimals are accepted
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    // ---------------------------------------------------------------- timelock

    function test_paramChangeCannotBeCommittedImmediately() public {
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _conservative());
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
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _conservative());
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        mk.disableMarket(address(tok));
    }

    /// Disabling is immediate BY DESIGN: it only stops new borrows, and delaying a shutdown would
    /// be the dangerous choice.
    function test_disableNeedsNoTimelock() public {
        vm.prank(GUARDIAN);
        mk.disableMarket(address(tok));
        assertFalse(mk.market(address(tok)).enabled);
    }

    // ---------------------------------------------------------------- fix #9: pin boundaries + constants
    // (kills mutation survivors on PARAM_TIMELOCK and MIN_RISK_GAP_BPS — a shortened timelock or narrowed
    //  gap passed a green suite because nothing asserted the exact edge or the exact value.)

    /// The timelock boundary is exact: locked at effectiveAt-1, open at effectiveAt.
    function test_timelockBoundaryIsExact() public {
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), _conservative());
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
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        m.liqThresholdBps -= 1; // one bp narrower -> rejected
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "risk gap too narrow"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    /// F-5 sweep survivor: the threshold ceiling is exact — MAX_LIQ_THRESHOLD_BPS itself deploys.
    function test_thresholdCeilingBoundaryIsExact() public {
        EsseyMarkets.Market memory m = _conservative();
        m.liqThresholdBps = mk.MAX_LIQ_THRESHOLD_BPS();
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        m.liqThresholdBps += 1;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "threshold too high"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    /// F-5 sweep survivor: ltv == threshold must be rejected as the LTV violation, not fall through
    /// to the risk-gap check masking it.
    function test_ltvEqualToThresholdIsRejectedAsLtvViolation() public {
        EsseyMarkets.Market memory m = _conservative();
        m.ltvBps = m.liqThresholdBps;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "ltv must be below threshold"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    /// F-5 sweep survivor: the bonus ceiling is exact — MAX_LIQ_BONUS_BPS itself deploys.
    function test_bonusCeilingBoundaryIsExact() public {
        EsseyMarkets.Market memory m = _conservative();
        m.liqBonusBps = mk.MAX_LIQ_BONUS_BPS();
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        m.liqBonusBps += 1;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "bonus too high"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    // ---------------------------------------------------------------- AD-1 step 3: resolver seam

    function test_resolverTimelockBoundaryIsExact() public {
        address R = makeAddr("resolver");
        vm.startPrank(ADMIN);
        mk.proposeResolver(R);
        uint256 effectiveAt = block.timestamp + mk.PARAM_TIMELOCK();
        vm.warp(effectiveAt - 1);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.TimelockNotElapsed.selector, 1));
        mk.commitResolver();
        vm.warp(effectiveAt);
        mk.commitResolver();
        vm.stopPrank();
        assertEq(mk.resolver(), R, "commits exactly at the timelock boundary");
        assertEq(mk.pendingResolverEffectiveAt(), 0, "pending cleared");
    }

    function test_onlyAdminProposesTheResolver() public {
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        mk.proposeResolver(makeAddr("resolver"));
    }

    function test_commitResolverWithoutProposalReverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.NoPendingChange.selector, address(0)));
        mk.commitResolver();
    }

    // ---------------------------------------------------------------- AD-1 step 3: gate split

    function test_positionCapBoundariesAreExact() public {
        EsseyMarkets.Market memory m = _conservative();
        m.maxPositionBps = 0;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "bad position cap"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        m.maxPositionBps = 10_001;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.InvalidRiskParams.selector, "bad position cap"));
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
        m.maxPositionBps = 10_000; // a full-cap position stays expressible
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(stub), m);
    }

    /// The session-gate split: borrowing needs an OPEN session, liquidation only a FRESH price.
    /// Pre-split, canLiquidate returned inSession and every weekday night was a liquidation outage.
    function test_gateSplit_weekdayNightFreshPrice() public {
        uint256 night = (block.timestamp / 86400) * 86400 + 1 days + 3 hours;
        _advanceLive(night - block.timestamp); // keeps beats + price prints fresh on the way
        assertFalse(mk.isUsMarketHours(block.timestamp), "fixture is a weekday night");
        assertTrue(liv.liquidationsAllowed(), "chain liveness is proven");
        assertFalse(mk.canBorrow(address(tok)), "no new borrows off-hours");
        assertTrue(mk.canLiquidate(address(tok)), "a fresh price liquidates overnight");
    }

    function test_gateSplit_deepStaleBlocksBoth() public {
        _advanceBeatsOnly(100_000); // liveness stays proven; the price print does not
        assertTrue(liv.liquidationsAllowed(), "liveness alone is not the blocker");
        assertFalse(mk.canBorrow(address(tok)));
        assertFalse(mk.canLiquidate(address(tok)), "past maxStaleness nothing may act");
    }

    function test_gateSplit_inSessionBothOpen() public view {
        assertTrue(mk.canBorrow(address(tok)));
        assertTrue(mk.canLiquidate(address(tok)));
    }

    function _advanceBeatsOnly(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes);
            _beat();
        }
        vm.warp(end);
        _beat();
    }

    /// WS4 #3: the heartbeat is a listing parameter carried propose -> commit, and the staleness
    /// bounds follow IT — under the old global 86400s constant an Ink-cadence (3600s) feed could
    /// only be listed with a bound that admits a 24h-old price.
    function test_perMarketHeartbeatCarriesFromProposeToCommit() public {
        MockStock inkTok = new MockStock();
        MockFeed inkPx = new MockFeed(300e8, 8);
        PoolStub stubInk = new PoolStub(address(inkTok), address(mk));
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(inkTok), AggregatorV3Interface(address(inkPx)), 3_600, 7_200, 8, address(inkTok), address(stubInk), _conservative());
        assertEq(mk.pendingMarket(address(inkTok)).heartbeat, 3_600, "pending carries the heartbeat");
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        inkPx.set(300e8, block.timestamp);
        mk.commitMarket(address(inkTok));
        assertEq(mk.feedConfig(address(inkTok)).heartbeat, 3_600, "committed config stores it");
        assertEq(mk.feedConfig(address(inkTok)).maxStaleness, 7_200);

        // A bound the old global heartbeat called legal is rejected FOR THIS FEED at commit —
        // since round 6 the freshness latch fires first: any change to the pair on a live
        // market is refused before the bounds are even consulted.
        mk.proposeMarket(address(inkTok), AggregatorV3Interface(address(inkPx)), 3_600, 90_000, 8, address(inkTok), address(stubInk), _conservative());
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.FreshnessIsImmutable.selector, address(inkTok)));
        mk.commitMarket(address(inkTok));
        vm.stopPrank();

        // Runtime effect: a price 8000s old — comfortably inside the old 90000s bound — is refused.
        inkPx.set(300e8, block.timestamp - 8_000);
        vm.expectRevert(
            abi.encodeWithSelector(StaleFeedGuard.PriceStale.selector, 8_000, 7_200, mk.isUsMarketHours(block.timestamp))
        );
        mk.collateralValue(address(inkTok), 1e18);
    }

    /// Pin the value-carrying constants so a mutation that shrinks them can't survive a green suite.
    function test_riskConstantsArePinned() public view {
        assertEq(mk.MIN_RISK_GAP_BPS(), 2_000, "the lender-protecting risk gap");
        assertEq(mk.PARAM_TIMELOCK(), 2 days, "the parameter-change timelock");
        assertEq(mk.MAX_LIQ_THRESHOLD_BPS(), 9_000, "the liquidation-threshold ceiling");
    }
}

/// G-LEND CRIT-1's own contract — see MarketsFixture for why it is not folded into
/// EsseyMarketsTest.
contract MultiplierShapeTest is MarketsFixture {
    /// G-LEND CRIT-1. The DEPLOYED Robinhood Stock Token answers newUIMultiplier() with ONE word, not
    /// the two IScaledUI declares, and return-data decoding fails OUTSIDE a typed try/catch — so the
    /// old guard REVERTED, taking canBorrow and canLiquidate with it. Every Robinhood market was dead
    /// on arrival, and had one been listed while the beacon still returned two words, a later beacon
    /// upgrade would have left every open loan unliquidatable and un-write-off-able. Both gates must
    /// ANSWER for every shape the token can present, including the shapes nobody designed for.
    function test_bothGatesAnswerForEveryMultiplierReturnShape() public {
        MockStock.Shape[4] memory shapes = [
            MockStock.Shape.OneWord, MockStock.Shape.TwoWords, MockStock.Shape.Garbage, MockStock.Shape.Reverts
        ];
        for (uint256 i; i < shapes.length; i++) {
            tok.setShape(shapes[i]);
            assertTrue(mk.canBorrow(address(tok)), "canBorrow must answer for every return shape");
            assertTrue(mk.canLiquidate(address(tok)), "canLiquidate must answer for every return shape");
        }
    }

    /// And the readable shape must still be READ — a guard that ignored the schedule entirely would
    /// pass the test above. This is the pair that separates "handles it" from "gave up on it".
    function test_aReadableScheduleStillBlocksAndAnUnreadableOneDoesNot() public {
        tok.schedule(2e18, block.timestamp + 20 minutes); // schedule() implies the two-word shape
        assertFalse(mk.canBorrow(address(tok)), "a readable schedule inside the window blocks");
        assertFalse(mk.canLiquidate(address(tok)), "and blocks liquidation");
        tok.setShape(MockStock.Shape.OneWord);
        assertTrue(mk.canBorrow(address(tok)), "the same schedule is unreadable one word wide");
    }

    /// What a one-word token costs is the PRE-flip warning, and nothing else: branch (b) — the
    /// observed move — needs no cooperation from the token at all. Refusing to act on an unreadable
    /// schedule instead would have bricked the market exactly as thoroughly as the revert did.
    function test_oneWordTokenIsStillGuardedByTheObservedMove() public {
        tok.schedule(2e18, block.timestamp + 20 minutes);
        tok.setShape(MockStock.Shape.OneWord); // schedule() flipped the shape; put it back
        assertTrue(mk.canBorrow(address(tok)), "no pre-flip warning is available");
        tok.setMultiplier(2e18); // the split APPLIES
        mk.syncMultiplier(address(tok)); // as the pool does on the borrow/liquidate paths
        assertFalse(mk.canBorrow(address(tok)), "the observed move blocks borrow");
        assertFalse(mk.canLiquidate(address(tok)), "and blocks liquidation");
    }

    /// The same trap one function over. syncMultiplier sits at the top of borrow, borrowMore,
    /// removeCollateral, liquidate and writeOff with no outer try, so a uiMultiplier() whose return
    /// shape moved under a beacon upgrade would brick all five.
    function test_syncMultiplierSurvivesAnUnreadableLiveMultiplier() public {
        uint256 seenBefore = mk.seenMultiplier(address(tok));
        assertGt(seenBefore, 0, "the baseline must be seeded, or this proves nothing");
        vm.mockCall(address(tok), abi.encodeWithSignature("uiMultiplier()"), hex"deadbeef");
        mk.syncMultiplier(address(tok)); // must not revert
        assertEq(mk.seenMultiplier(address(tok)), seenBefore, "an unreadable read records nothing");
        assertEq(mk.multiplierMovedAt(address(tok)), 0, "and must not fabricate a corporate action");
        vm.clearMockedCalls();
    }
}
