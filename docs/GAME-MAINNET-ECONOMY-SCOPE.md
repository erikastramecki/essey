# D.O.N. — Mainnet Economy Scope: the transition to REAL stock settlement

**Status:** internal economist scope. Technical only. Analysis + simulation — no contract
changes, no deploy, no commit made producing this doc.
**Date:** 2026-08-30
**Author:** game economist
**Grounding rule:** every mechanism claim below carries a `file:line` (paths under
`rh-chain/`) or a named memory/sim. Where a claim is inferred, it is labelled. All solvency
math is in **stock SHARES (units)**, which is oracle-free by construction; dollar figures are
display marks only and are **not load-bearing** (see §0).

---

## 0. The one idea that governs everything

Every value-emitting sink in the deployed game is **worst-case reserved or inventory-backed
BEFORE the roll**, so the protocol can never owe more than it holds. When it cannot reserve the
worst case, it **reverts** — it does not overpay:

| Sink | Reservation / backing guard | Cite |
|---|---|---|
| Degen gacha | reserves the 50× top tier in shares per open; reverts `InsufficientBankroll` | `EsseyCasesDegen.sol:219-221` |
| Fair-value case | `buy()` reverts `NoBackingInventory` unless a real unit backs every unopened case | `EsseyCases.sol:253` |
| Missions | reserves best outcome from `missionBudget` at depart; reverts `InsufficientBudget` | `MissionBoard.sol:280-283` |
| Bell distribution | pays only `reward.balanceOf(this) − reserved`; accumulator, fails open | `Bell.sol:145-147, 329-342` |
| Don floor | pays `reserve()/backedSupply`, monotone, adminless | `DonReserve.sol:80` |

**Consequence that reframes the founder's whole question:** the seed size never sets
*solvency* — the reservation law makes insolvency inexpressible. The seed sets only the
**stall probability** (how often a sink reverts because its float is too thin). "How much
stock to seed" is therefore a working-capital / variance question, not a "can it go bust"
question. This is the vault-sacred + worst-case-reservation law doing exactly its job.

Because reservation is counted in **shares, not dollars**, the AAPL price is irrelevant to
solvency — a `−50%` AAPL crash changes what a payout is *worth*, never whether the contract can
*make* it (it always can; it reserved the units). Confirmed as the design intent in
[[essey-combined-tokenomics-design]] ("redeems for the UNITS that exist, never a dollar figure
… unconditionally solvent"). I therefore quote seeds in shares and mark dollars as `≈` only.

---

## 1. Executive summary

- **RTP is correct where it's a house game, and fatal where it's a faucet.** The degen gacha is
  a clean **89.6% RTP** house-edge machine (`EsseyCasesDegen.sol` ladder, verified). Mission
  *provision* legs are a clean **90.0% RTP** by construction (`MissionBoard.sol:49`,
  `DeployGame.s.sol:161`). But the mission **base leg is 100% subsidy** — it MINTS the payout
  (`MissionBoard.sol:422-425`), and `MILK RUN` pays EV 5,944.8 for a fee of 1 (**≈594,000%
  RTP**, `DeployGame.s.sol:184`). Scrip can be minted; **AAPL cannot.** In real stock the base
  leg is a pure inventory drain, and the faucet briefs are catastrophic. They must not exist on
  the mainnet board — already flagged strip-before-real in `DeployGame.s.sol:182-185`, and
  confirmed as the live-chain leak in [[essey-game-milkrun-and-dead-raids]].
- **Recommended initial seed is SMALL and the founder's instinct is right** — but only after two
  calibration changes. As shipped, the degen case reserves **25 AAPL per open** (50× × 0.5 AAPL
  reference), so a "small" seed can't run one open. Shrink the reference to **0.02 AAPL** and cap
  the top tier **50×→10×**, and a **2–5 AAPL seed (≈$0.5–1.2k)** runs 2,000 opens at ~0% stall
  (§4 sim). Missions on the provision-only model need **no subsidy seed at all** (they are +10%
  house-positive); a fixed-unit tranche subsidy, if kept, is a **sub-1-share/day** bleed at pilot
  scale.
- **Funding structure: a dedicated, add-only game bankroll per spendable sink, fed by a
  fee→buy-stock→seed loop — separate from the vault-sacred floor.** The bankroll pattern already
  exists (`EsseyCasesDegen.seedReserve` / `EsseyCases.seedUnits` / `fundBuyback` — add-only, **no
  withdraw path**). The **missing wire** is that the case price routes to *treasury*, not the
  bankroll (`EsseyCasesDegen.sol:223`), so the reserve bleeds and never refills itself. Close that
  loop and the game is self-contained at the edge. Keep it structurally distinct from
  `DonReserve` / `EsseyReserve` (the adminless floor), per the ruled **unified intake, separate
  sinks** ([[essey-mainnet-launch-flr-seed]]).
- **Shielded winnings are economics-neutral and need NO payout-contract change.** The founder's
  demo — small seed → players win small stock → paid out SHIELDED — wires as a downstream relayer
  step, not a routing config on Bell/Cases/mission: a shielded deposit requires the recipient's
  own zk proof (`EsseyShieldedStock.sol:124-138`), which a payout contract cannot produce.
  Shielding is 1:1 backed and value-conservative, so it changes no RTP, no house edge, and does
  not raise the seed (§5d). It adds a relayer-fee haircut on the player and inherits the
  issuer-burn pro-rata haircut (founder-accepted). Wiring belongs to `SHIELDED-GAME-DEMO-PLAN.md`.
- **Top solvency risk is NOT insolvency (the law forbids it) — it is a MISPRICED PLAY becoming a
  real-stock faucet.** The degen case is priced at **100 $ESSEY** (`RedeployDegen.s.sol:30`), and
  $ESSEY launches at **$0.0000281** ([[essey-liquidity-launch-plan]], batch 8). 100 $ESSEY ≈
  $0.0028 buys an expected **0.448 AAPL (≈$100)** payout. That is a **~36,000× value RTP** — the
  MILK RUN failure mode wearing the gacha's clothes. Denominate the *price* in the payout asset's
  value, not in a token that launches at ~$0.

---

## 2. The four sinks, and who funds whom

| Lane | Who pays whom | Mints? | Solvency | Needs a seed? |
|---|---|---|---|---|
| **PvP raids** | player → player, protocol rakes 7.5% | never (`HouseEscrow.sol:257-258`) | zero-sum transfer; structurally solvent | **No** |
| **Bell distribution** | fees → staked Dons as stock | no (pays balance only) | accumulator, fails open (`Bell.sol:329-342`) | **No** (fee-funded) |
| **Job-Desk gacha** | player stake → house edge → player | no (reserve-backed) | worst-case reserved (`:219-221`) | **Yes — the bankroll float** |
| **Missions** | protocol → player (base) + provision gamble | **YES today** (`:422-425`) | budget-reserved (`:280-283`) | base=yes (subsidy); provision=no |

This is the batch-18/19 **two-lane** ruling made concrete: *PvP = a rake, no house edge; Job
Desk = the paid gacha, house edge lives here* (decision sheet lines 616-639). The economist
verdict that **F1 dissolves** under this reframe is confirmed independently by the Bell
accumulator identity `accPerWeight += distributed/totalWeight` (`Bell.sol:277-284`) — the
protocol distributes what it *collected*, never a promised best case, so the −9.6% structural
drift and the 99.5%-blocked-dispatch failure mode cannot occur in the PvP + Bell path.

**What actually changes at the real-stock transition** is confined to the two lanes that pay
from a pool: the gacha bankroll and any mission subsidy. Everything else (raids, Bell, the
floor) is already denominated in a settable token address (`MissionBoard.sol:80`,
`RaidEngine.sol:58`, `Bell.sol:36-37`, `DonReserve.sol:30-31`) and needs configuration, not
redesign — the Scrip-removal rule ([[essey-scrip-removed]]) is already satisfied at the type
level; the deploy script is the only place `Scrip` is hardcoded.

---

## 3. RTP / house-edge / EV / variance findings

### 3a. Degen gacha (`EsseyCasesDegen.sol`) — the house-edge machine

Deployed ladder (`RedeployDegen.s.sol:40-51`), reference = 0.5 AAPL:

| Tier | multiple | band prob | payout (AAPL) | RTP contribution |
|---|---|---|---|---|
| 0 | 0.65× | 0.840 | 0.325 | 0.5460 |
| 1 | 1× | 0.105 | 0.500 | 0.1050 |
| 2 | 2× | 0.040 | 1.000 | 0.0800 |
| 3 | 5× | 0.013 | 2.500 | 0.0650 |
| 4 | 50× | 0.002 | 25.000 | 0.1000 |
| | | | **RTP** | **0.8960** |

- **House edge = +10.4%** in share terms. Clean, matches header (`:38`). EV/open = 0.448 AAPL.
- **Variance is jackpot-dominated:** the 50× tier is 0.2% of opens but **11.2% of all RTP**. A
  player's realized return is 84% likely to be the 0.65× loss; the top tier is the entire
  advertised upside.
- **Capital-efficiency problem (load-bearing for seeding):** worst-case reservation is
  `50 × reference = 25 AAPL` per open (`:219`), while E[payout] is 0.448 AAPL — **the reserve
  locks 56× its own expected draw.** The 50× tier costs one ninth of the RTP but sets the entire
  seed requirement. This is the single biggest lever on "small seed" (§4).
- **Refill gap:** case price (100 $ESSEY) sinks to **treasury** (`:223`); the AAPL reserve is
  refilled ONLY by add-only `seedReserve` (`:205-210`). Nothing routes the price back into the
  reserve, so absent an ops loop the bankroll is a pure drain (§4 Scenario A).

### 3b. Fair-value case (`EsseyCases.sol`) — no seed risk

Uniform "which stock" draw, no multiplier (`:279-285`); edge is only the **5% sell-back spread**
(`spreadBps=500`, `RedeployCases.s.sol:36`). Inventory-backed (`:253`). No jackpot, no variance
tail, no bankroll drain beyond the spread. Solvent by construction; not a seeding concern.

### 3c. Missions (`MissionBoard.sol`) — base leg is the problem, provision leg is fine

Production briefs (strip faucets 5, 6), base-leg EV and provision RTP verified:

| Brief | base EV (Scrip) | provision RTP | worst-case reserve | Cite |
|---|---|---|---|---|
| PAPER ROUTE | 30.24 | 0.900 | 1.154 × P | `DeployGame.s.sol:165` |
| GLASS HARVEST | 57.9 | 0.900 | 1.286 × P | `:167` |
| PROOF OF WORK | 162.37 | 0.900 | 1.500 × P | `:169` |
| ABSOLUTE ZERO | 384.06 | 0.900 | 7.500 × P | `:172` |
| DEEP RUN | 106.8 | 0.108 | 0.900 × P | `:188` |
| ~~MILK RUN~~ | ~~5,944.8~~ | — | faucet | `:184` **strip** |
| ~~OPEN WINDOW~~ | ~~99.08~~ | — | faucet | `:185` **strip** |

- **Base leg is a 100% subsidy** — fee is 1.5% of EV, payout is minted (`:422-425`). In Scrip
  that is deliberate faucet economics; **in AAPL it is a straight inventory drain** and cannot be
  minted. Two honest options for mainnet:
  1. **Provision-only missions** (remove the base leg): every brief becomes **+10% house edge,
     self-funding, needs no subsidy seed.** The mission is then a pure provision gamble (stake P
     real units, get 0.9×P back in expectation). Cleanest; collapses missions into the same
     house-edge shape as the gacha.
  2. **Fixed-unit tranche subsidy** (the V2 `AssetPaymaster` design, `DON-V2-REAL-ASSET-PAYOUTS.md`
     §2c): keep a real-stock "take" as a *worst-case-reserved, pre-acquired* tranche. Solvent, but
     it is a subsidy that must be seeded and refilled from fees (leg A).
- **DEEP RUN is already the template for real-loss provisioning** (RTP 0.108) — a sanctioned
  −EV lottery brief; it survives the transition unchanged.

### 3d. Raids (`RaidEngine.sol`) — zero-sum, no protocol exposure

Pure PvP: `scrip.move(target→attacker, taken−tax)`, `scrip.burn(tax)` (`HouseEscrow.sol:257-258`).
Never mints. `pHit = clamp(0.72·A/(A+D), 5%, 70%)` (`:432-434`); big-tier slice
`1500+1500·u²` bps, hard-capped 30% (`HouseEscrow.sol:276`); 7.5% hit tax (`:52`).

**Real-stock transition delta:** the 7.5% tax and the 50-commit fee are **burned** today
(`RaidEngine.sol:250`); the ruled law is **route, don't burn** real assets (decision sheet
lines 312-320, [[essey-scrip-removed]]). At mainnet these reclassify to routed revenue legs
(Book/treasury), not burns — a fee-matrix config, not a mechanism change.

**Known mis-calibration to carry forward, not re-litigate:** trait weights are wrong — a maxed
offensive sheet moves raid odds ~+1.4pp while a maxed defensive sheet moves them ~−14.6pp
(defence ~9× offence per Edge-Budget unit), [[essey-trait-balance-broken]]. This is a **PvP
competitive-balance** bug, not a solvency bug (raids are zero-sum), so it does not gate the
mainnet economy — but it should ride the same V2 board redeploy that fixes the faucets.

---

## 4. Recommended initial seed + rating calibration

All figures from `scratchpad/degen_seed.py` and `scratchpad/mission_pilot.py` (4,000-trial Monte
Carlo). "Stall" = a `revert` because the float can't reserve the worst case — the protocol is
never in the red; play simply pauses until reseed.

### 4a. Degen gacha seed — the shipped 50× ladder is capital-hostile

| Ladder | worst-case reserve / open | seed for ~0% stall @ 2,000 opens (price value-matched refill) |
|---|---|---|
| **Shipped (50× top, ref 0.5 AAPL)** | 25 AAPL | ~250 AAPL (≈$57k) — Scenario B |
| **10×-capped, ref 0.5 AAPL** | 5 AAPL | ~50 AAPL (≈$11.5k) — Scenario C |
| **10×-capped, ref 0.02 AAPL** | 0.2 AAPL | **2–5 AAPL (≈$0.5–1.2k)** — pilot sim |

**Recommendation: cap the top tier 50×→10× and set reference ≈ 0.02 AAPL.** This is a **~125×
reduction in seed** for the same stall protection. The 50× tier is glamorous but it is the entire
reason the seed is large; a 10× top still gives a 500× headline in $ESSEY-value terms and an RTP
you re-tune to any target (a 10×-cap ladder simulates at 0.816 RTP as-is; redistribute the freed
0.2% band to lift it back to ~0.90 if desired).

### 4b. Missions

- **Provision-only model: seed = 0** (house-positive). Strongly recommended for a small launch.
- **Fixed-unit tranche model:** peak reservation = `N × successUnits`. At a 15-Don pilot with
  `successUnits = 0.01 AAPL`, peak reservation is **0.15 AAPL** and the subsidy bleed is **~1
  share/day** — trivially seedable, but it *is* a bleed that the fee loop must cover, so prefer
  provision-only unless the "real take" narrative is wanted.

### 4c. Rating calibration (the price is the real dial)

- **Denominate the play price in the payout asset's value, never in raw $ESSEY.** House edge is
  `1 − RTP` **only if price-value ≈ reference-value.** At 100 $ESSEY (≈$0.0028) for a 0.5-AAPL
  reference (≈$115), the value RTP is ~36,000%, not 89.6% — a faucet. Fix: price the open at
  ~`reference_value / RTP` in USDG (or in $ESSEY quoted off an oracle), so the edge is real.
- **Rake each WIN, not the session** — netting collapses the 10% edge to ~1.6% (decision sheet
  line 795, winnings-cut verdict). If a winnings-rake replaces the ante edge, `c = edge · m/(m−1)`:
  a **12.5% rake at ×5 ≡ 90% RTP**, and the loser pays only their stake.
- **Keep flat 90% provision RTP** (ruled B23, decision sheet line 96) for launch; tier later.
- **Jackpot tiers must honour ZERO trait edge** (F3/F4, decision sheet line 542): a reachable
  max-edge sheet takes a fixed-multiplier jackpot to 123.7% RTP. In the gacha this is closed by
  the pool-relative-jackpot ruling; enforce it on any mission jackpot too.

---

## 5. Funding structure — the concrete recommendation

**Answer to "is the game a self-contained economy?": yes at the edge, no at the base.** The
house edges (gacha +10.4%, provision +10%, raid rake) and fees *accrete*; any *subsidy* (mission
base leg, faucets) is founder-funded drain that never self-replenishes. Remove the subsidy and
the game self-funds; keep a seed only as a **variance float**, not a fuel tank.

### 5a. One vault or a contract? — a dedicated add-only bankroll contract per spendable sink

Not a single wallet. The shipped bankroll pattern is already the right shape and should be the
mainnet structure:

- **Add-only, no withdraw path** (`EsseyCasesDegen.seedReserve :205-210`,
  `EsseyCases.seedUnits :230-240`, `fundBuyback :243-246`). A plain wallet can be drained; these
  cannot — the stock goes in and only leaves as a player payout. This *is* the "dedicated game
  vault" the founder wants, and it already exists per sink.
- **Keep the game bankroll structurally separate from the floor.** `DonReserve` ($ESSEY,
  adminless, monotone, `:80`) and `EsseyReserve` (equity basket, adminless, 5% exit fee,
  [[essey-base-layer-equity-peg]]) are **vault-sacred** — never a payout source for the game.
  This is the ruled **unified intake, separate sinks**: floor → `DonReserve.fund()` (unspendable),
  gameplay → bankroll / Bell / mission budget (spendable) ([[essey-mainnet-launch-flr-seed]]).

### 5b. The fee→sink wiring (what to build)

The **one missing wire** is the loop that makes the bankroll self-refilling:

```
play price (USDG / $ESSEY)  ──today──▶  treasury          (EsseyCasesDegen.sol:223)
                            ──add ───▶  buy payoutStock  ──▶  seedReserve(bankroll)
```

- **Route a fixed fraction of the play price (or of treasury proceeds) into buying the payout
  stock and calling `seedReserve`.** At +10.4% edge with the price value-matched, routing ≥89.6%
  of price-value back into the reserve keeps it flat-to-rising; the +10.4% is the house's, which
  splits to treasury / floor / insurance per the ruled legs.
- **Bell already closes its own loop** (`DonFeeRouter` → USDG → Bell pot → stock to Dons,
  `DonFeeRouter.sol:199-203`). No change needed; it is fee-funded and self-solvent.
- **Mint fees already flow** (`DonDistributor._splitFee`, `teamBps=0` → 100% to feeSink → Bell,
  `DonDistributor.sol:216-230`). If missions keep a tranche subsidy, add a leg here (or from the
  gacha price loop) to fund `AssetPaymaster` — do NOT let the tranche outrun leg-A inflow (that is
  the F1 arithmetic; at 60/20/10/10 only 60% of a 1.5% fee funds tranches, decision sheet line
  546). Provision-only missions dodge this entirely.

### 5c. Replenishment model + insolvency guardrails

- **Replenishment = the +10% edge loop above.** Steady state, the bankroll drifts UP (Scenario B:
  end-bankroll > seed at every seed size). The founder funds only the **initial float** plus any
  subsidy bleed; the edge does the rest.
- **Guardrail 1 (structural, already present):** worst-case reservation → the protocol reverts,
  never overpays (§0). No insurance needed to prevent insolvency; it is impossible.
- **Guardrail 2 (variance float):** size the seed to the §4 stall table for the target concurrency.
  Reseed is a LOUD add-only event; watch `freeReserve()` (`:194-196`) as the dashboard line.
- **Guardrail 3 (insurance fund):** the Fixer's Book is over-funded **3.2×** by its four legs
  (premiums + hit-tax + all-tx skim + treasury seed) before premiums (decision sheet line 561,
  [[essey-combined-tokenomics-design]] cross-check). It cushions PvP wipes; it is **not** the
  bankroll and must not be conflated with it.

### 5d. Shielded winnings — a downstream relayer step, NOT a payout-contract change

The founder wants first players to experience shielding by receiving winnings **into
`EsseyShieldedStock`** rather than as a plain balance. The mechanics constrain how this can wire:

- **A shielded deposit needs the RECIPIENT's zk proof.** `transact` with `extAmount > 0` requires
  a valid join-split whose `outputCommitments` encode a note derived from the recipient's secret
  (`EsseyShieldedStock.sol:74-83, 124-138`); the caller must be `gate.isApproved(msg.sender)` and
  must already hold the token. **A payout contract cannot manufacture that commitment** — it does
  not have the player's secret. So the won stock **cannot be "routed" into the shielded pool by
  Bell/Cases/mission in their payout call.** Those pay plain transfers today: Bell →
  `vaultOf(donId)` (`Bell.sol:297-323`), degen → `owed[buyer]` + `withdraw` (`:276-283`), cases →
  the buyer. None can be turned into a shielded deposit by config.
- **Therefore the wiring is a two-hop relayer pattern (no game-contract change):** game pays the
  won shares to the player's (or an escrow) address → a **gate-approved relayer** calls
  `transact` with the **player-supplied commitment** to shield them. This is exactly the existing
  shielded-supply relayer pattern ([[essey-private-shielded-supply]], `RELAYER_PK`). **Recommended
  — it keeps every audited payout contract untouched** and confines the demo to the relayer + the
  already-deployed pool. An on-chain "shielding paymaster" adapter buys nothing: it still cannot
  produce the proof, so it would only re-implement the gate-approved-holder + relayer trigger with
  more surface.
- **Economics / RTP / solvency impact: NONE.** Shielding is value-conservative and 1:1 backed —
  a deposit transfers the real share in and sets `totalShielded += amount` (`:133-134`); the won
  **share count is identical**, it just lands as a note instead of a balance. It does **not**
  increase the seed (the player won those shares either way; shielding adds a hop, not an outflow)
  and does **not** change any house edge. Two second-order notes, neither an economics change:
  1. **Relayer fee** (`ExtData.relayer` / `fee`, `:65-72`) is a small gas-abstraction haircut on
     the *player's* realized winnings — not a protocol house-edge change. Keep it a flat, visible
     cost; at "small winnings" scale it can dominate a tiny payout, so batch or subsidize it for
     the demo.
  2. **Issuer-burn pro-rata haircut** (`:162`, `quoteHaircut`) and the **deposit-solvency gate**
     that closes deposits on impairment (`:132`) are borne by shielded-note holders, not the game
     bankroll. Issuer-freeze risk is **founder-accepted** — not a blocker here; flagged only so
     the demo plan knows shielded deposits *pause* (never lose) if the backing is ever impaired.
- **Fits the "small amounts" demo cleanly:** `maximumDepositAmount` (`:239`) caps per-deposit
  size — set it low for the pilot; small stock winnings shield trivially.

**Flagged for `SHIELDED-GAME-DEMO-PLAN.md` (deployment-manager owns this):** the relayer wiring,
gate approval for the relayer/escrow, the player-side commitment/proof UX, and the relayer-fee
subsidy decision. This economy doc's finding is only that **shielding is economics-neutral and
needs no change to the payout contracts or the seed size** — it is a delivery wrapper.

### 5e. Pilot instantiation (matches the ruled Phase-1 plan)

For the ~15-Don closed cohort ([[essey-mainnet-launch-flr-seed]]):

| Component | Seed (units) | ≈ USD (display) | Refill |
|---|---|---|---|
| Degen gacha bankroll (10×-cap, ref 0.02 AAPL) | **5 AAPL** | ≈$1.2k | price→buy-AAPL→seedReserve loop |
| Missions (provision-only) | **0** | $0 | self-funding (+10% edge) |
| Bell pot | 0 (fee-funded) | $0 | `DonFeeRouter` |
| Floor (`DonReserve`) | per genesis top-up | ≈$2k ([[essey-base-layer-equity-peg]]) | invite-gate floor leg |
| Insurance (Fixer's Book) | treasury bootstrap seed | small | 4 fee legs |

The **$100 paid-invite gate (20 inviter / 40 floor / 40 gameplay)** is the real inflow engine and
the demand governor; the FLR yield (~$10–15/day, decaying) seeds the mission float and pot —
ignition, not fuel ([[essey-mainnet-launch-flr-seed]]).

---

## 6. Contract change vs operational

| Change | Type | Where |
|---|---|---|
| Strip faucet briefs (MILK RUN, OPEN WINDOW) | **Contract** (briefs immutable, `MissionBoard.sol:207`) — reseed on V2 board | new board deploy |
| Mission base leg → provision-only (or tranche `AssetPaymaster`) | **Contract** (base leg mints, `:422-425`) | V2 board / new module |
| Cap degen top tier 50×→10×, shrink reference | **Contract** (ladder immutable, `EsseyCasesDegen.sol:164-165`) | redeploy degen with new args |
| Price the play in payout-asset value (not raw $ESSEY) | **Config at deploy** (constructor arg) | redeploy args |
| Fee→buy-stock→`seedReserve` refill loop | **Contract** (new routing; none exists) | new router leg |
| Raid tax/commit: burn→route | **Config** (fee-matrix) at real-asset deploy | fee-matrix finalize |
| Point every token address at real stock / USDG | **Config** (already settable, `MissionBoard.sol:80` etc.) | deploy script |
| Shielded winnings delivery | **Neither — a downstream relayer step** (payout contracts unchanged, §5d) | relayer + deployed `EsseyShieldedStock`; owned by `SHIELDED-GAME-DEMO-PLAN.md` |
| Trait weight recalibration (RP/HD/CMD) | **Contract** (AffinityRegistry) — competitive, not solvency | V2 board round |
| Seed the bankroll, reseed cadence, insurance bootstrap | **Operational** | ops wallet, LOUD events |

Everything solvency-critical is a **redeploy-with-different-args**, not a redesign — the
contracts already take token addresses and immutable economic args. This matches the ruled
"config promotion, not a rewrite" mode ladder (`DON-V2-REAL-ASSET-PAYOUTS.md` §0).

---

## 7. Top solvency risks (ranked)

1. **Mispriced play = real-stock faucet (CRITICAL).** 100 $ESSEY (≈$0.0028) for a 0.5-AAPL
   (≈$115) reference is a ~36,000% value RTP. This is the MILK RUN failure mode in the gacha.
   The reservation law stops *insolvency* but not *value bleed*: the house dutifully reserves and
   pays out stock worth 40,000× what it took in. **Fix: price in payout-asset value; re-audit the
   price arg against the reference on every deploy.**
2. **Faucet briefs on the mainnet board (CRITICAL).** If MILK RUN/OPEN WINDOW ship on a real-asset
   board, the base-leg mint becomes a real-stock drain at ≈594,000% RTP. Briefs are immutable and
   un-removable in place (`MissionBoard.sol:207`) — they must be absent at seed time. Verified
   live leak, [[essey-game-milkrun-and-dead-raids]].
3. **50× reservation makes a "small seed" impossible (HIGH, but self-protecting).** As shipped,
   one degen open needs 25 AAPL free or it reverts. Not a loss — but the game won't *run* small
   until the tier is capped. Fixed by §4a.
4. **Bankroll never refills (MEDIUM).** Price → treasury, not reserve (`:223`). Absent the §5b
   loop the reserve is a slow bleed (Scenario A) that eventually stalls; ops must reseed manually.
   A wired loop removes the manual dependency.
5. **Tranche subsidy outrunning leg-A inflow (MEDIUM, avoidable).** The F1 arithmetic: at
   60/20/10/10 only 60% of a 1.5% fee funds tranches vs a 20%-of-EV tranche outflow — 20× short
   (decision sheet line 546). Worst-case reservation means it throttles rather than busts, but it
   throttles *hard*. **Provision-only missions avoid it entirely; that is the recommendation.**

---

## 8. Numbered decisions & recommendations

1. **Ship missions provision-only on mainnet** (remove the minted base leg). Every brief becomes
   +10% house-edge and needs **zero subsidy seed**. Keep DEEP RUN's −EV lottery unchanged. Only
   adopt the fixed-unit `AssetPaymaster` tranche if the "real take" narrative is explicitly wanted
   — and if so, hold `trancheShare ≤ 0.60 × dispatchFeeShare` so leg-A funds it.
2. **Cap the degen top tier 50×→10× and set reference ≈ 0.02 AAPL.** Cuts the seed ~125× (250 →
   2–5 AAPL) for the same stall protection. Redistribute the freed 0.2% band to hold RTP ≈ 0.90.
3. **Price every paid play in the payout asset's VALUE, not in raw $ESSEY.** This is the single
   highest-leverage fix; a $ESSEY-denominated price at launch prices is a faucet regardless of the
   ladder. Re-verify price-vs-reference on every deploy.
4. **Recommended pilot seed: 5 AAPL gacha bankroll, 0 mission subsidy, Bell fee-funded, floor
   top-up per genesis (≈$2k), insurance bootstrap seed.** Total founder outlay ≈ a few thousand
   dollars of stock, most of it the floor — the *game* costs ≈$1.2k to seed.
5. **Build one contract: the fee→buy-payoutStock→`seedReserve` refill loop.** It converts the
   bankroll from a drain into a self-refilling float and makes the game genuinely self-contained.
6. **Funding structure = per-sink add-only bankroll contracts (spendable) walled off from the
   adminless floor (sacred), unified intake / separate sinks.** No single omnibus wallet. The
   pattern already exists in `EsseyCases`/`EsseyCasesDegen`; extend it, don't replace it.
7. **Reclassify raid tax + commit from burn to route** at the real-asset fee-matrix finalize
   (route-don't-burn law). Solvency-neutral; revenue-positive.
8. **Carry the trait recalibration on the same V2 board redeploy** — competitive-balance, not
   solvency, so it doesn't gate the economy but shouldn't ship broken.
9. **Deliver winnings shielded via the relayer pattern, not a payout-contract change.** Pay the
   won shares out, then a gate-approved relayer shields them with the player's commitment
   (`EsseyShieldedStock.transact`). Economics-neutral; set `maximumDepositAmount` low and decide
   the relayer-fee subsidy for the demo. Hand the wiring to `SHIELDED-GAME-DEMO-PLAN.md`.

---

### Load-bearing assumptions (flagged)

- **A1 (structural):** the deployed testnet degen/case config equals the intended mainnet
  economic shape. The mission agent could not confirm a mainnet deployment; treated as the
  baseline to *change*, not a live config (consistent with V2 board being written-not-deployed,
  [[essey-don-game-build-status]]). If a mainnet degen is deployed with different args, re-run §4
  against them.
- **A2 (price display only):** AAPL ≈ $230 is used solely for the `≈$` marks; **no solvency
  claim depends on it** — all reservation math is in shares (§0).
- **A3:** $ESSEY launch price $0.0000281 from [[essey-liquidity-launch-plan]] / decision-sheet
  batch 8 — load-bearing for risk #1 (the value-RTP faucet).
- **A4:** the +10% edge loop assumes the price is value-matched (rec #3); if it is not, the edge
  is undefined and #1 dominates.
