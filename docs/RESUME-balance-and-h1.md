# RESUME — trait magnitude + H-1 (start here in a fresh session)

Written 2026-08-15, superseding `RESUME-trait-calibration.md` (that doc's "one job" is done — the
economist ran, and its answer is folded in below). Everything here was verified on chain, by running
it, or by reading the source at the cited line. Where something is unresolved it says so.

## The founder's actual goal, in his words

> "I want the juice to be worth the squeeze on attacking."

Not economic solvency, and **not** per-budget fairness. The goal is a felt back-and-forth: a player
who builds offense feels it, a player who builds defense feels it, and neither dominates. Exact
parity is explicitly NOT required — "it's not so fair" that matters, it's that both levers are real.

**Scrip-denominated analysis is out of scope.** It gets thrown out when live assets land. Do not
re-derive hopper EV, break-even thresholds, or PvP rake — the founder ruled those disposable.

## The ruling: a maxed build is worth about ±10 points

At the reference fight — one hitter (`A = 50`, `RaidEngine.sol:93`) vs a bare Safehouse
(`D = 40`, `HouseDeed.sol:66`, confirmed on chain via `tierStats(0)`) — the baseline is 40.0%.

| | target |
|---|---|
| maxed attacker vs plain defender | 40% → ~50% |
| plain attacker vs maxed defender | 40% → ~30% |
| **maxed vs maxed** | **exactly 40%** |

**The last row is structural, not tuned.** `p_hit = 0.72 × A/(A+D)` (`RaidEngine.sol:85-87`). If
offense multiplies A by k and defense multiplies D by the same k, k cancels top and bottom and the
odds return exactly to baseline — **at every crew size and every house tier, forever**. No
simulation, no re-tuning when a tier-2 House ships.

So the design law is one line:

> **Every offensive trait is a percentage of attack power. Every defensive trait is a percentage of
> defense power. The two caps are equal.**

This also resolves the gender split without touching it. The founder confirmed male-offense /
female-defense is **intended design** ("we did have the idea that females boost defense") — 100% of
the 4,444 males roll `hdBps = 0`. Under equal percentage caps a maxed male and a maxed female cancel
exactly, so the specialization survives and the imbalance does not. **Do not file the gender split
as a defect again.**

### Concretely

| Constant | file:line | Now | Target |
|---|---|---|---|
| `RP_CAP` | `AffinityTraits.sol:56` | 800 (+8% A) | **8000 (+80% A)** |
| `HD_PCT_CAP` | `AffinityTraits.sol:57` | 1500 (+15% D) | **8000 (+80% D)** |
| `HD_FLAT_CAP` | `AffinityTraits.sol:58` | 40 raw points | **re-denominate, see below** |

k = 1.8 yields +9.9pp / −10.5pp at the reference and exact neutrality head-to-head. Effect ranges
~6–10pp across crew sizes because the curve flattens near `P_MAX_PPM = 700_000`; that spread is
irreducible and fine.

`RP_ODDS_PER_PCT = 15` and `HD_ODDS_PER_PCT = 16` (`AffinityRegistry.sol:81-82`) were measured at
parity already (2.1× vs 2.0× efficiency spread) — **leave them alone**.

### The `hdFlat` bug — fix this or the law does not hold

`AffinityRegistry.sol:83-86` declares `REF_DEFENSE = 200` with a comment stating a flat point is
"0.5% of D". **`grep -rn REF_DEFENSE rh-chain/src rh-chain/test` returns exactly one hit — the
declaration.** The price table was written fraction-denominated; the code applies raw points at
`AffinityRegistry.sol:215`, `AffinityRegistry.sol:344`, and `RaidEngine.sol:294`. That is the entire
root cause of defense out-leveraging offense.

Fix: `hdEff = hdBps + hdFlat·50` (additive, 1 point = 50 bps of the defender's own D). Additive over
compound costs 0.22pp at the extreme and **deletes the flat-then-percent ordering question entirely**
— which is unpinned by any test today, so this removes a gap rather than documenting one.

## Order of work, and why

1. **Constants + `hdFlat` as a percentage.** Smallest self-contained unit, lands committable alone.
2. **Pin defense with tests.** Not optional — see H-2 below. Today you could delete `hdFlat`
   entirely and all 161 tests stay green, so nothing would catch an error in step 1.
3. **Fix H-1.** Biggest piece, and it **must land with or before step 1** — see the interaction.
4. **Fresh stack + re-attest + re-point site/MCP/keeper.**

### The interaction that forces the ordering

H-1 lets a defender see a raid's outcome and escape if it's a hit. Its value scales with how much
they are protecting. **Turning defense up from ±1pt to ±10pt makes the free escape roughly ten times
more attractive.** Shipping step 1 without step 3 makes the exploit materially worse. Estimated,
not measured — nobody has modelled the two together.

## H-1, the one exploitable-today finding

Independent audit, 2026-08-15, on `ffee713`. Full detail is in that session; the mechanism:

- `entropyCallback` (`RaidEngine.sol:377-385`) stores the roll **without settling** when the garrison
  is unrevealed, and `raids` is a public mapping — the word is world-readable immediately.
- `floorSettle` is blocked until `revealedAt + GARRISON_TIMEOUT` (1h, `RaidEngine.sol:79`), so any
  junk `garrisonHash` buys a guaranteed hour between "outcome public" and "outcome applies".
- Inside that hour the defender calls `MissionBoard.resolve`/`reclaim` (both permissionless) to come
  home, then `bank()`s everything. `_settle` never re-checks the away window.
- Attacker takes 0. `damageBaseDeployed = deployedOf` after banking is 0, so repair is free too.

Strict free option — reveal is weakly better on a miss, escape strictly better on a hit. Three PoCs
were written, run green against the real stack, and deleted.

**Preferred fix:** request entropy *after* the garrison window closes, not at reveal. Nobody ever
sees a word before the defense is fixed, and settlement becomes one tx no player controls.
**Minimal alternative:** snapshot `hopperOf`/`deployedOf` into the `Raid` struct at reveal and settle
against `min(snapshot, live)`. **Do not gate `bank()`** — that breaks the exits law.

## Other audit findings, ranked

- **H-2 — the defensive trait wiring is unpinned.** Six adversarial mutations of `_withDefense`
  (`RaidEngine.sol:287-300`) survive all 161 tests: flat/percent ordering swapped, `hdFlat` deleted,
  `hdFlat`↔`hdBps` swapped, CMD deleted, CMD applied to the whole House, `cmdGarrisonBps`→`nrvBps`.
  Root cause: the only defender-side test (`GameRaid.t.sol:523-527`) uses an **unattested** Don, so
  it asserts a value every mutant also produces. The math itself is correct — engine and
  `previewDuel` both return 152,745,000 on a live defensive sheet. This is coverage, not a live bug.
- **M-1** — deleting `if (m.settled) revert` from `MissionBoard.reclaim` (`:407`) survives 161 tests;
  that guard is the only thing preventing repeated `scrip.mint`.
- **M-2** — 8h raid immunity is purchasable for ~50 Scrip via an alt Don; ~$1.50/day for round-the-
  clock cover. The L-1 heat fix has no regression test.
- **M-4** — "adminless over funds" does not hold: a re-pointed module after the 2-day timelock can
  drain vaults; `close()` is instant and has no reopen path.
- `previewDuel` advertises petrify lockouts to 72h while `HitterNFT.hospitalize` (`:193-196`)
  hardcodes 48h — **the site and MCP quote numbers the chain will not honor.**

## UNRESOLVED — do not act on this until settled

The two agents contradict each other, and neither saw the other's work:

- **Auditor H-3:** inert stats (`cmdFactionBps`, `lckBps` — charged by `edgeOf` at
  `AffinityRegistry.sol:182-186`, read by no deployed engine) dilute live stats through the
  proportional `_clamp`, costing ~1.9pp of defensive odds. Its worked example uses a sheet at edge
  **1380**.
- **Economist:** running the real resolver over all 8,888 Dons, max realized edge is **808 of 1000,
  and 0 of 8,888 clamp.**

If the economist is right, `_clamp` never fires on a mintable Don and H-3 has zero practical effect —
the mispricing is real in the design and inert in the collection. **Settle this by re-deriving
`edgeOf` over the collection independently before changing `edgeOf`.** Note the caps change in step 1
will move realized edge, so re-derive *after* picking the new numbers.

Related: the Edge Budget law is written per-Don, but a player runs a stable — the optimal build is a
shopping list (offense male + defense female), which under the founder's intended specialization is
the *intended* play pattern, not an exploit. The law may need restating at the player level.

## Deploy mechanics — verified 2026-08-15, this is the shipping constraint

- The caps and odds weights are `internal constant` (`AffinityTraits.sol:56-60`,
  `AffinityRegistry.sol:81-86`) → changing them needs **new bytecode**.
- `affinity` is `immutable` in **both** engines (`RaidEngine.sol:91`, `MissionBoard.sol:88`, set in
  constructor) → a new registry means **new RaidEngine and new MissionBoard too**.
- Re-pointing a **sealed** stack costs `TIMELOCK = 2 days` (`GameController.sol:22`, queue→execute).
- **But `setModule` is instant while unsealed** (`GameController.sol:85-92`) → **a fresh throwaway
  stack goes up same-day with no timelock.** This is the path; it is the same move made on 08-15.
- `oddsBudgetBps` IS settable (`ODDS_BUDGET_MIN 200` / `MAX 1000`) but **cannot scale magnitude up** —
  it is a ceiling on spend, and at 808/1000 realized it is not binding. Do not reach for it.
- A new registry starts with empty `_sheet` → **re-attest all ~147 minted Dons**
  (`AFFINITY=0x… ./attest-dons.sh 1 150`). Unattested Dons read a zero sheet and play at published
  odds, so testing can begin before attestation finishes.

## Safe to test RIGHT NOW on the live stack

The site is healthy and the game loop works. Missions, banking, deploys, Houses, Hitters, the UI and
the MCP are all unaffected by everything above. Two caveats for anyone collecting feedback:

1. **Do not collect trait feedback.** A maxed offensive sheet currently moves the odds ~1pt. Testers
   will correctly report that traits do nothing, which is already known and already being fixed.
2. **H-1 is live.** If a tester finds the escape, raiding will feel broken. Testnet is play money and
   nothing is at risk, but know it before reading the feedback.

## Site deploy — read this before deploying anything

Production is **CLI-deploy-only**, from the **repo root** (`vercel --prod --yes`; the Vercel Root
Directory is `app/web`, so running from inside it fails). `app/web/public/{traits,builder}` are
gitignored, so a git-sourced build ships an art-less site that returns healthy 200s.
`git.deploymentEnabled: {main: false}` now prevents that (`1255bc2`, verified — the push created no
deployment). **After every deploy run `./app/web/check-deploy-assets.sh`** (`07d8d17`, unpushed) — it
asserts content type, not status code, and was verified red against the build that broke production.

## First commands in a fresh session

```bash
cd /Users/erikastramecki/Developer/assay
git log --oneline -3          # 07d8d17 asset check, 1255bc2 deploy fix, ffee713 save point
forge test --match-path "rh-chain/test/Game*"   # expect 110 passing
grep -rn "REF_DEFENSE" rh-chain/src rh-chain/test   # expect 1 hit: the declaration
```
