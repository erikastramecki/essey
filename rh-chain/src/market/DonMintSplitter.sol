// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// DonMintSplitter — the two-leg native-ETH sink that Don mint/reroll/custom fees flow into.
///
/// The founder ruled the mint-fee split (2026-08-13, batch 1): **50% stock-seed / 50% treasury**.
/// NO Bell leg, NO floor leg (supersedes the earlier 50/20/10/20 proposal). This contract is the
/// concrete home of that ruling: DonDistributor.setFeeSink(thisSplitter) re-points 100% of the mint
/// ETH here (leaving DonDistributor.teamBps = 0 — all splitting lives in this auditable immutable
/// contract, not in the distributor), and flush() fans the accumulated ETH out by the immutable bps.
///
///   • leg A — STOCK-SEED. Funds the payout-asset inventory that seeds real-asset-season missions
///     (the AssetPaymaster budget lines, T−1→T solvency law). Until the AssetPaymaster ships, this
///     leg points at an interim treasury-controlled stock-seed reserve address (see the design doc's
///     open decision #1). Rounding dust folds into THIS leg — the payout bootstrap self-funds faster.
///   • leg B — TREASURY. Ops/runway — the protocol's money.
///
/// It mirrors the shipped FeeRouter's doctrine, in native ETH instead of an ERC-20:
///   - ADMINLESS OVER FUNDS. No owner, no setter, no upgrade, no rescue. The only thing this contract
///     can ever do with ETH is split it in the ratio it was born with, to the two addresses it was
///     born with. There is nothing to trust between a received fee and its split.
///   - IMMUTABLE DESTINATIONS + SHARES, pinned at deploy. `stockSeedBps` is the constructor knob
///     (5_000 for the ruled 50/50); the treasury share is the remainder to BPS.
///   - PERMISSIONLESS + IDEMPOTENT flush(): anyone (a keeper, or the minter that just paid the fee)
///     may call it; it splits whatever balance is present; a zero balance is a no-op, never a revert.
///   - EXACT, NO-DUST split: integer-division dust folds into the stock-seed leg, so the entire
///     balance always leaves in a single call and nothing is ever stranded here.
///   - REENTRANCY-SAFE: nonReentrant + effects (cumulative counters) written before the ETH sends.
///   - LOUD events per leg.
///
/// Both destinations MUST be able to receive ETH (an EOA, a multisig, or a payable contract). A leg
/// send that reverts reverts the whole flush (fail-closed, no partial split) — the ETH simply waits
/// for the next call. This is deliberate: it can never silently strand or misroute a leg's share.
contract DonMintSplitter is ReentrancyGuard {
    uint256 public constant BPS = 10_000;

    address public immutable stockSeed; // leg A — payout-asset inventory seed (AssetPaymaster / interim reserve)
    address public immutable treasury; // leg B — ops/runway (the protocol's money)
    uint256 public immutable stockSeedBps; // share to leg A (5_000 = 50%); treasury share is the remainder

    // Cumulative lifetime totals, updated on every flush (exact — they only count what leaves via flush()).
    uint256 public totalSplit; // total ETH ever split out
    uint256 public totalToStockSeed; // lifetime ETH sent to the stock-seed leg (incl. folded dust)
    uint256 public totalToTreasury; // lifetime ETH sent to the treasury leg

    event Received(address indexed from, uint256 amount);
    event Split(uint256 total, uint256 toStockSeed, uint256 toTreasury);

    error ZeroAddress();
    error SelfDestination();
    error SameDestination();
    error BadSplit();
    error TransferFailed();

    /// @param stockSeed_    leg A destination — the payout-asset seed sink (AssetPaymaster or interim reserve).
    /// @param treasury_     leg B destination — the treasury multisig / ops wallet.
    /// @param stockSeedBps_ leg A share in bps; the founder's ruling is 5_000 (50/50). Must be in (0, BPS).
    constructor(address stockSeed_, address treasury_, uint256 stockSeedBps_) {
        if (stockSeed_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        // A destination that is the splitter itself would recycle its cut into the balance and silently
        // leak that share to the other leg on the next flush. The contract is immutable, so reject it here
        // (impossible-by-construction beats deploy discipline — the FeeRouter/SeatReserve principle).
        if (stockSeed_ == address(this) || treasury_ == address(this)) revert SelfDestination();
        // Two distinct legs are the whole point of the split; collapsing them into one address would be a
        // silently misconfigured deploy (100% to one wallet, defeating the ruling).
        if (stockSeed_ == treasury_) revert SameDestination();
        // Both legs must be strictly positive: a 0% leg is a dead, misconfigured split. Requiring the
        // stock-seed share into (0, BPS) forces the treasury remainder into (0, BPS) too.
        if (stockSeedBps_ == 0 || stockSeedBps_ >= BPS) revert BadSplit();
        stockSeed = stockSeed_;
        treasury = treasury_;
        stockSeedBps = stockSeedBps_;
    }

    /// Accept mint-fee ETH forwarded by DonDistributor._splitFee (a plain `call{value}`), or by anyone.
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// The treasury share, derived so the two shares always sum to exactly BPS.
    function treasuryBps() external view returns (uint256) {
        return BPS - stockSeedBps;
    }

    /// ETH currently held and awaiting the next flush().
    function pending() external view returns (uint256) {
        return address(this).balance;
    }

    /// Split the splitter's entire ETH balance to the two destinations by the immutable shares.
    /// Permissionless and idempotent — safe to call anytime; a zero balance is a no-op. Rounding dust
    /// folds into the stock-seed leg (favouring the payout bootstrap), so the whole balance always
    /// leaves in one call and nothing is stranded. Fail-closed: a reverting leg reverts the flush.
    function flush() external nonReentrant returns (uint256 toStockSeed, uint256 toTreasury) {
        uint256 bal = address(this).balance;
        if (bal == 0) return (0, 0);

        toTreasury = (bal * (BPS - stockSeedBps)) / BPS;
        toStockSeed = bal - toTreasury; // remainder (incl. rounding dust) -> the stock-seed leg

        // Effects before interactions: the lifetime counters are settled before any ETH leaves.
        totalSplit += bal;
        totalToStockSeed += toStockSeed;
        totalToTreasury += toTreasury;

        (bool okA,) = stockSeed.call{value: toStockSeed}("");
        if (!okA) revert TransferFailed();
        (bool okB,) = treasury.call{value: toTreasury}("");
        if (!okB) revert TransferFailed();

        emit Split(bal, toStockSeed, toTreasury);
    }
}
