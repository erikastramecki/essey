// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StaleFeedGuard} from "../src/StaleFeedGuard.sol";
import {CollateralReconciler} from "../src/CollateralReconciler.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------- mocks

contract MockFeed is AggregatorV3Interface {
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;
    uint8 public dec;

    constructor(int256 a, uint8 d) { answer = a; dec = d; updatedAt = block.timestamp; startedAt = block.timestamp; }
    function set(int256 a, uint256 u) external { answer = a; updatedAt = u; }
    function setRounds(uint80 r, uint80 air) external { roundId = r; answeredInRound = air; }
    function setStartedAt(uint256 s) external { startedAt = s; }
    function decimals() external view returns (uint8) { return dec; }
    function description() external pure returns (string memory) { return "mock"; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// Mirrors Robinhood's Stock Token surface: raw balances plus a corporate-action multiplier,
/// and an adminBurn that destroys tokens from any holder with no pause or block check.
contract MockStock is ERC20 {
    uint256 public uiMultiplier = 1e18;
    uint256 internal _newMult;
    uint256 internal _effectiveAt;

    constructor() ERC20("Apple Robinhood Token", "AAPL") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function adminBurn(address from, uint256 amt) external { _burn(from, amt); }
    function setMultiplier(uint256 m) external { uiMultiplier = m; }
    bool public paused;
    function setPaused(bool v) external { paused = v; }
    function schedule(uint256 m, uint256 at) external { _newMult = m; _effectiveAt = at; }
    function newUIMultiplier() external view returns (uint256, uint256) { return (_newMult, _effectiveAt); }
    function balanceOfUI(address a) external view returns (uint256) { return balanceOf(a) * uiMultiplier / 1e18; }
    function totalSupplyUI() external view returns (uint256) { return totalSupply() * uiMultiplier / 1e18; }
}

contract GuardHarness is StaleFeedGuard {
    constructor(AggregatorV3Interface s) StaleFeedGuard(s) {}
    function setFeed(address t, AggregatorV3Interface f, uint32 maxStale, uint8 d) external {
        _setFeed(t, f, maxStale, d);
    }
}

contract ReconcilerHarness is CollateralReconciler {
    function reconcile(address t) external returns (uint256) { return _reconcile(t); }
    function credit(address t, uint256 a) external returns (uint256) { return _creditCollateral(t, a); }
    function debit(address t, uint256 a, uint256 snap) external { _debitCollateral(t, a, snap); }
    function effective(address t, uint256 raw, uint256 snap) external view returns (uint256) {
        return _effectiveCollateral(t, raw, snap);
    }
    function uiAmount(address t, uint256 raw) external view returns (uint256) { return _uiAmount(t, raw); }
    function index(address t) external view returns (uint256) { return _index(t); }
}

// ---------------------------------------------------------------- tests

contract StaleFeedGuardTest is Test {
    GuardHarness g;
    MockFeed seq;
    MockFeed px;
    address constant TOK = address(0xAA);

    // 2025-07-21 15:00 UTC = a MONDAY, 11:00 ET — inside the US equity session.
    // (Verified against the calendar; the contract's (days+3)%7 mapping agrees.)
    uint256 constant MON_IN_SESSION = 1_753_110_000;

    function setUp() public {
        vm.warp(MON_IN_SESSION);
        seq = new MockFeed(0, 0);            // 0 = sequencer up
        seq.setStartedAt(block.timestamp - 2 days); // well past the grace period
        px = new MockFeed(200e8, 8);
        g = new GuardHarness(seq);
        // heartbeat + grace, matching the real 86400s Robinhood Chain feeds
        g.setFeed(TOK, px, 90_000, 8);
    }

    function test_freshPriceInSession() public view {
        (uint256 p, uint8 d, bool inSession) = g.priceOf(TOK);
        assertEq(p, 200e8);
        assertEq(d, 8);
        assertTrue(inSession);
    }

    /// The core protection: a Friday-close price must NOT be usable on Sunday.
    function test_weekendStalePriceIsRejected() public {
        uint256 fridayClose = MON_IN_SESSION + 4 days; // Mon + 4 = Friday
        px.set(200e8, fridayClose);
        uint256 sunday = fridayClose + 2 days; // > heartbeat + grace, so the feed reads as silent
        vm.warp(sunday);
        assertFalse(g.isUsMarketHours(sunday), "fixture must actually be a weekend");
        vm.expectRevert();
        g.priceOf(TOK);
    }

    /// A quiet market must NOT revert. Every Robinhood Chain feed is 86400s/0.5%, so a price
    /// that is hours old simply means the stock has not moved 0.5%. An earlier draft used a
    /// 300s off-hours bound, which would have rejected every borrow overnight.
    function test_quietMarketDoesNotRevert() public {
        uint256 night = (MON_IN_SESSION / 86400) * 86400 + 3 hours;
        px.set(200e8, night - 6 hours); // 6h old: normal for a 24h heartbeat
        vm.warp(night);
        assertFalse(g.isUsMarketHours(night), "fixture is off-hours");
        (uint256 p,, bool inSession) = g.priceOf(TOK);
        assertEq(p, 200e8);
        assertFalse(inSession, "must report off-hours so callers can gate borrows");
    }

    /// But a SILENT oracle — past heartbeat + grace — is a broken oracle and must revert.
    function test_silentOracleBeyondHeartbeatReverts() public {
        uint256 t = MON_IN_SESSION;
        px.set(200e8, t - 90_001);
        vm.warp(t);
        vm.expectRevert();
        g.priceOf(TOK);
    }

    /// Configuring a bound tighter than the heartbeat is a misconfiguration that would look fine
    /// until the first quiet hour. Reject it at config time.
    function test_stalenessBelowHeartbeatIsRejected() public {
        MockFeed f2 = new MockFeed(100e8, 8);
        vm.expectRevert(
            abi.encodeWithSelector(StaleFeedGuard.StalenessBelowHeartbeat.selector, uint32(3600), uint32(86_400))
        );
        g.setFeed(address(0xCC), f2, 3600, 8);
    }

    function test_sequencerDownRejects() public {
        seq.set(1, block.timestamp); // 1 = down
        vm.expectRevert(StaleFeedGuard.SequencerDown.selector);
        g.priceOf(TOK);
    }

    /// A price can be fresh while the market has had no chance to react to a resumed sequencer.
    function test_sequencerGracePeriodRejects() public {
        seq.setStartedAt(block.timestamp - 60); // came back 60s ago
        vm.expectRevert();
        g.priceOf(TOK);
    }

    function test_nonPositiveAnswerRejects() public {
        px.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(StaleFeedGuard.PriceNotPositive.selector, int256(0)));
        g.priceOf(TOK);
    }

    function test_carriedOverRoundRejects() public {
        px.setRounds(5, 4); // answeredInRound < roundId
        vm.expectRevert(StaleFeedGuard.RoundIncomplete.selector);
        g.priceOf(TOK);
    }

    function test_unconfiguredFeedRejects() public {
        vm.expectRevert(abi.encodeWithSelector(StaleFeedGuard.FeedNotConfigured.selector, address(0xBB)));
        g.priceOf(address(0xBB));
    }

    /// A deployment with no uptime feed must still work, and must SAY so — the risk is real and
    /// carried by compensating controls, so it has to be visible rather than silently skipped.
    function test_missingSequencerFeedIsExplicitNotSilent() public {
        GuardHarness g2 = new GuardHarness(AggregatorV3Interface(address(0)));
        g2.setFeed(TOK, px, 90_000, 8);
        assertTrue(g2.sequencerCheckDisabled(), "must advertise that the check is off");
        (uint256 p,,) = g2.priceOf(TOK); // still functions
        assertEq(p, 200e8);
        // and the configured deployment must NOT claim the check is disabled
        assertFalse(g.sequencerCheckDisabled());
    }

    /// The session window is the INTERSECTION of the EST and EDT mappings: 14:30-20:00 UTC.
    ///
    /// The previous version of this test asserted 20:59 UTC was in-session, which is only true
    /// under EST. During EDT that same instant is 16:59 ET — an hour AFTER the close. The test
    /// enshrined the bug it should have caught, by labelling EDT timestamps as ET.
    function test_marketHoursBoundariesAreConservativeAcrossDst() public view {
        uint256 day = (MON_IN_SESSION / 86400) * 86400;
        assertFalse(g.isUsMarketHours(day + 14 hours + 29 minutes), "before the latest open");
        assertTrue(g.isUsMarketHours(day + 14 hours + 30 minutes), "EST open");
        assertTrue(g.isUsMarketHours(day + 19 hours + 59 minutes), "inside both windows");
        // 20:00 UTC is 16:00 ET under EDT — the market is SHUT. Must not report in-session,
        // even though under EST it would still be 15:00 ET and open.
        assertFalse(g.isUsMarketHours(day + 20 hours), "EDT close - the unsafe direction");
        assertFalse(g.isUsMarketHours(day + 20 hours + 59 minutes), "never open after the EDT close");
    }

    /// MARKET HOLIDAYS. The calendar knows weekends, not holidays. On a holiday the clock says
    /// in-session while the feed has not printed since the previous close — and an 18-24h holiday
    /// gap fits inside the 25h staleness bound, so staleness cannot catch it.
    function test_holidayIsNotReportedAsInSession() public {
        uint256 day = (MON_IN_SESSION / 86400) * 86400;
        uint256 midSession = day + 16 hours; // clock says open
        // last print was yesterday's close — the market never opened today
        px.set(200e8, day - 4 hours);
        vm.warp(midSession);
        assertTrue(g.isUsMarketHours(midSession), "the calendar alone believes it is a session");
        (,, bool inSession) = g.priceOf(TOK);
        assertFalse(inSession, "but no print since today's open -> treated as closed");
    }

    function test_normalSessionWithATodayPrintIsInSession() public {
        uint256 day = (MON_IN_SESSION / 86400) * 86400;
        uint256 midSession = day + 16 hours;
        px.set(200e8, day + 15 hours); // printed after today's open
        vm.warp(midSession);
        (,, bool inSession) = g.priceOf(TOK);
        assertTrue(inSession, "a normal session must still work");
    }

    /// Borrow-path fix #7: a genuine EDT opening-hour print (13:30-14:30 UTC) must NOT be false-rejected as
    /// a holiday. Pre-fix the holiday threshold was SESSION_OPEN_UTC (14:30, EST open), so such a print set
    /// inSession=false — and because canLiquidate shares the flag, a liquidation OUTAGE on EDT days.
    function test_edtOpeningHourPrintIsNotFalseRejected() public {
        uint256 day = (MON_IN_SESSION / 86400) * 86400;
        uint256 mid = day + 14 hours + 35 minutes; // in the intersection window (>=14:30): clock says open
        px.set(200e8, day + 13 hours + 45 minutes); // a fresh EDT opening-hour print (13:30-14:30 UTC)
        vm.warp(mid);
        assertTrue(g.isUsMarketHours(mid), "the calendar believes it is a session");
        (,, bool inSession) = g.priceOf(TOK);
        assertTrue(inSession, "an EDT opening-hour print is a valid today print, not a holiday");
    }

    function test_weekendIsNeverInSession() public view {
        uint256 day = (MON_IN_SESSION / 86400) * 86400;
        // Monday + 5 = Saturday, +6 = Sunday. Midday both days, when a naive
        // hour-of-day check would wrongly report "in session".
        assertFalse(g.isUsMarketHours(day + 5 days + 16 hours), "Saturday");
        assertFalse(g.isUsMarketHours(day + 6 days + 16 hours), "Sunday");
        // and the weekdays around them ARE in session, so the test is not vacuous
        assertTrue(g.isUsMarketHours(day + 4 days + 16 hours), "Friday");
        assertTrue(g.isUsMarketHours(day + 7 days + 16 hours), "next Monday");
    }
}

contract CollateralReconcilerTest is Test {
    ReconcilerHarness r;
    MockStock tok;
    uint256 snap0; // the setUp position's index snapshot

    function setUp() public {
        r = new ReconcilerHarness();
        tok = new MockStock();
        tok.mint(address(r), 100e18);
        snap0 = r.credit(address(tok), 100e18);
    }

    function test_noShortfallWhenBalancesAgree() public {
        assertEq(r.reconcile(address(tok)), 0);
        assertEq(r.effective(address(tok), 100e18, snap0), 100e18);
    }

    /// adminBurn is detected and RECORDED, and must not revert — reverting would freeze every
    /// other borrower and turn a partial loss into a total one.
    function test_adminBurnIsDetectedAndRecorded() public {
        tok.adminBurn(address(r), 30e18);
        assertEq(r.reconcile(address(tok)), 30e18);
        assertEq(r.shortfallRaw(address(tok)), 30e18);
        assertEq(r.reconcile(address(tok)), 0, "idempotent: nothing NEW the second time");
        // the nominal total is deliberately NOT reduced — it is for reporting, not the entitlement math
        assertEq(r.recordedRaw(address(tok)), 100e18);
        // the sole position recovers the surviving 70
        assertEq(r.effective(address(tok), 100e18, snap0), 70e18);
    }

    /// THE ORDERING BUG. Two borrowers PRESENT AT THE BURN, one burn: each must lose their share, in
    /// EITHER order. Previously the pooled balance was clamped against a per-borrower figure, so whoever
    /// repaid first recovered everything — including the other's collateral.
    function test_burnLossIsSharedProRataNotByRepaymentOrder() public {
        ReconcilerHarness r2 = new ReconcilerHarness();
        MockStock t2 = new MockStock();
        t2.mint(address(r2), 20e18);
        uint256 sA = r2.credit(address(t2), 10e18); // Alice
        uint256 sB = r2.credit(address(t2), 10e18); // Bob (same cohort — both pre-burn)
        t2.adminBurn(address(r2), 10e18); // Robinhood destroys half
        r2.reconcile(address(t2)); // the pool reconciles before computing any entitlement

        assertEq(r2.effective(address(t2), 10e18, sA), 5e18, "Alice's share");
        // Alice exits: transfer her 5 out (stand-in burn) and debit her nominal 10
        t2.adminBurn(address(r2), 5e18);
        r2.debit(address(t2), 10e18, sA);
        // Bob's share is still 5 — unharmed by Alice going first
        assertEq(r2.effective(address(t2), 10e18, sB), 5e18, "Bob's share, order-independent");
    }

    /// FIX #2 — a borrower who deposits AFTER a burn is INSULATED from it. Alice bears the whole loss;
    /// Bob, who arrived later, recovers his full deposit. (Pre-fix, Bob's intact collateral was diluted
    /// by the shared denominator and he silently paid for Alice's burn.)
    function test_postBurnDepositorIsInsulated() public {
        ReconcilerHarness r2 = new ReconcilerHarness();
        MockStock t2 = new MockStock();
        t2.mint(address(r2), 20e18);
        uint256 sA = r2.credit(address(t2), 20e18); // Alice, before the burn
        t2.adminBurn(address(r2), 10e18); // half of Alice's collateral destroyed
        r2.reconcile(address(t2)); // index -> 0.5
        t2.mint(address(r2), 10e18);
        uint256 sB = r2.credit(address(t2), 10e18); // Bob deposits fresh, AFTER the burn
        r2.reconcile(address(t2));

        assertEq(r2.effective(address(t2), 20e18, sA), 10e18, "Alice (pre-burn) bears the loss");
        assertEq(r2.effective(address(t2), 10e18, sB), 10e18, "Bob (post-burn) recovers his full deposit");
        // solvency: the two entitlements sum to exactly the surviving balance
        assertEq(t2.balanceOf(address(r2)), 20e18, "10 (Alice) + 10 (Bob) == actual");
    }

    function test_totalBurnLeavesEveryoneAtZeroNotSomeoneWhole() public {
        tok.adminBurn(address(r), 100e18);
        assertEq(r.reconcile(address(tok)), 100e18);
        assertEq(r.effective(address(tok), 100e18, snap0), 0); // exactly 0, not dust
    }

    /// Valuation must follow the corporate-action multiplier: a 4:1 split quadruples the
    /// share-equivalent, so pricing the RAW balance would understate the position 4x.
    function test_uiAmountFollowsTheMultiplier() public {
        assertEq(r.uiAmount(address(tok), 100e18), 100e18);
        tok.setMultiplier(4e18);
        assertEq(r.uiAmount(address(tok), 100e18), 400e18);
    }

    function test_pendingMultiplierIsVisibleBeforeItFires() public {
        tok.schedule(4e18, block.timestamp + 7 days);
        (uint256 m, uint256 at) = r.pendingMultiplier(address(tok));
        assertEq(m, 4e18);
        assertEq(at, block.timestamp + 7 days);
    }

    function test_debitBeyondRecordedReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(CollateralReconciler.InsufficientRecorded.selector, address(tok), 100e18, 101e18)
        );
        r.debit(address(tok), 101e18, snap0);
    }

    /// THE SOLVENCY INVARIANT (fix #2), fuzzed over random deposit/burn/close sequences: the sum of every
    /// open position's entitlement never exceeds the pool's actual balance — no burn, in any interleaving
    /// with deposits and closes, can ever let the pool owe out more collateral than it holds. Closing a
    /// position pays out its effective amount (simulated by burning that much from the harness balance).
    function testFuzz_entitlementsNeverExceedBalance(uint256 seed) public {
        ReconcilerHarness h = new ReconcilerHarness();
        MockStock t = new MockStock();
        uint256[] memory rawArr = new uint256[](32);
        uint256[] memory snapArr = new uint256[](32);
        uint256 n = 0;

        for (uint256 i = 0; i < 24; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = seed % 3;

            if (action == 0 && n < 32) {
                // DEPOSIT: mint fresh raw, reconcile, credit — skip if a total burn wiped the open cohort
                if (n > 0 && h.index(address(t)) == 0) {
                    // wiped cohort: a new deposit would (correctly) revert; nothing to do
                } else {
                    uint256 raw = 1e18 + ((seed >> 8) % 100e18);
                    t.mint(address(h), raw);
                    h.reconcile(address(t));
                    uint256 snap = h.credit(address(t), raw);
                    rawArr[n] = raw;
                    snapArr[n] = snap;
                    n++;
                }
            } else if (action == 1 && n > 0) {
                // CLOSE a random position: reconcile, pay out its effective (burn it), debit
                uint256 k = (seed >> 8) % n;
                h.reconcile(address(t));
                uint256 eff = h.effective(address(t), rawArr[k], snapArr[k]);
                if (eff > 0) t.adminBurn(address(h), eff); // stand-in for the outbound transfer
                h.debit(address(t), rawArr[k], snapArr[k]);
                rawArr[k] = rawArr[n - 1];
                snapArr[k] = snapArr[n - 1];
                n--;
            } else if (n > 0) {
                // BURN a random amount of the surviving balance (the adminBurn hazard)
                uint256 bal = t.balanceOf(address(h));
                if (bal > 0) {
                    uint256 burn = 1 + ((seed >> 8) % bal);
                    t.adminBurn(address(h), burn);
                    h.reconcile(address(t));
                }
            }

            // INVARIANT after every step
            h.reconcile(address(t));
            uint256 sumEff = 0;
            for (uint256 j = 0; j < n; j++) {
                uint256 e = h.effective(address(t), rawArr[j], snapArr[j]);
                assertLe(e, rawArr[j], "an entitlement never exceeds the raw posted");
                sumEff += e;
            }
            assertLe(sumEff, t.balanceOf(address(h)), "solvency: entitlements never exceed the balance");
            assertLe(h.index(address(t)), 1e18, "index never exceeds full survival");
        }
    }
}
