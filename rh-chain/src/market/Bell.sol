// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISeatHook} from "./ISeatHook.sol";
import {IConverter} from "./IConverter.sol";

/// The membership NFT the Bell rewards — everything the Bell needs from it. BOTH `Seat` and `Don` satisfy this
/// (ERC721 `ownerOf` + a token-bound `vaultOf`), so one Bell serves either collection. Generalized from the
/// concrete `Seat` type so the Dons era reuses the audited reward engine unchanged (Dons replace Seats).
interface ISeatLike {
    function ownerOf(uint256 id) external view returns (address);
    function vaultOf(uint256 id) external view returns (address);
}

/// The Bell — Essey's fee → reward engine, the StonkBrokers "Clock In" mechanic rebuilt on a strictly
/// better distribution pattern.
///
/// Fees (in the reward token) accrue in this contract as the pot. When the pot reaches `minRing`,
/// ANYONE can ring the Bell: the ringer earns a tip, and the rest of the pot is credited to active
/// Seats pro-rata by Tier weight. Distribution is the O(1) accumulator pattern (MasterChef/Synthetix):
/// ringing does ONE division — `accPerWeight += pot / totalWeight` — and each Seat later pulls
/// `weight × Δacc` into its Vault. No per-holder push loop (StonkBrokers pays gas per broker on every
/// drop), no off-chain Merkle computation, no trusted root-poster. Fully on-chain and O(1) both ways.
///
/// Tiers: a Seat's owner stakes $ESSEY to activate a Tier (weight multiplier). The fee is a SINK, not a
/// refundable stake — half burned, half to treasury — and the Tier clears on true ownership transfer
/// (per-owner, enforced via the Seat's transfer hook). Rewards, once credited, belong to the SEAT: they
/// are claimable by anyone, but only ever into the Seat's Vault, so they travel with the NFT.
contract Bell is ISeatHook, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- config
    ISeatLike public immutable seat;
    IERC20 public immutable essey; // Tier activation fees (burned/treasury)
    IERC20 public immutable reward; // the pot asset distributed at each ring
    address public immutable treasury;
    uint256 public immutable minRing; // pot threshold before the Bell can ring
    uint256 public immutable tipBps; // ringer's cut of the pot
    /// Optional claim-edge converter for payout choice (address(0) = base-asset payouts only).
    IConverter public immutable converter;
    /// Where a Seat with NO explicit payout choice is paid: address(0) = the base asset (USDG), or a
    /// converter-supported target (e.g. the BUNDLE sentinel) so unset Seats are paid in stock by
    /// default. Only meaningful when `converter` is set; still fails open to base if conversion can't
    /// settle (closed session, stale feed, thin reserve).
    address public immutable defaultPayout;

    uint256[] public tierFees; // cumulative $ESSEY fee to reach tier i+1 (strictly increasing)
    uint256[] public tierWeights; // payout weight of tier i+1 (strictly increasing)

    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_TIP_BPS = 1_000; // 10%

    // ---------------------------------------------------------------- state
    struct SeatState {
        uint8 tier; // 0 = inactive
        uint248 weight; // cached tierWeights[tier-1]
        uint256 rewardDebt; // weight * accPerWeight / PRECISION at last checkpoint
        uint256 pendingStored; // checkpointed, claimable rewards
    }

    mapping(uint256 => SeatState) public seats;
    /// Per-Don payout election (Clock-In 2.0): up to 3 converter-supported stocks with weights (bps summing
    /// to 10000). Empty = fall to `defaultPayout` (the BUNDLE), else the base asset. Owner-set, cleared on
    /// transfer (per-owner, like the Tier). Accounting never sees this — elections only matter at the claim edge.
    struct Election {
        address token;
        uint16 bps;
    }

    mapping(uint256 => Election[]) public payoutElections;
    uint256 public constant MAX_ELECTIONS = 3;
    uint256 public totalWeight;
    uint256 public accPerWeight;
    /// Rewards already credited to seats but not yet claimed — the part of our balance that is owed,
    /// not pot. pot() = balance − reserved, so fees can arrive by plain transfer.
    uint256 public reserved;

    event Activated(uint256 indexed id, uint8 tier, uint256 fee);
    event Upgraded(uint256 indexed id, uint8 fromTier, uint8 toTier, uint256 fee);
    event TierCleared(uint256 indexed id, address from, address to);
    event Rang(address indexed ringer, uint256 pot, uint256 tip, uint256 distributed);
    event Claimed(uint256 indexed id, uint256 amount, address vault);
    event PayoutSet(uint256 indexed id, uint256 count);
    event ClaimConverted(uint256 indexed id, address token, uint256 amountOut);
    event ClaimFellBack(uint256 indexed id, address token);

    error BadConfig();
    error NotSeatOwner();
    error NotSeatContract();
    error AlreadyActive();
    error NotAnUpgrade();
    error PotBelowMinimum();
    error NoActiveSeats();
    error CannotSweepReward();
    error UnsupportedPayoutToken();
    error TooManyElections();
    error BadElectionWeights();

    constructor(
        ISeatLike seat_,
        IERC20 essey_,
        IERC20 reward_,
        address treasury_,
        uint256 minRing_,
        uint256 tipBps_,
        uint256[] memory tierFees_,
        uint256[] memory tierWeights_,
        IConverter converter_,
        address defaultPayout_
    ) {
        if (
            address(seat_) == address(0) || address(essey_) == address(0) || address(reward_) == address(0)
                || treasury_ == address(0) || tipBps_ > MAX_TIP_BPS || tierFees_.length == 0
                || tierFees_.length != tierWeights_.length || tierFees_.length > type(uint8).max
                // A default payout must be a converter-supported target (e.g. the BUNDLE sentinel):
                // this catches a typo'd sentinel or an unseeded bundle at DEPLOY, instead of silently
                // paying base forever with no revert-time signal.
                || (defaultPayout_ != address(0)
                    && (address(converter_) == address(0) || !converter_.isSupported(defaultPayout_)))
        ) revert BadConfig();
        for (uint256 i = 1; i < tierFees_.length; i++) {
            // Strictly increasing, so an upgrade always owes a positive fee delta and higher tiers
            // always carry more weight.
            if (tierFees_[i] <= tierFees_[i - 1] || tierWeights_[i] <= tierWeights_[i - 1]) revert BadConfig();
        }
        seat = seat_;
        essey = essey_;
        reward = reward_;
        treasury = treasury_;
        minRing = minRing_;
        tipBps = tipBps_;
        tierFees = tierFees_;
        tierWeights = tierWeights_;
        converter = converter_;
        defaultPayout = defaultPayout_;
    }

    // ---------------------------------------------------------------- views

    /// Undistributed fees currently backing the next ring.
    function pot() public view returns (uint256) {
        return reward.balanceOf(address(this)) - reserved;
    }

    /// A Seat's total claimable rewards right now.
    function pendingOf(uint256 id) external view returns (uint256) {
        SeatState storage s = seats[id];
        return s.pendingStored + (uint256(s.weight) * accPerWeight) / PRECISION - s.rewardDebt;
    }

    function tierCount() external view returns (uint256) {
        return tierFees.length;
    }

    /// How many payout stocks a Don has elected (0 = falls back to defaultPayout / base).
    function electionCount(uint256 id) external view returns (uint256) {
        return payoutElections[id].length;
    }

    // ---------------------------------------------------------------- tiers

    /// Stake $ESSEY to put a Seat on the payout roll at `tier` (1-based). Owner-only: the fee is the
    /// owner's money. 50% burned (supply sink), 50% treasury. Clears when the Seat is transferred.
    function activate(uint256 id, uint8 tier) external nonReentrant {
        if (seat.ownerOf(id) != msg.sender) revert NotSeatOwner();
        SeatState storage s = seats[id];
        if (s.tier != 0) revert AlreadyActive();
        if (tier == 0 || tier > tierFees.length) revert BadConfig();

        uint256 fee = tierFees[tier - 1];
        _takeFee(fee);

        uint256 w = tierWeights[tier - 1];
        s.tier = tier;
        s.weight = uint248(w);
        s.rewardDebt = (w * accPerWeight) / PRECISION; // start accruing from now, not retroactively
        totalWeight += w;
        emit Activated(id, tier, fee);
    }

    /// Raise an active Seat's Tier, paying only the fee difference. Pending rewards are checkpointed
    /// first so the new weight applies strictly to future rings.
    function upgrade(uint256 id, uint8 newTier) external nonReentrant {
        if (seat.ownerOf(id) != msg.sender) revert NotSeatOwner();
        SeatState storage s = seats[id];
        uint8 cur = s.tier;
        if (cur == 0 || newTier <= cur || newTier > tierFees.length) revert NotAnUpgrade();

        uint256 fee = tierFees[newTier - 1] - tierFees[cur - 1];
        _takeFee(fee);

        _checkpoint(s);
        uint256 newW = tierWeights[newTier - 1];
        totalWeight = totalWeight - uint256(s.weight) + newW;
        s.tier = newTier;
        s.weight = uint248(newW);
        s.rewardDebt = (newW * accPerWeight) / PRECISION;
        emit Upgraded(id, cur, newTier, fee);
    }

    /// Elect up to 3 converter-supported stocks (with weights in bps summing to 10000) that this Don's claims
    /// are delivered in — "build your own dividend basket" (Clock-In 2.0). An empty election falls back to
    /// `defaultPayout` (the BUNDLE), else the base asset. Owner-only (it changes what lands in the Vault they
    /// own); per-owner, cleared on transfer, like the Tier. Each claim still fails open to base per slice.
    function setPayout(uint256 id, address[] memory tokens, uint16[] memory bps) public {
        if (seat.ownerOf(id) != msg.sender) revert NotSeatOwner();
        uint256 n = tokens.length;
        if (n != bps.length || n > MAX_ELECTIONS) revert TooManyElections();
        delete payoutElections[id];
        if (n == 0) {
            emit PayoutSet(id, 0); // cleared → defaultPayout / base
            return;
        }
        if (address(converter) == address(0)) revert UnsupportedPayoutToken();
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            if (!converter.isSupported(tokens[i])) revert UnsupportedPayoutToken();
            if (bps[i] == 0) revert BadElectionWeights();
            sum += bps[i];
            payoutElections[id].push(Election({token: tokens[i], bps: bps[i]}));
        }
        if (sum != BPS) revert BadElectionWeights();
        emit PayoutSet(id, n);
    }

    /// Convenience: elect a SINGLE stock at 100% (or clear the election with address(0)). Wraps `setPayout`,
    /// so the single-payout ergonomics are preserved while power users can elect up to 3.
    function setPayoutToken(uint256 id, address token) external {
        if (token == address(0)) {
            if (seat.ownerOf(id) != msg.sender) revert NotSeatOwner();
            delete payoutElections[id];
            emit PayoutSet(id, 0);
            return;
        }
        address[] memory toks = new address[](1);
        toks[0] = token;
        uint16[] memory bpsArr = new uint16[](1);
        bpsArr[0] = uint16(BPS);
        setPayout(id, toks, bpsArr);
    }

    /// Back-compat view: the Don's first elected stock, or address(0) if it has no election.
    function payoutTokenOf(uint256 id) external view returns (address) {
        return payoutElections[id].length == 0 ? address(0) : payoutElections[id][0].token;
    }

    /// Seat transfer hook: the Tier and payout preference are per-owner, so both clear on every true
    /// ownership transfer. The Seat's already-credited rewards are checkpointed and stay claimable —
    /// they belong to the Seat (they land in its Vault), not the departing owner.
    function onSeatTransfer(uint256 id, address from, address to) external {
        if (msg.sender != address(seat)) revert NotSeatContract();
        delete payoutElections[id];
        SeatState storage s = seats[id];
        if (s.tier == 0) return;
        _checkpoint(s);
        totalWeight -= uint256(s.weight);
        s.tier = 0;
        s.weight = 0;
        s.rewardDebt = 0;
        emit TierCleared(id, from, to);
    }

    // ---------------------------------------------------------------- ring & claim

    /// Ring the Bell: distribute the pot to active Seats, pro-rata by weight. Anyone may call once the
    /// pot has reached minRing; the caller earns tipBps of the pot for pulling the trigger. One
    /// division regardless of how many Seats are active.
    function ring() external nonReentrant {
        uint256 p = pot();
        if (p < minRing) revert PotBelowMinimum();
        if (totalWeight == 0) revert NoActiveSeats();

        uint256 tip = (p * tipBps) / BPS;
        uint256 distributed = p - tip;
        uint256 accDelta = (distributed * PRECISION) / totalWeight;
        // Credit exactly what the accumulator can pay out; sub-wei rounding dust stays in the next pot
        // instead of becoming unclaimable.
        uint256 credited = (accDelta * totalWeight) / PRECISION;
        accPerWeight += accDelta;
        reserved += credited;

        if (tip != 0) reward.safeTransfer(msg.sender, tip);
        emit Rang(msg.sender, p, tip, credited);
    }

    /// Pull a Seat's rewards into its Vault. Permissionless on purpose: the destination is fixed to the
    /// Seat's own Vault, so triggering a claim can only ever deliver the Seat its money.
    ///
    /// Payout choice, FAILS OPEN: if the owner set a stock preference, the amount is routed through the
    /// converter (which enforces oracle-fair output and delivers straight to the Vault). If conversion
    /// declines for ANY reason — closed session, stale feed, thin pool, broken router — the claim
    /// falls back to delivering the base asset. A payout can never be blocked by the swap leg.
    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        SeatState storage s = seats[id];
        _checkpoint(s);
        amount = s.pendingStored;
        if (amount == 0) return 0;
        s.pendingStored = 0;
        reserved -= amount;
        address vault = seat.vaultOf(id);

        // Payout election (Clock-In 2.0): split the claim across up to 3 elected stocks by weight; an empty
        // election falls to `defaultPayout` (the BUNDLE), so "pay me in stock" stays the default. Each slice
        // converts independently and fails open to the base asset if it can't settle — a payout can never be
        // blocked by the swap leg. The last slice takes the remainder, so slices always sum to `amount` exactly.
        Election[] storage els = payoutElections[id];
        uint256 n = els.length;
        if (n == 0) {
            _deliver(id, amount, defaultPayout, vault);
        } else {
            uint256 remaining = amount;
            for (uint256 i = 0; i < n; i++) {
                uint256 slice = (i == n - 1) ? remaining : (amount * els[i].bps) / BPS;
                remaining -= slice;
                if (slice != 0) _deliver(id, slice, els[i].token, vault);
            }
        }
        emit Claimed(id, amount, vault);
    }

    /// Deliver one slice of a claim: convert `amt` to `token` straight into the Vault, or fall open to the base
    /// reward asset if conversion can't settle (or there's no token/converter). Same per-slice safety the single
    /// payout had — the allowance is reset on BOTH the success and catch paths so a mis-behaving converter can
    /// never leave a standing allowance over the Bell's balance.
    function _deliver(uint256 id, uint256 amt, address token, address vault) internal {
        if (token != address(0) && address(converter) != address(0)) {
            reward.forceApprove(address(converter), amt);
            try converter.convert(amt, token, vault) returns (uint256 out) {
                reward.forceApprove(address(converter), 0);
                emit ClaimConverted(id, token, out);
                return;
            } catch {
                reward.forceApprove(address(converter), 0);
                emit ClaimFellBack(id, token);
            }
        }
        reward.safeTransfer(vault, amt);
    }

    /// Recover tokens mis-sent to the Bell — "rescue without trust". StonkBrokers solves this with an
    /// owner-only rescueToken that can also drain the pot; this cannot: the reward token itself can
    /// never be swept (the pot and reserved rewards are untouchable by construction), ETH cannot enter
    /// (no receive), the destination is the immutable treasury, and there is no privileged caller at
    /// all — anyone may trigger it.
    function sweep(IERC20 token) external nonReentrant {
        if (token == reward) revert CannotSweepReward();
        uint256 bal = token.balanceOf(address(this));
        if (bal != 0) token.safeTransfer(treasury, bal);
    }

    // ---------------------------------------------------------------- internals

    /// Move a seat's accrued-but-unstored rewards into pendingStored and reset its debt line. Must run
    /// before any weight change so past rings settle at the old weight.
    function _checkpoint(SeatState storage s) internal {
        uint256 w = uint256(s.weight);
        if (w != 0) {
            s.pendingStored += (w * accPerWeight) / PRECISION - s.rewardDebt;
            s.rewardDebt = (w * accPerWeight) / PRECISION;
        }
    }

    function _takeFee(uint256 fee) internal {
        uint256 half = fee / 2;
        essey.safeTransferFrom(msg.sender, BURN, half);
        essey.safeTransferFrom(msg.sender, treasury, fee - half);
    }
}
