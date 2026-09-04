# Security audits

Every substantive change to this protocol goes through an adversarial audit before it is
considered done: independent agents attack the code from different angles, and **every finding is
then independently verified by two skeptics whose job is to refute it**. Only findings that
survive refutation are reported. Refuted findings are recorded too — they show what was considered
and why it was dismissed, which is often more informative than the confirmed list.

## Publishing policy

These reports are public deliberately. The discipline is **fix-first**:

- A finding's full detail — exploit path, code, fix, closing commit — publishes **after** its fix
  is committed.
- **Open** findings appear as a placeholder: round, severity, affected surface, status. No exploit
  path.
- Clean rounds and refuted findings publish immediately; neither arms anyone.

The point is a trail an outsider can actually check, not a highlight reel. Severities are the
verifiers' calibrated ones, not the reporters' initial claims, and the reports name what was NOT
covered.

## Reports

| Round | Target | Confirmed | Status |
|---|---|---|---|
| [Sui 1–6](sui-rounds-1-6.md) | `move/` — the Move protocol | 9, 10, 17, 9, 9, 12 | fixes committed; **no round ever came back clean** |
| [Solidity 1](solidity-round-1.md) | `rh-chain/` — the Robinhood Chain port | 19 | criticals + highs fixed; tail open |
| [Solidity 2](solidity-round-1.md) | `rh-chain/` — re-audit + mutation sweep | see round-1 report | **not clean**; ~50 mutations survive a green suite |
| [Market layer 1](market-layer-round-1.md) | game-era: `rh-chain/src/market/` (Seats/Bell/Notes) + EsseyPool diff | 1 (fixed) | fix committed; **re-audit clean** |
| [Market layer 2](market-layer-round-2.md) | game-era: `EsseyToken.sol` + `EsseyExchange.sol` (the Seat AMM) | 1 hardening | **re-audit clean** |
| [Market layer 3](market-layer-round-3.md) | game-era: `MintDistributor.sol` (the Seat minter + WL) | 2 hardenings | **re-audit clean** |
| [Market layer 4](market-layer-round-4.md) | game-era: `EsseyCases.sol` (the fair-value stock gacha) | 2 HIGH + 1 MED + 3 LOW | 4 rounds; **final round clean** (all 3 lenses) |
| [Market layer 5](market-layer-round-5.md) | game-era: `EsseyPool.sol` reserve-routing → the Bell | 1 (fixed) | **round-2 clean** (all 3 lenses) |
| [Market layer 6](market-layer-round-6.md) | game-era: `SeatArt.sol` + `Seat.tokenURI` | 2 LOW + 5 hardenings | 3 rounds; **final round clean** (all 3 lenses) |
| [$ESSEY launch hook — gate](esseyreservehook-gate-2026-08-31.md) | **protocol (base layer):** `EsseyReserveHook.sol` (three-bucket fee model; **rails 40/50/20**, **default split 45 reserve / 40 holders / 15 dons** — `DeployEsseyV4Pool.s.sol:47-49`) + `LaunchSeeder.sol` | 1 test-only at gate (code CORRECT); **+2 LOW (S-1, S-2) raised 2026-09-02 post-gate, OPEN** | **GATE MET** (3 consecutive clean rounds, all 3 lenses, byte-identical code; 92 tests) — **push BLOCKED 2026-09-02** pending a fresh 3-round clean |
| [G-LEND 1–3](glend-round-3.md) | **protocol (lending):** `EsseyMarkets` · `EsseyPool` · `LivenessOracle` · `MarketHealthOracle`, on a real 4663 fork | R3: 1 CRIT, 1 HIGH, 3 MED, 2 LOW | all fixed; **counter reset to zero** |
| [G-LEND 4](glend-round-4.md) | same surface, re-audited at `cb3e6aa` | 2 HIGH, 3 MED, 6 LOW, 1 INFO | all fixed; R3's CRIT-1 and MED-3 confirmed still closed |
| [G-LEND 5](glend-round-5.md) | same surface at `2804b2e` | 0 CRIT, 0 HIGH, **2 MED**, 3 LOW, 6 INFO | fixed; INFO-1 also refuted our own stated cost of the liveness-key recovery path — see the decision list |
| [G-LEND 6](glend-round-6.md) | same surface at `c04a6ce` | 0 CRIT, 0 HIGH, **1 MED**, 3 LOW, 4 INFO | fixed |
| [G-LEND 7](glend-round-7.md) | same surface at `2309cb0` | **0 CRIT / 0 HIGH / 0 MED**, 2 LOW, 3 INFO | ✅ **CLEAN and countable** — receipt `audit-glend-r7` verified (5,161 B, 2026-09-04 10:33), real 4663 fork, sha256s identical start-to-end. **G-LEND: 1 of 3** at the time. The report is now tracked (`git ls-tree 1bc9ec7 docs/audits/`), closing the publish step this row used to flag |
| [G-LEND 8](glend-round-8.md) | same surface at `959b70a` | 0 CRIT / 0 HIGH, **1 MED**, 4 LOW, 9 INFO | all fixed in `1bc9ec7`; **counter reset to zero**. Worth reading for where the MED was: **not in the corroboration machinery seven rounds had hardened** — the 41-mutant gate was genuinely 41/41 — but pre-existing in `EsseyPool.accrue()`, where an instantaneous borrow-asset pause discarded the whole elapsed interval. The test named for the property passed identically against the defect and against the fix |
| [G-LEND 9](glend-round-9.md) | same surface at `1bc9ec7` | 0 CRIT / 0 HIGH / 0 MED, **2 LOW**, 8 INFO | **not clean; counter stays at zero.** LOW-1: the round-8 fix's two-endpoint rule forgives an unbounded interval, so two unrelated pause instants erase everything between them — and the shipped test goes red on the correct fix. LOW-2: the activation register says the liveness pager runs; nothing is installed. Both round-8 carry-forwards (`X-P`, `EsseyMarkets:525`) **resolved to no finding**, X-P refuted outright |

**Game-era vs protocol.** The **Market layer 1–6** rounds cover the D.O.N. **game / market layer**
(Seats/Bell/Cases/Exchange/Notes/art) — the contract lineage of the gamification wing. The **$ESSEY
launch-hook gate** is the **protocol base layer** — the fee model that accretes the adminless equity
reserve ([BASE-LAYER.md](../BASE-LAYER.md)). The [Solidity 1–2] rounds are the lending-engine port.

Round 2 (Solidity) has no separate file: its findings are corrections to round 1 and are folded into
that report. It is listed separately here because the round-1 document, read alone, states a
mutation-coverage claim that round 2 disproved by a factor of 50 — including that `MIN_RISK_GAP_BPS` and
`PARAM_TIMELOCK`, the two constants we cite publicly as controls, can both be halved with every test
passing. Anyone auditing us should know that before trusting round 1's coverage section.

## Method

Each round runs three auditors over different surfaces, then two verifiers per finding — one
instructed to **refute**, one to **reproduce**. Verifiers write and run real PoCs (Move tests,
Foundry tests, on-chain `eth_call`) rather than reasoning. Roughly a third of initial findings do
not survive.

Alongside every round we mutation-test guards: delete the guard, and a test must fail. We have
twice claimed "all guards mutation-verified" and been wrong both times — first by only mutating
guards we had already written tests for (circular), then by using a sweep script that matched
`if (...) revert` and was structurally blind to early-return guards, reporting 1 survivor where an
independent sweep of 139 mutations found 50. A passing suite is necessary and nowhere near
sufficient, and our own coverage claims are the thing to check hardest.
