# Cases v2 — the Gacha Cases, rebuilt into the Dons economy

> **Status: design/scoping doc (2026-08-11). No code.** This is the build spec for bringing the case
> system into the Dons v3 stack. Every number cited below is read from the contracts in
> `rh-chain/src/market/` and `rh-chain/src/travel/`, the deploy scripts in `rh-chain/script/`, or
> `docs/DEPLOYMENT-testnet.md` / `docs/TOKENOMICS-v3.md`. Where a choice is genuinely open it is
> marked **FOUNDER CALL**; everything marked **DECIDED** is what this design settles.

---

## 0. What exists today (the machinery being redesigned)

Three case variants have shipped; all three predate the Dons economy:

| Variant | Contract | Prize model | Entropy | Status |
|---|---|---|---|---|
| Fair-value | `EsseyCases.sol` | uniform draw over multi-stock unit inventory, sell-back at oracle − spread | blockhash commit (256-block window) | testnet `0x97ad…D749`, bound to **v1 ESSEY** `0x0659…879f` + old Bell |
| Multiplier | `EsseyCasesDegen.sol` | 0.65×–50× of a fixed share reference, ~89.6% RTP | entropy oracle (commit-reveal callback); MockEntropy on testnet | testnet `0xA0B4…9599`, bound to **v1 ESSEY** + old Bell |
| Travel raffle | `TravelCase.sol` | uniform draw over voucher NFTs, 7-day claim TTL | blockhash commit | built, not deployed |

They are all **v1-token-bound and old-Bell-bound**, which alone forces a v2 in the Dons stack
(ESSEY v2 = `0x32a8…3d1F`, 8,888,888,888e18 supply; Dons Bell = `0x5f2D…7289`).

Proven mechanics worth carrying (each is an audited invariant, not a vibe):

- **Provably-solvent bankroll** — `buy` reverts unless already-deposited inventory covers every
  unopened case (`EsseyCases.freeInventory()`, `EsseyCasesDegen.freeReserve()`; the Degen reserves the
  *worst-case* payout — `referenceShares × maxMultiplierBps / BPS` — before the roll).
- **Add-only bankroll role** — `seedUnits`/`seedReserve`/`seed` can only deposit; no withdrawal path,
  no owner, no pause, no upgrade, immutable treasury.
- **The entropy consumer pattern** — `IEntropyConsumer` with the **external `_entropyCallback`**
  gating on the oracle address (naming a single un-underscored callback is never invoked by the real
  oracle — recorded audit finding). Two-party commit-reveal; the provider can withhold but never alter
  a reveal; the `reclaim` valve settles a withheld case at the **floor multiplier** after
  `RECLAIM_TIMEOUT = 1 hours`, permissionlessly.
- **Pull-based payouts** — settlement credits `owed[buyer]` and can never revert; the winner
  `withdraw`s when able. A paused/blocklisted token can never strand a case.
- **Disclosed, immutable odds ladder** — `multiplierBps[]`/`cumPpm[]` validated at construction
  (strictly increasing to exactly 1,000,000 ppm) and never changeable.
- **The blockhash-entropy hard gate** (EsseyCases header, verbatim intent): *the moment prizes are
  deliberately non-uniform, blockhash entropy is insufficient and must be replaced with a hardened
  entropy oracle.* Cases v2 mixes stock bands with Don jackpots — deliberately non-uniform — so the
  blockhash machinery (draw windows, `claimExpired` floors, `CLAIM_TTL = 7 days`, `sweepAbandoned`)
  **does not carry into v2 at all**. One entropy standard, one settlement path.

And the Dons-era conventions v2 must respect:

- Fee split **70% → `feeSink` / 30% → treasury** in $ESSEY (`DonExchange.stockShareBps = 7000`,
  `DonLoan.stockShareBps = 7000`).
- `feeSink` = `DonFeeRouter` (`0x6EC2…2032` testnet): accepts ETH + $ESSEY, converts to USDG, and can
  **only** forward to the immutable Bell. `flushEssey` is keeper-quoted (ESSEY has no oracle),
  `minOutBps ≥ 9,000` enforced (deployed 9,700).
- Don floor: `DonReserve.floorPerDon()` — funded to **300,030 $ESSEY/Don**; exchange trades at
  `max(live floor, 300,000e18)` with 8%/12% fees; loans at 50% LTV / 70% liq / 15% APR.
- Team reserve: `DonDistributor.mintReserved`, bounded by the **immutable `reserveCap = 2,722`**
  (2,222 AMM float + **up to 500 partners/team**). The 500 is the only possible source of prize Dons —
  the cap cannot be raised, ever.

---

## 1. Architecture: one engine, `DonCases`

**DECIDED.** One new contract, `DonCases` (working name), deployed **once per case product** with an
immutable config — the Degen shape, generalized. A "case" is:

- an immutable **band table**: `Band { assetKind (STOCK | DON), token, amount, ppm }`, cumulative ppm
  validated to exactly 1,000,000 at construction, at most **one DON band** per case;
- a **spin price in $ESSEY v2** plus the entropy fee in native ETH (`msg.value`, refund of excess —
  the exact Degen `buy` shape);
- a **payout reserve** per stock token, and a **Don queue** (ids held by the contract) if the case has
  a DON band;
- the standard **roles**: immutable `treasury`, add-only `bankroll`, admin-rotatable `keeper` for the
  restock leg only. No owner, no pause, no upgrade, no oracle feeds anywhere in the contract.

Why per-case contracts instead of one registry contract: every shipped case system here is an
immutable-config contract, the audits were passed in that shape, and "odds can never be swapped under
players" is cheapest to prove when the whole config is constructor-frozen. Three cases = three small
deploys of one audited implementation.

Why bands are **share-denominated** (token units, not USD): that is what makes the Degen open 24/7
with zero feeds — solvency is a token count, not a dollar value. v2 inherits that: **no
StaleFeedGuard, no session gate, no `NotInSession` anywhere in the spin/settle/withdraw path.** The
old fair-value contract needed oracles only for sell-back and expired-claim floors; both are cut (§6).

---

## 2. Inventory: how items get in, how it tops up (founder Q: "how do we put items into it")

**Prize types, v2 launch set:** tokenized stock units (AAPL/NVDA and whatever the bankroll lists at
deploy) and **Dons**. Explicitly *not* in v2 launch: USDG bands (a stable payout band is just a worse
stock band and drags the reward story), $ESSEY bands (paying the access token back out fights the
sink design — Bell activation burns it, treasury sinks it; the case should not recycle it), and
travel vouchers (the `TravelCase` seed/receiver pattern is the template when TravelSwap RTUs arrive
post-mainnet — a later case product, not a v2 band type).

**Segregation: per-case inventory, not a pooled vault.** Each `DonCases` deploy holds its own
reserves and Don queue. A pooled vault shared across cases would make the per-case solvency check
(`freeReserve`) a cross-case race and would let one case's drawdown brick another's buys. Depth is
public per case, which is exactly what the transparency page (§7) wants to show.

**Who can add, and how:**

| Path | Who | What it does |
|---|---|---|
| `seedStock(token, amount)` | **anyone** (permissionless, like `EsseyCases.fundBuyback`) | deposits payout stock into that token's reserve. Can only strengthen solvency; no one can drain it. |
| `seedDons(ids[])` | **bankroll only** (the `TravelCase.seed` pattern: `safeTransferFrom` pull + register; `onERC721Received` gated to the Don collection so junk NFTs can't enter) | queues Dons as jackpot prizes. Curated on purpose — a Don prize is a scarcity decision, not a liquidity one. |
| `restock(deadline, quote)` | **keeper only** | converts the contract's retained $ESSEY revenue into payout stock, output staying in the reserve (§3). |

**Top-ups never change odds.** The band table (odds *and* per-band amounts) is constructor-frozen;
seeding only deepens how many spins the case can back. So EV per spin is a constant, published
on-chain (`bandCount()` / `bandAt(i)` views), and "the house quietly nerfed the case" is structurally
impossible. What varies — and is public — is **depth**: `freeReserveOf(token)`, `donQueueLength()`,
and `maxSpinsBackable()`. When depth hits zero, `buy` reverts (`InsufficientBankroll`), same as the
Degen today; the case shows "restocking" rather than degrading its odds.

**DECIDED:** per-case inventory; permissionless stock top-up, bankroll-gated Don seeding,
keeper-gated restock; immutable band table = immutable odds and EV; depth is the only variable and it
is fully readable.

**FOUNDER CALL:** the launch stock list per case (which tickers beyond AAPL/NVDA — testnet only has
mock AAPL `0xaC6c…B731` / NVDA `0x8393…91E9`; more names = more mocks + more feed-keeper rows).

---

## 3. "A portion of stocks go there" — how stock flows into cases

Three routing options were evaluated against the standing invariant that **fee routing stays simple
and audited** (DonFeeRouter's whole security argument is "admin can retune, funds can only ever go to
the Bell"; the Distributor/Exchange/Loan splits are two-way, fixed-ratio, and clean):

1. **DonFeeRouter grows a second sink share** (x% of flushed USDG → cases instead of the Bell).
   ✗ Rejected. It breaks the router's core immutable — `_sweepToBell` sends to one fixed address, and
   that single-destination property is why the admin role is safe. A second configurable sink is
   exactly the "admin can redirect funds" capability the router was built to not have. It also taxes
   Bell stakers to subsidize gamblers, which inverts the flywheel story.
2. **Bell pot carve-out** (bps of each ring skimmed to cases). ✗ Rejected. The Bell is the audited
   O(1) accumulator shared by the whole economy; v3 deliberately runs it at `tipBps = 0` so 100% of
   the pot reaches staked Dons. Touching `ring()` for a side-game is the highest-blast-radius option.
3. **The case buys its own stock from its own revenue.** ✓ **Recommended and DECIDED.** The case is a
   revenue business with a house edge; it self-funds prizes exactly the way the rest of the economy
   buys stock — by converting fee revenue.

The money loop per spin (price `P` in $ESSEY):

- **edge share** (`edgeBps`, = 10,000 − RTP target, §5): split **70% → feeSink / 30% → treasury** —
  the exact `DonExchange._routeFee` convention, so case volume pays the seated Dons and the team the
  same way AMM volume does. The feeSink leg needs no new plumbing at all: `DonFeeRouter.flushEssey`
  swaps its **entire held $ESSEY balance**, so case edge fees forwarded to the router join the
  existing keeper leg automatically.
- **bankroll share** (the RTP-backing remainder): retained in the contract as $ESSEY revenue.
  The keeper's `restock(deadline, quote)` converts it to payout stock **in place** — the swap output
  lands in the case's own reserve, never in any external wallet. This is a verbatim reuse of the
  `flushEssey` trust shape (keeper-quoted bound because ESSEY has no oracle, `quote × minOutBps /
  10,000` enforced, `minOutBps` floor 9,000): audited pattern, zero new trust surface.

At RTP = bankroll share, the reserve is EV-neutral in expectation and the seeded float only absorbs
variance — meaning the initial seed is a one-time float, not an ongoing subsidy, and "a portion of
stocks go there" happens continuously, bought by spin revenue.

**DECIDED:** option 3. No change to DonFeeRouter, Bell, or any existing route. New surface: the
case's own two-way split at buy + the keeper restock leg.

**FOUNDER CALL:** none here (sizing of the initial stock float is operational; see §9 solvency note).

---

## 4. Dons in the boxes

**Where prize Dons come from.** `DonDistributor.mintReserved(to, combos[])` — admin-only, bounded by
the immutable `reserveCap = 2,722`, of which 2,222 is spoken for as AMM float, leaving **≤ 500** for
partners, team, *and* case prizes. The flow:

1. Admin mints reserved Dons **to the ops/seeder wallet** with explicit curated combos (mint-direct-
   to-contract also works since the case implements the gated receiver, but minting to ops and
   seeding keeps registration explicit and batchable — the TravelCase pattern).
2. Bankroll calls `seedDons(ids[])` → Dons pulled into the case, queued as jackpot prizes.

**State of a Don sitting in a case (all verified against `Don.sol`/`Bell.sol`):** traits set,
`locked = false` (never staked — `lockTraits` only fires via `lockOnStake` when `tier > 0`, and a
contract-held Don is never activated), `liened = false`, Bell `tier = 0`, empty Vault, no payout
elections. Nothing about case custody needs a new Don state: **the invariant is simply "seed only
unstaked, unliened, unlocked Dons," and every `mintReserved` output already satisfies it.** The lien
system never touches case Dons (liens exist only via `DonLoan.borrow`, owner-called).

**What the winner receives.** On a DON-band win the id leaves the queue and is credited to the winner
(pull-claimed, §6). The transfer fires the Don's hook → `Bell.onSeatTransfer` → tier/elections clear
(no-op here, tier was 0). The winner holds a **fresh, unlocked Don**: they can pay `rerollFee`
(0.00075 ETH testnet, ~$3 target) to restyle it — `DonDistributor.reroll` checks only ownership +
not-staked, both true — or `mintCustom`-style keep the curated look, then activate a Bell tier to
start earning. **Reroll rights: yes, deliberately.** Rationale: (a) it's mechanically free — blocking
it would need new state; (b) "win it, restyle it, stake it" feeds reroll fees to the feeSink, so even
jackpot winners generate stock for the room; (c) art-lock semantics stay exactly "staking locks the
art," no special case. The curated combo is a *default*, not a constraint.

**Art locked or unlocked:** unlocked until the winner stakes — same rule as every other Don. **DECIDED.**

**Scarcity math.** Each Don prize carries hard value ≥ the live floor (300,030 $ESSEY redeemable at
`DonReserve`, or ~276k net selling to the desk after the 8% fee — both venues already exist, which is
why the case needs no Don buyback of its own). At a 0.2% DON band (2,000 ppm — the same slot the 50×
occupies in today's ladder), one Don pays out per ~500 spins in expectation. An allocation of **48
Dons** (motif-friendly, < 10% of the 500 reserve) backs ~24,000 jackpot-armed spins across the first
seasons — at a 6,666 $ESSEY spin price that is ~160M $ESSEY of gross spin volume per full drip.
Recommended posture: drip 8–12 per case season rather than queueing all at once, so
`donQueueLength()` stays honest about what's currently winnable.

**When the queue is empty** (or every queued Don is already reserved by in-flight spins): the DON
band does not vanish or re-weight — it settles to a disclosed **fungible fallback** (`donFallback =
(token, amount)`, part of the immutable config, sized ≈ the band's EV so the table stays honest), and
a public `donBandArmed()` view says which mode the band is in. The UI must show it (§7).

**FOUNDER CALL — prize-Don SOURCE (undecided, per founder 2026-08-11):** the team reserve is NOT the settled
source; the reserve's allocation is undecided for now. Options when this is picked back up:
  (a) a tranche of the ≤500 team reserve via `mintReserved` (cheapest; consumes the irreversible partner budget),
  (b) protocol BUYS Dons from the DonExchange at the live price +8% (keeps the reserve untouched; sustainable
      forever, incl. post-mint-out; cost ~324k $ESSEY/Don at today's floor; those buys themselves pay 70% of the
      fee back to the stock pot),
  (c) protocol custom-mints from public headroom paying its own ETH fee (works only pre-mint-out).
Everything else in this section (seed flow, custody, winner gets reroll
rights; art unlocked until staked; empty-queue fallback with an on-chain armed flag.

**FOUNDER CALL:** total prize-Don allocation out of the 500 (recommended 48) and the drip schedule —
this budget competes directly with partner allocations and is irreversible once minted (`reserveCap`
immutable).

---

## 5. Spin mechanics

**Entropy: the Degen standard, verbatim.** The entropy oracle's commit-reveal service on Robinhood
Chain (request-side surface pinned in `EsseyCasesDegen.sol`, live at `0xd8a0…0a0c`) on mainnet;
`MockEntropy` (`0xb9b8…1E6F` + keeper) on testnet. The consumer implements the exact
`IEntropyConsumer` shape — external `_entropyCallback` gated on the oracle address (the audit-finding
naming trap), internal `entropyCallback` doing settlement. User randomness is contract-derived
(`keccak256(msg.sender, …, blockhash(n-1))`), **no client-side randomness in the outcome, ever** —
the client only animates. The trust statement carries unchanged and stays honestly worded: the
provider cannot alter a committed reveal but can withhold one; `reclaim` after **1 hour** settles a
withheld spin permissionlessly at the **worst band** of the table (floor settle — never gameable,
only un-sticking), and the reservation releases.

**Odds on-chain and readable:** band table views as in §2; a `tableHash()` view (keccak of the full
band table) so the UI can pin "the odds you saw are the odds that settled."

**One roll covering fungible and NFT prizes.** The roll is `random % 1,000,000` mapped over the
cumulative band table — exactly `_multiplierFor`. A band resolves to either shares of its token or a
Don. The "a Don can't be fractional" problem is solved by reservation + fallback, not by odds math:

- **Buy-time reservation (the solvency generalization).** Per unopened spin the contract reserves,
  **per token, the largest amount any band pays in that token** (the per-token worst case — the
  Degen's `worstShares` generalized to a multi-token table), and **one Don from the queue if the DON
  band is armed**. `buy` reverts if any leg can't be reserved. Settlement credits the won band and
  releases everything else. Cost of over-reserving: bounded by callback latency (seconds) × concurrent
  spins — negligible against the hard guarantee that *every possible outcome of every in-flight spin
  is already in custody*. This keeps the EsseyCases sentence true in v2: "the house reserved this
  prize in real inventory before you opened" is an invariant, not a promise.
- If the DON band could not be armed at buy, that spin's DON outcome pays the disclosed fallback
  (whose amount is inside the per-token worst case, so the reservation already covers it).

**Price currency: $ESSEY v2, plus the entropy fee in ETH `msg.value`.** Consistency argument: the
Dons economy prices membership things in ESSEY (exchange, loans, Bell tiers) and *mint* things in ETH.
A spin is a market action, not a mint → ESSEY. This also deletes a real v1 UX wart: the old Degen
charged `casePrice` in ESSEY **and** `buyFee = 5e18` in USDG — three assets to hold, two approvals
(the live UI literally tells players to go collect "$ESSEY + USDG + a little gas ETH"). v2: one ERC-20
approval (ESSEY), gas + entropy fee in ETH. No separate USDG fee leg — the edge split (§3) replaces
`_takeFee` entirely.

**RTP target.** The deployed Degen ladder is 0.65×/1×/2×/5×/50× at 84%/10.5%/4%/1.3%/0.2% → **89.6%
RTP** (`DeployDegenCase.s.sol`), and the site already frames it that way ("an average roll returns
less than it costs"). v2 keeps **~90% RTP as the house standard across case tiers** — one number the
brand can defend ("the only case system where the odds AND the bankroll are provable" needs a single,
memorable, disclosed edge), leaving `edgeBps = 1,000` → 700 to the feeSink / 300 to treasury per
10,000 of price. Per-tier variance differs (a starter case is tight, a premium case is spiky), RTP
does not. Illustrative premium-case table (Capo, 6,666 $ESSEY spin): fungible bands summing to ~5,400
EV (81%) + DON band 0.2% × 300,030 floor ≈ 600 EV (9%) = 6,000 ≈ 90% — the Don's EV **counts inside**
the RTP, valued conservatively at floor (market value is strictly ≥ floor, so disclosed RTP only ever
understates).

**DECIDED:** entropy-oracle standard everywhere (blockhash draws retired); contract-derived user
randomness; immutable ppm table + per-token worst-case & Don reservation; ESSEY pricing + ETH entropy
fee; 90% RTP standard with Don EV counted at floor; 1-hour permissionless floor reclaim.

**FOUNDER CALL:** spin prices per case tier (proposed: Street 666 / Capo 6,666 $ESSEY — 666-motif
consistent with the Bell ladder), and whether a third flagship tier exists at launch.

---

## 6. Redeem mechanics

**Claim-to-wallet, pull-based, for everything.** Settlement credits `owedStock[buyer][token]` and
pushes won Don ids to `wonDons[buyer]`; `withdraw(token)` / `claimDon(id)` deliver. Reused Degen
rationale: settlement can never revert (paused token, non-receiver contract winner), so a roll always
lands. NFTs go pull-based too — a `transferFrom` inside the entropy callback could still grief on
gas; the queue-out + credit is O(1) and safe.

**No TTL, no expiry, no confiscation.** The v1 fair-value contract needed `CLAIM_TTL = 7 days` +
`sweepAbandoned` because its blockhash draw *expired* and its floor claim was an American option over
drifting inventory. TravelCase inherited the same 7-day bound for the same reason. v2 has neither
problem: the entropy callback settles in seconds, `reclaim` (1h) closes the withheld-reveal gap, and
once settled, `owed` balances are debts — they sit until claimed, full stop. Reserved-but-unclaimed
prizes are excluded from `freeReserve` (the Degen's `totalOwed` deduction, extended per-token), so
unclaimed winnings never get re-sold to later spins.

**Sell-back: not in the contract — the economy already has the exits.** v1's `sellBack` (oracle value
minus `spreadBps`, floor 150 / ceiling 2,000 bps) existed because stock had no other on-site exit. It
dragged in the whole oracle stack: StaleFeedGuard, session gating ("no off-hours buyback"), a funded
buyback reserve, and the dispersion-management operational burden the EsseyCases header spends 20
lines on. In the Dons era every prize class already has an audited venue: stock → the Bell-side
converter flow and the lending markets (borrow against it — that *is* the Assay pitch); Dons → sell
to `DonExchange` (net ~92%) or redeem at `DonReserve` (100% of floor, consumes the Don). Duplicating
those inside the case contract violates the reuse rule and re-imports the exact complexity v2 is
deleting. The UI presents "keep / borrow / sell" as one reveal-screen choice by deep-linking the
existing flows (§7) — the *product* keeps instant-feeling sell-back; the *contract* doesn't hold it.
Consequence: no re-entry of sold-back prizes into case inventory; inventory refills only via §2/§3.

**DECIDED:** pull-based claim for stock and Dons; no TTL/expiry anywhere; no in-contract sell-back;
sold prizes exit through the existing desk/reserve/converter venues.

**FOUNDER CALL:** none — but flagging honestly: if the founder wants the case itself to quote instant
buyback (the old ~95% chip), that reopens oracle + session + buyback-reserve scope; recommendation is
to ship v2 without it and measure whether the DonExchange/converter path feels instant enough.

---

## 7. The clean flow (the founder's "pain in the ass" fix)

One diagrammable loop:

```
            $ESSEY spin price + ETH entropy fee
 player ───────────────►  DonCases.buy()
                            ├─ edge 10%: 70% → DonFeeRouter (…→ USDG → Bell → staked Dons)
                            │            30% → treasury
                            ├─ bankroll 90%: retained → keeper restock() → payout-stock reserve
                            ├─ reserve check: per-token worst case + 1 queued Don   (revert = never insolvent)
                            └─ entropy request ──► oracle callback ──► settle band
                                                        ├─ stock band → owedStock[buyer][token]
                                                        └─ DON band  → wonDons[buyer]  (or fallback shares)
 player ◄── withdraw(token) / claimDon(id)
        └─ keep │ borrow (lend) │ sell (DonExchange / redeem DonReserve / converter)
```

Every arrow is an existing audited pattern; the only new box is `DonCases` itself.

**What's wrong with the current `app/web/src/cases.tsx` (specific, with fixes):**

1. **Two contradictory narratives on one page.** The arcade band copy sells the fair-value story
   ("every pull lands ~the case's value… the draw only ever decides which name, never how much…
   sell it back for ~95%") while the live mechanic underneath is the multiplier roll and the page
   header says "win more or less than you paid, 0.65× to 50×." Fix: one narrative — the v2 band/RTP
   story — everywhere; delete the fair-value copy (single-narrative rule).
2. **Fake case catalog.** The three `CASES` boxes (401(k)/Blue Chip/Founders) are hardcoded sample
   lineups with invented odds; when live, `pickCase` silently snaps any selection back to index 0
   ("On testnet only the 401(k) Pack opens for real"). Players click Blue Chip and get something
   else. Fix: the browse grid renders **only deployed `DonCases` contracts**, config read on-chain
   (`bandAt`, price, depth); no simulated catalog in live mode.
3. **Fake reel contents.** `LIVE_ITEMS` is a two-item flavor strip (AAPL 60 / NVDA 40) unrelated to
   the real ladder, and `spinLive` seeds a *provisional* winner it "corrects on reveal" — the reel
   can visibly land on a different card than the reveal shows. Fix: build the strip from the real
   band table; keep the proven hold-at-rest gate (`stagePendingRef` + the rAF watchdog — that part is
   right and hard-won) so the reveal is only ever the settled outcome.
4. **Hardcoded reveal math.** `degenWinItem` fabricates `sym: "AAPL"` and `value: x × 100` regardless
   of config. Fix: reveal renders the settled band (token, shares) from the event, USD estimate from
   the same feed data the rest of the app uses.
5. **The withdraw foot-gun.** Winnings silently sit in `owed` until a separate "Withdraw to wallet"
   press; the code even documents the `NothingOwed` revert trap it must dodge. Fix: reveal screen
   offers the full decision — **Claim to wallet / Borrow against it / Sell it** — plus a persistent
   claim-center badge ("you have unclaimed winnings") fed by `owedStock`/`wonDons` reads, so nothing
   is ever stranded-but-invisible.
6. **Three-asset onboarding.** "opening needs $ESSEY + USDG + a little gas ETH." Fixed at the
   contract (§5): ESSEY + gas only.
7. **Odds shown without EV.** The ladder table lists per-band odds but never the one number that
   builds trust: RTP. Fix: show "returns ~90% on average — verified from the on-chain table" with the
   `tableHash` pin.

**The /cases page, v2 states:** (a) **Browse** — deployed cases with live odds, EV/RTP, spin price,
depth meters (`freeReserveOf`, `donQueueLength`, `donBandArmed` — "Don jackpot LIVE" vs "fallback
active"); (b) **Spin** — reel over real bands, staged narration (approve → buy → sealing → oracle
reveal), hold-at-rest until callback; (c) **Reveal** — settled band + keep/borrow/sell/claim actions;
(d) **Claim center** — all unclaimed stock + Dons across cases; (e) **Provably-fair /
inventory page** — the band table verbatim from chain, reserve balances, Don queue ids (each linking
to its art), tableHash, and the entropy-trust paragraph in plain language.

**DECIDED:** the loop above; UI rebuilt on on-chain config with the seven fixes; keep the reel/
watchdog animation core.

---

## 8. Migration

**What dies (all testnet, play money — retire, don't migrate):**

- `EsseyCases` v1 (`0x97ad…D749` + retired `0x1516…3972`) — bound to v1 ESSEY + old Bell; blockhash
  machinery not carried.
- `EsseyCasesDegen` (`0xA0B4…9599` + retired `0x96d5…f42d`) — same binding; its *patterns* survive,
  the deployment doesn't. Outstanding `owed` balances are testnet play money; announce a claim window
  in the UI banner, then delist.
- The simulated catalog/copy in `cases.tsx` (§7 items 1–4).
- `TravelCase` — never deployed; parked until the travel era, to be rebuilt on the v2 engine.

**What carries over (pattern-level):** `IEntropyConsumer` verbatim; worst-case reservation + free-
reserve check; pull-based `owed`/`withdraw` + `totalOwed` accounting; `reclaim` floor valve +
`sweepEth`; add-only bankroll; gated `onERC721Received` + `seed` (TravelCase); the 70/30
`_routeFee` split (DonExchange); the keeper-quoted swap leg (`flushEssey` → `restock`); `MockEntropy`
as the testnet fixture.

**Deploy order & wiring.** `DonCases` sits at the leaf of the dependency graph — nothing in
`DeployDons.s.sol` changes, and no existing contract needs re-wiring (the router's `flushEssey`
already sweeps whatever ESSEY balance arrives; `DonDistributor.setFeeSink` is untouched):

1. Prereq (already live): DeployDons stack + DonFeeRouter wired as feeSink.
2. New `DeployDonCases.s.sol` (per case): env `ESSEY` (v2 `0x32a8…3d1F`), `FEESINK`
   (`DonFeeRouter 0x6EC2…2032`), `TREASURY`, `BANKROLL`, `KEEPER`, `ENTROPY` (MockEntropy testnet /
   the oracle at `0xd8a0…0a0c` mainnet) + provider, band table, spin price, `edgeBps`, donFallback —
   the `DeployDegenCase.s.sol` shape.
3. Post-deploy ops (the DeployDons console-log convention): seed the stock float per case;
   `mintReserved(ops, comboBatch)` → `seedDons(ids)` for the first Don drip; register the case
   address in the web app's `live.ts` ADDR map; feed-keeper unaffected (no feeds in the contract).
4. Mainnet note: this slots into the existing go-live plan (docs/MAINNET-GO-LIVE.md phases); cases
   ship in the same wave as the rest of the Dons stack or after — nothing upstream depends on them.

**DECIDED:** all of the above; v1 case contracts sunset with a UI claim-window banner.

---

## 9. Risks & decisions for the founder

| # | Topic | The call | Recommendation |
|---|---|---|---|
| 1 | **RTP / house edge** | One standard (~90%, edge 10% split 70/30) vs per-tier edges | Keep one number: 90%. It matches the shipped Degen ladder (89.6%), it's defensible copy, and the edge already compounds with restock spread + reroll fees from winners. |
| 2 | **Prize-Don SOURCE + allocation** | WHERE prize Dons come from (team reserve is expressly UNDECIDED — founder 2026-08-11) and how many | No recommendation until the source is picked: options are reserve tranche / exchange buys / public-headroom mints (see §3). If a count is wanted for modeling: 48 dripped 8-12/season was the earlier sketch, contingent entirely on the source call. |
| 3 | **Spin pricing** | Street 666 / Capo 6,666 $ESSEY proposal (§5) | Approve or reprice; keep the 666 motif; DON band only on the premium tier. |
| 4 | **Sell-back** | Ship without in-contract buyback (§6) | Yes — measure the DonExchange/reserve/converter exits first; re-scope a buyback desk only if reveal-screen selling demonstrably needs it. |
| 5 | **Regulatory framing** | The mechanic is a paid randomized prize with disclosed odds | Keep the existing framing exactly: entertainment, testnet play money, the site-wide experimental warning modal, and the already-shipped honest copy ("an average roll returns less than it costs"). v2 must not soften any of that — the RTP disclosure and provable solvency are the differentiators, so lead with them. Mainnet enablement of cases is its own gate inside the go-live plan (beta whitelist first), not an automatic ship. |
| 6 | **Bankroll solvency** | — | Non-negotiable and kept hard: per-token worst-case + Don reservation before every spin, `buy` reverts on thin depth, unclaimed winnings excluded from the free reserve. The case can never owe a prize it doesn't hold — same sentence as v1, stronger machinery. |
| 7 | **Withheld-reveal trust** | Same as Degen: oracle can withhold (not alter) a reveal | Accepted, stated in the provably-fair page; 1-hour permissionless floor reclaim bounds it. On testnet the MockEntropy keeper's uptime is ops-critical (same class as the feed keeper — fold into the same cron watch). |
| 8 | **Keeper restock leg** | The only privileged money-touching action (quote for ESSEY→stock) | Same trust bound as `flushEssey` (minOut floor 9,000 bps, output can't leave the contract); admin-rotatable keeper; monitor quotes like the router's. |

---

## Build slice (when this is approved)

1. `DonCases.sol` + tests (fork the Degen test suite: solvency fuzz over multi-token reservation,
   callback/reclaim races, Don queue arm/fallback, edge-split conservation).
2. `DeployDonCases.s.sol` + Street/Capo configs; testnet deploy against MockEntropy.
3. `mintReserved` → `seedDons` ops runbook entry + first drip.
4. `cases.tsx` rebuild per §7 (on-chain catalog, claim center, provably-fair page).
5. 3-agent audit round (pre-push gate) before any deploy; audit note published fix-first per the
   standing audit-trail rule.
