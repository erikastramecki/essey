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
    /// Hot emergency key, safe-direction only: disableMarket and nothing else, so its compromise
    /// cost is stopping new borrows — never funds, never liquidation.
    ///
    /// G-LEND MED-3: that claim used to be extended to "the LivenessOracle.keeper trust shape" and it
    /// was FALSE. The health keeper does share it (effectiveCap is read only at canBorrow and
    /// EsseyPool._gateNewDebt — zero liquidation authority). The LIVENESS keeper does not: it need not
    /// be compromised at all, only SILENT, and liquidations then close protocol-wide while interest
    /// compounds. Inherent to a fail-closed gate, and bounded only OPERATIONALLY: two independent
    /// keepers, and page on lastHeartbeat ageing past gapThreshold / 2.
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
        Market memory mk = _configuredMarket(token);
        uint256 price;
        uint8 feedDec;
        (price, feedDec, inSession) = priceOf(token);
        // balanceOf is raw and stable; the share-equivalent moves on splits. Pricing the raw
        // amount is correct until the first corporate action and catastrophically wrong after.
        uint256 uiAmount = (rawAmount * IScaledUI(multiplierSource[token]).uiMultiplier()) / 1e18;
        value = (uiAmount * price * (10 ** assetDecimals)) / (10 ** mk.collateralDecimals * 10 ** feedDec);
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

    /// The last uiMultiplier this registry observed for a token, and when it last MOVED. `syncMultiplier`
    /// (called on the borrow AND liquidate paths) records a move the instant a corporate action applies —
    /// this is what covers the POST-flip desync window robustly, without depending on whether the token
    /// keeps its scheduled `newUIMultiplier` populated after the flip.
    mapping(address => uint256) public seenMultiplier;
    mapping(address => uint256) public multiplierMovedAt;

    /// True while a scheduled or just-applied uiMultiplier change makes the token's multiplier and its
    /// Chainlink feed inconsistent — the ~2x mis-valuation window. Both canBorrow AND canLiquidate refuse to
    /// act while this holds (declining on an unverifiable price beats a mispriced borrow OR a wrongful
    /// seizure; the ~1h gap is absorbed by the 20pp MIN_RISK_GAP_BPS buffer).
    function _desyncGuard(address token) internal view returns (bool) {
        // (a) scheduled action within the window (pre-flip / at-flip while newUIMultiplier still reports it)
        uint256 effectiveAt = _scheduledEffectiveAt(multiplierSource[token]);
        if (effectiveAt != 0) {
            uint256 d = block.timestamp > effectiveAt ? block.timestamp - effectiveAt : effectiveAt - block.timestamp;
            if (d <= MULTIPLIER_GUARD_WINDOW) return true;
        }
        // (b) the live multiplier MOVED within the window (post-flip, observed via syncMultiplier)
        uint256 movedAt = multiplierMovedAt[token];
        return movedAt != 0 && block.timestamp - movedAt < MULTIPLIER_GUARD_WINDOW;
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
    function _scheduledEffectiveAt(address source) internal view returns (uint256) {
        (bool ok, bytes memory ret) = source.staticcall{gas: 50_000}(abi.encodeWithSignature("newUIMultiplier()"));
        if (!ok || ret.length != 64) return 0;
        (, uint256 effectiveAt) = abi.decode(ret, (uint256, uint256));
        return effectiveAt;
    }

    /// Same defensive decode as _scheduledEffectiveAt, for the same reason: syncMultiplier sits at the
    /// top of borrow, borrowMore, removeCollateral, liquidate and writeOff with no outer try, so a
    /// short or absent return here would brick all five. 0 means "could not read" and syncMultiplier
    /// records nothing.
    function _liveMultiplier(address source) internal view returns (uint256) {
        (bool ok, bytes memory ret) = source.staticcall{gas: 50_000}(abi.encodeWithSignature("uiMultiplier()"));
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
        seenMultiplier[token] = cur;
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
    function disableMarket(address token) external {
        if (msg.sender != admin && msg.sender != guardian) revert NotAdmin();
        _markets[token].enabled = false;
        delete _pending[token];
        emit MarketDisabled(token);
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
