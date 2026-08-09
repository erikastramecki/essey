// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StaleFeedGuard} from "./StaleFeedGuard.sol";
import {LivenessOracle} from "./LivenessOracle.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IScaledUI} from "./interfaces/IScaledUI.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// Risk registry: which Stock Tokens are accepted, on what terms, and when.
///
/// This is where the three Robinhood-specific hazards turn into numbers. Each is priced into the
/// parameters rather than assumed away:
///   - collateral is a Jersey DEBT token, not equity — Robinhood counterparty risk
///   - `adminBurn` can destroy it, held by a plain EOA with no multisig or timelock
///   - the price is blind nights and weekends (86400s heartbeat, 24/5 equity feeds)
///
/// THE GAP IS THE SAFETY MARGIN, NOT THE LTV. A position can only be liquidated once the market
/// reopens and the chain is demonstrably live, so the distance between `ltvBps` and
/// `liqThresholdBps` is what has to absorb an unliquidatable weekend gap or chain outage. That is
/// why `MIN_RISK_GAP_BPS` is enforced in code: a future parameter change cannot quietly narrow the
/// one thing protecting lenders.
contract EsseyMarkets is StaleFeedGuard {
    error NotAdmin();
    error MarketNotEnabled(address token);
    error InvalidRiskParams(string reason);
    error NoPendingChange(address token);
    error TimelockNotElapsed(uint256 secondsRemaining);
    error FeedIsImmutable(address token);

    event MarketProposed(address indexed token, uint16 ltvBps, uint16 liqThresholdBps, uint256 effectiveAt);
    event MarketCommitted(address indexed token, uint16 ltvBps, uint16 liqThresholdBps);
    event MarketDisabled(address indexed token);

    struct Market {
        bool enabled;
        uint16 ltvBps; // max borrow against collateral value
        uint16 liqThresholdBps; // liquidation trigger
        uint16 liqBonusBps; // liquidator's cut, above the debt
        /// The collateral token's own decimals. REQUIRED for normalisation — see collateralValue.
        uint8 collateralDecimals;
        uint128 cap; // per-collateral exposure cap, in borrow-asset units
    }

    struct PendingMarket {
        Market m;
        AggregatorV3Interface feed;
        uint32 maxStaleness;
        uint8 feedDecimals;
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
    LivenessOracle public immutable liveness;
    /// Decimals of the BORROW asset (USDG = 6 on Robinhood Chain). Everything this contract
    /// returns is denominated in these units so debt and collateral are directly comparable.
    uint8 public immutable assetDecimals;

    mapping(address => Market) internal _markets;
    mapping(address => PendingMarket) internal _pending;

    constructor(
        AggregatorV3Interface sequencerUptimeFeed_,
        LivenessOracle liveness_,
        address admin_,
        uint8 assetDecimals_
    ) StaleFeedGuard(sequencerUptimeFeed_) {
        liveness = liveness_;
        admin = admin_;
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
    function collateralValue(address token, uint256 rawAmount)
        public
        view
        returns (uint256 value, bool inSession)
    {
        Market memory mk = _markets[token];
        if (!mk.enabled) revert MarketNotEnabled(token);
        uint256 price;
        uint8 feedDec;
        (price, feedDec, inSession) = priceOf(token);
        // balanceOf is raw and stable; the share-equivalent moves on splits. Pricing the raw
        // amount is correct until the first corporate action and catastrophically wrong after.
        uint256 uiAmount = (rawAmount * IScaledUI(token).uiMultiplier()) / 1e18;
        value = (uiAmount * price * (10 ** assetDecimals)) / (10 ** mk.collateralDecimals * 10 ** feedDec);
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
        Market memory m = _requireEnabled(token);
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
        // Mainnet-config: gate NEW borrows on chain liveness too (not just liquidation). Under the
        // disabled-sequencer config the price path has no on-chain sequencer gate, so without this a
        // sequencer restart could admit a borrow on a stale pre-outage price. During the post-outage
        // resume grace, declining new borrows is the safe, conservative response.
        if (!liveness.liquidationsAllowed()) return false;
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
        try IScaledUI(token).newUIMultiplier() returns (uint256, uint256 effectiveAt) {
            if (effectiveAt != 0) {
                uint256 d = block.timestamp > effectiveAt ? block.timestamp - effectiveAt : effectiveAt - block.timestamp;
                if (d <= MULTIPLIER_GUARD_WINDOW) return true;
            }
        } catch {}
        // (b) the live multiplier MOVED within the window (post-flip, observed via syncMultiplier)
        uint256 movedAt = multiplierMovedAt[token];
        return movedAt != 0 && block.timestamp - movedAt < MULTIPLIER_GUARD_WINDOW;
    }

    function _liveMultiplier(address token) internal view returns (uint256) {
        try IScaledUI(token).uiMultiplier() returns (uint256 m) {
            return m;
        } catch {
            return 0;
        }
    }

    /// Observe the token's live uiMultiplier and stamp the moment it moves. Permissionless + non-view; the
    /// pool calls it on the borrow/liquidate paths (a keeper may also call it) so `_desyncGuard` sees a
    /// corporate action the instant it applies — the FIRST action that touches the pool records the move and
    /// is itself gated by the window.
    function syncMultiplier(address token) public {
        uint256 cur = _liveMultiplier(token);
        if (cur == 0) return; // token without the view / transient read failure — nothing to record
        uint256 prev = seenMultiplier[token];
        if (prev != 0 && cur != prev) multiplierMovedAt[token] = block.timestamp;
        seenMultiplier[token] = cur;
    }

    /// Liquidation additionally requires demonstrated chain liveness — see LivenessOracle. A
    /// borrower must not be liquidated in the first block after an outage they could not react to.
    function canLiquidate(address token) external view returns (bool) {
        Market memory m = _markets[token];
        if (!m.enabled) return false;
        if (!liveness.liquidationsAllowed()) return false;
        // Same corporate-action desync guard as canBorrow — SYMMETRY IS THE POINT: during the ~2x
        // mis-valuation window `collateralValue` reads ~half, which would flip healthy positions to
        // "underwater" and let a liquidator seize (near-)full collateral for half the debt. Declining to
        // liquidate on an unverifiable price (the ~1h window is inside the 20pp gap) beats wrongful seizure.
        if (_desyncGuard(token)) return false;
        try this.collateralValue(token, 1e18) returns (uint256, bool inSession) {
            return inSession;
        } catch {
            return false;
        }
    }

    // ---------------------------------------------------------------- admin (timelocked)

    function proposeMarket(
        address token,
        AggregatorV3Interface feed,
        uint32 maxStaleness,
        uint8 feedDecimals,
        Market memory m
    ) external {
        if (msg.sender != admin) revert NotAdmin();
        _validate(m);
        _assertRealDecimals(token, m.collateralDecimals, feed, feedDecimals);
        _pending[token] =
            PendingMarket(m, feed, maxStaleness, feedDecimals, block.timestamp + PARAM_TIMELOCK);
        emit MarketProposed(token, m.ltvBps, m.liqThresholdBps, block.timestamp + PARAM_TIMELOCK);
    }

    function commitMarket(address token) external {
        if (msg.sender != admin) revert NotAdmin();
        PendingMarket memory p = _pending[token];
        if (p.effectiveAt == 0) revert NoPendingChange(token);
        if (block.timestamp < p.effectiveAt) revert TimelockNotElapsed(p.effectiveAt - block.timestamp);
        // Re-validate at commit: the rules may have tightened since the proposal was made, and a
        // stale proposal must not be able to install parameters that would be rejected today.
        _validate(p.m);
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
        _setFeed(token, p.feed, p.maxStaleness, p.feedDecimals);
        _markets[token] = p.m;
        // Seed the observed-multiplier baseline (once) so the first post-commit corporate action registers
        // as a MOVE via syncMultiplier, not as uninitialised state.
        if (seenMultiplier[token] == 0) seenMultiplier[token] = _liveMultiplier(token);
        delete _pending[token];
        emit MarketCommitted(token, p.m.ltvBps, p.m.liqThresholdBps);
    }

    /// Disabling is IMMEDIATE and needs no timelock. Turning a market off is always safe —
    /// it stops new borrows; it does not seize anything and does not block repayment.
    function disableMarket(address token) external {
        if (msg.sender != admin) revert NotAdmin();
        _markets[token].enabled = false;
        emit MarketDisabled(token);
    }

    function _validate(Market memory m) internal pure {
        if (!m.enabled) revert InvalidRiskParams("market must be enabled");
        if (m.liqThresholdBps > MAX_LIQ_THRESHOLD_BPS) revert InvalidRiskParams("threshold too high");
        if (m.ltvBps >= m.liqThresholdBps) revert InvalidRiskParams("ltv must be below threshold");
        if (m.liqThresholdBps - m.ltvBps < MIN_RISK_GAP_BPS) revert InvalidRiskParams("risk gap too narrow");
        if (m.liqBonusBps > MAX_LIQ_BONUS_BPS) revert InvalidRiskParams("bonus too high");
        if (m.cap == 0) revert InvalidRiskParams("cap must be set");
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

    /// Deliberately redundant with the enabled-check inside `collateralValue`: it fails fast with
    /// the right error before any oracle work. A mutation sweep flags it as deletable for exactly
    /// that reason — the redundancy is intentional, not an untested guard.
    function _requireEnabled(address token) internal view returns (Market memory m) {
        m = _markets[token];
        if (!m.enabled) revert MarketNotEnabled(token);
    }

    function market(address token) external view returns (Market memory) {
        return _markets[token];
    }

    function pendingMarket(address token) external view returns (PendingMarket memory) {
        return _pending[token];
    }
}
