# Market layer — adversarial audit round 5 (loan-interest → the Bell)

**Target:** the reserve-routing addition to `rh-chain/src/EsseyPool.sol` — the third Bell engine.
· **Date:** 2026-08-03 · **Result:** 1 defect found and fixed, round 2 **CLEAN** on all three lenses.

Three independent auditors (lender-safety/ERC-4626; economics/integration; reentrancy/regression
against the pool's audited F/R invariants). Same gate as always. This change touches the **lending
core** — the one part of the codebase whose accrual math survived six adversarial rounds unbroken — so
the regression lens verified byte-level that borrow/repay/liquidate/accrue were untouched.

## What was added

Three constructor immutables (`bellSink`, `reserveTreasury`, `bellShareBps`, with a
deployment-coherence guard proving the sink's reward token IS the pool asset via a minimal interface —
the lending core never imports the market layer) and a permissionless `skimReserves()`: accrue, take
`min(totalReserves, cash)`, split immutably between the Bell's pot and the reserve treasury.

**Lender safety by construction, verified three ways:** `totalAssets` already excludes reserves, so a
skim moves cash and `totalReserves` down in lockstep — the share price provably cannot move (asserted
directly in tests, traced through OZ's ERC-4626 entry points, and reentrancy-mapped: every
state-changing entry point shares one guard, so the transient mid-skim accounting window is unreachable).

## The defect the gate caught (round 1 → 2)

**Utilization counted protocol reserve cash as lendable supply.** Reserves idling in the pool
suppressed utilization — and therefore the borrow rate — until the moment anyone skimmed, at which
point the rate jumped discontinuously at an arbitrary caller's chosen timing. Rates must not be a
function of skim-keeper diligence. *Fix:* `utilizationBps` now excludes the skimmable part of reserves
from the denominator (the Compound-lineage formula, plus a clamp Compound itself lacks: when reserves
exceed cash, u saturates at exactly 100% instead of misbehaving). Round 2 verified the fix
**algebraically invariant across every regime** — full skim, cash-bounded partial skim, the
repay-then-settle corridor — and empirically probed it, including at 100%-of-interest reserves.

## Accepted and documented (not defects)

- **The skim/liquidity race.** A skim can consume idle cash ahead of a withdrawal or borrow — one-shot,
  gas-cost griefing at worst; the loser retries. Both parties were already racing for the same cash.
- **Reserve seniority under catastrophic issuer burn.** If the asset issuer burned the pool's cash,
  skims would take remaining cash while lender shares floor at zero — a priority-of-claims choice now
  stated in the code rather than left implicit.
- **Accrual drift.** Excluding reserves makes u drift up smoothly as interest accrues (never a jump,
  ≤ ~5 bps/day at realistic parameters) — the correct economics: the reserve cut was never lendable.

## What was NOT covered

Not deployed. The MVP deploy script wires no Bell (`BELL_SINK=0` → everything to the treasury) and
zero rates, so nothing skims until a market-layer deploy sets the sink — at which point the constructor
guard makes a mis-wired one un-deployable. Tests: `rh-chain` 255/255 (10 routing tests, including rate
invariance across skims in both the normal and reserves-exceed-cash regimes, boundary share configs,
and the partial-skim settlement corridor).
