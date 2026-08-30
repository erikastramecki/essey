// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// Oracle gate for Stock Tokens. Fails CLOSED everywhere: a revert is the correct outcome for an
/// unknown price.
///
/// Stock Tokens trade 24/7 but Chainlink equity feeds run 24/5, so the price goes stale nights and
/// weekends. Lending against a Friday close through a weekend is the classic RWA blowup.
///
/// Rejected: a second oracle (Pyth) reports the same closed market, so failures correlate. The
/// Stock Token's own 24/7 DEX price is thin and manipulable, reintroducing the flash-loan surface
/// a signed-publisher oracle avoids. Off-hours the honest answer is "no fresh price", not one we
/// synthesise.
///
/// The heartbeat is PER FEED (Robinhood Chain equity feeds beat at 86400s, Ink's at 3600s — a
/// global constant would admit a 24h-old price on a 1h-cadence feed), so the staleness bound
/// catches a BROKEN oracle, not a quiet market, and must be >= heartbeat + grace — an earlier draft
/// used 3600s/300s and would have bricked the protocol nightly. Off-hours protection comes from the
/// session flag instead, and it gates NEW BORROWS ONLY: liquidations run whenever the price is
/// fresh (inside the staleness bound), session open or not — see EsseyMarkets._liquidationPriceGate.
contract StaleFeedGuard {
    error SequencerDown();
    error SequencerGracePeriod(uint256 secondsRemaining);
    error PriceStale(uint256 age, uint256 limit, bool inSession);
    error PriceNotPositive(int256 answer);
    error RoundIncomplete();
    error FeedNotConfigured(address token);
    error StalenessBelowHeartbeat(uint32 given, uint32 heartbeat);
    error StalenessAboveCeiling(uint32 given, uint32 ceiling);
    error HeartbeatTooShort(uint32 given, uint32 floor);
    error HeartbeatTooLong(uint32 given, uint32 ceiling);

    /// Heartbeats differ per feed — never hardcode a global value.
    struct FeedConfig {
        AggregatorV3Interface feed;
        /// The feed's own publish cadence, a listing parameter verified against Chainlink's
        /// directory per market (RH equities 86400s, Ink equities 3600s).
        uint32 heartbeat;
        /// In [heartbeat, heartbeat+grace]: tighter reverts on a quiet market; looser would let
        /// liquidation act on an older price (this bound IS canLiquidate's freshness gate).
        uint32 maxStaleness;
        uint8 decimals;
        bool configured;
    }

    /// Grace on top of the heartbeat before we call a feed broken. Operational slack, not a feed
    /// property — stays global on purpose.
    uint32 public constant STALENESS_GRACE = 3_600;
    /// No real Chainlink feed beats sub-minute; a zero heartbeat would make staleness meaningless.
    uint32 public constant MIN_HEARTBEAT = 60;
    /// Round-6 A/B: an unbounded heartbeat lets a re-commit treat an arbitrarily old print as
    /// fresh. 2 days sits above every real equity cadence and below anything that defeats
    /// staleness — the MIN_RISK_GAP_BPS philosophy applied to liquidation availability.
    uint32 public constant MAX_HEARTBEAT = 2 days;

    /// After a sequencer outage, prices are fresh but the market had no chance to react. Reject
    /// for a grace period rather than liquidating people on a resumed-but-unwound market.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600;

    /// The L2 sequencer uptime feed, or address(0) if none exists on this chain.
    ///
    /// UNRESOLVED AS OF DEPLOYMENT (2026-07-20). Robinhood's docs state that "Chainlink provides
    /// an L2 Sequencer Uptime Feed for this; check it before reading any price." That feed could
    /// not be found: Robinhood Chain is absent from Chainlink's canonical L2 sequencer feed list,
    /// absent from the Robinhood feed directory (55 entries, all price feeds), returns nothing on
    /// a name search, and every contract deployed by Chainlink's deployer on this chain resolves
    /// to a price feed. Their docs have already been wrong once on this chain (they described
    /// transfer restrictions the deployed token does not have), so the doc claim alone is not
    /// evidence.
    ///
    /// Setting this to address(0) SKIPS the check and accepts a real, named risk: during a
    /// sequencer outage no transaction executes, so nothing can be liquidated; on resumption a
    /// backlog runs against prices users had no chance to react to. The 24h heartbeat means
    /// staleness detection would not catch an outage for a full day, which is far too slow to
    /// substitute.
    ///
    /// Compensating controls REQUIRED when this is address(0):
    ///   - the LTV/liquidation buffer must absorb an outage-length gap (this is a second reason
    ///     the buffer is 20pp, not a thin one)
    ///   - an off-chain keeper must pause the pool on detected outage
    /// Revisit before mainnet: if a real uptime feed appears, deploy with it set.
    AggregatorV3Interface public immutable sequencerUptimeFeed;

    /// True when this deployment has no sequencer uptime feed and is running on compensating
    /// controls instead. Exposed so the UI and any monitoring can surface it rather than assume.
    bool public immutable sequencerCheckDisabled;
    mapping(address => FeedConfig) internal _feeds;

    constructor(AggregatorV3Interface sequencerUptimeFeed_) {
        sequencerUptimeFeed = sequencerUptimeFeed_;
        sequencerCheckDisabled = address(sequencerUptimeFeed_) == address(0);
    }

    /// Reverts unless the L2 sequencer is up and has been up for the full grace period.
    /// Standard Arbitrum-stack requirement. It has no analogue in the Sui design because Sui has
    /// no sequencer — this is a category of failure that only exists on an L2.
    function _requireSequencerUp() internal view {
        // No feed on this chain — see the note on `sequencerUptimeFeed`. Deliberately explicit
        // rather than a silent no-op, so this cannot be mistaken for a passing check.
        if (sequencerCheckDisabled) return;
        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        // 0 = up, 1 = down
        if (answer != 0) revert SequencerDown();
        uint256 elapsed = block.timestamp - startedAt;
        if (elapsed < SEQUENCER_GRACE_PERIOD) {
            revert SequencerGracePeriod(SEQUENCER_GRACE_PERIOD - elapsed);
        }
    }

    /// The price of one whole unit of `token`, scaled to the feed's own decimals, together with
    /// whether the US equity session is currently open.
    ///
    /// `inSession` gates NEW BORROWS only (EsseyMarkets.canBorrow returns it); liquidation ignores
    /// it and relies on the freshness bound below. No off-hours haircut exists — off-hours the
    /// protocol declines to lend rather than price the unknown.
    function priceOf(address token) public view returns (uint256 price, uint8 decimals, bool inSession) {
        FeedConfig memory c = _feeds[token];
        if (!c.configured) revert FeedNotConfigured(token);

        _requireSequencerUp();

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            c.feed.latestRoundData();

        if (answer <= 0) revert PriceNotPositive(answer);
        // A round that never completed, or an answer carried over from an earlier round, is not a
        // current price.
        if (updatedAt == 0 || answeredInRound < roundId) revert RoundIncomplete();

        inSession = isUsMarketHours(block.timestamp);
        uint256 age = block.timestamp - updatedAt;
        // One bound, sized to the heartbeat: this detects a SILENT oracle. It deliberately does
        // not try to detect a stale market — see the note at the top of this file.
        if (age > c.maxStaleness) revert PriceStale(age, c.maxStaleness, inSession);

        // MARKET HOLIDAYS. The calendar above knows weekends but not holidays, so on Thanksgiving
        // it reports "in session" while the feed has not published since the previous trading
        // day's close. The staleness bound cannot catch it — an 18-24h holiday gap fits inside a
        // 25h bound. So: if we believe we are in session, the feed must have published AT OR AFTER
        // today's open. On a holiday the last print is from yesterday and this correctly refuses.
        //
        // A very quiet stock that has not moved 0.5% since the open would also be refused. That is
        // the conservative direction — declining to lend on an unconfirmed price — and is accepted.
        if (inSession && updatedAt < _sessionOpenEarliestOf(block.timestamp)) {
            inSession = false;
        }

        return (uint256(answer), c.decimals, inSession);
    }

    /// US equity regular session, computed CONSERVATIVELY across both US time zones.
    ///
    /// Eastern time is UTC-5 in winter (EST) and UTC-4 in summer (EDT), so the session maps to a
    /// different UTC window depending on the date:
    ///     EST  09:30-16:00 ET  ->  14:30-21:00 UTC
    ///     EDT  09:30-16:00 ET  ->  13:30-20:00 UTC
    ///
    /// A previous version hardcoded the EST window. During EDT that reported "in session" for the
    /// hour AFTER the market closed — the unsafe direction, since it would admit new borrowing
    /// against a market that had already shut.
    ///
    /// Rather than implement the DST calendar on-chain, this returns the INTERSECTION of the two
    /// windows: 14:30-20:00 UTC. It is therefore never open when the market is shut, and gives up
    /// the first hour of an EST session and the last hour of an EDT one. Losing an hour of
    /// borrowing availability is the correct trade against ever lending into a closed market; a
    /// proper DST implementation would recover it.
    function isUsMarketHours(uint256 ts) public pure returns (bool) {
        if (!_isWeekday(ts)) return false;
        uint256 secondsOfDayUtc = ts % 86400;
        return secondsOfDayUtc >= SESSION_OPEN_UTC && secondsOfDayUtc < SESSION_CLOSE_UTC;
    }

    /// 14:30 UTC — the later of the two session opens (EST). Conservative.
    uint256 public constant SESSION_OPEN_UTC = 14 hours + 30 minutes;
    /// 20:00 UTC — the earlier of the two session closes (EDT). Conservative.
    uint256 public constant SESSION_CLOSE_UTC = 20 hours;
    /// 13:30 UTC — the EARLIER of the two session opens (EDT). Used ONLY as the holiday-check threshold
    /// below. A genuine EDT opening-hour print (13:30-14:30 UTC) must not be mistaken for a stale
    /// yesterday/holiday print: the old code compared against SESSION_OPEN_UTC (14:30) and false-rejected
    /// those prints, setting inSession=false — and because `canLiquidate` shares that flag, that was a
    /// liquidation OUTAGE on EDT days. Yesterday's close (prior-day ~20:00 UTC) is still far below today's
    /// 13:30, so holiday detection is unaffected; the only cost is possibly honouring an early
    /// (13:30-14:30) print on an EST day, which is well within the staleness bound already accepted.
    uint256 public constant SESSION_OPEN_EARLIEST_UTC = 13 hours + 30 minutes;

    function _isWeekday(uint256 ts) internal pure returns (bool) {
        // 1970-01-01 was a Thursday: shift so 0 = Monday.
        uint256 dow = ((ts / 86400) + 3) % 7;
        return dow < 5;
    }

    /// The earliest today's session could have opened (EDT open, 13:30 UTC), in absolute time — the
    /// holiday-check threshold. See SESSION_OPEN_EARLIEST_UTC.
    function _sessionOpenEarliestOf(uint256 ts) internal pure returns (uint256) {
        return (ts / 86400) * 86400 + SESSION_OPEN_EARLIEST_UTC;
    }

    function feedConfig(address token) external view returns (FeedConfig memory) {
        return _feeds[token];
    }

    /// Internal setter — the owning market registry decides access control. Kept internal so this
    /// contract has no admin surface of its own to get wrong.
    /// Reverts if `maxStaleness` is tighter than the heartbeat — a misconfiguration that would
    /// look like a working system until the first quiet hour and then reject every borrow — or
    /// looser than heartbeat+grace, which would widen the price age liquidations may act on.
    function _setFeed(address token, AggregatorV3Interface feed, uint32 heartbeat, uint32 maxStaleness, uint8 decimals)
        internal
    {
        if (heartbeat < MIN_HEARTBEAT) revert HeartbeatTooShort(heartbeat, MIN_HEARTBEAT);
        if (heartbeat > MAX_HEARTBEAT) revert HeartbeatTooLong(heartbeat, MAX_HEARTBEAT);
        if (maxStaleness < heartbeat) revert StalenessBelowHeartbeat(maxStaleness, heartbeat);
        if (maxStaleness > heartbeat + STALENESS_GRACE) {
            revert StalenessAboveCeiling(maxStaleness, heartbeat + STALENESS_GRACE);
        }
        _feeds[token] = FeedConfig(feed, heartbeat, maxStaleness, decimals, true);
    }
}
