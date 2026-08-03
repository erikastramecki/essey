# Market layer — adversarial audit round 1

**Target:** `rh-chain/src/market/` (Seat, SeatVault, Bell, StockConverter, Note, interfaces) + the
`EsseyPool.sol` "Note-ification" diff · **Date:** 2026-08-02 · **Result:** 1 confirmed (fixed), re-audit
**CLEAN.**

Three independent auditors, each on a scoped surface (the audited lending-core diff + Note; the Bell
fee/reward engine + StockConverter; the Seat NFT + token-bound Vault). The gate rule: all three clean in
the same round before push; a fix re-runs every auditor from scratch.

---

## The lending-core change under review

`EsseyPool` positions became transferable bearer deeds: the stored `borrower` field was removed, and
repay authority, returned collateral, and liquidation surplus now follow `note.ownerOf(id)` at execution
time. A `Note` ERC-721 is minted on borrow and burned in the pool's single close path. The pool carries
invariants from six prior Sui audit rounds (F3/F5/R2/R3/R5/R6); the review's central question was whether
the change weakened any of them.

**Verdict: it did not.** Auditors verified `principal ≠ 0 ⟺ Note exists` (so `ownerOf` can never revert
on a live position and brick repay/liquidate), a single mint site and a single burn+delete+release site,
monotonic never-reused ids, the F3 surplus holder read *before* the burn, plain `_mint` (no
`onERC721Received` callback surface), and all mutators still `nonReentrant`.

---

## Fixed (full detail — fix committed with this change)

### LOW / defense-in-depth — Bell.claim reset the converter allowance on only one path

`Bell.claim` approves the payout converter for `amount`, then calls `converter.convert` inside a
try/catch that fails open to the base asset. The reset `forceApprove(converter, 0)` ran on the **catch**
path but not the **success** path. With the honest `StockConverter` this is harmless (it pulls exactly
`amountIn`, leaving the allowance at 0). But the converter is external code the audit treats
adversarially: a converter that returned success while under-pulling would leave a standing `reward`
allowance over the Bell's entire balance (pot + other Seats' reserved rewards), drainable later up to
`amount`.

**Fix:** reset the allowance on **both** paths, unconditionally. Verified by a test
(`test_NoDanglingAllowanceOnUnderpullingConverter`) using a deliberately under-pulling converter, and by
a from-scratch re-audit confirming the allowance is provably 0 after both paths with no regression.

---

## Confirmed sound (no defect)

- **Bell accumulator:** O(1) MasterChef/Synthetix distribution; `credited ≤ distributed`, `reserved`
  always covers all pending, `pot() = balance − reserved` never underflows; no double-claim, no
  wrong-Seat payout (destination is the deterministic Vault), no cross-Seat drain. Rounding leaves only
  sub-wei dust (revert-not-steal, self-healing on the next ring).
- **Tier lifecycle:** activate/upgrade fee + checkpoint ordering correct; `onSeatTransfer` (seat-gated)
  clears tier + payout preference + deregisters weight while preserving earned rewards.
- **StockConverter:** oracle-fair `minOut` with correct 6/18/8-decimal normalization; append-only
  registrar-gated registry (no feed/pool swap under an opted-in token); fail-closed off-session / stale /
  incomplete-round; no custody at rest; router approval reset after swap.
- **sweep():** cannot move the reward token or reserved rewards; treasury-fixed; no privileged caller.
- **Seat / SeatVault:** Vault control follows `ownerOf` live (no desync); CREATE2 deployer-binding makes
  clone/initialize front-running impossible; mint cap exact, no id 0; assets not trappable.

## Accepted trust assumptions / deferred (documented, not defects)

- **Trusted-minter hook liveness:** `Seat._update` calls the transfer hook un-try/caught and `setHook`
  is one-shot, so a *broken* hook would freeze Seat transfers (not Vault contents). The shipped Bell's
  hook is pure state with no revert path; both "fixes" are worse (try/catch breaks the
  tier-clears-on-transfer invariant; a replaceable hook adds an admin key). Accepted under the
  trusted-minter model.
- **HARD REQUIREMENT for the future collateral-in-Vault phase:** `SeatVault.execute` must gain a
  reentrancy guard + pool-lien check before it custodies collateral. Today it holds nothing.
- **Pre-existing, not introduced:** a blocklisting collateral token could make a liquidation refund
  revert — identical pattern existed before Notes; self-limiting (deep-underwater sets refund 0).

## What was NOT covered

- Research build; not deployed. The Floor (Seat AMM), the $ESSEY token, the Case system, and the
  collateral-in-Vault (lien) Notes-v2 do not exist yet and were out of scope.
- The ZK oracle-bound transition circuit (`circuit/poseidon/oracle_transition.go`) is separate work on a
  different branch and gets its own gate.
