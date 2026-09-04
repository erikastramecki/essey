// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// EsseyMarkets binds this oracle immutably in its constructor, so the reverse edge is wired
/// post-deploy (wireMarkets). STATIC cap only: markets.borrowCap consults this oracle back —
/// calling it from _ramped would recurse.
interface IStaticMarketCap {
    function marketCap(address token) external view returns (uint256);
}

/// Depth-derived per-market borrow cap (AD-2). A keeper posts measured sellable depth; the cap
/// the pool sees is a fraction of it, moved through an asymmetric ratchet: down instantly, up
/// only after a delay and a slew limit. Staleness is judged IN THE VIEW (the LivenessOracle
/// inversion): a keeper that stops posting means the cap is already 0 when anyone looks —
/// never last-known-good, and a fresh deployment starts at 0.
///
/// This contract has ZERO liquidation-side authority by design: a spoofed-low or silent reading
/// can only stop NEW borrows, never trigger a seizure. Do not wire any liquidation path to it.
contract MarketHealthOracle {
    error NotKeeper();
    error NotGuardian();
    error NotAdmin();
    error ZeroAddress();
    error NoPendingChange();
    error AlreadyWired();
    error TimelockNotElapsed(uint256 secondsRemaining);
    error InvalidParams(string reason);

    event DepthPosted(
        address indexed token, uint128 depth, uint64 sampleBlock, bytes32 methodology, uint256 capTarget
    );
    event CapLowered(address indexed token, uint256 from, uint256 to);
    event RampReset(address indexed token, uint256 readingAge);
    event RaiseArmed(address indexed token, uint256 from, uint256 to, uint256 effectiveAt);
    event RaiseCancelled(address indexed token, uint256 pendingTo, uint256 byTarget);
    event KeeperChanged(address indexed keeper);
    event MarketsWired(address indexed markets);
    event ParamsProposed(Params p, uint256 effectiveAt);
    event ParamsCommitted(Params p);
    event ParamsProposalCancelled();

    struct Reading {
        uint128 depth;
        uint64 postedAt;
        uint64 sampleBlock;
    }

    struct CapState {
        uint128 effective;
        uint128 pendingRaiseTo;
        /// When an armed raise matures and its slew ramp starts. 0 = no raise armed.
        uint64 pendingRaiseAt;
        /// Slew base, frozen at arm time — crystallizing posts must not re-base the rate to
        /// their own progress (that stretched the nominal 10-day from-zero ramp to ~25).
        /// 0 = armed while unwired/unlisted: derived in the view instead, which fails closed.
        uint128 rampBase;
    }

    struct Params {
        uint16 capFractionBps;
        uint16 hysteresisBps;
        uint16 maxRaisePerDayBps;
        uint256 raiseDelay;
    }

    uint256 public constant MAX_READING_AGE = 24 hours;
    uint256 public constant PARAM_TIMELOCK = 2 days;
    uint256 internal constant BPS = 10_000;

    /// Posts depth readings. Hot key: compromise can stop new borrows (silence, post-0) or try
    /// to inflate — which the delay, slew, cancel-on-lower-post, and the registry's min() against
    /// the timelocked Market.cap each independently blunt. It can never move funds or seize.
    address public keeper;
    address public immutable guardian; // cold; keeper rotation only (safe direction)
    address public immutable admin; // timelocked param changes only

    /// Ceiling for the from-zero ramp base. One-shot (wireMarkets); until wired the base is 0.
    IStaticMarketCap public markets;
    uint64 internal wiredAt;

    uint16 public capFractionBps;
    uint16 public hysteresisBps;
    uint16 public maxRaisePerDayBps;
    uint256 public raiseDelay;

    Params public pendingParams;
    uint256 public pendingParamsEffectiveAt;

    mapping(address => Reading) public readings;
    mapping(address => CapState) internal _caps;

    constructor(address keeper_, address guardian_, address admin_) {
        if (keeper_ == address(0) || guardian_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        guardian = guardian_;
        admin = admin_;
        capFractionBps = 3_333;
        hysteresisBps = 1_000;
        maxRaisePerDayBps = 1_000;
        raiseDelay = 2 days;
    }

    /// One-shot: the registry bounds the from-zero ramp, so a swappable registry would hand the
    /// admin a slew bypass. The deploy script wires it in the same broadcast that creates the
    /// registry; ramping starts no earlier than the wire, so late wiring earns no retroactive gain.
    function wireMarkets(address markets_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (markets_ == address(0)) revert ZeroAddress();
        if (address(markets) != address(0)) revert AlreadyWired();
        markets = IStaticMarketCap(markets_);
        wiredAt = uint64(block.timestamp);
        emit MarketsWired(markets_);
    }

    /// The cap this token has earned, or 0 if the reading is stale or was never posted.
    /// Unclamped oracle opinion — may exceed Market.cap; the registry's borrowCap min() is
    /// the enforcement (accepted, two audit rounds).
    function effectiveCap(address token) external view returns (uint256) {
        Reading memory r = readings[token];
        if (r.postedAt == 0) return 0;
        if (block.timestamp - r.postedAt > MAX_READING_AGE) return 0;
        return _ramped(token, _caps[token], block.timestamp);
    }

    function capState(address token) external view returns (CapState memory) {
        return _caps[token];
    }

    /// A matured raise does not step: it RAMPS from `effective` toward `pendingRaiseTo` at
    /// maxRaisePerDayBps per day of the arm-time `rampBase`. From effective == 0 the base is
    /// the target — CLAMPED to the registry's static cap (MED finding: unclamped, an absurd
    /// posted target swept 0 -> Market.cap in hours instead of BPS/maxRaisePerDayBps days).
    /// rampBase == 0 means the arm predates wireMarkets: fail-closed here, and a later wire
    /// starts the clamped ramp with no retroactive credit.
    function _ramped(address token, CapState memory c, uint256 t) internal view returns (uint256) {
        if (c.pendingRaiseAt == 0 || t < c.pendingRaiseAt) return c.effective;
        uint256 base = c.rampBase;
        uint256 start = c.pendingRaiseAt;
        if (base == 0) {
            base = _clampedBase(token, c.pendingRaiseTo);
            if (start < wiredAt) start = wiredAt;
        }
        uint256 gain = (base * maxRaisePerDayBps * (t - start)) / (1 days * BPS);
        uint256 v = uint256(c.effective) + gain;
        return v > c.pendingRaiseTo ? c.pendingRaiseTo : v;
    }

    function _clampedBase(address token, uint256 target) internal view returns (uint256) {
        uint256 ceil = address(markets) == address(0) ? 0 : markets.marketCap(token);
        return target < ceil ? target : ceil;
    }

    function postDepth(address token, uint128 depthUsd, uint64 sampleBlock, bytes32 methodology) external {
        if (msg.sender != keeper) revert NotKeeper();
        uint64 prevPostedAt = readings[token].postedAt;
        readings[token] = Reading(depthUsd, uint64(block.timestamp), sampleBlock);
        uint256 target = (uint256(depthUsd) * capFractionBps) / BPS;
        emit DepthPosted(token, depthUsd, sampleBlock, methodology, target);

        CapState memory c = _caps[token];
        // Silence is never credit (MED finding): past MAX_READING_AGE the pool enforced 0, so a
        // resume restarts there — ramp state cleared, an armed raise re-arms through the full
        // delay. Without this the blackout kept accruing and one post crystallized all of it.
        if (prevPostedAt != 0 && block.timestamp - prevPostedAt > MAX_READING_AGE) {
            emit RampReset(token, block.timestamp - prevPostedAt);
            c = CapState(0, 0, 0, 0);
        }
        uint256 cur = _ramped(token, c, block.timestamp);
        // Crystallize the matured part of a ramp before comparing, so the anchor moves forward
        // and the slew keeps binding relative to what the cap has actually reached.
        if (c.pendingRaiseAt != 0 && block.timestamp >= c.pendingRaiseAt) {
            c.effective = uint128(cur);
            if (cur >= c.pendingRaiseTo) {
                (c.pendingRaiseTo, c.pendingRaiseAt, c.rampBase) = (0, 0, 0);
            } else {
                c.pendingRaiseAt = uint64(block.timestamp);
            }
        }
        // ANY lower post cancels an armed raise — no hysteresis here. Sustaining a raise requires
        // every intervening post to hold the line, which is what makes a spike unsustainable.
        if (c.pendingRaiseAt != 0 && target < c.pendingRaiseTo) {
            emit RaiseCancelled(token, c.pendingRaiseTo, target);
            (c.pendingRaiseTo, c.pendingRaiseAt, c.rampBase) = (0, 0, 0);
        }
        uint256 band = (cur * hysteresisBps) / BPS;
        if (target < cur && cur - target > band) {
            c.effective = uint128(target);
            emit CapLowered(token, cur, target);
        } else if (target > cur && target - cur > band && c.pendingRaiseAt == 0) {
            c.pendingRaiseTo = uint128(target);
            c.pendingRaiseAt = uint64(block.timestamp + raiseDelay);
            c.rampBase = uint128(cur == 0 ? _clampedBase(token, target) : cur);
            emit RaiseArmed(token, cur, target, c.pendingRaiseAt);
        }
        _caps[token] = c;
    }

    function setKeeper(address keeper_) external {
        if (msg.sender != guardian) revert NotGuardian();
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperChanged(keeper_);
    }

    // ---------------------------------------------------------------- params (timelocked)

    function proposeParams(Params calldata p) external {
        if (msg.sender != admin) revert NotAdmin();
        _validate(p);
        pendingParams = p;
        pendingParamsEffectiveAt = block.timestamp + PARAM_TIMELOCK;
        emit ParamsProposed(p, pendingParamsEffectiveAt);
    }

    function cancelParamsProposal() external {
        if (msg.sender != admin) revert NotAdmin();
        if (pendingParamsEffectiveAt == 0) revert NoPendingChange();
        delete pendingParams;
        delete pendingParamsEffectiveAt;
        emit ParamsProposalCancelled();
    }

    /// PERMISSIONLESS after the timelock, the commitMarket shape: only the proposed payload can
    /// be enacted. The re-validation is defense-in-depth only — the bounds are compile-time
    /// constants in a non-upgradeable contract, so they cannot have changed since the proposal.
    function commitParams() external {
        uint256 at = pendingParamsEffectiveAt;
        if (at == 0) revert NoPendingChange();
        if (block.timestamp < at) revert TimelockNotElapsed(at - block.timestamp);
        Params memory p = pendingParams;
        _validate(p);
        capFractionBps = p.capFractionBps;
        hysteresisBps = p.hysteresisBps;
        maxRaisePerDayBps = p.maxRaisePerDayBps;
        raiseDelay = p.raiseDelay;
        delete pendingParams;
        delete pendingParamsEffectiveAt;
        emit ParamsCommitted(p);
    }

    function _validate(Params memory p) internal pure {
        if (p.capFractionBps == 0 || p.capFractionBps > 5_000) revert InvalidParams("cap fraction");
        if (p.hysteresisBps > 5_000) revert InvalidParams("hysteresis");
        if (p.maxRaisePerDayBps == 0 || p.maxRaisePerDayBps > BPS) revert InvalidParams("raise slew");
        if (p.raiseDelay < 1 days || p.raiseDelay > 30 days) revert InvalidParams("raise delay");
    }
}
