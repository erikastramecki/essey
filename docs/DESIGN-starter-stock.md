# DESIGN — Starter Stock: every new Don mints already owning stock

> **Status: scoping / costing only — nothing built, nothing committed.** This doc gives the founder the
> full cost/design picture for the onboarding mechanic: every freshly minted Don's token-bound Vault
> ships with a small starter stock position, so the first thing a new holder sees is *"your Don already
> owns stock."* Decision inputs grounded in the deployed/written contracts
> (`rh-chain/src/market/{Don,DonDistributor,Bell,BundleConverter,SeatVault}.sol`),
> `docs/TOKENOMICS-v3.md`, and `docs/MAINNET-DEPLOY-CHECKLIST.md`.

## 0. Recommendation up front

**GO — at $1 per Don, delivered by a pre-funded keeper drop (zero contract changes), funded from a
treasury budget line capped at $8,888 all-in.**

| Knob | Recommended value |
|---|---|
| Starter value | **$1.00 of tokenized stock** per newly minted Don |
| Ticker | **Random one of the listed stocks** (AAPL / NVDA today) — the surprise is part of the hook |
| Delivery | **Async keeper drop** from a pre-funded inventory wallet, target < 30 s after mint |
| Who gets it | WL free claims + custom mints **at mint**; desk-float Dons **at first exchange purchase**; partners/team at seed |
| Funding | **Treasury budget line** (≤ $8,888 worst case) — do **not** carve the mint fee |
| Lock/vesting | **None** — immediately owned, immediately sellable |
| Contract changes | **Zero** — fits the #81 window as an independent ops workstream |

Total protocol outlay at $1 if literally every one of the 8,888 Dons gets one: **$8,888 — the
collection number itself.** Realistic launch-phase outlay (WL + early customs): ~$6–7k.

---

## 1. Why this works mechanically (the two load-bearing facts)

1. **A Vault is just an address that accepts plain ERC-20 transfers.** `SeatVault` (the account every
   Don clones) has no deposit function and needs none — `receive()` + standard token transfer is a
   deposit. Nothing in the protocol has to "know" about the starter.
2. **The Vault address is deterministic and predictable *before* the mint.** `Don.vaultOf(id)` is a
   CREATE2 prediction (`Clones.predictDeterministicAddress`). A keeper watching the mint (the ERC-721
   `Transfer` from `address(0)`, or the distributor's `ClaimedWL` / `CustomMinted` events) can compute
   the Vault and land the stock transfer in the next block — or even pre-fund the Vault of the next id.

So the "your Don already owns stock" moment does not require touching the mint money-path at all.

---

## 2. Mechanics options

### Option A — atomic mint-hook: mint → converter buys stock → Vault, one tx

The purist version: `DonDistributor` calls a converter during `claimWL` / `mintCustom` and the stock
lands in the same transaction.

**What it actually requires (all grounded, all bad):**

- **The converter is single-caller by design.** `BundleConverter.convert` is gated to the Bell
  (`if (msg.sender != bell) revert NotBell()` — deliberately, because an open `convert` is a public
  redeem-at-oracle desk). The distributor cannot call it. We'd need either a second converter instance
  gated to the distributor, or a converter code change — new audit surface either way.
- **Currency mismatch.** Mint fees are native ETH; the converter takes USDG. The atomic path needs an
  ETH→USDG swap leg inside the mint (router dependency, slippage bound, pool-liveness dependency).
- **Session dependency kills the promise exactly when it's made.** The converter fails closed outside
  the live US equity session and on any stale feed (`NotInSession`, `StaleFeedGuard`). The US session
  is ~32.5 h of a 168 h week — **most mints would happen off-session** and the atomic path would have
  to fall open to USDG, i.e. the one moment the mechanic exists for ("owns *stock*") degrades to
  "owns a dollar" for the majority of minters.
- **Gas:** mint today ≈ 250–300k gas (mint + Vault clone + init). Swap leg + convert + two guarded
  feed reads adds roughly another 250–350k — about **2× the mint gas**, paid by the minter.
- **Distributor delta = a 3-agent audit round.** `claimWL`'s mint loop is effects-before-interaction
  with `_safeMint` callbacks; inserting an external value-moving call into it is precisely the kind of
  mint-money-path change that triggers the full pre-push audit gate — and the distributor is welded
  as the Don's immutable minter, so post-#81 this becomes a full-stack redeploy. Pre-#81 it's a
  deploy-blocking re-audit.

**Verdict: reject.** Maximum cost, maximum audit surface, and the off-session degradation defeats the
purpose.

### Option B — pre-funded pool the mint draws from (on-chain)

A small on-chain "starter reserve" contract the mint hook pulls from. Strictly dominated: it keeps the
distributor contract delta and audit round of Option A (the hook still has to exist) while only
removing the swap leg. Same session problem if it converts; if it just holds stock and transfers, it
is Option C with extra contract risk. **Reject.**

### Option C — async keeper drop (recommended)

A keeper process (co-hosted with the already-planned feed-keeper / flush-keeper crons, Section E5 of
the deploy checklist) subscribes to mint events, computes `vaultOf(id)`, and sends the starter from a
pre-funded inventory wallet holding real tokenized stock.

- **Contract delta: zero.** No distributor change, no converter change, no new audit surface on the
  money-path. The mint contracts never learn the mechanic exists.
- **Latency:** one block-scan cycle — target **< 30 seconds** after mint. The UI reveal (see §7)
  covers the gap naturally ("opening your Don's Vault…"), so the *perceived* moment is still instant.
- **Gas:** an ERC-20 transfer ≈ 50–65k gas per drop, paid by the keeper on Robinhood Chain (L2 gas —
  fractions of a cent). All 8,888 drops ≈ **~0.5 Ggas total, single-digit dollars of gas, ever.**
  This line item is noise; the stock itself is the cost (§3).
- **No feed / session dependency on-chain:** transfers don't care whether the market is open. The
  keeper prices "$1 worth" off-chain at the latest Chainlink print (same feeds the stack already
  reads) — for a $1 gift, last-close pricing is fine.
- **Idempotent + restart-safe:** keeper keeps a durable ledger of dropped ids; on restart it
  reconciles against `Transfer` logs from the inventory wallet. One drop per token id, ever.
- **Key risk is capped by construction:** the inventory wallet holds only a small float (top up
  $200–$500 of stock at a time from treasury). Worst-case key compromise = the float, not the budget.

### Option D axis — random ticker vs fixed

Not a separate delivery mechanism — an axis on top of C. **Recommend random one-of-N** (AAPL or NVDA
today; anything later listed in the converter joins the pool):

- Costs nothing extra ($1 is $1 in either ticker; both tokens are 18-dec so there is no dust issue —
  $1 of AAPL at ~$305 ≈ 3.3e15 units).
- The surprise element is the hook: "which stock did *my* Don get?" is shareable in a way "everyone
  gets $1 of AAPL" is not.
- It seeds the core product behavior: a holder whose Don "came with NVDA" is one tap away from
  electing NVDA dividends via `Bell.setPayout` — the starter becomes the tutorial for the payout
  election.
- Randomness is keeper-side (it's a gift, not a wager — no fairness claim needed; explicitly *not* an
  entropy/Dice surface, and the site copy must not present it as a game of chance).

---

## 3. The cost table (the core ask)

**Population, grounded in the tokenomics allocation** (8,888 total):

| Tranche | Dons | Pays a fee? |
|---|---:|---|
| WL free claims (indexed list) | 5,540 | No — gas only |
| Desk float (exchange inventory, `mintReserved`) | 2,222 | No — protocol mints to itself |
| Partners / team (rest of `reserveCap` 2,722) | up to 500 | No |
| Public custom headroom | 626 | Yes — `customFee` (rec 0.0053 ETH ≈ **$9.97** @ $1,880) |

Note on "customs if all sell": the theoretical ceiling of *paid* custom mints is **3,348**
(8,888 − 5,540), reachable only if the WL under-claims and/or reserve tranches were instead sold as
customs. The table below shows both the doc-allocation view and that ceiling.

**Per-mint starter value × tranche = total protocol outlay ($):**

| Tranche (count) | $0.50 | $1 | $2 | $5 |
|---|---:|---:|---:|---:|
| WL free claims (5,540) | 2,770 | **5,540** | 11,080 | 27,700 |
| Custom headroom (626) | 313 | **626** | 1,252 | 3,130 |
| Desk float (2,222) | 1,111 | **2,222** | 4,444 | 11,110 |
| Partners/team (500) | 250 | **500** | 1,000 | 2,500 |
| **All 8,888** | **4,444** | **8,888** | **17,776** | **44,440** |
| *(ceiling: 3,348 paid customs)* | *1,674* | *3,348* | *6,696* | *16,740* |

**The margin math against the custom fee** (rec `CUSTOM_FEE_WEI = 0.0053 ETH ≈ $9.97`):

| Starter | % of the $9.97 custom fee | % of the $3.01 reroll fee (for scale) |
|---|---:|---:|
| $0.50 | 5.0% | 16.6% |
| $1.00 | **10.0%** | 33.2% |
| $2.00 | 20.1% | 66.4% |
| $5.00 | 50.2% | 166% (underwater) |

At the 3,348-custom ceiling, fee revenue ≈ $33,380; a $1 starter on every one of them = $3,348 =
**10% of custom-fee revenue** if funded by carving the fee. $2 doubles that; $5 hands back half the
fee and is out of the question.

**The three tranche questions, answered:**

- **Do FREE WL claims get a starter?** This is the big line: **$5,540 at $1 — pure protocol cost, no
  offsetting fee.** Recommend **yes**. The WL is 62% of the pre-public collection; excluding it kills
  the hook for the majority of early holders, and the WL is exactly the audience being onboarded
  (holders of the indexed partner collections, burning/holding real NFTs to claim — not an open
  faucet, so the cost is bounded by an identity-gated list, not farmable).
- **Do desk-float Dons get one at seed time?** **No — at first exchange purchase.** Seeding 2,222
  protocol-owned Vaults with $2,222 of stock is the protocol paying itself: zero onboarding value
  while they sit at the desk, and capital parked for possibly months. Dropping at the moment a human
  buys one from `DonExchange` (keeper watches the exchange's sale events) preserves the identical
  buyer experience — "the Don I just bought already owns stock" — and each such drop is accompanied
  by ≥ 24,000 $ESSEY of swap fee (8% of the 300k floor price), of which 30% already flows to
  treasury. The starter on the float tranche is comfortably self-funding at the moment it's paid.
- **Partners/team (≤ 500):** consistency says yes ($500 at $1), and their Vaults holding stock is a
  live demo asset. Founder's call; it's the smallest line.

---

## 4. Where the money comes from

| Option | Mechanics | Verdict |
|---|---|---|
| **Carve X% of the custom fee** | e.g. route 10% of each custom fee to the starter wallet (the distributor's `teamBps`/`treasury` knobs could approximate this without code changes) | **Reject as the primary source.** It only covers customs — the WL majority pays no fee, so the carve can't fund 62% of the need. And it dilutes the flagship "100% of every mint fee buys stock for staked Dons" flywheel by exactly the carve — a 10% haircut on the loudest number in the tokenomics for at most $626–$3,348 of coverage. |
| **Treasury budget line (recommended)** | Treasury tops up the keeper's inventory wallet with real tokenized stock in $200–$500 tranches, hard cap $8,888 | **Recommend.** Covers every tranche including the free majority; keeps the 100%→feeSink story intact; the float-tranche portion is recouped in real time by the treasury's 30% share of exchange fees (§3); the cap is small against the treasury's inflow legs (30% of 8%/12% exchange fees, 30% of loan prepaid ETH). |
| **WL exclusion (free mints get none)** | Only customs + float get starters | Cuts the bill to ~$2,850–$3,850 — and kills the hook for the majority of early mints. Only worth revisiting if the budget line is genuinely contested; at $1 the full bill is one mid-size NFT sale. **Not recommended.** |

**Accounting note:** the starter is a *customer-acquisition cost*, not a protocol-solvency item. It
never touches the Bell pot, the reserve floor, the loan pot, or any audited money-path — it is a
gift from a treasury-funded ops wallet into user-owned Vaults.

---

## 5. Edge cases

- **Feed staleness at mint.** On-chain: irrelevant — the drop is a plain transfer, no feed is read.
  Keeper-side: the "$1 worth" sizing uses the latest Chainlink print; if the feed is stale the keeper
  uses last-known price (a $1 gift tolerates ±25h price drift) or holds the drop until fresh —
  operator's choice, default = use last price, never block the moment. There is **no fail-open to
  USDG needed and no async retry queue for pricing** — those problems belong to Option A, which is
  rejected partly because of them.
- **Market-closed windows.** Transfers of the tokenized stock work 24/7; only *pricing* references
  the market, per above. A mint at 3 a.m. Sunday still gets stock, not a fallback.
- **The reroll path.** `DonDistributor.reroll` → `Don.reroll` only rewrites the trait hash — **no
  mint, no new Vault, no starter.** Confirmed in code; nothing to build, nothing to exclude. Same for
  tier activation/upgrade and transfers: one starter per token id, at Vault birth (or first exchange
  sale for float), ever.
- **Dust vs decimals.** AAPL/NVDA are 18-dec (`uiMultiplier()=1e18`); $0.50 at a $305 stock ≈ 1.6e15
  units — nothing rounds to zero at any tier in the table. The UI must render fractional shares
  ("0.0033 AAPL"), which the stock-payout display already requires independently of this mechanic.
- **Locked/vested vs immediately sellable.** **Immediately sellable — no lock.** A lock would require
  Vault or lien contract changes (the whole point is zero contract delta), and a gift you can't touch
  undercuts the ownership message. Extraction math: a custom minter pays ~$10 to extract $1 —
  negative EV, non-issue. A WL claimer can extract $1 per Don via `SeatVault.execute`; the worst case
  (every WL claimer strips every starter) is $5,540 — i.e. exactly the WL line of the budget, already
  priced in §3, and gated behind holding/burning the indexed partner NFTs. **Acceptable churn:** the
  budget *is* the acquisition spend; extraction is the floor outcome, engagement is the upside.
- **Keeper failure / replay.** Durable (id → dropped) ledger reconciled against on-chain `Transfer`
  logs; a dead keeper delays drops but can never double-pay or lose track. Inventory-wallet key
  compromise loses only the standing float ($200–$500).

---

## 6. Effort estimate & ship window

| Workstream | Recommended (Option C) | If Option A were chosen instead |
|---|---|---|
| Contract delta | **None.** | Distributor hook + a distributor-callable converter path (the existing converter is Bell-gated) + ETH→USDG leg. Distributor is the Don's immutable minter → post-#81 this is a full-stack redeploy; pre-#81 it blocks the deploy. |
| Audit surface | No contract change → **no 3-agent contract round required.** An ops review of the keeper (key handling, float cap, idempotency ledger) is sufficient. | Touches the mint money-path → **full 3-agent round + re-test before #81**, per the standing gate. |
| Keeper build | ~1 day: event subscription (`ClaimedWL`, `CustomMinted`, `ReservedMinted`-excluded ids, exchange sale events), `vaultOf` computation, transfer + ledger. Co-hosted with the feed-keeper/flush-keeper crons already required by the deploy checklist (E5). | n/a |
| UI | ~0.5–1 day: mint-success reveal ("Opening your Don's Vault… **it already owns 0.0046 NVDA**") — poll the Vault's stock balances post-mint; the portfolio view already reads Vault holdings. | Same, minus the poll. |
| Ship window | **Fits alongside #81** — it is deploy-independent (the keeper starts whenever the inventory wallet is funded, and can even backfill Dons minted before it went live, since the (id → dropped) ledger makes backfill trivially safe). It should not gate the deploy; treat it as a parallel ops workstream that ideally goes live with the first WL wave. | Fast-follow at best; realistically misses #81. |

**The key structural answer:** this does **not** need a contract change. The deterministic
`vaultOf(id)` + plain-transfer Vault deposits mean the entire mechanic lives keeper-side with zero
contract risk. The only version that needs Solidity is the atomic one, and it is worse on every axis
that matters (session dependency, gas, audit round, immutable-minter lock-in).

---

## 7. Go / no-go

**GO**, with this exact config:

- **Value:** $1.00 per Don (10% of the custom fee — noticeable to the holder, invisible to margins).
- **Ticker:** random one of the listed stocks, keeper-chosen; framed as a gift, not a wager.
- **Delivery:** async keeper drop, < 30 s target, from a treasury-topped inventory wallet
  ($200–$500 float cap).
- **Recipients:** WL claims + custom mints at mint; desk-float Dons at first exchange purchase;
  partners/team at seed (founder's call, $500).
- **Funding:** treasury budget line, hard cap **$8,888** (all 8,888 at $1); no mint-fee carve — the
  "100% of mint fees → stock for staked Dons" flywheel stays untouched.
- **Lock:** none — immediately owned, immediately sellable; extraction is bounded and priced in.
- **Timing:** parallel to #81, non-blocking; live for the first WL wave. Revisit an on-chain/atomic
  v2 only if the keeper version proves the hook and the founder wants it trust-minimized — that v2 is
  a contract change plus a full audit round, and nothing about v1 forecloses it.

If the founder wants a cheaper first probe: run identical config at **$0.50** ($4,444 cap; still
lands "your Don owns stock", the reveal copy carries the moment more than the amount) — every other
line of this doc is unchanged.
