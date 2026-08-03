// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Seat} from "./Seat.sol";
import {ISeatHook} from "./ISeatHook.sol";
import {IConverter} from "./IConverter.sol";

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
    Seat public immutable seat;
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
    /// Per-Seat payout choice: address(0) = the base reward asset; otherwise a converter-supported
    /// stock. Owner-set, cleared on transfer (per-owner, like the Tier). Accounting never sees this —
    /// preferences only matter at the claim edge.
    mapping(uint256 => address) public payoutTokenOf;
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
    event PayoutTokenSet(uint256 indexed id, address token);
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

    constructor(
        Seat seat_,
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

    /// Choose the asset this Seat's claims are delivered in: address(0) for the base reward asset, or
    /// any converter-supported stock. Owner-only (it changes what lands in the Vault they own); the
    /// preference is per-owner and clears on transfer, like the Tier.
    function setPayoutToken(uint256 id, address token) external {
        if (seat.ownerOf(id) != msg.sender) revert NotSeatOwner();
        if (token != address(0)) {
            if (address(converter) == address(0) || !converter.isSupported(token)) revert UnsupportedPayoutToken();
        }
        payoutTokenOf[id] = token;
        emit PayoutTokenSet(id, token);
    }

    /// Seat transfer hook: the Tier and payout preference are per-owner, so both clear on every true
    /// ownership transfer. The Seat's already-credited rewards are checkpointed and stay claimable —
    /// they belong to the Seat (they land in its Vault), not the departing owner.
    function onSeatTransfer(uint256 id, address from, address to) external {
        if (msg.sender != address(seat)) revert NotSeatContract();
        delete payoutTokenOf[id];
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

        // Hybrid payout: an explicit choice wins; an unset Seat falls to `defaultPayout` (the bundle),
        // so "pay me in stock" is the default without every holder having to opt in. Either way the
        // convert path below fails open to the base asset if it can't settle.
        address pref = payoutTokenOf[id];
        if (pref == address(0)) pref = defaultPayout;
        if (pref != address(0) && address(converter) != address(0)) {
            reward.forceApprove(address(converter), amount);
            try converter.convert(amount, pref, vault) returns (uint256 out) {
                // Reset the allowance on BOTH paths. The honest converter pulls exactly `amount`
                // (allowance already 0), but resetting unconditionally means even a converter that
                // returns success while under-pulling cannot leave a standing allowance over the
                // Bell's balance — the reset is symmetric with the catch path by design.
                reward.forceApprove(address(converter), 0);
                emit ClaimConverted(id, pref, out);
                emit Claimed(id, amount, vault);
                return amount;
            } catch {
                reward.forceApprove(address(converter), 0);
                emit ClaimFellBack(id, pref);
            }
        }
        reward.safeTransfer(vault, amount);
        emit Claimed(id, amount, vault);
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
