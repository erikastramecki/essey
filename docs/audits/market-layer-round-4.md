# Market layer — adversarial audit rounds (the Case system)

**Target:** `rh-chain/src/market/EsseyCases.sol` — the fair-value stock gacha ("401(k) pack").
· **Date:** 2026-08-03 · **Result:** 4 rounds, 2 HIGHs + 1 MEDIUM + 3 LOWs found and fixed, final round **CLEAN** on all three lenses.

Three independent auditors per round (entropy/draw-fairness; oracle/economics; reentrancy/roles/
integration). Gate rule: all three clean in the same round before push; every fix re-runs every lens.
This contract took four rounds — the most of any market-layer contract — because randomness + drifting
prize values is genuinely adversarial territory. That is the gate working, not failing.

---

## What the contract is

Buy a Case in $ESSEY (price sunk to treasury; buy fee split to the Bell pot/treasury), a
blockhash-committed uniform draw over an on-chain prize inventory delivers real stock straight to your
wallet, and a two-sided flow lets you sell any unit back at oracle value minus a floored spread (spread's
booster share feeds the Bell; the stock re-enters the prize pool). **Fair-value variant only**: every
unit is seeded at ~one case's value, so the draw decides *which* stock, never how much — the property
that licenses blockhash entropy at all. The multiplier "degen" variant is explicitly not built and is
hard-gated on a real VRF.

**Provably-solvent bankroll:** `buy` reverts unless inventory exceeds unopened cases — every unopened
Case is backed by a real, already-deposited prize unit, as an invariant (machine-checked across all five
mutating paths in round 3).

## What the gate caught (and the fixes)

- **HIGH (round 1): free re-rolls.** The original `rearm` let a buyer whose draw outcome was public
  simply wait out the 256-block window and re-roll — converting a uniform draw into max-selection over
  the inventory's price drift, a systematic bankroll drain. *Fix:* re-rolls deleted; an expired case pays
  the **current lowest-oracle-value unit** (`claimExpired`), so abandoning a draw can never beat opening it.
- **HIGH (round 1): open-timing steering.** The draw index runs over a mutable inventory array, giving
  an in-window buyer selection power. *Fix + honest bound:* the residual on every remaining lever
  (open-timing, self sell-backs, sequencer bias, expired-claim timing) is **inventory value dispersion**,
  kept small operationally by bankroll re-seeding near par — documented as a monitored risk knob, with
  every extraction round-trip paying the spread floor.
- **MEDIUM (round 2): the unbounded floor option.** `claimExpired` with no deadline was an American
  option on min(inventory value) — wait for cheap units to drain, then claim a floor that beats the
  abandoned draw. *Fix:* a 7-day claim TTL; after it, anyone may sweep the abandoned case (backing freed,
  prize stays pooled, buyer forfeits — disclosed plainly).
- **LOW (rounds 2–3):** spread floor raised to 150 bps (the round trip crosses *two* 0.5% oracle
  deviation bands); token decimals bounded at listing (an overflow brick); one dead Chainlink feed no
  longer bricks every expired claim (unpriceable tokens are excluded from floor candidacy, all-dead
  reverts); and `sweepAbandoned` now requires the draw window lapsed as well as the TTL — without it, a
  multi-day chain halt would have let a third party sweep a still-openable case out from under its buyer.
- **Round 4 (confirmation, all three lenses): CLEAN.** The settle matrix (open / claimExpired / sweep)
  was enumerated across every regime — exactly one path available in each, exact seams, no double-settle,
  no permanent wedge. The entropy lens additionally gas-probed the floor scan across a fine-combed gas
  band to refute a 63/64 starvation attack (structurally impossible: no gas window exists where the
  cheap feed fails but the claim still completes).

## Accepted tradeoffs (documented, not defects)

- **$ESSEY-drift reserve exposure** and **inventory fair-value decay** under two-sided flow — deploy-time
  economics on an immutable contract, managed by pricing margin, re-seeding, and monitoring
  (`docs/TOKENOMICS-essey.md`).
- **Wall-clock TTL vs chain liveness:** a >7-day halt can forfeit an honest claimer's expired-claim
  window (never their live open). Wall-clock deadlines can't promise liveness the chain doesn't have.
- **Floor front-running of an expired claim** (griefing-only, self-inflicted by expiring) and
  **inventory-stuffing gas grief** (costs the attacker the spread per unit; self-limiting).

## What was NOT covered

Not deployed. The arcade UI is a labeled client-side sandbox. Entropy remains sequencer-trust-bounded
by design — sufficient **only** for the fair-value variant. Tests: `rh-chain` 219/219 (30 for Cases).
