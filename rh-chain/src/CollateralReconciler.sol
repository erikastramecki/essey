// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IScaledUI} from "./interfaces/IScaledUI.sol";

/// Collateral accounting for a token whose issuer can destroy or rescale it underneath you.
///
/// WHY THIS EXISTS. Two properties of Robinhood Stock Tokens, both read from the deployed
/// contract rather than from documentation:
///
///   1. `adminBurn(from, amount)` under ADMIN_BURNER_ROLE destroys tokens from ANY address with
///      no pause check and no block check. Verified on-chain: that role is held by a plain EOA,
///      with no multisig and no timelock anywhere in the stack. Collateral can therefore vanish
///      from a live pool, leaving a loan unsecured with nothing to liquidate.
///
///   2. `balanceOf()` is the raw amount and is stable; `balanceOfUI()` is the share-equivalent and
///      changes on corporate actions via `uiMultiplier()`. The multiplier can be SCHEDULED with a
///      future `effectiveAt`, so a position's economic size changes with no transaction touching
///      this pool.
///
/// THE BURN-SHARING MODEL — a per-token INDEX, so losses fall only on who was present.
///
/// A burn destroys raw units held by the whole pool, but the loss must be shared ONLY among the
/// positions that were open WHEN it happened. An earlier version divided each position's raw by the
/// live pooled total (`raw * actual / recordedRaw`); because `recordedRaw` is a single per-token
/// figure, a borrower who deposited AFTER a burn was charged for it too — their intact collateral
/// funding someone else's loss (finding: "pro-rata correct on close, wrong on open").
///
/// The fix is a monotonically non-increasing `collateralIndex[token]` (INDEX_ONE = full survival).
/// Each position snapshots the index at open; its entitlement is `raw * indexNow / snapshot`. A burn
/// ratchets the index DOWN so that the total entitlement equals the surviving balance — but a
/// position opened AFTER the burn snapshots the already-lowered index, so `indexNow == snapshot` for
/// it and it recovers its full raw. Burns before you arrived cannot touch you; burns during your loan
/// are shared pro-rata with everyone else who was there. Order of repayment is irrelevant.
///
/// SOLVENCY INVARIANT (what the fuzz tests pin): the sum of open positions' entitlements is always
/// <= the pool's actual balance of the token. Integer rounding is retained by the pool (paid amounts
/// floor; scaled totals decrement exactly), always in the safe direction.
abstract contract CollateralReconciler {
    /// The index's "1.0": full survival, no burn yet. A token's index lazily starts here (0 == unset).
    uint256 internal constant INDEX_ONE = 1e18;

    /// NOMINAL raw units this pool holds for `token`: the sum of open positions' posted collateral.
    /// Reporting + the debit guard only; the entitlement math uses the index below, not this.
    mapping(address => uint256) public recordedRaw;

    /// Cumulative raw units destroyed under this pool's feet, for reporting.
    mapping(address => uint256) public shortfallRaw;

    /// Per-token collateral survival index, WAD-scaled, monotonically NON-INCREASING. 0 == unset ==
    /// INDEX_ONE (nothing burned yet). Ratcheted down only by `_reconcile` when a NEW burn is found.
    mapping(address => uint256) public collateralIndex;

    /// Sum over open positions of `rawPosted * INDEX_ONE / snapshot` — the index-scaled collateral
    /// total. `totalEntitlement(token) = scaledCollateral[token] * index / INDEX_ONE`.
    mapping(address => uint256) public scaledCollateral;

    event CollateralShortfall(address indexed token, uint256 recorded, uint256 actual, uint256 shortfall);

    error InsufficientRecorded(address token, uint256 have, uint256 want);
    /// A total burn zeroed the index while positions were still open. Those dead positions carry no
    /// entitlement and can still be repaid/liquidated (they just return 0 collateral), but a NEW position
    /// cannot be mixed into a wiped cohort under one index — clear the dead ones first.
    error CollateralCohortWiped(address token);

    /// The live index for `token`. 0 means either never-credited OR a total burn (both correctly yield a
    /// zero entitlement in `_effectiveCollateral`); a live, partially-burned token is in (0, INDEX_ONE].
    function _index(address token) internal view returns (uint256) {
        return collateralIndex[token];
    }

    /// A position's ACTUAL entitlement now: its raw scaled by how much collateral has survived SINCE
    /// it opened (`raw * indexNow / snapshot`). Burns before `snapshot` don't move it, so a post-burn
    /// depositor recovers its full raw. Clamped to raw defensively (index is <= snapshot by monotonicity).
    function _effectiveCollateral(address token, uint256 rawAmount, uint256 snapshot)
        internal
        view
        returns (uint256)
    {
        if (snapshot == 0) return rawAmount; // defensive: a real position always snapshots a nonzero index
        uint256 idx = _index(token);
        if (idx >= snapshot) return rawAmount; // no burn since this position opened
        uint256 eff = (rawAmount * idx) / snapshot; // idx == 0 (total burn) -> exactly 0, never dust
        return eff > rawAmount ? rawAmount : eff;
    }

    /// Ratchet the index down to reflect any burn discovered since the last reconcile, and update the
    /// shortfall report. MUST be called before a new deposit is credited (so the new position snapshots
    /// the post-burn index and is insulated) and before an entitlement is computed. Monotonic: the index
    /// only ever decreases. `actual` must be the balance BEFORE any not-yet-credited deposit.
    function _reconcile(address token) internal returns (uint256 newShortfall) {
        uint256 actual = IERC20(token).balanceOf(address(this));

        uint256 scaled = scaledCollateral[token];
        if (scaled != 0) {
            uint256 idx = _index(token);
            uint256 expected = (scaled * idx) / INDEX_ONE; // total entitlement the index implies
            if (actual < expected) {
                // A burn happened: drop the index so total entitlement == the surviving balance.
                // actual < expected == scaled*idx/ONE  =>  actual*ONE/scaled < idx, so this only decreases.
                collateralIndex[token] = (actual * INDEX_ONE) / scaled;
            }
        }

        // Reporting (unchanged semantics): cumulative raw destroyed vs the nominal recorded total.
        uint256 nominal = recordedRaw[token];
        if (actual < nominal) {
            uint256 total = nominal - actual;
            uint256 known = shortfallRaw[token];
            if (total > known) {
                newShortfall = total - known;
                shortfallRaw[token] = total;
                emit CollateralShortfall(token, nominal, actual, total);
            }
        }
    }

    /// Economic value of `rawAmount`, priced via the live corporate-action multiplier.
    function _uiAmount(address token, uint256 rawAmount) internal view returns (uint256) {
        return (rawAmount * IScaledUI(token).uiMultiplier()) / 1e18;
    }

    /// Is a corporate action scheduled but not yet effective? Lets the UI and keeper warn before
    /// a split silently rescales every position.
    function pendingMultiplier(address token) external view returns (uint256 newMultiplier, uint256 effectiveAt) {
        try IScaledUI(token).newUIMultiplier() returns (uint256 m, uint256 at) {
            return (m, at);
        } catch {
            return (0, 0);
        }
    }

    /// Record a newly-posted position's collateral and return the index snapshot to store on it. Call
    /// AFTER `_reconcile` (and after the transfer in), so it snapshots the post-burn index.
    function _creditCollateral(address token, uint256 rawAmount) internal returns (uint256 snapshot) {
        // A fresh cohort (never used, or fully wound down) starts the index at full survival. This also
        // resets it after a token was totally burned and every dead position has since been cleared, so
        // new capital comes in at par rather than inheriting a collapsed index.
        if (scaledCollateral[token] == 0) collateralIndex[token] = INDEX_ONE;
        snapshot = collateralIndex[token];
        // snapshot == 0 only if scaled > 0 and a prior total burn zeroed the index: the cohort is wiped
        // and a new position cannot be scaled into it (it would also divide by zero). Clear the dead
        // positions first. This is an extreme, transient state, not a normal path.
        if (snapshot == 0) revert CollateralCohortWiped(token);
        recordedRaw[token] += rawAmount;
        scaledCollateral[token] += (rawAmount * INDEX_ONE) / snapshot;
    }

    /// Retire a position's collateral from the books, using the snapshot it was opened with.
    function _debitCollateral(address token, uint256 rawAmount, uint256 snapshot) internal {
        uint256 have = recordedRaw[token];
        if (have < rawAmount) revert InsufficientRecorded(token, have, rawAmount);
        recordedRaw[token] = have - rawAmount;

        uint256 scaled = (rawAmount * INDEX_ONE) / (snapshot == 0 ? INDEX_ONE : snapshot);
        uint256 st = scaledCollateral[token];
        scaledCollateral[token] = st < scaled ? 0 : st - scaled; // floor at 0 for rounding safety
    }
}
