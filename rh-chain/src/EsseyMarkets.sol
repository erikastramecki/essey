// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StaleFeedGuard} from "./StaleFeedGuard.sol";
import {LivenessOracle} from "./LivenessOracle.sol";
import {MarketHealthOracle} from "./MarketHealthOracle.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IScaledUI} from "./interfaces/IScaledUI.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// The two bindings commit verifies before a pool becomes activePool. Declared minimally here:
/// EsseyPool imports this file, so importing it back would be a cycle.
interface IPoolBinding {
    function collateralToken() external view returns (address);
    function markets() external view returns (address);
}

/// Risk registry: which Stock Tokens are accepted, on what terms, and when.
///
/// This is where the three Robinhood-specific hazards turn into numbers. Each is priced into the
/// parameters rather than assumed away:
///   - collateral is a Jersey DEBT token, not equity — Robinhood counterparty risk
///   - `adminBurn` can destroy it, held by a plain EOA with no multisig or timelock
///   - the price is blind nights and weekends (24/5 equity feeds; heartbeat is per-market)
///
/// THE GAP IS THE SAFETY MARGIN, NOT THE LTV. Liquidation needs a FRESH price (age within the
/// feed's staleness bound, ceiling heartbeat+grace) and a demonstrably live chain — weekday nights
/// stay actionable, but the feed ages out ~25h after Friday's close so a weekend gap and a chain
/// outage remain unliquidatable-into. The distance between `ltvBps` and `liqThresholdBps` is what
/// has to absorb them. That is why `MIN_RISK_GAP_BPS` is enforced in code: a future parameter
/// change cannot quietly narrow the one thing protecting lenders.
contract EsseyMarkets is StaleFeedGuard {
    error NotAdmin();
    error MarketNotEnabled(address token);
    error InvalidRiskParams(string reason);
    error NoPendingChange(address token);
    error TimelockNotElapsed(uint256 secondsRemaining);
    error FeedIsImmutable(address token);
    error FreshnessIsImmutable(address token);
    error BadMultiplierSource(address token, address source);
    error MultiplierSourceIsImmutable(address token);
    error ZeroGuardian();
    error DeprecationOrderViolated(address token);
    error BadActivePool(address token, address pool);
    error PauseTooLong(uint256 until, uint256 ceiling);
    error PauseOnCooldown(address token);

    /// The FULL pending payload, not a digest: commit is permissionless, so the log must be enough
    /// for any watcher to decode exactly what a ripe proposal will install (WS2 #3).
    event MarketProposed(
        address indexed token,
        Market m,
        AggregatorV3Interface feed,
        uint32 heartbeat,
        uint32 maxStaleness,
        uint8 feedDecimals,
        address multiplierSource,
        address pool,
        uint256 effectiveAt
    );
    event MarketProposalCancelled(address indexed token);
    event MarketCommitted(address indexed token, uint16 ltvBps, uint16 liqThresholdBps);
    event MarketDisabled(address indexed token);
    event ResolverProposed(address indexed resolver, uint256 effectiveAt);
    event ResolverCommitted(address indexed resolver);
    event LiquidationPaused(address indexed token, uint256 until);
    /// The feed and the multiplier disagree by more than MAX_PRICE_DEVIATION_BPS. Emitted from the
    /// permissionless observer, so a corporate action is visible to a watcher the block it is seen.
    event PriceDesyncDetected(address indexed token, uint256 refProduct, uint256 observedProduct);
    event PriceDesyncCleared(address indexed token, uint256 observedProduct);
    /// The hold ran out and the legs never agreed: this IS the new level. Distinct from Cleared,
    /// because "the corporate action completed" and "we gave up waiting" want different alerts.
    event PriceDesyncExpired(address indexed token, uint256 staleRefProduct, uint256 observedProduct);

    struct Market {
        bool enabled;
        uint16 ltvBps; // max borrow against collateral value
        uint16 liqThresholdBps; // liquidation trigger
        uint16 liqBonusBps; // liquidator's cut, above the debt
        /// The collateral token's own decimals. REQUIRED for normalisation — see collateralValue.
        uint8 collateralDecimals;
        uint128 cap; // per-collateral exposure cap, in borrow-asset units
        uint16 maxPositionBps; // share of `cap` one position may borrow; gates NEW borrows only
    }

    struct PendingMarket {
        Market m;
        AggregatorV3Interface feed;
        uint32 heartbeat;
        uint32 maxStaleness;
        uint8 feedDecimals;
        address multiplierSource;
        address pool;
        uint256 effectiveAt;
    }

    /// The minimum distance between max-LTV and liquidation. 20 percentage points.
    ///
    /// Sized against the risk that cannot be liquidated into: a weekend gap on a single-name
    /// equity, or a chain outage. A position opened at max LTV survives roughly a 30% adverse move
    /// before going underwater. Deliberately conservative — raise it as the MVP proves itself,
    /// never narrow it after an incident.
    uint16 public constant MIN_RISK_GAP_BPS = 2_000;
    /// Nothing may be liquidated at or above par; leaves room for the bonus to be payable.
    uint16 public constant MAX_LIQ_THRESHOLD_BPS = 9_000;
    /// A bonus larger than this would let a liquidation take more than the shortfall justifies.
    uint16 public constant MAX_LIQ_BONUS_BPS = 1_500;
    /// Parameter changes are visible on-chain for this long before they bite. Same reasoning as
    /// the Sui operator-key rotation: a privileged change that is atomic with its use is not a
    /// control at all.
    uint256 public constant PARAM_TIMELOCK = 2 days;

    address public immutable admin;
    /// Hot emergency key. It can STOP things, never move funds and never seize: `disableMarket` and
    /// `pauseLiquidation`. THE SECOND ONE IS A LIQUIDATION KILL SWITCH while it holds, bounded since
    /// R3 MED-3 by a cooldown as long as the pause it follows, so this key's compromise halts
    /// liquidation for at most half the time. DeployMarkets._checkRoles requires it to differ from
    /// LIVENESS_KEEPER and LIVENESS_GUARDIAN, the other addresses that reach the same outcome.
    ///
    /// MED-3: the health keeper shares the safe-direction shape (effectiveCap is read only at
    /// canBorrow and EsseyPool._gateNewDebt). The LIVENESS keeper does not — it need only go SILENT.
    /// R2 LOW-4: the bound on that is NOT "two independent keepers", which `heartbeat()` cannot
    /// express (LivenessOracle.sol:88-89 gates one address). It is one keeper, one cold rotation key,
    /// and paging on lastHeartbeat past gapThreshold / 2. A 1-of-N relay keeper would restore the
    /// stronger claim; nothing here builds one.
    address public immutable guardian;
    LivenessOracle public immutable liveness;
    MarketHealthOracle public immutable health;
    /// Decimals of the BORROW asset (USDG = 6 on Robinhood Chain). Everything this contract
    /// returns is denominated in these units so debt and collateral are directly comparable.
    uint8 public immutable assetDecimals;

    mapping(address => Market) internal _markets;
    mapping(address => PendingMarket) internal _pending;

    /// WS4 #4: where this market's ERC-8056 corporate-action multiplier is read. Robinhood Stock
    /// Tokens carry the surface themselves (source == token); Backed's Ink 4626 wrapper does not —
    /// an un-adapted call would revert inside collateralValue and brick canBorrow/canLiquidate for
    /// good, so such a market lists a ConstantMultiplier adapter instead. Never defaulted silently
    /// (the 1e12 lesson): commit asserts the source answers uiMultiplier() with a nonzero value.
    mapping(address => address) public multiplierSource;

    /// F1 (round 6): the ONE pool per token allowed to open NEW borrows. The market gate alone is
    /// per-token, so after a same-token pool succession the retired pool re-armed — any stranger
    /// could deposit there and borrow, doubling effective exposure against the shared cap.
    /// Flips only through the timelocked propose/commit pipeline; nothing else on a superseded
    /// pool gates on it, so its book winds down through the untouched paths.
    mapping(address => address) public activePool;

    /// The bad-debt resolver: the ONE address the pools accept writeOff() from, and the recipient of
    /// written-off collateral. Timelocked like every risk parameter — an atomic admin->resolver swap
    /// could sweep residual collateral with no warning on-chain.
    address public resolver;
    address public pendingResolver;
    uint256 public pendingResolverEffectiveAt;

    constructor(
        AggregatorV3Interface sequencerUptimeFeed_,
        LivenessOracle liveness_,
        MarketHealthOracle health_,
        address admin_,
        address guardian_,
        uint8 assetDecimals_
    ) StaleFeedGuard(sequencerUptimeFeed_) {
        if (guardian_ == address(0)) revert ZeroGuardian();
        liveness = liveness_;
        health = health_;
        admin = admin_;
        guardian = guardian_;
        assetDecimals = assetDecimals_;
    }

    // ---------------------------------------------------------------- risk math

    /// Value of `rawAmount` units of `token`, DENOMINATED IN THE BORROW ASSET's decimals.
    ///
    /// DECIMAL NORMALISATION IS THE WHOLE POINT OF THIS FUNCTION. On Robinhood Chain the three
    /// scales genuinely differ — USDG has 6 decimals, Stock Tokens have 18, Chainlink feeds have
    /// 8 (all verified on mainnet). An earlier version divided out only the feed decimals and
    /// returned a collateral-scaled number, which was then compared against a 6-decimal debt:
    /// every LTV limit was 1e12 too permissive, and a $2,000 position could drain the pool. The
    /// bug was invisible to the test suite because its mock borrow asset used 18 decimals.
    ///
    ///   value = uiAmount x price x 10^assetDec / (10^collDec x 10^feedDec)
    ///
    /// Reverts if the price is unusable (silent oracle, sequencer down). Callers get no price
    /// rather than a stale one — an unknown price must never round to a usable number.
    /// Requires the market COMMITTED, not currently enabled: disableMarket stops new borrows only,
    /// and valuation must keep serving liquidation/write-off of the positions that already exist.
    function collateralValue(address token, uint256 rawAmount)
        public
        view
        returns (uint256 value, bool inSession)
    {
        uint8 collDec = _configuredMarket(token).collateralDecimals;
        uint256 price;
        uint8 feedDec;
        (price, feedDec, inSession) = priceOf(token);
        // R4 LOW-1: the SAME capped read the observer uses. Uncapped here and capped there, a token
        // upgraded past the observer's budget (Stock Tokens are beacon-upgradeable) kept being valued
        // and borrowed against while its breaker and delay line silently recorded nothing.
        uint256 mult = _liveMultiplier(multiplierSource[token]);
        if (mult == 0) revert BadMultiplierSource(token, multiplierSource[token]);
        value = _valueAt(rawAmount, price, mult, collDec, feedDec);
    }

    /// The one place the three scales are reconciled, shared with corroboratedValue so the live and
    /// the corroborated read cannot disagree by a rounding step at the threshold.
    function _valueAt(uint256 rawAmount, uint256 price, uint256 mult, uint8 collDec, uint8 feedDec)
        internal
        view
        returns (uint256)
    {
        // balanceOf is raw and stable; the share-equivalent moves on splits. Pricing the raw
        // amount is correct until the first corporate action and catastrophically wrong after.
        uint256 uiAmount = (rawAmount * mult) / 1e18;
        return (uiAmount * price * (10 ** assetDecimals)) / (10 ** collDec * 10 ** feedDec);
    }

    /// The cap the pool enforces: min(timelocked Market.cap, depth-oracle cap). The static cap
    /// stays the ceiling-of-ceilings (AD-2) — the oracle moves only within it, so a compromised
    /// depth keeper can never raise exposure past what the 2-day timelock installed.
    function borrowCap(address token) external view returns (uint256) {
        uint256 oracleCap = health.effectiveCap(token);
        uint256 staticCap = _markets[token].cap;
        return oracleCap < staticCap ? oracleCap : staticCap;
    }

    /// The stored static cap alone, for the health oracle's from-zero ramp clamp. Deliberately
    /// NOT borrowCap: that consults the oracle back and would recurse.
    function marketCap(address token) external view returns (uint256) {
        return _markets[token].cap;
    }

    /// Most that may be borrowed against `rawAmount` of `token`, in borrow-asset units.
    function maxBorrow(address token, uint256 rawAmount) external view returns (uint256) {
        Market memory m = _requireEnabled(token);
        (uint256 value,) = collateralValue(token, rawAmount);
        return (value * m.ltvBps) / 10_000;
    }

    /// Is this position liquidatable on VALUE alone? Callers must also check `canLiquidate`,
    /// which covers whether the chain and market are in a state where liquidating is legitimate.
    function isUnderwater(address token, uint256 rawAmount, uint256 debt) external view returns (bool) {
        Market memory m = _configuredMarket(token); // liquidation-side: must survive disableMarket
        (uint256 value,) = collateralValue(token, rawAmount);
        return debt > (value * m.liqThresholdBps) / 10_000;
    }

    /// Is it ALSO underwater at the observation this registry has had time to corroborate? R3
    /// HIGH-1; the reasoning is at PRICE_CONFIRM_DELAY. A COMPLETED corporate action costs nothing
    /// here — both legs rescale in opposite directions, so the corroborated value equals the live
    /// one and a genuinely underwater position never waits.
    function isUnderwaterCorroborated(address token, uint256 rawAmount, uint256 debt)
        external
        view
        returns (bool)
    {
        (uint256 value, bool available) = corroboratedValue(token, rawAmount);
        if (!available) return false;
        return debt > (value * _configuredMarket(token).liqThresholdBps) / 10_000;
    }

    /// Write-off's own bar, corroborated. NOT isUnderwaterCorroborated: insolvency sits far below the
    /// threshold, so a position being written off is underwater at any price worth discussing and
    /// that test would wave every uncorroborated move through.
    function isInsolventCorroborated(address token, uint256 rawAmount, uint256 debt)
        external
        view
        returns (bool)
    {
        (uint256 value, bool available) = corroboratedValue(token, rawAmount);
        return available && value < debt;
    }

    /// The observation the corroborated read uses: the OLDEST slot of the delay line. Nothing else
    /// may be read for corroboration — the fresher slots exist only to age into this one.
    function confirmedObservation(address token) public view returns (Observation memory) {
        return _confirmRing[token][(_confirmHead[token] + 1) % CONFIRM_SLOTS];
    }

    function confirmedPrice(address token) external view returns (uint256) {
        return confirmedObservation(token).price;
    }

    function confirmedMultiplier(address token) external view returns (uint256) {
        return confirmedObservation(token).mult;
    }

    /// When that observation was TAKEN. Deliberately not named `confirmedAt`: the old field held
    /// the moment of PROMOTION, and reading one as the other is exactly how R4 HIGH-1 survived.
    function confirmedObservedAt(address token) external view returns (uint256) {
        return confirmedObservation(token).takenAt;
    }

    /// Value of `rawAmount` at the corroborated observation, and whether there IS one. `available ==
    /// false` means the registry cannot vouch for a price, NOT that the collateral is worthless.
    ///
    /// THE AGE TEST IS THE SECURITY PROPERTY, so it lives here rather than being inferred from the
    /// push rule. Too YOUNG (R4 HIGH-1) and a move that has not stood for PRICE_CONFIRM_DELAY could
    /// justify a seizure; too OLD (R4 HIGH-2) and a market nobody has observed since keeps vouching
    /// for a price, which is how an unsupervised keeper turned into a fail-OPEN. Both directions
    /// refuse, and refusing costs a liquidation window, never a wrongful seizure.
    function corroboratedValue(address token, uint256 rawAmount) public view returns (uint256 value, bool available) {
        Observation memory o = confirmedObservation(token);
        if (o.price == 0) return (0, false);
        // No `takenAt == 0` conjunct: a never-observed market reads as older than any ceiling and is
        // refused by the age test below, which is the test that is pinned. A second reason to refuse
        // would make that one unfalsifiable — the shape the old promotion rule hid behind.
        uint256 age = block.timestamp - o.takenAt;
        if (age < PRICE_CONFIRM_DELAY || age > MAX_CONFIRM_AGE) return (0, false);
        Market memory m = _configuredMarket(token);
        value = _valueAt(rawAmount, o.price, o.mult, m.collateralDecimals, _feeds[token].decimals);
        available = true;
    }

    // ---------------------------------------------------------------- gating

    /// New borrows require an enabled market, a usable price, AND an open US equity session.
    ///
    /// Off-hours borrowing is blocked outright rather than haircut. The feed is 24/5, so overnight
    /// there is no fresh price to haircut FROM — only a Friday-close price that a Monday gap can
    /// invalidate. Declining to lend is the honest response to not knowing the price.
    function canBorrow(address token) external view returns (bool) {
        Market memory m = _markets[token];
        if (!m.enabled) return false;
        // WS3 stage 1: ltvBps == 0 is a market in retirement. maxBorrow is already 0, so without
        // this a stage-1 market would advertise borrowable and then revert every borrow.
        if (m.ltvBps == 0) return false;
        // Mainnet-config: gate NEW borrows on chain liveness too (not just liquidation). Under the
        // disabled-sequencer config the price path has no on-chain sequencer gate, so without this a
        // sequencer restart could admit a borrow on a stale pre-outage price. During the post-outage
        // resume grace, declining new borrows is the safe, conservative response.
        if (!liveness.liquidationsAllowed()) return false;
        // AD-2 pre-flight honesty: a stale/zero depth reading means the pool will refuse anyway.
        if (health.effectiveCap(token) == 0) return false;
        // Corporate-action desync guard: around a uiMultiplier change the token's multiplier and its
        // Chainlink feed reprice at different instants, opening a ~2x mis-valuation window a borrower could
        // TIME (effectiveAt is public). Refuse new borrows while it holds.
        if (_desyncGuard(token)) return false;
        try this.collateralValue(token, 1e18) returns (uint256, bool inSession) {
            return inSession;
        } catch {
            return false;
        }
    }

    uint256 public constant MULTIPLIER_GUARD_WINDOW = 1 hours;

    /// DERIVED AT ORIGINATION, AND ONLY THERE. Flipping a position opened at max LTV needs an
    /// under-read of `1 - ltvBps / liqThresholdBps`; the most fragile market _validate admits is
    /// liqThreshold 9,000 over ltv 7,000 = 2,223bps, so 2,000 sits below it for every listable market.
    ///
    /// R3 HIGH-1: a seasoned loan's cushion is smaller than that and reaches zero at the threshold,
    /// so no bound covers every open position — a 6:5 split's 16.67% leg harvested one for 2,600bps.
    /// This detects a DISLOCATION; PRICE_CONFIRM_DELAY is what protects a position. Constant because
    /// it is a function of constants already here, and a settable copy could only drift from them.
    uint16 public constant MAX_PRICE_DEVIATION_BPS = 2_000;
    /// How old the baseline may be before a move measured against it stops being evidence of a
    /// DISCONTINUITY rather than drift (R3 MED-1: _breaker compares observations, not feed rounds).
    /// The liveness keeper observes every market on its gapThreshold/3 = 300s beat
    /// (keeper/liveness-keeper.mjs), so an hour is twelve consecutive missed beats.
    uint256 public constant MAX_BASELINE_AGE = 1 hours;
    /// Ceiling on an UNRESOLVED disagreement — it clears the instant the product comes back. Sized
    /// against the unliquidatable window this design already carries: the 24/5 feed ages out ~25h
    /// after Friday's close, so a weekend is ~65h that the 20pp MIN_RISK_GAP_BPS absorbs by
    /// construction (file header). One US session is well inside that.
    uint256 public constant PRICE_DESYNC_HOLD = 6 hours;
    /// Long enough to sit out an ex-date, short enough that a forgotten pause is not the permanent
    /// freeze the missing `enabled` conjunct on canLiquidate exists to prevent. The cap is per CALL,
    /// which on its own chained into exactly that freeze (R3 MED-3) — pauseLiquidation's cooldown is
    /// what actually bounds it.
    uint256 public constant MAX_LIQUIDATION_PAUSE = 24 hours;

    /// How long a price move must stand before it may justify a SEIZURE (R3 HIGH-1). Branch (b)'s
    /// window, applied to the other leg ordering — the one nothing covered — and at every magnitude,
    /// because a sub-bound move flips a seasoned position just as thoroughly as a large one.
    /// Separation by TIME, not magnitude: a real move stands, a half-landed action is joined by its
    /// other leg. IT DELAYS NOTHING ALREADY JUSTIFIED.
    ///
    /// SIX HOURS, MEASURED, not inherited from MULTIPLIER_GUARD_WINDOW as it was. The delay spends
    /// the threshold-to-liquidator-indifference distance: 21.25% at 5000/7500/500. Every round of
    /// both listed feeds on 4663, 2026-06-22 -> 2026-09-04 (74.3d; AAPL 0x6B22…2cD0 555 rounds,
    /// NVDA 0x379E…9F15 981) gives a worst move of 6.80/7.06% at 1h, 8.47/7.88% at 6h, 8.97/9.22%
    /// at 12h, 10.23/12.00% at 24h — nothing within a third of the buffer, and NVDA no more volatile
    /// than AAPL. The binding constraint is HOW LATE AN ISSUER'S SECOND LEG LANDS, which is why
    /// PRICE_DESYNC_HOLD is already 6h; equal, the sub-bound and above-bound cases get the same
    /// protection. 74 days holding one stress episode cannot BOUND a 21.25% tail, only miss it.
    uint256 public constant PRICE_CONFIRM_DELAY = 6 hours;

    /// R4 HIGH-1: one promoted snapshot cannot deliver a delay however it is rate-limited, because
    /// the limit measures the PROMOTION clock and `syncMultiplier` is permissionless — a move landing
    /// late in an interval was blessed one second later, for 2,592bps against a healthy borrower.
    /// A DELAY LINE instead: pushed no faster than CONFIRM_STEP apart, read (CONFIRM_SLOTS - 1) slots
    /// back, and the age re-tested in the view so the property survives a wrong cadence.
    uint256 internal constant CONFIRM_SLOTS = 5;
    uint256 public constant CONFIRM_STEP = PRICE_CONFIRM_DELAY / (CONFIRM_SLOTS - 1);
    /// And a CEILING, which is what makes an observation outage fail CLOSED (R4 HIGH-2): without it
    /// a market the keeper stopped observing vouches forever for a price nobody has checked. One
    /// CONFIRM_STEP above the steady-state maximum, so a live keeper never trips it.
    uint256 public constant MAX_CONFIRM_AGE = PRICE_CONFIRM_DELAY + 2 * CONFIRM_STEP;

    /// The last uiMultiplier this registry observed for a token, and when it last MOVED. `syncMultiplier`
    /// (called on the borrow AND liquidate paths) records a move the instant a corporate action applies —
    /// this is what covers the POST-flip desync window robustly, without depending on whether the token
    /// keeps its scheduled `newUIMultiplier` populated after the flip.
    mapping(address => uint256) public seenMultiplier;
    mapping(address => uint256) public multiplierMovedAt;

    /// The price half of the same observation, and WHEN it was taken — the age is what says whether
    /// a move measured against it is a discontinuity or three weeks of drift (MAX_BASELINE_AGE).
    mapping(address => uint256) public seenPrice;
    mapping(address => uint256) public seenPriceAt;

    /// The armed state, as ONE value in two slots, WRITTEN AND CLEARED TOGETHER on every path. R3
    /// CRIT-1 was this pair coming apart: the reference was released only on agreement while the hold
    /// expired on a clock, so one unresolved move left a stale reference that swallowed every later
    /// observation and the market could never arm again.
    mapping(address => uint256) public desyncRefProduct;
    mapping(address => uint256) public priceDesyncAt;

    /// Both legs rather than their product, so `_valueAt` is the arithmetic that values the live
    /// price too. `takenAt` is when the pair was READ; the old `confirmedAt` held when it was
    /// PROMOTED, and that distinction is the whole of R4 HIGH-1.
    struct Observation {
        uint256 price;
        uint256 mult;
        uint256 takenAt;
    }

    /// The delay line. `_confirmHead` indexes the most recent push; the oldest — the one the
    /// corroborated read uses — is always the slot after it.
    mapping(address => Observation[CONFIRM_SLOTS]) internal _confirmRing;
    mapping(address => uint256) internal _confirmHead;

    /// Guardian's bounded corporate-action lever. Liquidation only.
    mapping(address => uint256) public liquidationPausedUntil;
    /// Earliest a NEW pause may start. R3 MED-3: without it the per-call cap was no cap at all.
    mapping(address => uint256) public pauseCooldownUntil;

    /// True while a scheduled or just-applied uiMultiplier change makes the token's multiplier and its
    /// Chainlink feed inconsistent — the ~2x mis-valuation window. Both canBorrow AND canLiquidate refuse to
    /// act while this holds (declining on an unverifiable price beats a mispriced borrow OR a wrongful
    /// seizure; the ~1h gap is absorbed by the 20pp MIN_RISK_GAP_BPS buffer).
    function _desyncGuard(address token) internal view returns (bool) {
        // (a) scheduled action within the window (pre-flip, while newUIMultiplier still reports it).
        // INERT AGAINST EVERY SOURCE THIS REPO LISTS: the Stock Token answers with ONE word so
        // _scheduledEffectiveAt returns 0 forever, and ConstantMultiplier answers (0, 0)
        // (adapters/ConstantMultiplier.sol:12-14). Forward coverage only — nothing may be argued from
        // its presence about the tokens that ship. Branch (c) covers those.
        uint256 effectiveAt = _scheduledEffectiveAt(multiplierSource[token]);
        if (effectiveAt != 0) {
            uint256 d = block.timestamp > effectiveAt ? block.timestamp - effectiveAt : effectiveAt - block.timestamp;
            if (d <= MULTIPLIER_GUARD_WINDOW) return true;
        }
        // (b) the live multiplier MOVED within the window (post-flip, observed via syncMultiplier)
        uint256 movedAt = multiplierMovedAt[token];
        if (movedAt != 0 && block.timestamp - movedAt < MULTIPLIER_GUARD_WINDOW) return true;
        // (c) the FEED moved without the multiplier — the half (a) and (b) cannot see. See _syncPrice.
        uint256 desyncAt = priceDesyncAt[token];
        return desyncAt != 0 && block.timestamp - desyncAt < PRICE_DESYNC_HOLD;
    }

    /// THE PRODUCT IS THE INVARIANT. A corporate action rescales both legs in opposite directions —
    /// a 2:1 split halves the feed and doubles the multiplier — so `price x uiMultiplier` is
    /// continuous across a COMPLETED action and dislocated while only one leg has landed. Branch (b)
    /// sees the multiplier leg; nothing saw the FEED leg, the one that reads collateral low and let a
    /// healthy 45%-LTV position be liquidated for ~110% of the debt in free profit.
    ///
    /// Arming, not detection, is what makes it work: syncMultiplier runs at the top of borrow,
    /// borrowMore, removeCollateral, liquidate and writeOff, above their gates (EsseyPool.sol:695-696),
    /// so the first transaction to reach the dislocated price arms the breaker and is refused by it.
    /// That transaction REVERTS, taking the arming write with it — which is why nobody can
    /// arm-and-bypass in one transaction, and why an honest liquidator's sequence after a real >20%
    /// gap is a standalone permissionless syncMultiplier, then the hold, then liquidate.
    ///
    /// IT MEASURES BETWEEN OBSERVATIONS, NOT BETWEEN FEED ROUNDS, and only the standalone call makes
    /// a durable one — the five pool paths revert when the guard fires and take the write with them.
    /// So across a long gap this measures drift (R3 MED-1), answered by MAX_BASELINE_AGE and by
    /// keeper/liveness-keeper.mjs observing every market on the heartbeat it already sends.
    ///
    /// WHAT IT CANNOT COVER: legs more than PRICE_DESYNC_HOLD apart (hence `pauseLiquidation` for a
    /// date known in advance), and any single-leg move under the bound — that second one is what
    /// isUnderwaterCorroborated exists for, because it is unbounded in harm and the bound cannot be
    /// tightened to reach it. And at the instant it happens a split is INDISTINGUISHABLE on-chain
    /// from a real crash of the same size — both read as "the feed moved and the multiplier did
    /// not" — so holding both is the only honest response to identical evidence, not a shortcoming
    /// of the rule.
    /// Returns whether the observation was RECORDED. R4 MED-1: the two halves of the pair were
    /// coming apart — `seenMultiplier` was written unconditionally while this returned without
    /// writing `seenPrice`, so a multiplier leg landing while the feed was unreadable left the next
    /// observation treating Friday's price and Monday's multiplier as matched. The AAPL feed is
    /// unreadable ~55h EVERY weekend, which is exactly when a Monday ex-date is applied.
    function _syncPrice(address token, uint256 prevMult, uint256 curMult) internal returns (bool) {
        uint256 price = _readablePrice(token);
        if (price == 0) return false; // unreadable price records nothing, exactly as a failed multiplier read does
        uint256 prevPrice = seenPrice[token];
        uint256 prev = prevPrice * prevMult; // 0 when either half has no baseline yet
        uint256 baselineAge = block.timestamp - seenPriceAt[token];
        seenPrice[token] = price;
        seenPriceAt[token] = block.timestamp;
        _confirmable(token, price, curMult);
        if (prev == 0) return true; // no baseline: `baselineAge` is meaningless here and goes unused
        _breaker(token, prev, price * curMult, baselineAge);
        return true;
    }

    /// Push this observation onto the delay line, no faster than one slot per CONFIRM_STEP.
    ///
    /// The CURRENT pair, not an earlier one: "an earlier observation" was the old rule's attempt at
    /// the same property and it bought one observation, not one delay. What stops the transaction
    /// that first sees a dislocation blessing it is that this slot cannot be READ for
    /// PRICE_CONFIRM_DELAY, which holds however the caller times it.
    ///
    /// A market's FIRST observation fills every slot with itself. An empty slot would give the read a
    /// second reason to refuse — "none yet" as well as "too young" — and a defence that can only fail
    /// for the other's reason is unpinnable, which is how the old rule survived three rounds.
    function _confirmable(address token, uint256 price, uint256 mult) internal {
        uint256 head = _confirmHead[token];
        uint256 last = _confirmRing[token][head].takenAt;
        if (last == 0) return _seedConfirmRing(token, price, mult);
        if (block.timestamp - last < CONFIRM_STEP) return;
        head = (head + 1) % CONFIRM_SLOTS;
        _confirmRing[token][head] = Observation(price, mult, block.timestamp);
        _confirmHead[token] = head;
    }

    function _seedConfirmRing(address token, uint256 price, uint256 mult) internal {
        for (uint256 i = 0; i < CONFIRM_SLOTS; i++) {
            _confirmRing[token][i] = Observation(price, mult, block.timestamp);
        }
    }

    function _breaker(address token, uint256 prev, uint256 observed, uint256 baselineAge) internal {
        uint256 ref = desyncRefProduct[token];
        // ARMED: the reference is the only thing consulted, because judging against the previous
        // observation would re-arm on the issuer's SECOND leg — the event that resolves the desync.
        // Three ways out, all of which leave the pair consistent.
        if (ref != 0) {
            if (!_deviates(ref, observed)) return _disarm(token, observed, true); // the legs agreed
            if (block.timestamp - priceDesyncAt[token] < PRICE_DESYNC_HOLD) return; // still holding
            // The hold is spent and the legs never agreed: this IS the new level, not a dislocation
            // from it. Release the pair and re-baseline against `prev` below, so a LATER event can
            // arm. Leaving the reference set here was R3 CRIT-1 — a permanent, silent disarm.
            _disarm(token, observed, false);
        }
        // R3 MED-1: a baseline this old measures drift, not a discontinuity, and arming on it costs a
        // real liquidation window on the thin markets least able to afford one. Safe to decline
        // because it is not what protects a position — the delay line is, and R4 HIGH-2 is why that
        // claim needed the delay line to be real: a market unobserved for one hour discarded a
        // 5,000bps split leg here as drift and was harvested an hour later for 10,988bps.
        if (baselineAge > MAX_BASELINE_AGE) return;
        if (!_deviates(prev, observed)) return;
        // Stamped ONCE: a further gap while armed does not extend the hold, so a dislocation costs a
        // bounded PRICE_DESYNC_HOLD rather than a blackout a falling market could keep renewing.
        desyncRefProduct[token] = prev;
        priceDesyncAt[token] = block.timestamp;
        emit PriceDesyncDetected(token, prev, observed);
    }

    /// The ONLY writer that clears the armed state, so the two slots cannot come apart.
    function _disarm(address token, uint256 observed, bool legsAgreed) internal {
        uint256 staleRef = desyncRefProduct[token];
        delete desyncRefProduct[token];
        delete priceDesyncAt[token];
        if (legsAgreed) emit PriceDesyncCleared(token, observed);
        else emit PriceDesyncExpired(token, staleRef, observed);
    }

    /// No zero guard on `ref`: _syncPrice returns before this when there is no baseline, and the
    /// armed branch only reaches here with a nonzero reference. A zero guard here made THAT guard
    /// unpinnable — two defences each hiding the other's absence — so this one goes and the safe
    /// direction is kept: a zero reference would arm, not wave through.
    function _deviates(uint256 ref, uint256 observed) internal pure returns (bool) {
        uint256 diff = observed > ref ? observed - ref : ref - observed;
        return diff * 10_000 > ref * MAX_PRICE_DEVIATION_BPS;
    }

    /// 0 when the price cannot be read. Never reverts: syncMultiplier sits above five entry points
    /// with no outer try, and priceOf reverts on stale, silent, sequencer-down and unconfigured.
    function _readablePrice(address token) internal view returns (uint256) {
        try this.priceOf(token) returns (uint256 p, uint8, bool) {
            return p;
        } catch {
            return 0;
        }
    }

    /// `effectiveAt` of a scheduled corporate action, or 0 for "nothing scheduled that I can read".
    ///
    /// G-LEND CRIT-1: the deployed Stock Token answers `newUIMultiplier()` with ONE word, not the two
    /// IScaledUI declares, and return-data decoding fails OUTSIDE a typed catch — so this used to
    /// revert and take canBorrow and canLiquidate with it. Raw staticcall + exact length, the shape
    /// EsseyPool._borrowAssetPaused already uses.
    ///
    /// An unreadable schedule reports "none", NOT "guarded": returning true would brick both gates as
    /// thoroughly as the revert did. Branch (b) covers such a token, and needs nothing from it.
    /// The budget for BOTH reads of an untrusted collateral token, valuation included. It exists to
    /// stop a griefing token bricking five entry points, and that goal is met here as well as at the
    /// 50,000 it used to be — `uiMultiplier()` on the deployed AAPL token costs 15,719 gas
    /// (test/GLendR4.t.sol), so 50,000 was 3.18x headroom on a contract this protocol does not own
    /// and cannot pin.
    uint256 internal constant MULTIPLIER_READ_GAS = 200_000;

    function _scheduledEffectiveAt(address source) internal view returns (uint256) {
        (bool ok, bytes memory ret) = source.staticcall{gas: MULTIPLIER_READ_GAS}(abi.encodeWithSignature("newUIMultiplier()"));
        if (!ok || ret.length != 64) return 0;
        (, uint256 effectiveAt) = abi.decode(ret, (uint256, uint256));
        return effectiveAt;
    }

    /// Same defensive decode as _scheduledEffectiveAt, for the same reason: syncMultiplier sits at the
    /// top of borrow, borrowMore, removeCollateral, liquidate and writeOff with no outer try, so a
    /// short or absent return here would brick all five. 0 means "could not read" and syncMultiplier
    /// records nothing.
    function _liveMultiplier(address source) internal view returns (uint256) {
        (bool ok, bytes memory ret) = source.staticcall{gas: MULTIPLIER_READ_GAS}(abi.encodeWithSignature("uiMultiplier()"));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// Observe the market's live uiMultiplier (at its multiplierSource) and stamp the moment it moves.
    /// Permissionless + non-view; the pool calls it on the borrow/liquidate paths (a keeper may also
    /// call it) so `_desyncGuard` sees a corporate action the instant it applies — the FIRST action
    /// that touches the pool records the move and is itself gated by the window.
    function syncMultiplier(address token) public {
        address source = multiplierSource[token];
        if (source == address(0)) return; // never committed — nothing wired to observe
        uint256 cur = _liveMultiplier(source);
        if (cur == 0) return; // transient read failure — nothing to record
        uint256 prev = seenMultiplier[token];
        if (prev != 0 && cur != prev) multiplierMovedAt[token] = block.timestamp;
        // R4 MED-1: the multiplier half advances only when the price half did, so the pair stays as
        // it was last read TOGETHER. `multiplierMovedAt` above is stamped either way and re-stamps
        // until the price returns, which only ever REFUSES.
        if (_syncPrice(token, prev, cur)) seenMultiplier[token] = cur;
    }

    /// Liquidation additionally requires demonstrated chain liveness — see LivenessOracle. A
    /// borrower must not be liquidated in the first block after an outage they could not react to.
    ///
    /// Deliberately NO `enabled` conjunct: a disabled market's existing positions must stay
    /// liquidatable (and write-off-able), or disableMarket would freeze risk exactly when it is
    /// being managed — with dust surviving, un-write-off-able until a 2-day re-commit (C-M2/B-L1).
    /// A never-committed market declines FIRST, on `configured`, so the answer never depends on what
    /// an unlisted address happens to return. _desyncGuard is revert-proof since CRIT-1, so the order
    /// is now clarity rather than the load-bearing guard it used to be.
    function canLiquidate(address token) external view returns (bool) {
        if (!_feeds[token].configured) return false;
        if (!liveness.liquidationsAllowed()) return false;
        // NOT an `enabled` conjunct: see above. A permanent freeze must stay impossible; this expires.
        if (block.timestamp < liquidationPausedUntil[token]) return false;
        // Same corporate-action desync guard as canBorrow — SYMMETRY IS THE POINT: during the ~2x
        // mis-valuation window `collateralValue` reads ~half, which would flip healthy positions to
        // "underwater" and let a liquidator seize (near-)full collateral for half the debt. Declining to
        // liquidate on an unverifiable price (the ~1h window is inside the 20pp gap) beats wrongful seizure.
        if (_desyncGuard(token)) return false;
        return _liquidationPriceGate(token);
    }

    /// Liquidation's price gate is FRESHNESS, not session: the old inSession gate made every weekday
    /// night a liquidation outage against a price still inside its staleness bound. Success of the
    /// price read IS the freshness proof (priceOf reverts PriceStale past `maxStaleness`, which
    /// _setFeed caps at heartbeat+grace); any revert — stale, silent, sequencer — declines.
    function _liquidationPriceGate(address token) internal view returns (bool) {
        try this.collateralValue(token, 1e18) returns (uint256, bool) {
            return true;
        } catch {
            return false;
        }
    }

    // ---------------------------------------------------------------- admin (timelocked)

    function proposeMarket(
        address token,
        AggregatorV3Interface feed,
        uint32 heartbeat,
        uint32 maxStaleness,
        uint8 feedDecimals,
        address multiplierSource_,
        address pool_,
        Market memory m
    ) external {
        if (msg.sender != admin) revert NotAdmin();
        _validate(m);
        _assertRealDecimals(token, m.collateralDecimals, feed, feedDecimals);
        _assertMultiplierSource(token, multiplierSource_);
        _assertActivePool(token, pool_);
        _pending[token] = PendingMarket(
            m, feed, heartbeat, maxStaleness, feedDecimals, multiplierSource_, pool_, block.timestamp + PARAM_TIMELOCK
        );
        emit MarketProposed(
            token, m, feed, heartbeat, maxStaleness, feedDecimals, multiplierSource_, pool_,
            block.timestamp + PARAM_TIMELOCK
        );
    }

    /// PERMISSIONLESS (WS2 #2): a ripe proposal is executable by anyone. No executor privilege
    /// exists — every check below re-runs at execution, so a stranger can only enact what the
    /// admin proposed, exactly as proposed, after the full timelock.
    function commitMarket(address token) external {
        PendingMarket memory p = _pending[token];
        if (p.effectiveAt == 0) revert NoPendingChange(token);
        if (block.timestamp < p.effectiveAt) revert TimelockNotElapsed(p.effectiveAt - block.timestamp);
        // Re-validation is defense-in-depth only: _validate is pure over compile-time constants
        // in a non-upgradeable contract, so it cannot fail here where the proposal succeeded.
        _validate(p.m);
        // WS3 stage-order guard: a dust threshold (below MIN_RISK_GAP_BPS) force-liquidates every
        // open position, so it may only follow a timelocked stage 1 (installed ltvBps == 0) —
        // skipping straight to stage 2 is impossible by construction. Gated on `configured`, the
        // durable ever-committed marker: empty storage also reads ltvBps == 0, and without the
        // marker a FRESH listing at dust threshold would slip through in a single commit.
        if (p.m.liqThresholdBps < MIN_RISK_GAP_BPS) {
            if (!_feeds[token].configured || _markets[token].ltvBps != 0) revert DeprecationOrderViolated(token);
        }
        // Re-cross-check decimals at commit too: the token's decimals() can't change, but this keeps the
        // guarantee at the authoritative install point, symmetric with the re-validation above.
        _assertRealDecimals(token, p.m.collateralDecimals, p.feed, p.feedDecimals);
        // Feed is APPEND-ONLY per market: once a feed is configured for a token, a later commit cannot SWAP
        // it. An admin swapping a live market's feed to an attacker-controlled one — even behind the 2-day
        // timelock — could force-liquidate healthy borrowers or enable pool-draining over-borrow. Risk-param
        // updates stay allowed; a genuine feed migration onboards a new token entry. (StockConverter is
        // append-only for feeds for the same reason.)
        FeedConfig memory existing = _feeds[token];
        if (existing.configured && address(existing.feed) != address(p.feed)) revert FeedIsImmutable(token);
        // The multiplier source is append-only for the feed's exact reason: swapping a live market's
        // source — even behind the timelock — could force-liquidate healthy borrowers (fake low
        // multiplier) or enable a pool-draining over-borrow (fake high one).
        if (existing.configured && multiplierSource[token] != p.multiplierSource) {
            revert MultiplierSourceIsImmutable(token);
        }
        // The freshness pair latches with them (round-6 A/B): loosening re-widens the stale-
        // liquidation window the per-feed heartbeat closed; tightening below the feed's real
        // cadence turns PriceStale into a liquidation freeze that also blocks writeOff while
        // debt accrues. The feed is immutable; the clock it is judged by must be too.
        if (existing.configured && (existing.heartbeat != p.heartbeat || existing.maxStaleness != p.maxStaleness)) {
            revert FreshnessIsImmutable(token);
        }
        // Re-assert the source answers NOW, not just at propose — a wrong wiring must fail loudly at
        // commit, never at the first borrow. Same for the pool binding: commit is where activePool
        // flips, so commit is where the binding must hold.
        uint256 liveMult = _assertMultiplierSource(token, p.multiplierSource);
        _assertActivePool(token, p.pool);
        _setFeed(token, p.feed, p.heartbeat, p.maxStaleness, p.feedDecimals);
        _markets[token] = p.m;
        multiplierSource[token] = p.multiplierSource;
        activePool[token] = p.pool;
        // Seed the observed-multiplier baseline (once) so the first post-commit corporate action registers
        // as a MOVE via syncMultiplier, not as uninitialised state.
        if (seenMultiplier[token] == 0) seenMultiplier[token] = liveMult;
        delete _pending[token];
        emit MarketCommitted(token, p.m.ltvBps, p.m.liqThresholdBps);
    }

    function proposeResolver(address resolver_) external {
        if (msg.sender != admin) revert NotAdmin();
        pendingResolver = resolver_;
        pendingResolverEffectiveAt = block.timestamp + PARAM_TIMELOCK;
        emit ResolverProposed(resolver_, pendingResolverEffectiveAt);
    }

    /// PERMISSIONLESS, same reasoning as commitMarket: only the timelocked payload can be enacted.
    function commitResolver() external {
        uint256 at = pendingResolverEffectiveAt;
        if (at == 0) revert NoPendingChange(address(0));
        if (block.timestamp < at) revert TimelockNotElapsed(at - block.timestamp);
        resolver = pendingResolver;
        delete pendingResolver;
        delete pendingResolverEffectiveAt;
        emit ResolverCommitted(resolver);
    }

    /// Disabling is IMMEDIATE and needs no timelock. Turning a market off is always safe —
    /// it stops NEW borrows and nothing else: repay, addCollateral, liquidation, and write-off
    /// all continue (the valuation path keys on `configured`, not `enabled`).
    ///
    /// The pending proposal is cleared too: every committable proposal carries enabled=true, so
    /// a ripe one left in place would let the next commitMarket silently reverse an emergency
    /// disable with no fresh notice. Re-enabling always pays the full timelock.
    ///
    /// R4 MED-3: GUARDIAN ONLY. `admin` held this too, which made `_roleKey`'s "no role may be the
    /// deploy key" rule narrower than it reads — the deploy key already had the emergency key's
    /// powers, and `admin` is immutable with no setter, so that could never be rotated out of.
    /// Admin keeps the timelocked route to the same outcome (propose ltvBps 0, commit after 2 days).
    function disableMarket(address token) external {
        if (msg.sender != guardian) revert NotAdmin();
        _markets[token].enabled = false;
        delete _pending[token];
        emit MarketDisabled(token);
    }

    /// The lever a known corporate action needs and the protocol did not have. _syncPrice covers the
    /// un-manned case; this covers the one a human sees coming, since an ex-date is public months
    /// ahead and an issuer later than PRICE_DESYNC_HOLD is outside what any automatic rule can infer.
    ///
    /// Immediate and un-timelocked for disableMarket's reason — it only STOPS something. Capped per
    /// call so a forgotten pause expires; `until` in the past stands it down without waiting.
    ///
    /// R3 MED-3: the per-call cap alone was not a cap. The storage is an absolute deadline that each
    /// call overwrites, so calling it daily held liquidation off indefinitely while interest
    /// compounded — the permanent freeze the missing `enabled` conjunct on canLiquidate exists to
    /// make impossible. The cooldown is the actual bound: a new pause may not start until the last
    /// one has been over for as long as it lasted, so liquidation is open at least half of any span
    /// and always for a contiguous window at least as long as the pause before it.
    ///
    /// R4 MED-3: GUARDIAN ONLY, for disableMarket's reason. The doc block at `guardian` called this
    /// the guardian's hot emergency key while `admin` silently held it as well.
    function pauseLiquidation(address token, uint256 until) external {
        if (msg.sender != guardian) revert NotAdmin();
        uint256 ceiling = block.timestamp + MAX_LIQUIDATION_PAUSE;
        if (until > ceiling) revert PauseTooLong(until, ceiling);
        // Standing a pause DOWN only ever reopens liquidation, so it is never rate-limited.
        if (until > block.timestamp) {
            if (block.timestamp < pauseCooldownUntil[token]) revert PauseOnCooldown(token);
            pauseCooldownUntil[token] = until + (until - block.timestamp);
        }
        liquidationPausedUntil[token] = until;
        emit LiquidationPaused(token, until);
    }

    /// The non-emergency sibling of disableMarket: immediate because it only REMOVES a pending
    /// change — the installed market is untouched. Admin-only; the guardian's emergency path
    /// (disableMarket) already clears _pending as a side effect.
    function cancelMarketProposal(address token) external {
        if (msg.sender != admin) revert NotAdmin();
        if (_pending[token].effectiveAt == 0) revert NoPendingChange(token);
        delete _pending[token];
        emit MarketProposalCancelled(token);
    }

    function _validate(Market memory m) internal pure {
        if (!m.enabled) revert InvalidRiskParams("market must be enabled");
        if (m.liqThresholdBps > MAX_LIQ_THRESHOLD_BPS) revert InvalidRiskParams("threshold too high");
        // Deprecation mode (WS3): ltvBps == 0 means no new borrows can ever open, so the gap that
        // protects OPEN borrowers from unliquidatable moves has no one left to protect — stage 2
        // (dust threshold) must be expressible. Every other bound below still binds.
        if (m.ltvBps != 0) {
            if (m.ltvBps >= m.liqThresholdBps) revert InvalidRiskParams("ltv must be below threshold");
            if (m.liqThresholdBps - m.ltvBps < MIN_RISK_GAP_BPS) revert InvalidRiskParams("risk gap too narrow");
        }
        if (m.liqBonusBps > MAX_LIQ_BONUS_BPS) revert InvalidRiskParams("bonus too high");
        if (m.cap == 0) revert InvalidRiskParams("cap must be set");
        if (m.maxPositionBps == 0 || m.maxPositionBps > 10_000) revert InvalidRiskParams("bad position cap");
        if (m.collateralDecimals == 0 || m.collateralDecimals > 36) revert InvalidRiskParams("bad collateral decimals");
    }

    /// Cross-check the operator-typed decimals against the token's / feed's real decimals() on-chain.
    /// collateralValue normalises with `collateralDecimals` and `feedDecimals`; if either disagrees with
    /// the source of truth, a one-character typo silently reproduces the original 1e12 mispricing (the
    /// drain the decimals fix was meant to close). Making them impossible to commit unless they match
    /// removes the operator-trust surface entirely — impossible-by-construction, not deploy-discipline.
    function _assertRealDecimals(
        address token,
        uint8 collateralDecimals,
        AggregatorV3Interface feed,
        uint8 feedDecimals
    ) internal view {
        if (collateralDecimals != IERC20Metadata(token).decimals()) revert InvalidRiskParams("collateral decimals mismatch");
        if (feedDecimals != feed.decimals()) revert InvalidRiskParams("feed decimals mismatch");
    }

    /// A DIRECT call, no try: a source lacking uiMultiplier() must revert here — at propose/commit,
    /// where the operator is watching — not brick valuation at the first borrow. A zero answer is
    /// equally unusable (it would value all collateral at nothing and mark everyone liquidatable).
    function _assertMultiplierSource(address token, address source) internal view returns (uint256 live) {
        if (source == address(0)) revert BadMultiplierSource(token, source);
        live = IScaledUI(source).uiMultiplier();
        if (live == 0) revert BadMultiplierSource(token, source);
    }

    /// Direct calls, no try — a mis-wired pool must fail loudly here, where the operator is
    /// watching, never as a NotActivePool brick at the first borrow (the _assertMultiplierSource
    /// precedent). The markets() check is the cross-registry squat guard: a pool bound to someone
    /// else's registry can never become this one's active pool.
    function _assertActivePool(address token, address pool) internal view {
        if (
            pool == address(0) || IPoolBinding(pool).collateralToken() != token
                || IPoolBinding(pool).markets() != address(this)
        ) revert BadActivePool(token, pool);
    }

    /// BORROW-side read: maxBorrow only. Liquidation-side paths use _configuredMarket instead.
    function _requireEnabled(address token) internal view returns (Market memory m) {
        m = _markets[token];
        if (!m.enabled) revert MarketNotEnabled(token);
    }

    /// LIQUIDATION-side read: requires the market was ever committed, not that it is enabled.
    /// `_feeds[token].configured` is the durable commit marker — feeds are append-only
    /// (commitMarket), so it can never be un-set the way `enabled` can.
    function _configuredMarket(address token) internal view returns (Market memory m) {
        if (!_feeds[token].configured) revert MarketNotEnabled(token);
        m = _markets[token];
    }

    function market(address token) external view returns (Market memory) {
        return _markets[token];
    }

    function pendingMarket(address token) external view returns (PendingMarket memory) {
        return _pending[token];
    }
}
