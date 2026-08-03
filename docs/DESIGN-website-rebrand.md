# DESIGN — essey.xyz rebrand & website scope (the Market layer front-and-center)

**Status:** design + scope only. No contract (`.sol`/Move) or app code is touched here — contracts are
under the 3-agent audit gate. This document is the brief the build works from.

**What changed (founder decision, 2026-08-02, recorded in `DESIGN-seats-market-layer.md` §"Website &
messaging reframe" and task #14):** the Market layer — Seats, Vaults, Tiers, the Exchange, the Bell,
Payouts, After Hours, Notes, Cases, the Tape — becomes *the* face of Essey. The lending protocol
doesn't recede; it becomes the **proof engine underneath the game**. The site must do what StonkBrokers'
site did — pull people in with live, gamified engagement energy — and point every bit of that energy at
the one thing no meme competitor can claim: **provably fair AND provably solvent.**

**Reference we are answering (and out-classing):** StonkBrokers (stonkbrokers.cash), same Robinhood
Chain, same tokenized-stock assets. What worked for them: (1) a first-visit experimental-software
disclaimer modal, (2) a constantly-scrolling live "drops happening now" ticker where each row is a real
tx, (3) a docs reading room, (4) heavy gamification. We match the *architecture* of that engagement and
re-point it from degen to **trust**. Their measured economy is in `ECONOMICS-seats-model.md`; the
mechanics are in `DESIGN-seats-market-layer.md`; the token in `TOKENOMICS-essey.md`. Nothing in this doc
invents mechanics — it dresses the ones that are built or scoped.

**The one-line north star for the whole site:** *"The stock-market club where the odds and the books are
both provable."*

---

## 0. What already exists (so we evolve, not discard)

Grounded in the current repo, not assumed:

- **Palette (live in `app/web/src/styles.css`):** ink `#0A0C11`, a surface ladder `--s1 #10131A →
  --s4 #262D3B`, gold `#D4A94E` with highlight `#E7C57A`, text `#E9EBF1 / #98A0B0 / #616A7B`, and a
  full semantic set already defined — `--good #3DD68C`, `--warn #F0913E`, `--crit #F26D6D`. These are
  already the right bones. We keep every token.
- **Type:** `--serif` (New York/Georgia/Didot family) for headings, `--sans` (system) for body,
  `--mono` (SF Mono) for all numbers with `font-variant-numeric: tabular-nums`. This serif+mono pairing
  IS the premium-finance voice. Keep it; the rebrand tunes it, doesn't replace it.
- **The hallmark:** the hexagon E-monogram — an outer hex `M50 7.81 …` in a gold gradient stroke with an
  inset faint second hex and a Didot "E" (`brand/logo-final.html`). This is the single most valuable
  brand asset we own. The whole rebrand hangs off promoting it from *logo* to *mechanic* (see §1).
- **Current site (`app/web/src/App.tsx`) is dark-only** (`color-scheme: dark`) and is structured as a
  serious lending landing page: Hero → Markets ("Collateral, priced live") → Borrow & Earn ("The money
  moment") → Why-different → Dregg → Chains → Proof (four gates) → Docs reading room → Governance →
  Positions. The **docs reading room already exists and already renders the repo's own markdown in-place**
  (`DocsSection` uses `marked` + `DOMPurify`, groups docs, links "source ↗" to GitHub). We extend that
  component, we don't rebuild it.
- **Brand banner** already ships the "provably different" motif: two rows of nodes, "others" partly-lit
  vs "essey" all-gold (`brand/banner-final.html`), tagline *"Borrow against your onchain assets — on any
  chain"*, eyebrow *"the proof is the oracle."* That "proof is the oracle" line is the seed of the new
  positioning.

The rebrand is therefore an **evolution**: same ink+gold+serif spine, same hallmark, same docs room —
turned up into something alive and gamified, with a permanent live proof-feed and a game surface bolted
on top of the existing lending surface.

---

## 1. Brand direction — "the provable stamp," alive

### The core visual metaphor: the hallmark is a stamp of proof

Today the hexagon E-monogram is a static logo. **We make it a verb.** In a real exchange, a clearing
house *stamps* a certificate to make it official; a hallmark stamped into gold is the historical mark of
*assayed*, verified purity — which is literally what "assay" (the project's origin name) means. So:

> **The hexagon hallmark is the "provable" stamp. Anything Essey has verified gets stamped with it.**

- A loan proven solvent → the Note card gets the hallmark pressed into its corner.
- A Bell that rang with a valid ZK distribution proof → the Tape row carries a small gold hallmark.
- A Case whose draw was provably fair → the prize deed is stamped.
- Hover/tap the stamp anywhere → it flips to reveal the Blockscout tx + "verify it yourself" (the button
  the market-layer doc promises is real, not a slogan — `DESIGN-seats-market-layer.md` §"provable twist").

This gives us one motif that unifies the serious side (proven loans) and the game side (fair draws) under
a single gesture. It is finance-native, premium, and instantly legible: *stamped = proven*.

### Palette — evolve, add two accents, keep the discipline

Keep the entire existing token set. Add exactly two, tightly scoped:

| Role | Token | Value | Where it's allowed |
|---|---|---|---|
| Base ink | `--ink` | `#0A0C11` | everything (kept) |
| Gold / gold-hi | `--gold` / `--gold-hi` | `#D4A94E` / `#E7C57A` | proof, the stamp, primary action (kept) |
| Solvent green | `--good` | `#3DD68C` | "proven solvent", healthy HF, supply APR (kept) |
| **Bell brass** *(new)* | `--bell` | `#F0C46A` (a hotter gold) | reserved **only** for a live Bell ring / Payout moment — so a ring reads as an *event*, brighter than resting gold |
| **Tape phosphor** *(new, restrained)* | `--tape` | `#7FE3C4` (dim mint-cyan) | the live Tape's "just now" pulse and the verify-checkmark only |

Rule: brass and phosphor are **event colors**, never chrome. If everything glows, nothing reads as
special — and this is a *trust* brand, so restraint is the credibility. Degen sites use rainbow gradients
everywhere; our discipline is the flex.

### Type pairing — sharpen the two-voice system

- **Display serif (Didot/New York):** headlines, the wordmark, mechanic names ("the Bell", "the
  Exchange") set in italic-capable serif. This is the "club" voice — old-money exchange, brass and marble.
- **Mono (SF Mono):** every number, every address, every tx hash, the Tape, the timers, tier weights,
  Payout amounts. Mono = "this is a fact you can check." The mono/serif split maps exactly onto the brand
  thesis: **serif says what we claim, mono shows the receipt.**
- **Sans (system):** body copy and UI labels only. Never headlines.

### Motion principles

1. **Proof settles; hype flashes.** Our animations *resolve into place* (a stamp presses down, a number
   ticks up and locks) rather than bounce/wiggle. Easing: authoritative `cubic-bezier(.2,.8,.2,1)`,
   ~240ms. The one exception is §the-Bell moment.
2. **The Tape never stops.** One element on the site is always in motion — the live Tape crawl. That
   single perpetual motion carries all the "something is happening here" energy so the rest of the page
   can stay calm and premium.
3. **Reduced-motion is a first-class path**, not an afterthought: `prefers-reduced-motion` freezes the
   Tape crawl into a static "latest 5" list and disables the Bell flash (see §8). Non-negotiable for a
   trust brand — we don't seize anyone's screen.

### The one real aesthetic risk (take it): the ticker-tape rail

**A permanent, physical "ticker-tape" rail runs along the bottom edge of every page on the entire site**
— styled as actual paper stock-ticker tape (subtle perforations, a faint paper-cream `#F3EFE7` at 6%
opacity texture over ink, mono glyphs) — printing real events as they happen: `● BELL RUNG · 0.44 ETH →
1,662 Vaults · proof ✓ 0x9f…`. It is docked, ~40px tall, and it is the first thing that says "this place
is live and it publishes everything." The risk: we permanently spend screen real estate and commit to an
indexer being up. The payoff: it's the StonkBrokers "drops ticker" reflex, but re-cast as a **printing
press for proof** — the single strongest expression of "provably solvent" as a *feeling*, not a claim.
On mobile it collapses to a tap-to-expand single-line crawl (§8). This is the aesthetic bet of the
rebrand: **turn the whole site into a room where a ticker is always printing receipts.**

---

## 2. The hero — land "provably fair AND provably solvent" in one glance

The hero has one job: in the first 3 seconds, a newcomer must feel *(a)* this is a game with money moving
through it right now, and *(b)* unlike every other such game, both the odds and the books are provable —
and then be pulled toward acting.

**Concept: "The Exchange."** A split hero. Left = the human hook and the claim. Right = a live, breathing
proof surface (the Bell + a live Tape peek) so the promise is demonstrated, not asserted, above the fold.
The hallmark sits at the seam, stamping the whole thing.

```
┌───────────────────────────────────────────────────────────────────────────┐
│  ⬡ essey            Market   Seats   the Bell   Cases   Docs      [Connect] │  ← sticky nav
├───────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌ eyebrow (mono) ──────────────┐        ┌───────────── LIVE ───────────┐  │
│   │ PROVABLY FAIR · PROVABLY      │        │   THE BELL          ⬡ proof  │  │
│   │ SOLVENT                       │        │  ┌────────────────────────┐  │  │
│   └───────────────────────────────┘        │  │      🔔  pot: 0.63 ETH │  │  │
│                                             │  │   [ RING THE BELL ]    │  │  │
│   A stock-market club                       │  │   next payout → 1,662  │  │  │
│   where the odds and the                    │  │   Vaults, by Tier      │  │  │
│   books are both  ⟨provable⟩.  ← serif,     │  └────────────────────────┘  │  │
│                                gold italic  │                              │  │
│   Buy a Seat. Earn Payouts in real          │  THE TAPE  (last 4, crawling)│  │
│   stock. Borrow against them. Every         │  ● BELL 0.44Ξ→1,662  ✓ 0x9f… │  │
│   ring, every draw, every loan —            │  ● LOAN proven solvent ✓ 0x2a│  │
│   verifiable on-chain.                      │  ● SEAT #1204 minted   ✓ 0x77│  │
│                                             │  ● CASE opened  fair✓  ✓ 0xc3│  │
│   [ Enter the Market ]  [ How it works ]    │  └──────────── see all → ────┘  │
│                                             └──────────────────────────────┘  │
│                                                                             │
│   ⬡ 2,222 Seats · $349k Payouts distributed · every row a real tx           │  ← proof strip
├═════════════════════════════════════════════════════════════════════════════┤
│ ● BELL RUNG 0.44Ξ→1,662 Vaults ✓0x9f… ● SEAT #1204 minted ✓0x77… ● LOAN…    │  ← permanent ticker-tape rail
└───────────────────────────────────────────────────────────────────────────┘
```

Why this lands both halves of the claim at once:

- **"Provably fair"** is carried by the live **Bell** widget (a game event, with a `⬡ proof` stamp on it)
  and the Case/Bell rows in the peek Tape, each showing `fair ✓`.
- **"Provably solvent"** is carried by the `LOAN proven solvent ✓` Tape row and the proof strip — the
  lending engine shown as a *ledger that publishes its own solvency*, not hidden backstage.
- The **headline is serif**, the differentiator word `⟨provable⟩` in **gold italic** — the one gold word
  in the sentence, echoing the existing hero's `h1 em { color: var(--gold) }`.
- The **primary CTA "Enter the Market"** is the gold button (`.btn-gold`, kept); the secondary "How it
  works" opens the mechanic explainer scroll (§5).
- The right column is **the demo** — a real, throttled read of the on-chain pot and the last few Tape
  events. If the pot is genuinely ringable, "RING THE BELL" is live and anyone can be the person who
  rings it (and earns the tipper's cut — a real hook, per `Bell.sol`). If not, it shows the countdown /
  "pot filling."

**The Bell moment (the one big motion):** when a Bell is rung (by this visitor or anyone, observed via the
indexer), the hero briefly does the thing degen sites do for hype — but for proof. A single brass
(`--bell`) sweep crosses the screen, the hallmark stamp presses down over the Bell widget with a soft
"cl:unk", and the Payout number counts up into the Tape. ~900ms, once, then calm. It is the site's
signature gesture: **the moment fees become stock in people's Vaults, made physical.** Respects
`prefers-reduced-motion` (no sweep; the number just updates).

---

## 3. The live Tape — a printing press for proof

The Tape is the heart of the rebrand and the direct answer to StonkBrokers' "drops happening now" ticker.
Their ticker broadcasts *hype* ("someone just won 12×!"). **Ours broadcasts *proof* — every row is a real
Blockscout tx, and every row that can be verified carries the hallmark and a "verify" affordance.** It
exists in three surfaces at three densities:

1. **The rail** (permanent, every page — the §1 aesthetic risk): one-line crawl of the freshest events.
2. **The hero peek** (§2): last ~4 events, taller rows.
3. **`/tape` — the full room:** a dedicated page. A live, reverse-chronological, filterable feed.

### Row anatomy (the full `/tape` room)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ⬡  BELL RUNG           0.44 ETH  →  1,662 Vaults      by Tier      just now    │
│    Payout distributed as AAPL · NVDA · USDG      proof ✓  rang by 0x3f…9c      │
│    ────────────────────────────────────────────────────  0x9f4a…21e  ↗ verify │
├──────────────────────────────────────────────────────────────────────────────┤
│ ✓  LOAN PROVEN SOLVENT  Note #418   debt 1,240 USDG   HF 1.72   35% LTV   2m   │
│    ────────────────────────────────────────────────────  0x2a10…8b  ↗ verify  │
├──────────────────────────────────────────────────────────────────────────────┤
│ ◆  SEAT #1204 MINTED    Vault created   ⬡ ERC-6551   earned by borrowing  4m   │
├──────────────────────────────────────────────────────────────────────────────┤
│ ▲  TIER UP              Seat #0891  Base → Tier II    50% of fee burned    6m   │
├──────────────────────────────────────────────────────────────────────────────┤
│ ⬡  CASE OPENED          drew NVDA ×1.0   draw fair ✓   sealed in Vault    9m   │
└──────────────────────────────────────────────────────────────────────────────┘
   [ All ]  [ Bells & Payouts ]  [ Loans ]  [ Seats & Tiers ]  [ Cases ]  [ ⬡ proven only ]
```

Design rules that keep it on-brand (proof, not hype):

- **Every row ends in a real tx.** Mono hash + `↗ verify` deep-links to Blockscout. No row exists that
  isn't a real event. This is the literal expression of the repo's ethos ("an audit trail you only
  publish when it is flattering is not an audit trail," `WHY-ESSEY-IS-DIFFERENT.md`).
- **The hallmark `⬡` marks *proven* rows** — a Bell with a valid ZK distribution proof, a loan that
  passed its solvency check, a provably-fair Case draw. A `⬡ proven only` filter lets a skeptic watch
  *only* the verifiable events. That filter is the whole pitch in one toggle.
- **No dollar-brag styling.** Amounts are mono, calm, tabular. Green (`--good`) is reserved for the word
  *solvent* and healthy HF — not for "big number." We are not a casino win-feed.
- **Newest row pulses `--tape` phosphor once** as it prints, then settles to resting ink. That single
  pulse is the "live" signal; everything else is still.
- **Empty/again-honest state:** if the indexer is behind or a chain is quiet, the Tape says so plainly
  ("no events in the last 10m — the Bell fills as fees accrue") rather than faking motion. Honesty is the
  brand; a fake-busy ticker would betray it.

### What feeds it (grounding the event types in shipped contracts)

Every row type maps to a real emitted event from a built contract:
- **BELL RUNG / PAYOUT** ← `Bell.sol` ring + per-Vault claim (`accPerWeight` accumulator).
- **LOAN PROVEN SOLVENT** ← `EsseyPool` borrow/health, keyed by `Note` id (`Note.sol`, `ownerOf(id)` auth).
- **SEAT MINTED / VAULT CREATED** ← `Seat.sol` + `SeatVault.sol` (ERC-6551, atomic init).
- **TIER UP** ← Tier staking (50% burn) in `Bell.sol`.
- **EXCHANGE TRADE** (buy/snipe/sell) ← `EsseyExchange.sol`.
- **CASE OPENED / DRAW FAIR** ← Case system (Phase 5, scoped) once built.

This is why the Tape needs an **indexer** (see §9) — it's the one genuinely dynamic subsystem.

---

## 4. Information architecture — from "what is this" to acting

The site is one premium landing scroll (the current App.tsx spine, re-sequenced) **plus** a small set of
dedicated app routes for the Market. A newcomer should be able to go top-to-bottom and understand
Seats → Tiers → the Exchange → the Bell → Notes → Cases before they're ever asked to connect a wallet.

### Sitemap

```
/  (landing — the scroll)
│
├─ 1. HERO — "The Exchange"                     provably fair AND solvent, live Bell + Tape  (§2)
├─ 2. THE CLAIM STRIP                        one line: the odds AND the books are provable
├─ 3. HOW THE CLUB WORKS  (the on-ramp)      Seat → Tier → the Bell → Payout, as a 4-beat flow (§5)
├─ 4. THE MECHANICS  (explainer cards)       one card per glossary term, each with its interaction (§5)
│      Seat · Vault · Tier · the Exchange · the Bell · Payout · After Hours · Note · Cases · $ESSEY
├─ 5. THE PROVABLE TWIST                      "the part they can't copy" — fair + solvent, verify buttons
├─ 6. THE LENDING ENGINE UNDERNEATH          the existing Markets + Borrow/Earn surface, reframed as
│      "why the Payouts are real": conservative oracle, fail-closed, Notes  (keeps App.tsx Markets/Money)
├─ 7. THE NUMBERS                             live: Seats minted, Payouts distributed, TVL, pot run-rate
├─ 8. DOCS READING ROOM                       the existing DocsSection, extended  (§7)
├─ 9. FOOTER                                  honest disclaimers, links, "not a dividend" note
│
└─ permanent: ticker-tape RAIL (bottom) + first-visit WARNING modal  (§6)

/market        the app: your Seats, your Vaults, Tiers, live Bell, connect  (gated interactions)
/exchange      buy / snipe / sell a Seat  (EsseyExchange)
/bell          the Bell in full: pot, ring, your claimable Payouts, After Hours, Tier ladder
/tape          the full live proof room  (§3)
/cases         the Case system  (scoped; ships behind a flag, jurisdiction-gated §6)
/notes         your loan positions as bearer Notes: sell / transfer / prove solvent
/docs/:slug    deep-linkable docs reading room  (§7)
```

### The newcomer's path (designed, not accidental)

1. **Land (Hero):** sees money moving + "both provable." Feels: *this is alive and it's honest.*
2. **The claim strip → How the club works:** four beats — *Get a Seat → Raise its Tier → Someone rings
   the Bell → Stock lands in your Vault.* This is the dopamine loop in one sentence before any jargon.
3. **The Mechanics cards (§5):** each term explained in a one-liner + a toy interaction. Self-paced.
4. **The provable twist:** now that they get the game, hit the differentiator — and hand them a *verify*
   button so it's not just a claim.
5. **The lending engine underneath:** the serious reader who asks "where does the yield come from?" gets
   the real answer (fees from real loans + royalties + interest share — `TOKENOMICS-essey.md`), which is
   also the current site's strongest material. This reassures rather than excites — on purpose.
6. **Act:** "Enter the Market" → `/market`, connect, earn a Seat by borrowing/supplying (the usage-gated
   free mint, `TOKENOMICS-essey.md` decision #1), or buy one on the Exchange.

The genius of the sequence: **the game pulls them in, the proof keeps them, and the lending engine is the
reason the proof is real.** Degen sites only have step 1.

---

## 5. Explaining each mechanic — simple + fun (the core of the ask)

For every glossary term (`DESIGN-seats-market-layer.md`): a **one-liner** anyone gets, plus a
**visual/interaction** that makes the on-chain mechanic graspable and enticing. Each card carries a small
"verify" or "see it on the Tape" link so the fun always resolves to proof. Copy is honest — "Payout,"
never "dividend."

### ⬡ Seat — *membership NFT*
- **One-liner:** "A seat on the exchange. Own one, and you get a cut of everything the Exchange earns."
- **Interaction:** a **seat map** — 2,222 hexagon seats laid out like a stadium/trading-floor chart, lit
  ones = owned/active, dim = held by the Exchange as float. Hover a lit seat → its Vault contents + last
  Payout. Live count ticks as Seats mint. Makes scarcity *visible* (and honestly shows the Exchange holds
  much of the float — `ECONOMICS-seats-model.md` insight #1, "that's the design, not a failure").

### ⬡ Vault — *the Seat's token-bound wallet (ERC-6551)*
- **One-liner:** "Every Seat carries its own wallet. Sell the Seat, the wallet and everything in it goes
  with it."
- **Interaction:** a Seat card that **flips** to reveal its Vault — stacked stock tokens + collateral
  inside. Drag the Seat to a "sell" zone and the Vault visibly travels with it. The "aha": the NFT *is* a
  wallet. (Grounded: `SeatVault.sol`, transfer moves the Vault + contents.)

### ▲ Tier — *staking level*
- **One-liner:** "Stake $ESSEY to level up your Seat. Higher Tier = a bigger slice of every Payout."
- **Interaction:** a **weight ladder** (100 / 160 / 200 / 333 — the kept ratios from
  `ECONOMICS-seats-model.md`). Drag a slider up the ladder and watch a mock Payout re-split live toward
  your Seat. Show the honest cost: 50% of the activation fee is **burned**. Note the churn truth — Tier
  clears on transfer, so it's a recurring choice, not a one-time flex.

### ⇄ the Exchange — *the Seat AMM*
- **One-liner:** "Swap $ESSEY for a Seat instantly — take the next one, or snipe the exact number you
  want."
- **Interaction:** two buttons, **Buy next** (flat price) and **Snipe #____** (type a number, pay the
  premium fee). A tiny inventory readout shows Seats-in-float shrinking as people buy. Every trade's fee
  visibly **drops into the Bell pot** on the same screen — so you *see* trading feed the Payouts
  (grounded: `EsseyExchange.sol`, fees → Bell pot, verified end-to-end).

### 🔔 the Bell — *permissionless payout event*
- **One-liner:** "When the fee pot is full, anyone can ring the Bell — and whoever does earns a tip for
  paying the gas."
- **Interaction:** the hero's centerpiece. A **fill gauge** on the pot; when full, a big brass **RING**
  button anyone can press. Pressing it triggers the Bell moment (§2) and shows *your* tipper's cut. The
  hook is real and unusually generous to explain: *you* can be the one who rings it. O(1), no bot, no
  admin (`Bell.sol`).

### ◆ Payout — *the fee-funded reward (NOT "dividend")*
- **One-liner:** "The Bell splits the pot into every active Seat's Vault — paid in real stock, by Tier."
- **Interaction:** an animated **split diagram** — one pot → many Vaults, slice sizes proportional to
  Tier weight, tokens (AAPL/NVDA/USDG) raining into Vaults. Always labeled *Payout* with a footnote:
  "protocol fees distributed to Seat holders — mechanically LP-style fees, not a dividend"
  (`DESIGN-seats-market-layer.md` §honest-risk-flags). Let the user set a **payout preference** toggle
  (base vs a specific stock) — real feature (`StockConverter`, Phase 2.5).

### 🌙 After Hours — *the second payout engine*
- **One-liner:** "A second Bell, funded by a different stream — the Exchange keeps paying after the close."
- **Interaction:** a day/night toggle on the Bell page: "Regular Hours" (trade + origination fees) vs
  "After Hours" (e.g. liquidation revenue / royalties). Reinforces the durability story from
  `TOKENOMICS-essey.md`: royalties + loan-interest are the engines that outlast launch trade-fees.

### 📜 Note — *loan position as a transferable NFT*
- **One-liner:** "Your loan is a certificate you can sell. The debt, the collateral, and its solvency
  proof all travel with it."
- **Interaction:** a **bearer certificate** card — debt on one side, collateral in its Vault on the
  other, the ⬡ hallmark stamped in the corner = *proven solvent*. A "transfer" demo shows the whole
  position changing hands intact. This is the moment the game meets the hard tech: *a self-contained,
  provably-solvent, portable credit object* (`Note.sol` — bearer deeds, `ownerOf(id)` auth; the killer
  line vs StonkBrokers' escrow-dead LoanVault).

### 🎁 Cases — *stock gacha (scoped, gated)*
- **One-liner:** "Open a Case, get real stock sealed in a Vault. Keep it, borrow against it, or sell it
  back."
- **Interaction:** a **case-opening** animation (the CS:GO reflex) that resolves into a *stock deed*, not
  a coin — and shows the **provable-bankroll** stamp: "the house reserved this prize in real inventory
  before you opened — verify ✓." Ship the **fair-value "401k pack" variant first** (not a game of chance);
  gate the multiplier "degen" variant behind jurisdiction + legal review (`TOKENOMICS-essey.md`,
  `DESIGN-seats-market-layer.md` §honest-risk-flags). The card copy must not overclaim — this is the
  reg-hot surface.

### ◈ $ESSEY — *the access token*
- **One-liner:** "The chip you spend to get in — buy Seats, raise Tiers, open Cases. You never earn
  $ESSEY; you earn stock."
- **Interaction:** a simple **sinks diagram**: $ESSEY flows *in* (Seats/Tiers/Cases), stock flows *out*
  (Payouts). The one honest sentence that defuses the death-spiral question: *"Rewards are never paid in
  $ESSEY — you spend the volatile token to earn the stable asset"* (`TOKENOMICS-essey.md`, the anti-death-
  spiral rule). Fixed supply, no emissions, no buyback in v1 — state it plainly.

### 📈 the Tape — *the live proof feed*
- **One-liner:** "Everything the Exchange does, printed live — and every line is a real receipt."
- **Interaction:** it's already live on the page (the rail). The card just points to `/tape` and the
  `⬡ proven only` filter (§3).

**Presentation:** these are a responsive grid of cards (evolving the existing `.doc-card` / flow-step
patterns already in `styles.css`). Each expands in place to its interaction (no page nav needed to
learn). The interactions are **toys, not the real app** — safe, no wallet, no risk — a sandbox to
understand before you commit. That is the trust move: *let them play with the mechanic before it costs
anything.*

---

## 6. The experimental-software warning (first-visit modal)

Matches StonkBrokers' first-visit disclaimer reflex and our own no-overclaim discipline
(`WHY-ESSEY-IS-DIFFERENT.md` §"being honest about the limits"). Honest enough to be real, human enough not
to scare people off. Reuses the existing `Overlay` component (`App.tsx`, focus-trap, scroll-lock) so it's
one build. Shows once, stored in `localStorage`; re-openable from the footer ("Terms & risk").

**Visual:** ink modal, the hallmark centered and *un-stamped* at first (a hollow hex), single accept
action. No dark patterns — the "Enter" button isn't pre-glowing; you read first.

**Draft copy:**

> ### ⬡ Before you step onto the Exchange
>
> **Essey is experimental software.** It's live, it's early, and it's built in the open — including the
> audits that made us look bad. Read this before you connect a wallet.
>
> - **Nothing here is financial advice.** Not from us, not from the app, not from anyone. You decide what
>   you do with your money.
> - **The assets are volatile.** $ESSEY is a pure access token — you spend it to get in; you never earn it
>   back as a reward. Its price moves with demand and can go to zero. Tokenized stocks move with their
>   markets and with oracle risk.
> - **"Payouts" are protocol fees, not dividends.** When the Bell rings, it distributes fees to Seat
>   holders as stock. That is a mechanical fee-share — **not a dividend, not a yield promise, not a
>   guarantee.** Some days the pot is thin. Some days nobody rings it.
> - **No payout is guaranteed.** Ever. The pot is whatever fees have accrued. If the Exchange is quiet, it's
>   quiet — and the Tape will show you that honestly.
> - **Provable ≠ risk-free.** We prove the things we can prove — that a distribution split is correct,
>   that a loan is solvent, that a draw was fair — and we hand you the button to check. We do **not** claim
>   the whole system is safe. Oracles can be wrong within their confidence band; liquidation isn't instant;
>   ordinary software has ordinary bugs. Proof removes one *class* of risk, not all of it.
> - **You are responsible for your own jurisdiction.** Some features (certain Case types) are restricted
>   in some places for good reason. Confirming you may lawfully use them is on you.
> - **Early and small.** Test assets, small amounts, no track record. Don't risk what you can't lose.
>
> Everything above is documented, with sources, in the docs room — and every claim on this site links to
> a real on-chain transaction you can verify yourself.
>
> **[ I understand — enter the Exchange ]**   ·   *Read the full docs first →*

Tone check: it discloses the volatility and the "no guaranteed payout" reality *as part of the pitch*
("the Tape will show you that honestly") rather than as a legal wall — which is exactly the brand (proof
you can check beats promises you must trust). "Payout, never dividend" is enforced in the copy itself.

---

## 7. The docs reading room — for the technical audience

We already have this and it's genuinely good: `DocsSection` renders the **repo's own markdown in-place**
(`marked` + `DOMPurify`, sanitized), grouped, each card linking `source ↗` to GitHub. Keep the substance,
elevate the room:

- **Framing headline stays honest:** *"These are the repo's own files, rendered here — not a marketing
  summary of them."* That sentence is a trust asset; keep it verbatim.
- **New groups for the Market layer** so the deep reader finds the new material: *The Market* (this doc,
  `DESIGN-seats-market-layer.md`), *Tokenomics* (`TOKENOMICS-essey.md`), *Economics — measured*
  (`ECONOMICS-seats-model.md`), alongside the existing *Risk*, *Audits*, *Architecture*, *Outstanding*.
- **Deep-linkable:** `/docs/:slug` so any doc is shareable/citable (the reader modal already remounts per
  slug — add a route + `?doc=` sync). Critical for a technical audience that links each other specific
  sections.
- **The audit trail gets a badge, not a hero:** a quiet "audited fix-first — 6 adversarial rounds, 66
  confirmed findings on Move, published clean or not" line linking `docs/audits/`. Understatement is the
  flex; it reads as confidence (`WHY-ESSEY-IS-DIFFERENT.md`).
- **Every mechanic card (§5) links into the exact doc section** that specifies it — so "fun explainer →
  formal spec" is one click. The game and the paper are the same object at two altitudes.
- **A "verify it yourself" appendix:** the Blockscout contract addresses (Seat, SeatVault, Bell,
  EsseyExchange, EsseyToken, Note, EsseyPool), each verified-source-linked. This is the literal receipts
  drawer for the whole protocol.
- **Reading affordances:** persistent left ToC on desktop, mono code blocks in gold (kept, `code {
  color: var(--gold) }`), reading-progress bar, and copy-anchor on headings. Keep it a *reading room*,
  calm and serif — the one place on the site with no motion, deliberately.

---

## 8. Mobile-first + theme

**Mobile is the primary surface** (StonkBrokers' traction was phone-first; a ring-the-Bell tap has to feel
great one-handed).

- **Hero on phone:** stacks to Bell widget first (the live hook), then headline, then CTAs. The Tape peek
  becomes a swipeable single row. Primary CTA is a full-width thumb-reachable gold button.
- **The ticker-tape rail on phone:** collapses to a single 32px line above the bottom nav; tap expands to
  a bottom-sheet `/tape`. Never covers content; respects safe-area insets.
- **Mechanic cards:** one-column, tap-to-expand accordions; the toy interactions are touch-designed
  (drag-the-Seat, slide-the-Tier) with generous hit targets.
- **The Bell moment on phone:** a contained brass pulse + a subtle haptic (`navigator.vibrate`, opt-in via
  reduced-motion respect), not a full-screen seizure.
- **Tables** (Markets, Tier ladder, Tape) get the existing `overflow-x: auto` scroll pattern already in
  `styles.css` (`.tbl-scroll`) — the page body never scrolls sideways.

**Theme — go light/dark aware (a real change).** The current site is `color-scheme: dark` only. The
rebrand adds a **light theme** because a premium finance brand should look right in daylight and because
theme-awareness itself signals polish/trust:

- **Dark (default, the club at night):** current ink/gold — unchanged, it's the signature.
- **Light (the trading floor by day):** a warm paper theme — ground `#F6F4EE` (paper-cream), ink text,
  the same gold as accent (gold sits beautifully on cream — it's literally gold-leaf-on-parchment, which
  *reinforces* the assay/hallmark metaphor). The Tape reads as ink-on-paper ticker tape — arguably more
  on-brand in light than dark.
- Implement with CSS custom properties already in place: promote the `:root` tokens to
  `:root[data-theme]` overrides, default from `prefers-color-scheme`, toggle in nav persists to
  `localStorage`. Semantic tokens (`--good/--warn/--crit`) get light-mode variants with AA contrast.
- **Reduced-motion** (§1): freezes the Tape crawl to a static list, disables the Bell sweep and the
  case-opening spin. Everything remains fully usable — proof doesn't require motion.

---

## 9. Build scope — pages, components, priority, dynamic vs static

### What's genuinely dynamic vs static

- **Needs an indexer (the one real backend):** the **Tape** (all three surfaces), the live **Bell** pot +
  ringable state, the **seat map** live counts, and **The Numbers** strip. Scope a lightweight indexer
  that subscribes to the Robinhood Chain events from the shipped contracts (`Bell`, `Seat`, `SeatVault`,
  `EsseyExchange`, `EsseyPool`/`Note`) and serves a small JSON/websocket feed. This is the critical-path
  new infra. `DESIGN-seats-market-layer.md` already calls the Tape "lightweight (app + indexer)."
- **Reads chain directly (dapp-kit / viem, no backend):** wallet-gated actions — buy/snipe/sell on the
  Exchange, ring the Bell, claim Payouts, activate Tiers, mint/earn a Seat, borrow/repay (Notes). Reuse
  the existing wallet + pool read patterns already in `App.tsx`/`pool.ts`/`markets.ts`.
- **Fully static (build-time):** the landing scroll, all §5 mechanic explainer cards and their **toy**
  interactions (client-side sandboxes, no chain), the warning modal, the docs reading room (already
  bundles `docs.generated.ts`), the footer. Most of the site is static — the dynamism is concentrated in
  the Tape + Bell.

### Component inventory (evolve existing where noted)

| Component | New/Evolve | Notes |
|---|---|---|
| `TickerTapeRail` | **new** | permanent bottom rail; the §1 risk; subscribes to indexer feed |
| `TapeRoom` (`/tape`) | **new** | full feed, filters incl. `⬡ proven only`, verify deep-links |
| `TapeRow` | **new** | one component, variant per event type; ends in Blockscout tx |
| `BellWidget` | **new** | pot gauge + RING + tipper cut + the Bell moment animation |
| `SeatMap` | **new** | 2,222-hex stadium map, live lit/float state |
| `MechanicCard` | **evolve** `.doc-card`/flow-step | expand-in-place, houses each §5 toy |
| `Hallmark` (stamp) | **evolve** existing `Hallmark` SVG | add "press/stamp" animated variant + flip-to-verify |
| `WarningModal` | **evolve** `Overlay` | first-visit gate, §6 copy, localStorage-once |
| `DocsSection`/`DocReader` | **evolve** | add Market groups, `/docs/:slug` routes, ToC, progress bar |
| `ThemeToggle` + light tokens | **new** | §8; promote `:root` → `[data-theme]` |
| Exchange / Bell / Notes / Cases panels | **new** | wallet-gated app routes; reuse pool/wallet plumbing |
| `Numbers` strip | **new** | live Seats/Payouts/TVL from indexer |

### Priority order (ship-sequenced, matches the contract phases that are already built)

**P0 — the rebrand's spine (mostly static; highest impact, lowest risk):**
1. Brand system pass: light/dark tokens, type sharpening, the **hallmark-as-stamp** motif + flip-to-verify.
2. **Hero "The Exchange"** with the live `BellWidget` + Tape peek (§2) — the single most important screen.
3. The **first-visit warning modal** (§6) — needed before any wallet action ships, and cheap (evolve `Overlay`).
4. §5 **mechanic explainer cards + toys** — the core of the ask; all static, no chain dependency, so they
   can ship immediately and carry the whole "understand it" job even before the app routes are live.
5. Docs reading room upgrade (§7) — evolve what exists; add Market/Tokenomics/Economics groups + routes.

**P1 — make it live (the dynamic subsystem):**
6. **The indexer** + `TickerTapeRail` (permanent) — the aesthetic bet; turns the static site alive.
7. **`/tape` full room** with the `⬡ proven only` filter — the differentiator made watchable.
8. The **Numbers** strip wired to the indexer.

**P2 — the app surface (wallet-gated; gated by contract audit sign-off):**
9. `/market` + `/exchange` (buy/snipe/sell — `EsseyExchange` is built), `/bell` (ring + claim + Tiers +
   After Hours — `Bell` is built), `/notes` (bearer Notes — `Note` is built). These wire the game to the
   shipped contracts; each ships as its contract clears the 3-agent gate.
10. **Usage-gated free-mint flow** (earn a Seat by borrowing/supplying — `TOKENOMICS-essey.md` decision #1).

**P3 — behind flags / legal review:**
11. `/cases` — ship the **fair-value "401k pack" variant first**; multiplier "degen" variant stays gated
    behind jurisdiction + legal review + a decided entropy source (`TOKENOMICS-essey.md` open items). Do
    not build the reg-hot surface on the critical path.

**Guardrails for the build (from the repo's own discipline):**
- No page may claim more than the contracts deliver — every "provable" claim needs a working *verify*
  link, or it says "designed to" (the exact status-honesty of `WHY-ESSEY-IS-DIFFERENT.md`/README).
- "Payout," never "dividend," everywhere — copy lint it.
- The Tape must degrade honestly when the indexer is behind (no fake motion).
- Reduced-motion and light/dark are acceptance criteria, not polish.
- Contracts stay untouched by this work; the site reads them, it doesn't change them.

---

## Appendix — the rebrand in one paragraph (for tweet/social alignment, task #14)

Essey is the stock-market club where **the odds and the books are both provable**. Buy a Seat, raise its
Tier, and when anyone rings the Bell, protocol fees land in your Vault as real stock — then borrow against
that stock in the same place. Every ring, every draw, every loan prints to a live Tape where each line is
a real on-chain receipt you can check yourself. StonkBrokers is provably fair. Essey is **provably fair
AND provably solvent** — and the whole site is a room where a ticker never stops printing the proof.
