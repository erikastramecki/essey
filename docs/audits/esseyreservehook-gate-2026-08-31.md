# $ESSEY Launch Hook — Audit Gate Receipt

**Date:** 2026-08-31
**Scope:** `rh-chain/src/market/EsseyReserveHook.sol` (3-bucket fee model) + `rh-chain/src/market/LaunchSeeder.sol`
**Gate:** standing 3-agent audit gate — Lens A (economics/solvency/value-extraction), Lens B (access-control/reentrancy/authorization), Lens C (test-integrity/mutation). Requirement: **3 consecutive rounds, all three lenses clean, on byte-identical code.**
**Verdict:** **MET.** Three consecutive complete-clean rounds on the hardened suite (source byte-identical throughout).
**Profile:** `FOUNDRY_PROFILE=v4` (via_ir). Tests: **92 passed, 0 failed** (71 hook + 19 launch-seed + 2 fork; fork RPC live).

## What the hook is
The $ESSEY launch hook skims a fee (always denominated in USDG/`feeCurrency`) on every swap and splits the base fee three ways — **reserve / holders / dons** — with an anti-snipe surcharge (linear decay over `snipeSeconds`) routed 100% to the reserve. Default deploy split **50 holders / 40 reserve / 10 dons** (constructor arg). `LaunchSeeder` performs a one-shot single-sided atomic seed of the pool.

## Finding raised and resolved during the gate
- **F-C1 (test-integrity, LOW–MED, deployed code CORRECT):** the anti-snipe surcharge's linear-decay *shape* was unpinned — a step-function mutant (`return snipeStartBps;`, full surcharge the whole window then cliff) passed all 92 tests because every existing assertion sat at the window endpoints. **Fixed (test-only):** added a strict-decrease + exact-interior-linear assertion (`test/EsseyReserveHook.t.sol:380-381`) and a `pendingEffectiveTime==0` assertion after `lock()` (`:730`). Both mutation-verified RED against their specific mutants; source byte-unchanged. The 3 consecutive clean rounds were run on this hardened suite.

## Invariants VERIFIED (each pinned by a test proven RED against its mutation)
- Three-bucket split sums to exactly `baseFee`; residual → reserve; conservative rounding (never over-credits holders/dons); 0% share accrues exactly 0.
- Rails enforced at construction AND `proposeSplit`: `MIN_RESERVE_BPS=4000`, `MAX_HOLDERS_BPS=5000`, `MAX_DONS_BPS=2000`, sum==BPS. Reserve floor ≥40% of base + 100% of surcharge always holds.
- Governor may change ONLY the split, within rails, after a 48h timelock; `lock()` is one-way (sets `splitLocked`, renounces `governor=address(0)`, cancels pending). Fee RATE and all sinks are `immutable` — no setter.
- Surcharge 100% → reserve, independent of the split, non-bypassable.
- Reserve adminless; hook never mints or skims ESSEY (fee always `feeCurrency`); ESSEY total supply invariant asserted.
- `fund*` payouts: CEI + `nonReentrant`, zero-escrow-before-transfer, immutable sinks only; arbitrary-token calls revert `NothingToFund`.
- `LaunchSeeder` locked-by-construction (no withdraw/remove/collect path — principal permanently locked), one-shot (`seedCaller`-gated + `seeded` flag), single-sidedness self-enforcing (`UsdgOwed` revert).
- No `delegatecall`/`assembly`/`selfdestruct`/arbitrary-call/`create2` in either file.

## Mutation summary
~64 mutations per round, restored from pristine copies with anchor assertions (no false-kill artifacts). All semantically-meaningful mutants killed. **4 survivors, all proven equivalent** (not coverage gaps): two `surchargeBpsAt` boundary collapses (`<=`→`<`, `>=`→`>` — same value at the boundary), `MAX_LEFTOVER` `>`→`>=` (boundary unreachable), and the unreachable `proposeSplit` `splitLocked` guard (after `lock()`, `governor==address(0)` so `onlyGovernor` reverts first). Real tree proven byte-identical each round (`diff -q`).

## DEPLOY-CONFIG PRECONDITIONS (NOT contract defects — must be enforced at deploy)
1. **`feeCurrency` must be the USDG (non-ESSEY) leg.** The hook accepts `feeCurrency ∈ {currency0, currency1}` but has no knowledge of which is ESSEY; the "never skim ESSEY" guarantee holds only if deploy pins `feeCurrency = USDG`. Deploy script MUST assert this.
2. **ESSEY must be non-circulating until the atomic seed.** `afterAddLiquidity` stamps `launchTime` on the first ESSEY-supplying add; if ESSEY circulated earlier, a third party could stamp the clock early and decay the surcharge before the real seed. Mint ESSEY ONLY into `LaunchSeeder` pre-launch. Confirm at deploy: no ESSEY `transfer`/`mint` reaches any address other than `LaunchSeeder` before `seed()`.

## Status
Code gate **MET**. Remaining before mainnet: the two deploy-config checks above, per-instance founder deploy authorization, and a cosmetic cleanup of the stale `// PENDING FOUNDER CONFIRMATION` comments on the rail constants (rails now founder-confirmed at 40/50/20). Contracts + tests are untracked (`??`); this receipt grounds the audit-clean state for the product tracker.
