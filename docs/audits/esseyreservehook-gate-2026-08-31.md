# $ESSEY Launch Hook — Audit Gate Receipt

**Date:** 2026-08-31
**Scope:** `rh-chain/src/market/EsseyReserveHook.sol` (3-bucket fee model) + `rh-chain/src/market/LaunchSeeder.sol`
**Gate:** standing 3-agent audit gate — Lens A (economics/solvency/value-extraction), Lens B (access-control/reentrancy/authorization), Lens C (test-integrity/mutation). Requirement: **3 consecutive rounds, all three lenses clean, on byte-identical code.**
> ⚠️ **THIS VERDICT IS WITHDRAWN.** A later real-PoolManager fork harness found HIGHs A-1/A-3 in
> the shipping bytes, and the G1 counter was reset to ZERO — see
> the G1 row in `docs/MAINNET-ACTIVATION.md`. The round below is kept as an audit trail;
> do not cite it as a passed gate.

**Verdict (WITHDRAWN — see banner):** **MET.** Three consecutive complete-clean rounds on the hardened suite (source byte-identical throughout).
**Profile:** `FOUNDRY_PROFILE=v4` (via_ir). Tests: **92 passed, 0 failed** (71 hook + 19 launch-seed + 2 fork; fork RPC live).

## What the hook is
The $ESSEY launch hook skims a fee (always denominated in USDG/`feeCurrency`) on every swap and splits the base fee three ways — **reserve / holders / dons** — with an anti-snipe surcharge (linear decay over `snipeSeconds`) routed 100% to the reserve. Default deploy split **45 reserve / 40 holders / 15 dons** (constructor arg) — `script/DeployEsseyV4Pool.s.sol:47-49`
(`RESERVE_SHARE_BPS = 4_500`, `HOLDERS_SHARE_BPS = 4_000`, `DONS_SHARE_BPS = 1_500`), matched by
`test/EsseyReserveHook.t.sol:132-134`. `LaunchSeeder` performs a one-shot single-sided atomic seed of the pool.

> **CORRECTION 2026-09-02 (H-3, caught by the scoped pre-push audit).** This line previously read
> "Default deploy split **50 holders / 40 reserve / 10 dons**." That was **wrong**, and wrong in a way that
> understated the shipped risk posture: it conflated the **RAILS** with the **SPLIT**.
> - **RAILS** (immutable bounds, `EsseyReserveHook.sol:38-40`): `MIN_RESERVE_BPS = 4_000`,
>   `MAX_HOLDERS_BPS = 5_000`, `MAX_DONS_BPS = 2_000` — i.e. 40/50/20.
> - **SPLIT** (the default the deploy script actually passes): **45/40/15**.
>
> The retracted "50/40/10" sits **exactly ON two rails** — holders at the 5000 ceiling and reserve at the
> 4000 floor — meaning zero governor headroom in either direction and a reserve pinned at its minimum. The
> real 45/40/15 default has **500 bps of margin above the reserve floor and 1000 bps below the holders
> ceiling.** Anyone reading the old line would have believed the launch shipped at its rail limits. It does not.

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
*(Expanded 2026-09-02: #1 strengthened, #3 and #4 added, per the scoped pre-push audit.)*
1. **`feeCurrency` must be the ERC20 USDG (non-ESSEY) leg — NEVER the native currency.** The hook accepts `feeCurrency ∈ {currency0, currency1}` but has no knowledge of which is ESSEY; the "never skim ESSEY" guarantee holds only if deploy pins `feeCurrency = USDG`. **A V4 `Currency` may be the zero address (native), and the fee-payout path assumes an ERC20 transfer — so a native-currency leg must be rejected outright, not merely "not ESSEY."** Deploy script MUST assert both properties.
2. **ESSEY must be non-circulating until the atomic seed.** `afterAddLiquidity` stamps `launchTime` on the first ESSEY-supplying add; if ESSEY circulated earlier, a third party could stamp the clock early and decay the surcharge before the real seed. Mint ESSEY ONLY into `LaunchSeeder` pre-launch. Confirm at deploy: no ESSEY `transfer`/`mint` reaches any address other than `LaunchSeeder` before `seed()`.

3. **`LaunchSeeder.seed()` has no ACTIVE-liquidity post-condition (S-2, LOW — see below).** The deploy MUST
   verify, from a simulation/fork run before the real call, that the chosen rungs produce **non-zero active
   liquidity at spot**. `seed()` is `seedCaller`-gated, one-shot (`seeded = true`, `LaunchSeeder.sol:127`),
   and the contract has **no withdraw path** — a misconfigured ladder locks the seed ESSEY permanently.
4. **Rung contiguity.** The rung set must be contiguous and must bracket spot, with the first rung's
   `tickLower` at the pinned launch price. A gap at spot yields zero active liquidity even though every
   individual rung passed its own `liquidity != 0` check (`LaunchSeeder.sol:162`).

## LOW findings raised 2026-09-02 by the scoped pre-push audit (NOT in the original gate — recorded, not fixed)
These were found AFTER the three clean rounds, in the pre-push round. They do not retract the gate verdict
(no clean round is invalidated), but they are **open** and the founder must rule fix-vs-accept. **PM does not
decide this.**

- **S-1 (LOW) — the empty-pool guard stays armed forever.** `EsseyReserveHook.sol:256`
  (`if (poolManager.getLiquidity(...) == 0) revert EmptyPool();`) is unconditional — it has no post-launch
  disarm. It exists to stop a sniper trading a zero-liquidity pool before the seed. But **after** launch, an
  oversized buy that walks price past the top rung and exhausts active liquidity leaves
  `getLiquidity() == 0`, and from that moment **every swap reverts** until someone adds liquidity. The pool
  is bricked, not just illiquid.
- **S-2 (LOW) — `seed()` never asserts it produced active liquidity.** `LaunchSeeder.seed()`
  (`LaunchSeeder.sol:123`) validates each rung individually — tick order `:156`, alignment `:157`,
  `liquidity != 0` `:162`, `UsdgOwed` single-sidedness `:168`, `LeftoverTooLarge` `:144` — but has **no
  post-condition that the resulting position set is active at spot.** A ladder entirely above spot passes
  every check and mints zero active liquidity. Combined with the one-shot `seeded` flag and no withdraw, the
  seed ESSEY is locked permanently.

**S-1 and S-2 COMPOUND, and that is the finding worth the founder's attention.** A mis-parameterized seed
(S-2) produces a pool with zero active liquidity, which S-1 then makes **permanently un-swappable** — a
launch that cannot be traded and cannot be recovered, from one bad rung array, on a one-shot call. Neither
finding alone is worse than LOW; together they are the plausible path to a bricked launch. Preconditions #3
and #4 above are the *procedural* mitigation; whether to add a *code* post-condition is the founder's call.

## Content hashes (added 2026-09-02 — process improvement)
The original receipt recorded no content hash, so byte-identity of the audited code could not be proved from
the document alone. **Every future receipt MUST carry `sha256sum` of each audited file.** For this gate,
hashed 2026-09-02. **These pin the HEAD-COMMITTED content, not a working-tree snapshot** — re-derive with
`git show HEAD:<path> | shasum -a 256`, which is stable regardless of what is in the tree at the time:
```
b113fe7d3f3e2aec2fe52ec3dcf969aa72dfe0f5ab8243cec91e5d3156150c35  rh-chain/src/market/EsseyReserveHook.sol
449c6da723cf11cc844c8590e1f882e2999dde4347f13884cebb0b2fe0cc421a  rh-chain/src/market/LaunchSeeder.sol
```
Independent second derivation — the git blob ids for the same two files at the same commit:
```
bd9eca95950cdfbc255a4e1e68fec99f447f81de  rh-chain/src/market/EsseyReserveHook.sol
39ae98c1006c013a420808ccc4ed21f0a1416d61  rh-chain/src/market/LaunchSeeder.sol
```
**Why the "HEAD-committed" qualifier is load-bearing:** while this correction was being written, the working
copy of `EsseyReserveHook.sol` was churning through three different hashes in about two minutes — an auditor
mutation run in progress (observed mutants: the `EmptyPool` guard at `:256` deleted, then
`_feeIsSpecified` reduced to `return true;`). A receipt that pinned a *working-tree* hash would have recorded
a mutant and looked authoritative doing it. **Always hash the committed blob, never the file on disk.**
**Honest caveat:** these hashes were taken on 2026-09-02, NOT during the three clean rounds on 2026-08-31.
They pin the files from today forward; they do **not** retroactively prove the audited bytes were these
bytes. Only a receipt written with hashes at gate time can do that. Treat this block as the baseline for the
NEXT gate, not as proof of the last one.

## Open contradiction to resolve before deploy (flagged 2026-09-02)
This receipt says "Rails founder-confirmed 40/50/20," but the committed source still carries
`// PENDING FOUNDER CONFIRMATION` on all three rail constants (`EsseyReserveHook.sol:37-40`) and on the
default split in both `DeployEsseyV4Pool.s.sol:46` and `test/EsseyReserveHook.t.sol` — i.e. **the code says
the numbers are the economist's proposal, not founder-final, while this receipt says they are confirmed.**
One of the two is wrong. Resolve before deploy: either the founder confirms and the comments are stripped,
or the receipt's "founder-confirmed" claim is downgraded. Cosmetic in form, load-bearing in fact.

## Status
Code gate **MET** for the three clean rounds of 2026-08-31. **The push is separately BLOCKED** as of
2026-09-02 pending a fresh 3-round clean after the corrections above (H-2/H-3 doc fixes; S-1/S-2 open). Remaining before mainnet: the two deploy-config checks above, per-instance founder deploy authorization, and a cosmetic cleanup of the stale `// PENDING FOUNDER CONFIRMATION` comments on the rail constants (rails now founder-confirmed at 40/50/20). Contracts + tests are untracked (`??`); this receipt grounds the audit-clean state for the product tracker.
