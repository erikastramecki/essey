# RESUME — trait calibration (start here in a fresh session)

Written 2026-08-15 at the end of a long session. Everything below was verified on chain or by running
it, not recalled. Where something is unverified it says so.

## The one job

**Run `don-economist` on trait balance.** Nobody has ever run the trait sheet through the raid odds
curve. The founder did the arithmetic by hand and found offense is nearly inert while defense is
decisive. That finding is confirmed and explained below — it needs weighted scenarios, then a
calibration decision, then a fix.

## The finding, with the arithmetic that produced it

`p_hit = clamp(0.72 × A/(A+D), 5%, 70%)` — RaidEngine.sol header.
One L1 hitter is `A = 50`; a Safehouse is `D = 40` (AffinityRegistry.referenceGarrison).
Baseline **40.0%**.

| Sheet | Effect | p_hit | Δ |
|---|---|---|---|
| none | — | 40.0% | — |
| maxed offence, `RP_CAP = 800` | +8% of A: 50→54 | 41.4% | **+1.4pp** |
| maxed defence, `HD_FLAT_CAP = 40` then `HD_PCT_CAP = 1500` | (40+40)×1.15 = 92 | 25.4% | **−14.6pp** |

**Root cause: `hdFlat` is denominated in raw defence POINTS and a Safehouse only has 40 of them**, so
a maxed defensive sheet doubles a starter house before the percentage even applies. Offence is capped
at a percentage of attack power. The two stats are not in the same units of leverage.

**Per unit of Edge Budget it is worse.** `AffinityRegistry.edgeOf` charges `RP_ODDS_PER_PCT = 15` per
percent and `HD_FLAT_ODDS = 8` per point. Maxed RP costs 120 bps of the 1000 budget to buy +1.4pp;
maxed hdFlat costs 320 bps to buy roughly −12pp. **hdFlat returns about 9× the effect per budget
spent.** The Edge Budget accounting is internally consistent; its weights were simply never checked
against the actual curve at Safehouse scale.

## What the economist needs to answer

1. Weighted scenarios across real house tiers (Safehouse 40/2, Row House 60/3) and crew sizes 1–5 —
   what does each stat actually buy in pp, per unit of Edge Budget?
2. Is the right fix recalibrating `HD_FLAT_CAP` / `HD_FLAT_ODDS`, expressing hdFlat as a fraction of
   house defence rather than absolute points, or something else?
3. Does the Edge Budget law survive the fix — a rarer Don must shift WHERE its edge sits, never how
   much it has. Today it does not: defensive sheets are strictly stronger.
4. Turtling equilibrium: if defence dominates, does anyone raid at all? What does that do to the
   PvP rake the economy depends on?

**Do not skip:** this must go through the p_hit curve numerically. Qualitative reasoning is what
missed it the first time.

## Decision waiting on that output

I recommended, and the founder has NOT yet ruled on it:

- **Ship missions trait-live** — NRV is a direct pp shift on a published ladder, symmetric,
  budget-accurate, mutation-tested. No leverage problem.
- **Revert raids to trait-blind** until calibrated — one line, pass `address(0)` as RaidEngine's
  registry in the deploy. Raids are currently trait-LIVE on testnet with the imbalance above.

Testnet is play money and no testers have been invited, so leaving it live is survivable; it is left
live deliberately so the economist can measure the real deployed system.

## State of the world (all verified)

Traits-live stack, RH testnet 46630, deployed 2026-08-15:

| Contract | Address |
|---|---|
| GameController | `0x9Bcdbe576347eD8666f125072210cc340492a203` |
| Scrip | `0x31D04bd5b1c1eAE56698F1A90C3fEe3e590f6E93` |
| HouseDeed | `0x689dF249cEFF6e28d3EB7dDE125CEa7f7f29700d` |
| HouseEscrow | `0x24cB6Db8F4d52d78742bc0304B08710B053cdB7e` |
| MissionBoard (reads NRV) | `0x15D607638BeEcF9d62E6eC00a37601A89E72CDF1` |
| RaidEngine (reads RP/HD/CMD) | `0xc4B372ff6b3c2Ba511FB8Affa54f88F3Bdc1b2f6` |
| HitterNFT | `0x5C714163454D525906Ab6273d1cec701A5399103` |
| AffinityRegistry | `0x2d9CC510D464977F0Eb597237F467b453CB3e484` |

Verified by `cast call`, not from the broadcast log: both engines return the registry address, and
both bind the LIVE collection `0x582E4B8E3A783B1FE09409AEDa3C6533782dB53c` — no Don moved, holders
keep art, sheets and AMM position. Abandoned on the old 2026-08-13 stack: Scrip, deeds, garrisons,
in-flight missions.

- **110 game tests pass.** The two load-bearing ones are mutation-verified: neutering the NRV shift
  turns the mission flip test red (14.4 != 36); dropping the RP multiplier turns the raid test red
  (50000000 <= 50000000). Each has an opposite-direction twin so neither passes for the wrong reason.
- **Faucet**: 500,000 $ESSEY / 8h (raised from 100k, which could not buy a 336k Don). ~197 drips of
  runway at `0x90312b383Eac08E691c851a7ef866f106E6d9d7d` — **top up before a real test weekend.**
- **MCP**: 8 tools, zero-config testnet defaults, `don_sheet` live. Verified over the real protocol.

## Open items, none started

1. **Browser click-through of the game on the new stack.** NOT done. Contract and MCP reads are
   verified; the browser path is not.
2. **Attestation is incomplete.** ~111 Dons attested; roughly 29 report "no preimage" from the
   script even though `/api/don/:id` demonstrably returns one for them (checked #30, #90, #139). The
   script now retries (`--retry 4 -m 25`) and retries nonce races; **re-run it and re-check**:
   `AFFINITY=0x2d9CC510D464977F0Eb597237F467b453CB3e484 ./attest-dons.sh 1 145`
   An unattested Don is not broken — it reads a zero sheet and plays at published odds.
3. **Independent audit of settlement math.** The three rounds on commit 8ebeaa1 were SINGLE-REVIEWER
   (agent budget was exhausted at 200/200). This is the highest-stakes code in the game and deserves
   `essey-auditor` before real testers.
4. **`script/GameE2E.s.sol` fails `forge build` with "stack too deep."** Verified PRE-EXISTING by
   stashing. `forge test` unaffected.
5. **Merge to main as a save point.** Founder wants this; main is ~100 commits behind, which is why
   GitHub looks dead. Needs explicit per-instance authorization — the guard hook blocks pushes to
   main unless the founder says "push" in that same turn.
6. **`cmdGarrisonBps` and `hdFlat` ordering** are exercised but not isolated by any test.

## First commands in the fresh session

```bash
cd /Users/erikastramecki/Developer/assay
git log --oneline -5          # 87c7433 is the traits-live re-point
forge test --match-path "test/Game*"   # expect 110 passing
```

Then spawn `don-economist` with the four questions above.
