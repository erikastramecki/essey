# DESIGN — "Earn Your Mint": the Essey whitelist + onboarding quest

**Status:** design + scope only. No contract or app code changes here — the market-layer
contracts are under the 3-agent audit gate. This document specs task **#17 (the mint distributor)**
and the off-chain + UI system around it.

**Grounded in:**
- `docs/TOKENOMICS-essey.md` — free mint, **usage-earned** (borrow/supply on `EsseyPool` earns a Seat
  allocation) + a **minter-controlled whitelist tranche** (decision #1). Supply target ~2,222 Seats.
- `docs/DESIGN-seats-market-layer.md` — the mechanic set + glossary (Seat, Vault, Tier, the Exchange,
  the Bell, Payout, Note, the Tape).
- `rh-chain/src/market/Seat.sol` — the NFT. **`minter` is immutable**, `mint()` is minter-gated, and
  `setHook` is one-shot. There is **no on-chain whitelist function anywhere yet.**
- `rh-chain/foundry.toml` — Robinhood Chain **testnet** `rh_testnet` (chainId **46630**,
  `rpc.testnet.chain.robinhood.com/rpc`) and **mainnet** (chainId 4663).
- Reference: StonkBrokers' `setWhitelist(stage, wallets[], allocations[])`, `MINT_PRICE = 0`, whitelist
  earned by burning a prior NFT. We keep the shape, **swap the earn-condition from "burn an NFT" to
  "dogfship the protocol on testnet."**

**The founder's thesis (the whole design serves this):** you earn a mainnet mint by *doing* the
protocol on testnet. The quest is simultaneously the **guided tour** (you learn Seats / Tiers / the
Bell / the Exchange / Notes / Cases by performing each one), the **onboarding** (you arrive on mainnet
already knowing how to use it), and the **sybil filter** (real, sequenced, time-gated usage costs more
to fake than a free mint is worth). Education = onboarding = sybil-resistance, fused into one funnel.

---

## 0. The hard architectural fact that shapes everything

`Seat.minter` is **immutable and set at construction** (`Seat.sol:26`, `Seat.sol:47`). Whoever is
wired as the minter at deploy time is the *only* address that can ever call `mint()`. Therefore:

> **The mint distributor (task #17) is not "a contract that talks to Seat" — it IS the Seat
> collection's `minter`.** The mainnet Seat must be deployed with `minter = MintDistributor`. There is
> no retrofit; if we deploy Seat with an EOA as minter, the whitelist mechanism has to live in that
> EOA's off-chain trust, which defeats the auditability goal. **Deploy order is load-bearing: deploy
> MintDistributor first (or via CREATE2 to a known address), then deploy Seat with that address as
> minter.** This must be in the mainnet deploy script and in the audit scope.

Everything below assumes the distributor is the minter and holds the whitelist state.

---

## 1. The quest flow — "One Trading Day"

The quest is framed as living **one full trading day** on the Exchange. Nine stations, ordered so each
teaches the mechanic the next one depends on. Every station is a **real testnet transaction** against
the deployed stack on chainId 46630. You cannot skip ahead — the UI unlocks stations in order because
the on-chain prerequisites gate them (you can't ring a Bell with an empty pot; you can't raise a Tier
without a Seat).

Stations 1–7 are the **core quest** (required for any whitelist spot). Station 8 (Case) is a **bonus**
because the Case system is Phase 5 / not yet built (`DESIGN-seats-market-layer.md` §Phase 5) — it ships
as a bonus station only once a testnet Case contract exists. Station 9 (Verify) is a required *click*,
not a tx — it teaches the brand.

| # | Station name | The action (testnet tx) | What you learn | Why it's a good quest step |
|---|---|---|---|---|
| 1 | **Get Seated** | Claim testnet **gas ETH** + testnet **USDG** from the Essey faucet | wallet, chain, gas, the stable unit of account | The faucet is the sybil chokepoint (§3). Teaches the chain before any risk. |
| 2 | **Take a Position** | **Supply** USDG to `EsseyPool` (≥ a meaningful minimum) | the lender side; where yield/TVL comes from | Supplying, not borrowing, is the safest first real action — no liquidation risk, teaches the pool. |
| 3 | **Post a Note** | Deposit stock collateral, **borrow** USDG → this **mints a Note** (`Note.sol`, minted by the pool on borrow) | Notes, collateral, LTV, the portable bearer deed | The single richest teaching moment: collateral, health, and "your loan is an NFT you could sell." |
| 4 | **Buy a Seat** | On **the Exchange** (`EsseyExchange.sol`), swap testnet $ESSEY → the next **Seat** (`buy`) | the Exchange AMM, Seats, the Vault (ERC-6551) that travels with it | Gets the user their membership object — the thing the whole club is about. |
| 5 | **Raise your Tier** | **Stake** $ESSEY on your Seat to activate a **Tier** (`Bell.sol` tier staking, 50% burn) | Tiers, the $ESSEY sink, payout weight | Teaches the access-demand loop and sets up a non-zero payout weight for stations 6–7. |
| 6 | **Ring the Bell** | Call `ring()` on the **Bell** when the fee pot is full — permissionless, earns the tipper's cut | the Bell, permissionless payouts, O(1) accumulator | "Anyone can ring, and you get paid to" is the most StonkBrokers-fun moment — a real reward for a real tx. |
| 7 | **Claim your Payout** | **Claim** the Tier-weighted Payout into your Seat's **Vault** | Payouts (never "dividend"), Vaults as the wallet | Closes the flywheel loop the user just powered: fees → Bell → Payout into *your* Vault. |
| 8 | **Crack a Case** *(bonus)* | Buy + open a **Case**, receive stock sealed in a Vault-NFT | the gacha/stock-acquisition path, sell-back spread | Bonus until Phase 5 testnet contract exists. High-delight, so it's the natural "extra credit." |
| 9 | **Verify it yourself** | Click **Verify** on a Tape row (a proof, solvency, or a fair draw) | the moat: *provably fair AND provably solvent* | Not a tx — a click. Teaches that "verify it yourself" is a button, not a slogan. The brand payoff. |

**Design notes on the ordering**
- **Supply before borrow (2 → 3):** the borrower needs a funded pool to borrow from; supplying first is
  both pedagogically safer and makes the testnet pool self-seeding as more questers arrive.
- **Tier before Ring/Claim (5 → 6 → 7):** a Seat with no Tier has ~zero payout weight, so claiming would
  teach nothing. Staking first makes the Payout in station 7 land as a real, visible number in the Vault.
- **The Bell needs a full pot:** stations 3–5 *generate the fees* (borrow origination, Exchange trade
  fee, tier activation) that fill the pot the user then rings in station 6. The quest is self-fueling:
  earlier stations literally create the reward the later stations distribute. This is not a coincidence
  to hide — **surface it in copy** ("the fees you just paid are the pot you're about to ring").

---

## 2. Allocation model — how testnet activity → a mainnet mint slot

Design principles: **binary floor, graded ceiling.** Completing the core quest is pass/fail (you either
did all seven real actions or you didn't — no partial credit, which kills spam-for-points). *On top of*
that floor, depth and earliness earn a better **stage** (mint earlier) and occasionally **+1 allocation**.

### Supply split (~2,222 Seats, tunable against the economics memo)

| Tranche | Size (illustrative) | How you get in |
|---|---|---|
| **Founding** | ~222 (first-N completers) | Full core quest **+** curated review (§3). Mints first, guaranteed 1 Seat, gets the "Founder" badge. |
| **General (earned)** | ~1,600 | Full core quest, passes anti-sybil + attestor review. Guaranteed 1 Seat within the General window. |
| **Partner/Community** | ~200 | Minter discretion (early community, integrations, StonkBrokers-style partners) — decision #1's reserved tranche. |
| **Float / LP / treasury** | remainder | Never minted to individuals; the Exchange's inventory + liquidity (per TOKENOMICS float-control). |

If earned demand exceeds the earned tranches, **completion still guarantees eligibility** but mint order
is set by the priority score below; excess completers roll to a public post-launch Exchange buy (they
learned the protocol either way — no wasted funnel).

### The score (decides *stage* and *order*, not *whether*)

Completion of all 7 core stations = **1.0 base** (the guaranteed floor). Everything else is a
**priority multiplier / additive**, capped, so no single lever is farmable into a landslide:

- **First-N-completers bonus** — the first ~222 verified completers → **Founding** stage. Pure
  earliness; the strongest, fairest motivator (StonkBrokers' whitelist was also earliness-gated).
- **Depth bonus (small, capped):** supplied ≥ 2× the minimum, or held the Note healthy past the
  time-gate (§3) → +0.25. Rewards *meaningful* usage over dust.
- **Streak bonus (capped):** touched the quest across ≥ 3 distinct UTC days → +0.25. Time is the one
  thing sybil farms can't parallelize cheaply.
- **Referral bonus (capped, anti-collusion):** you referred someone who **also fully completed** →
  +0.1 each, max +0.3. Only completers count, so referral farming requires farming full quests — which
  is exactly the expensive behavior we want.
- **Identity/social multiplier (optional, priority-only):** a passport score / linked social → moves you
  up the *order*, never a hard gate (keeps the base permissionless). See §3.

**Hard caps:** 1 Seat per address in the earned tranches (Founding + General). Bonuses affect *stage and
order only*; the max any earned address mints is 1 unless the minter explicitly grants a Partner slot.
This keeps a whale who farms depth from vacuuming allocations — the scarce reward is *earliness*, which
is zero-sum and self-limiting.

**Why binary floor + graded ceiling:** a pure points system invites "grind 400 dust txs for rank 1."
Making completion binary means the *only* way to score at all is to do all seven real, sequenced,
time-gated actions — and the extras are bounded, so the game is "complete early and for real," not
"spam hardest."

---

## 3. Anti-sybil — honest about what testnet can and can't prove

**The uncomfortable truth up front:** testnet transactions are ~free, the faucet is the only real cost,
and **no amount of testnet activity proves unique humanity.** A ZK proof of testnet activity proves the
activity *rigorously* but the activity itself is still cheap — proving a farmable thing precisely doesn't
make it unfarmable. So the honest goal is **not** "make sybils impossible." It is:

> **Raise the cost-to-farm-one-slot above the value-of-one-free-mint, and put a curated human gate on
> the tranche where it matters most (Founding).**

Everything below is in service of that. Layered, because no single layer holds:

1. **Full-quest requirement (the primary defense).** A whitelist spot requires *all seven* core
   stations, each a **distinct contract interaction** (supply, borrow/Note-mint, Exchange buy, tier
   stake, Bell ring, claim, + faucet). You cannot farm by repeating one cheap action. A sybil must
   reproduce a seven-step, ordered, interdependent flow **per fake address**.

2. **The faucet is the chokepoint, not gas.** Gas is free; **meaningful USDG collateral is not, if we
   make the faucet the scarce resource.** Gate testnet USDG behind a **rate-limited, identity-lite
   faucet**: captcha + one of {GitHub OAuth of age > N months, Gitcoin Passport ≥ threshold, a small
   proof-of-personhood}. One faucet grant per identity per cooldown, sized to *just enough* for one
   quest run. This is the single highest-leverage control: it moves the cost of a sybil from "gas" to
   "a fresh aged identity + a faucet cooldown." Be honest in copy that this is a *speed bump*, not a wall.

3. **Economic-depth minimums.** Station 2 requires supply ≥ a floor; station 3 a borrow ≥ a floor. Dust
   (1 wei) doesn't count toward completion. Combined with the faucet cap, this means each sybil consumes
   a whole faucet grant, so faucet throughput *is* the sybil throughput ceiling.

4. **Time-gating / hold requirement.** The Note from station 3 must **stay open and healthy for ≥ 72h**
   before completion locks. Time cannot be parallelized away: 1,000 sybils still each need the wall-clock
   hold, and each is exposed to a (testnet) liquidation if they under-collateralize — teaching real risk
   *and* adding a maintenance cost per fake.

5. **Streak / recency window.** The quest must span ≥ 3 distinct UTC days (also a scoring lever, §2).
   Turns a one-shot script into a multi-day babysitting job per address.

6. **Per-address + per-funding-cluster caps.** 1 earned Seat per address. The attestor additionally runs
   **funding-graph clustering** on testnet: addresses funded from the same source, or exhibiting
   near-identical timing entropy, are flagged and **discounted to one effective completion** for the
   Founding tranche (and reviewed for General). Testnet-honest caveat: funding graphs are weaker on
   testnet (faucet-funded addresses share a source *by design*), so this is a *signal*, not a verdict —
   it feeds the review queue, it doesn't auto-reject.

7. **Optional identity/social signals — as priority, never as the base gate.** Passport score, a linked
   and aged social account, or a Discord role **move you up the order** and are **required for Founding**,
   but are never required for a General earned slot. This preserves a permissionless base (anyone can
   earn *a* slot by doing the work) while letting the scarce, first-to-mint Founding tranche carry a
   real human gate.

8. **Curated final review + public allowlist.** Before the minter calls `setWhitelist`, the computed
   allowlist (addresses + stage + allocation, derived from **public testnet logs**) is **published for a
   review window**. Anyone can recompute it from chain data and dispute. Founding especially gets a
   human pass. This is the "trust but publish" backstop the whole system leans on (§4).

**What we tell users (honesty discipline, per repo norms):** "Testnet farming is possible and we don't
pretend otherwise. We make it expensive, slow, and reviewed — and the earliest, best slots require
passing a human gate. Do the quest for real and you're fine." No overclaiming of "sybil-proof."

---

## 4. On-chain verification → mainnet whitelist

### The mechanism (recommended: Merkle-committed attestor)

```
Testnet (46630)                    Off-chain                         Mainnet (4663)
──────────────                     ─────────                         ──────────────
questers emit events   ──►  Indexer reads logs per address  ──►  Attestor computes
(Supply, Borrow/Note,        (station-by-station completion,       {addr → stage, alloc}
 Exchange Buy, Tier,          hold-time, streak, clustering)        │
 Bell Ring, Claim)                        │                         ▼
                                          │              Publishes dataset + Merkle root
                                          │              for a public review window
                                          ▼                         │
                             Minter (2-key/timelock) ──────────────►│
                                                     setWhitelist(  ▼
                                                       stage, root / wallets[], allocs[])
                                                     on MintDistributor (= Seat.minter)
                                                            │
                                    quester calls mint() ───┘  (free; checks their allocation)
```

**Steps:**
1. **Indexer** subscribes to the testnet stack's events for each participating address and records which
   of the seven stations fired, plus timestamps (for hold-time and streak) and funding source.
2. **Attestor** applies the completion rules + anti-sybil scoring (§2, §3) → produces `{address → stage,
   allocation}`.
3. **Publish** the full dataset **and its Merkle root** during a review window. Because it's derived
   entirely from **public testnet logs**, anyone can independently recompute it and check the root.
4. **Minter** (a **2-of-N multisig behind a short timelock**, emitting events) calls
   `setWhitelist(stage, root)` — or `setWhitelist(stage, wallets[], allocations[])` for small tranches —
   on the **MintDistributor**.
5. **Questers** call `mint()` on the distributor; it verifies their allocation (Merkle proof against the
   committed root, or the stored mapping) and mints their Seat **for free** (`MINT_PRICE = 0`, per
   TOKENOMICS + the StonkBrokers reference), respecting per-address caps and stage timing.

### The trust assumption, stated plainly

**There is exactly one trusted off-chain component: the attestor that asserts "this address completed the
testnet quest."** The chain can't natively read another chain's logs, so *someone* bridges testnet
completion → mainnet allowlist. We keep that honest by making it **auditable, not blind**:

- **Derived from public data:** every input (testnet logs) is public; the mapping is reproducible by
  anyone. The attestor has no private inputs.
- **Committed + reviewable:** publish the root and the dataset; a review window lets the community catch
  a corrupt or buggy allowlist *before* it's set.
- **Constrained key:** `setWhitelist` is multisig + timelocked + evented (matches the repo's "if admin
  must exist, timelock + events" posture, `DESIGN-seats-market-layer.md` §Trust model). It can *add* a
  stage's allowlist; design it **append-only per stage / finalizable** so a set stage can't be silently
  rewritten after mint opens.
- **Bounded power:** the distributor's only power is *who may mint a free Seat*. It cannot touch funds,
  the pool, the Bell, or existing Seats. Worst-case abuse = a wrong free mint, caught by the public
  allowlist + capped supply. This is deliberately the *least* powerful place to put the one trusted step.

### Can any of it be trustless? (tie to the provable brand — honestly)

- **ZK proof of testnet activity.** In principle: a storage/receipt proof that address X emitted the
  required event set on testnet, verified on mainnet. **Honest assessment:** (a) it's heavy — you're
  proving cross-chain state against a testnet with *no economic security or finality*, so the proof is
  rigorous about a substrate that is itself cheap to manipulate; (b) **it removes the attestor's
  discretion but not the sybil economics** — it can't prove hold-time-under-real-risk or unique
  humanity, which are exactly the properties that matter. A ZK proof of a farmable quest is a precise
  proof of a farmable quest.
- **Recommendation:** ship the **Merkle-committed attestor now** (auditable, cheap, good enough given a
  capped free mint). Treat a ZK completion proof as a **v2 brand flourish** on the *verification* surface
  (station 9, the Tape) — where Essey's "verify it yourself" story is genuinely load-bearing — **not** as
  the sybil fix it can't actually be. Don't let the brand write a check the mechanism can't cash.

---

## 5. The gamification wrapper

Point StonkBrokers' engagement energy at *real usage* — every flashy moment is backed by a real testnet
tx and reuses the market-club vocabulary (Seats / Tiers / the Bell / the Exchange / the Tape).

- **The board — "The Trading Desk."** The quest home is a live board of the nine stations styled as a
  market ticker. Locked stations are greyed; the next one pulses. On-brand chrome: an opening-bell
  animation when you start, a closing bell when you complete.
- **Progress — "your Ticker."** A seven-cell tape (core stations) that fills as each on-chain action
  confirms. Each cell flips from ░ to a green print the moment the tx lands — the same "a real tx per
  row" ethos as the Tape.
- **Badges — station stamps.** `Get Seated`, `On the Tape`, `Noteholder`, `Seated` (bought a Seat),
  `Tiered Up`, `Bellringer`, `Paid`, and the bonus `Case Cracker` + the brand `Verifier`. Founding
  completers get a distinct `Founder` stamp. Badges are cosmetic testnet SBT-style marks (or just
  off-chain until mint) — they visualize the funnel and are shareable.
- **The live leaderboard.** Ranks completers by priority score (earliness, depth, streak, referrals),
  with a visible **"Founding slots remaining: N/222"** counter to drive the first-N urgency honestly.
  Streaks and "days on the Exchange" shown to reward the time-gating rather than hide it.
- **The Tape tie-in.** The testnet deployment runs a **testnet Tape** (`DESIGN-seats-market-layer.md`
  §The Tape). Questers' own Bells, Payouts, and Notes appear on it in real time — so a quester *watches
  their own quest actions* scroll the public feed. Station 9's "Verify" button lives on Tape rows. This
  makes the quest feel like joining a live market, not filling a form.
- **The "you're whitelisted" moment — "You've earned your Seat."** On attestation, the closing bell
  rings, a stamped **Ticket** card is issued (your address, stage, allocation, a shareable image) and the
  UI flips to a countdown to the mainnet mint window for your stage. This is the payoff screen — make it
  as loud as StonkBrokers' mint reveal, but the thing being celebrated is *"you already know how to use
  this,"* which is true.
- **Vocabulary discipline.** Never invent parallel jargon. It's Seats, Tiers, the Bell, the Exchange,
  Notes, the Tape, Payouts (never "dividend"), Vaults. The quest teaches the *actual* nouns the mainnet
  app uses, so onboarding transfers 1:1.

---

## 6. Instructions / copy (user-facing, ship-ready draft)

Voice: fun, direct, a little market-floor swagger; unambiguous on the mechanics; honest on risk. Each
station shows **Do this → Why → You'll learn** and a live "waiting for your tx…" state.

> ### Welcome to the Exchange. Earn your Seat by trading a day on Essey.
> No presale. No allowlist form. You get a mainnet Seat by actually *using* Essey on testnet — supply,
> borrow, buy a Seat, ring the Bell, get paid. Finish the day, earn your mint. This is testnet: fake
> money, real mechanics, real proof. Let's ring the opening bell.
>
> **Station 1 — Get Seated.** Tap *Claim* to get testnet gas + testnet USDG.
> *Why:* you can't trade with an empty pocket. *You'll learn:* your wallet, the chain, and USDG, the unit
> everything's priced in. (One claim per person — this is how we keep the farmers out.)
>
> **Station 2 — Take a Position.** *Supply* your USDG to the pool.
> *Why:* every loan is funded by someone who supplied first. Today that's you. *You'll learn:* the lender
> side and where yield comes from. No liquidation risk here — you're the bank.
>
> **Station 3 — Post a Note.** Put up a little stock as collateral and *borrow* against it. Congrats —
> you just minted a **Note**, a loan you could literally sell.
> *Why:* this is Essey's core trick — your loan is a transferable, provably-solvent object. *You'll
> learn:* collateral, health, and LTV. Keep it healthy for 3 days to lock your completion (yes, that's on
> purpose — real positions take time, and so does earning your Seat).
>
> **Station 4 — Buy a Seat.** Head to **the Exchange** and swap $ESSEY for the next **Seat**.
> *Why:* the Seat *is* the club — it earns a share of the Exchange. *You'll learn:* the Exchange, and the
> **Vault** that rides inside every Seat and travels with it when you sell.
>
> **Station 5 — Raise your Tier.** Stake $ESSEY on your Seat to activate a **Tier**.
> *Why:* higher Tier = bigger cut of every Payout. *You'll learn:* the $ESSEY sink and why Tier is your
> payout weight. (Half your stake burns — that's the token doing its job.)
>
> **Station 6 — Ring the Bell.** The fee pot is full — from the fees *you* just paid in stations 3–5.
> Hit **Ring**. Anyone can, and the ringer takes a tip.
> *Why:* Payouts are permissionless — no bot, no admin, just whoever rings. *You'll learn:* the Bell, and
> that you get *paid* to push the button.
>
> **Station 7 — Claim your Payout.** Pull your Tier-weighted **Payout** into your Vault.
> *Why:* the loop just closed — fees became a reward, and it landed in *your* Seat. *You'll learn:* what a
> Payout is (a share of real fees — never a "dividend") and that your Vault is your wallet.
>
> **Station 8 — Crack a Case.** *(Bonus.)* Buy a **Case**, open it, and see what stock you drew — sealed
> in its own tradeable Vault.
> *Why:* it's the fun one. *You'll learn:* the gacha path, and that you can borrow against or sell back
> what you draw. (Extra credit — bumps you up the leaderboard.)
>
> **Station 9 — Verify it yourself.** On the Tape, hit **Verify** on any row — a Payout, a solvent Note,
> a fair draw.
> *Why:* this is the whole point of Essey. *You'll learn:* "provably fair AND provably solvent" isn't a
> tagline, it's a button. Click it. That's your last stamp.
>
> ### Closing bell — you've earned your Seat.
> Finish all seven core stations and you're on the mainnet whitelist. Earliest, deepest, most consistent
> questers mint first (the first 222 become **Founders**). Your Ticket shows your stage and slot.
> We publish the whole list from public testnet data before anyone mints — verify your own spot. See you
> on the Exchange.

---

## 7. Build scope

Priority order, with trust/security flags. **Nothing here modifies audited contracts;** the pool-auth
Note change already landed (`DESIGN-seats-market-layer.md` §Phase 3).

### P1 — MintDistributor contract (task #17) — **SECURITY-CRITICAL: it is the Seat minter**

New additive contract. Deployed **before** mainnet Seat; Seat is deployed with `minter = MintDistributor`
(see §0). Full 3-agent audit gate before push, like everything money/scarcity-touching.

**Interface spec (design intent — not final code):**

```solidity
interface IMintDistributor {
    // ── stages (Founding, General, Partner…), each with its own open/close window ──
    struct Stage { bytes32 root; uint64 opensAt; uint64 closesAt; bool finalized; }

    // Minter (multisig+timelock) commits an allowlist for a stage.
    // Merkle mode for large tranches; explicit arrays for small/partner ones.
    function setWhitelist(uint8 stage, bytes32 merkleRoot, uint64 opensAt, uint64 closesAt) external;
    function setWhitelist(uint8 stage, address[] calldata wallets, uint16[] calldata allocations) external;

    // Append-only / finalize: once a stage is finalized its root cannot change (anti-rug of the list).
    function finalizeStage(uint8 stage) external;

    // Quester mints their earned Seat(s). Free (MINT_PRICE = 0). Enforces per-address cap + stage window.
    function mint(uint8 stage, uint16 allocation, bytes32[] calldata proof) external returns (uint256 seatId);

    // Views for the UI: has this address minted? remaining supply? stage state?
    function minted(address who) external view returns (uint16);
    function stageOf(uint8 stage) external view returns (Stage memory);
}
```

**Required properties (audit checklist):**
- **Immutable Seat binding** — holds the Seat address immutably; is the sole minter.
- **Free mint** — `MINT_PRICE = 0` constant (TOKENOMICS decision #1; StonkBrokers reference).
- **Per-address cap** — 1 earned Seat per address across Founding+General; double-mint impossible even
  across stages (track `minted[who]`).
- **Global supply cap** — never mints past the reserved earned tranches; respects Seat's own `maxSupply`.
- **Finalizable stages** — a set-and-finalized root/list cannot be rewritten (the "publish then set"
  guarantee has teeth).
- **Constrained admin** — `setWhitelist`/`finalizeStage` behind multisig + timelock + events; **no** key
  can move funds, touch the pool/Bell, or alter existing Seats. No `receive`; no rescue-into-EOA.
- **Reentrancy-safe mint** — `mint()` calls `Seat.mint` (which stands up a Vault clone); guard + CEI.
- **Merkle verification** — standard sorted-pair OZ MerkleProof; allocation encoded in the leaf so a
  proof can't be replayed for a bigger allocation.

**Trust flag:** the *only* trusted input is the attestor-computed root, mitigated by public-data
derivation + review window + finalize (§4). This is the highest-risk new artifact in the whole system —
gate it hardest.

### P2 — Testnet deployment of the full stack — **needed before any quest can run**

- Run `script/Deploy.s.sol` against `rh_testnet` (chainId 46630, per `foundry.toml`), with env overrides
  for testnet USDG/stock/feed addresses (the script already reads decimals from chain, `Deploy.s.sol:39`).
- Deploy the market layer: testnet `EsseyToken`, `Seat` (testnet minter can be a simple testnet
  distributor or EOA — testnet Seats are throwaway), `SeatVault` impl, `Bell`, `EsseyExchange`
  (**seed it with Seat inventory + $ESSEY reserve** so station 4 works), `StockConverter`, `Note`
  wiring. Fund a testnet feed or point at a testnet oracle.
- **Faucet-fund the Exchange and pool** enough that early questers aren't blocked by an empty pool/empty
  Exchange inventory before organic supply arrives.
- Stand up a **testnet Tape** indexer for the live feed.
- *(When Phase 5 lands)* deploy a testnet Case contract to light up bonus station 8.

**Flag:** testnet economic params (min supply/borrow, Exchange price/fees, tier costs) are quest-tuning
knobs, not the mainnet economics memo — set them for *learnability*, not yield.

### P3 — Faucet service — **the anti-sybil chokepoint, build it deliberately**

Rate-limited, identity-lite (captcha + one of aged-GitHub / Passport / PoP), one grant per identity per
cooldown, grant sized to one quest run (gas + just-enough USDG + a little $ESSEY for stations 4–5).
**This is the single most important sybil control (§3);** its throughput *is* the sybil ceiling. Log
funding for the attestor's clustering. Keep the personhood check swappable.

### P4 — Indexer / attestor — **the one trusted off-chain component**

- Indexes testnet events per address → station completion, hold-time, streak, funding source.
- Applies completion + scoring + clustering rules (§2, §3) → `{address → stage, allocation}`.
- Publishes the **dataset + Merkle root** for the review window; then the multisig calls `setWhitelist`.
- **Must be reproducible from public testnet logs** — ship the computation as an open script so anyone
  can recompute the root. That reproducibility *is* the trust mitigation (§4).

**Flag:** discretion lives here (clustering, Founding review). Keep inputs public, publish before set,
constrain the key.

### P5 — Quest UI — **the funnel + the fun**

The Trading Desk board, the seven-cell Ticker progress, station-gated flow with the copy in §6, badges,
the live leaderboard with the Founding counter, the testnet Tape embed with Verify buttons, and the
"You've earned your Seat" Ticket + mainnet-mint countdown. Reuses mainnet app components/vocabulary so
onboarding transfers 1:1 (`app/web/`).

### Sequencing

**P2 (testnet stack) → P3 (faucet) → P5 (UI) can run the live quest and start collecting completions
immediately.** P4 (attestor) is needed before *attesting* but not before *questing* — questers can
accumulate on-chain history while it's built. **P1 (MintDistributor) is only needed at mainnet-mint
time**, but it's the highest-risk artifact, so **start its design + audit early and in parallel** — it
must not be rushed at the end. Locked deploy-order dependency: MintDistributor deployed before/with the
mainnet Seat (§0).

---

## Summary (the recommendation, tight)

- **Quest:** one ordered "trading day" of **seven required real testnet actions** — faucet → supply →
  borrow (mint a Note) → buy a Seat → raise a Tier → ring the Bell → claim a Payout — plus a **bonus
  Case** (when Phase 5 lands) and a required **Verify** click. Each station teaches the mechanic the next
  depends on, and the early stations literally generate the fee pot the later ones distribute.
- **Allocation:** **binary floor, graded ceiling** — completing all seven = a guaranteed earned Seat (1
  per address); **earliness (first ~222 = Founding), capped depth/streak/referral bonuses** decide *stage
  and order*, never *whether*. ~2,222 supply split Founding / General-earned / Partner / float.
- **Anti-sybil (honest):** testnet can't prove humanity, so we **raise cost-to-farm above value-of-mint**:
  full seven-step quest per address, **the identity-lite rate-limited faucet as the real chokepoint**,
  economic-depth minimums, a **72h healthy-Note hold** + **3-day streak** (time can't be parallelized),
  funding-cluster flags, optional identity as *priority + Founding gate only*, and a **public,
  recomputable allowlist + curated Founding review** before mint.
- **Verification:** an **indexer/attestor reads public testnet logs → publishes a dataset + Merkle root →
  multisig+timelock calls `setWhitelist` on the MintDistributor** (which *is* the immutable Seat minter,
  §0). One trusted step, made auditable by public-data derivation + a review window + finalizable stages.
  **ZK-proof-of-testnet is a v2 brand flourish on the Verify surface, not the sybil fix it can't be** —
  said honestly.
- **Top build items, in priority:** (1) **MintDistributor** — task #17, security-critical because it's
  the Seat minter, audit-gated, deploy-order-locked; (2) **testnet deployment** of the full stack + Tape;
  (3) **the faucet** — the anti-sybil chokepoint; (4) **indexer/attestor** — the one trusted, public,
  reproducible component; (5) **quest UI** — the Trading Desk. P2→P3→P5 can run the live quest now; P1
  is needed only at mint time but must start early because it carries the most risk.
