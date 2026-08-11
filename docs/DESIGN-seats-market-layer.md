# DESIGN — Seats: Essey's NFT + incentives layer

A consumer/engagement layer for Essey, adapting the mechanics that gave the reference desk (on the same
Robinhood Chain rails) real traction — NFT-as-wallet, fee→reward distribution, staking tiers, an NFT
AMM, live public feed — re-skinned as a **stock-market club** in Essey's voice, and fused with Essey's
one true differentiator: **everything is provable.** the reference desk is "provably fair." Essey is
**provably fair *and* provably solvent** — the NFTs, the yield, and any randomness all verify against
the ZK stack in `circuit/poseidon` (see `docs/SCOPE-solvency-rollup.md`).

## Glossary (finance-native — say what it is, no theme to decode)

| Essey term | What it is (mechanic) | the reference desk analog |
|---|---|---|
| **Seat** | membership NFT — like an exchange seat: scarce, tradeable, entitled to a share of the floor | Broker (4,444) |
| **Vault** | the Seat's ERC-6551 token-bound wallet; holds collateral + earned Payouts | broker's TBA |
| **Tier** | staking level — stake $ESSEY to raise a Seat's Tier → bigger share of fees | activation tiers |
| **the Exchange** | the Seat AMM — swap $ESSEY ⇄ a Seat, or snipe a specific # | Anvil NFT AMM |
| **the Bell** | permissionless payout event — anyone *rings the Bell* when the fee pot is full, earns a tip | Clock In |
| **Payout** | the fee-funded reward the Bell distributes into active Seats' Vaults, by Tier (NOT "dividend") | the stock drop |
| **After Hours** | a second payout engine (e.g. liquidation revenue) | Overtime |
| **Note** | a loan position as a transferable NFT whose Vault holds the collateral | Certificate/deed |
| **the Tape** | live public feed of Bells, Payouts, proofs, and loans — each row a real tx | live drops ticker |
| **$ESSEY** | the access/sink token — buy Seats on the Exchange, raise Tier, etc. | the reference desk |

## The two NFTs

**1. Seat (membership collection).** A fixed collection (e.g. 4,444) of ERC-721 Seats, each an
**ERC-6551** token that owns a **Vault** (its token-bound wallet). Seats are the engagement flywheel:
acquire one on the Exchange, raise its Tier by staking $ESSEY, and it earns a share of protocol fees at
every Bell. The Vault (and everything in it) travels with the NFT on transfer — sell the Seat, sell the
Vault. *(Foundation built — `src/market/Seat.sol`, `SeatVault.sol`; the core mechanic is proven in
`test/Seat.t.sol`.)*

**2. Note (loan position).** Today `EsseyPool` stores a position as a struct keyed by id, owned by a
stored `borrower`, with collateral pooled in the contract. We turn the position into a **Note** — an
ERC-721 whose Vault *holds that position's collateral* — and switch the pool's auth from
`p.borrower == msg.sender` to `ownerOf(id) == msg.sender`. Result: **positions become transferable,
composable bearer notes.** You can sell your loan (debt + collateral travel together), and — the payoff
— **the position's portable solvency proof travels with the Note.** This is where the consumer layer
meets the hard tech: a Note is a self-contained, provably-solvent, portable credit object.

## Mechanic-by-mechanic adaptation

- **NFT-as-wallet (ERC-6551).** The core primitive, adopted wholesale. On EVM/Robinhood Chain we use an
  ERC-6551 registry + account (same standard the reference desk uses). *On Sui this is native* — a Move object
  can own its collateral objects directly, so the Note/Vault is just how Sui already works; the
  formally-verified `dregg` core gets this for free.
- **Fee → reward distribution ("the Bell").** Protocol fees (loan origination, a slice of interest,
  liquidation bonus, Exchange AMM fees) accrue in a **Booster** contract. When the pot is full, *anyone*
  can ring the Bell (pay gas, earn a tipper's cut). It swaps the fee asset into the reward lineup and
  distributes pro-rata by Tier into every active Seat's Vault. 100% on-chain, permissionless, no bot.
- **Staking / Tiers.** Stake $ESSEY to raise a Seat's Tier, each a higher payout multiplier. Activation
  fee partly **burned** (token sink), partly to protocol. A whale mechanic + a real $ESSEY sink.
- **The Exchange (Seat AMM).** A vault-AMM: swap a flat amount of $ESSEY (+ small fee) for the next Seat,
  or snipe a specific #. Makes an illiquid NFT liquid and creates fee flow that feeds the Booster.
- **Fee-recycling buyback.** A slice of fees recycles into $ESSEY buybacks — and here Essey's ZK makes
  the trigger *provably* unfront-runnable, not just "trust the VRNG."
- **The Tape (live feed).** A public, real-time ticker of Bells, loans proven solvent, and mints — each
  row a real tx link. On-brand: it broadcasts *proof*, not hype. Lightweight (app + indexer).
- **Reward lineup = tokenized stocks.** Essey already lends against Robinhood Stock Tokens; a Payout can
  distribute the same tokenized equities the reference desk uses (AAPL/NVDA/…) — or USDG — as the reward.

## The provable twist (the part they can't copy)

Every gamified element routes through the ZK stack:
- **Provably-solvent loans** behind the fees — the Notes carry the portable solvency proof.
- **Provably-fair Bells/mints** — any randomness (mint order, buyback timing) is a ZK-verifiable draw,
  same rigor as the IVC work; "verify it yourself" is a real button, not a slogan.
- **One live claim no competitor can make: "provably fair AND provably solvent."**

## Architecture / where each piece lives

- **EVM / `rh-chain/`** (Robinhood Chain — the consumer surface, same as the reference desk): Seat (ERC-721 +
  ERC-6551), SeatVault, Booster/Bell, Tier staking, the Exchange AMM, Note integration into `EsseyPool`.
  New contracts are **additive**; the one edit to audited code is switching `EsseyPool` position auth
  from stored `borrower` → `ownerOf(id)`.
- **Sui / `move/`**: Notes/Vaults are native objects; a later port once the EVM design settles.
- **App / `app/web/`**: the Tape feed, Seat gallery, Tier staking UI, ring-the-Bell button.

## Phased build (safety-aware; each phase testable + audit-gated)

1. **Foundation — Seat NFT + Vault (ERC-6551).** ✅ Built. Mint → Vault exists → deposit collateral →
   transfer moves the Vault + contents; deterministic address; init-once; minter/cap guards.
   (`src/market/`, `test/Seat.t.sol`, 4/4 passing.)
2. **The Bell — Booster + Tiers.** ✅ Built. O(1) accumulator ring with tip, Tier staking (50% burn),
   transfer-clears-Tier hook, permissionless vault-fixed claims, trustless sweep.
   (`src/market/Bell.sol`, `test/Bell.t.sol`, 9/9 passing.)
2.5. **Payout choice (ETH/base vs stocks).** ✅ Built. Per-Seat preference (`setPayoutToken`, owner-set,
   cleared on transfer); claim-edge conversion through `StockConverter` (inherits `StaleFeedGuard`:
   silent-feed/holiday/session discipline; oracle-fair `minOut` minus a capped slippage bound; router
   delivers straight to the Vault — no custody at rest; append-only registrar-gated stock registry);
   Bell claim path **fails open to base** on any conversion decline, with approval reset. Accounting
   stays single-unit; preferences never touch the accumulator. Tests: 10/10 covering conversion math,
   the minOut boundary, all four fallback paths (router down, bad pool price, off-session, stale
   feed), auth, transfer-clear, registry gating. This is the front half of the priority flywheel:
   **fees → Bell → stock payouts into Vaults → borrow against those stocks → more fees.**

   *CV verification result (2026-08-02):* CoinVoyage's Robinhood Chain (4663) support is **real**
   (CV 3.3.0, shipped 2026-07-29; chain in the v3 API enum, networks table, and SDK). But CV is
   **API-only — there is no on-chain router a contract can call** (swapExecute returns a signable EVM
   tx for a specific wallet). *Authenticated probe (same day):* **stock tokens as CV swap outputs
   CONFIRMED** — AAPL (`0xaf3d…93f9`, Blockscout-verified canonical, 29k holders) and NVDA are in CV's
   4663 registry, with real quotes for ETH→AAPL same-chain and USDC-on-Base→AAPL **cross-chain**
   (~0.25% protocol fee). Caveat: USDG-as-source returned NO_ROUTE (unresolved); quotes verified,
   execution not yet exercised end-to-end.
   Consequences: the **in-protocol Converter is the on-chain DEX route** (Uniswap is live on Robinhood
   Chain since mainnet day one, and the reference desk's stock router proves on-chain ETH→stock swaps
   work there today).

   *Decision (2026-08-02, delegated by founder):* **build direct on Robinhood Chain's on-chain rails —
   no CoinVoyage dependency anywhere in the core.** Simpler (no API keys, no backend wallet, no paykit
   v2→v3 migration on the critical path), trustless end-to-end, and the converter had to be on-chain
   regardless. CV remains an *optional, later* enhancement for exactly one leg it's uniquely good at:
   any-chain acquisition (pay from Ethereum/Base/Arbitrum into $ESSEY/Seats). If/when that ships, it
   needs the paykit v2→v3 migration (breaking: /v3 base, Order naming, webhook payloads; reusable
   pattern in cv-trader-app's quote→execute).
3. **Notes — positions as NFTs.** ✅ Built (v1). `Note.sol`: ERC-721 deed deployed BY the pool (only
   minter/burner), token id == position id, minted on borrow via plain `_mint` (no callback surface in
   the borrow path), **burned in the pool's single close path** (R5/R6 preserved) so a spent deed
   cannot exist. `EsseyPool` diff is minimal and surgical: the stored `borrower` field is GONE — repay
   auth, returned collateral, and liquidation surplus all follow `note.ownerOf(id)` at execution time.
   Result: **positions are transferable bearer deeds** — sell a loan mid-life and the debt + collateral
   claim travel together (vs the reference desk' LoanVault, which escrows the NFT dead for the loan's life).
   Validated: 5 new bearer-note tests AND the full audited invariant suite re-run green under the
   subclassed harness (NoteTest extends EsseyPoolTest — all 26 hardened tests pass under bearer
   semantics). *v2 (deferred, deliberate):* collateral held in a per-position Vault under a pool lien +
   the portable solvency proof riding with the Note — deferred because it adds external calls to the
   liquidation path (the most safety-critical code) for a property that is composability, not security;
   it gets its own design pass. (Back half of the flywheel now functional: stocks in Vaults → borrow.)
4. **The Exchange (Seat AMM).** ✅ Built. `EsseyExchange.sol` — a two-sided flat-price vault-AMM:
   holds a Seat inventory + an $ESSEY reserve and trades between them. **buy** (next Seat), **snipe**
   (specific #, premium fee), **sell** (return a Seat for the flat price). Every trade fee is charged in
   the **Bell's reward token** and split `boosterShareBps`/rest → **Bell pot** / treasury (fees feed the
   Bell by plain transfer — verified end-to-end: buy → ring → claim lands in a Vault). Faithful flat
   price + float (inventory) as the scarcity dial; **adminless over funds** (only a `seeder` role that
   can add float, never move funds); decoupled from minting (float via `seed`/sell-backs). v1
   simplification: flat immutable price + flat immutable fees (no oracle to manipulate, no admin to
   move) — a %-of-ETH-notional TWAP-sandwich fee is a possible v2. Tests: 10/10 (buy/snipe/sell, fee
   routing, pot-feed, seeder auth, empty-inventory / absent-snipe / dry-reserve guards, config guards).
   $ESSEY token (`EsseyToken.sol`) also built (fixed supply, adminless, burnable+permit).
5. **The Case system** (founder-prioritized) — stock gacha + two-sided fee engine (buy fee + sell-back
   spread), prizes = stock sealed in Vault-NFTs, feeds the Bell. Reuses Seat/Vault; two reg-differentiated
   variants; provably-fair + provably-solvent-bankroll twist; entropy source TBD. See the Phase-5 section
   below and `docs/TOKENOMICS-essey.md`.
6. **The Tape** live feed (app).
7. **Sui port** of Notes/Vaults (native objects).

## Website & messaging reframe (founder decision, 2026-08-02 — do not forget)

The market layer is **the new focus** of what Essey is building. essey.xyz and all public messaging get
reframed around it once the core technical build lands:

- **Tone:** fun, gamified, engaging — the Market (Seats, Tiers, the Bell, the Exchange, the Tape) front and
  center, with the provable-trust spine as the differentiator ("provably fair AND provably solvent").
- **Experimental-software warning:** a broker-desk-style first-visit modal — experimental software,
  nothing is financial advice, assets are volatile, no guarantee of payouts, user responsible for their
  jurisdiction — worded honestly per our no-overclaim discipline (and "Payout" never "dividend").
- Update landing sections, the docs reading room, and align social/tweet copy with the new direction.
- Tracked as task #14; sequenced after converter/Notes/Exchange unless slack appears.

## Economics modeling (in progress — measured, not assumed)

Calibrate our collection size, tier fees, and Exchange fee bps from the reference desk' *measured* on-chain
economy (their contracts are public on Blockscout). Inputs being pulled: fee inflow cadence, drop
sizes, activation rate by tier, the reference desk burn total, AMM trade volume, protocol age. Already
captured from their live site (2026-08-02): **$349,083 total distributed** across ~746 Clock In + ~208
Overtime rounds; recent drops 0.014–0.70 ETH; **~1,662 of 4,444 activated (~37%)**. Output: an
economics memo with defensible assumptions for supply (do we want 4,444?), tier-ladder pricing (per the
verified ladder rule), Exchange fees, and projected Bell pot run-rate.

Every contract phase goes through the 3-agent audit gate (see `docs/audits/`) before push.

## Improvements over the reference desk' structure

**Verified against their actual on-chain source** (all five core contracts are verified on Blockscout:
the reference desk's booster/activation/loan-vault/NFT-AMM contracts; fetched
2026-08-02). Each claim below cites what the real code does.

1. **O(1) accumulator payouts instead of their O(N) push.** *Confirmed in source:* `continueDrop` is a
   cursor `while` loop pushing STOCK_COUNT transfers per broker per round, with `paidRound` bookkeeping
   to survive activation-set shifts mid-round. Gas grows with holders and rounds can stall part-paid.
   The Bell uses the MasterChef/Synthetix accumulator instead: ringing does ONE division
   (`accPerWeight += pot/totalWeight`); each Seat pulls `weight × Δacc` into its Vault. O(1) ring, O(1)
   claim, no cursor, no partial-round state, no off-chain computation. *(Built — `Bell.sol`. Note: this
   also supersedes the earlier Merkle-pull idea, which would have needed an off-chain root computation.)*
2. **Lien, not escrow, for Notes.** *Confirmed in source:* their `borrow()` does
   `collection.safeTransferFrom(msg.sender, address(this), tokenId)` — the NFT sits dead in the vault
   for the loan's life. Our Note keeps collateral in the position's own Vault under a pool **lien**; the
   Note stays live, transferable, and composable while borrowed.
3. **No admin over the pot.** *Found in source:* their booster has `onlyOwner rescueEth / rescueToken /
   cancelRound` — the owner can drain undistributed pot and stocks. The Bell has **zero admin**: every
   parameter is immutable, and no key can touch the pot or reserved rewards. For a protocol selling
   provable trust, adminlessness is the point.
4. **Provable distributions.** Their drop math is trusted contract logic; ours can carry a **ZK proof
   that the Tier-weighted split is exactly correct** (same machinery as the IVC work).
5. **Reward real usage, not just staking.** Boost a Seat's Tier for maintaining a healthy, active loan —
   point the incentive at the behavior that makes the protocol money, not just at holding.
6. **Atomic Vault init, and never the canonical registry for our accounts.** *Confirmed:* their NFT
   wires a project-local **initializing** ERC-6551 registry, and their docs explicitly warn never to use
   the canonical registry with their certificate deploys — because an account implementation with an
   `initialize()` deployed through the permissionless canonical registry can be init-frontrun. Our Seat
   independently landed on the same hardened pattern (CREATE2 clone + initialize, atomically in mint).
   Canonical-registry interop remains possible later only via an account impl with *derived* (not
   initialized) binding.

## Design lessons adopted from their code (verified, worth copying as calibration rules)

- **Tier-ladder pricing rule** (ActivationManager header): price each tier so an upgrade's cost per
  weight-point is at-or-slightly-better than the "just buy another NFT + Base-activate it" route —
  otherwise every tier above Base is economically irrational and the burn sink starves. Apply when the
  real $ESSEY fees are set (our test numbers are placeholders).
- **Cross-product fee coherence** (LoanVault header): their cheapest borrow fee (15% of notional) is
  deliberately ≥ the 15% snipe fee and > the 10% swap fee so *lending can never be a discount exit from
  the AMM*. Same invariant must hold between Note origination fees and Exchange exit fees.
- **Restricted-transfer resilience** (StockBooster `_tryTransfer`): real Robinhood stock tokens can carry
  transfer restrictions; one poisoned recipient must never brick a round. Their fix is skip-and-roll-
  forward inside the push loop; our pull-claims get this isolation *by construction* (a failing claim
  only affects that Seat), but reward-token choice should still prefer unrestricted assets.
- **Manipulation-resistant fee notional** (AMM vault): fee base = `max(slowTWAP, min(fastTWAP,
  slow × spikeCap))` — pushing price down can't cut fees below the slow average; pushing up is capped.
  Adopt for the Exchange's ETH-notional fees.
- **`activateBatch`** with a single fee pull — cheap UX win to add to the Bell later.

## Trust & migration model (why adminless is safe here — and how we migrate anyway)

the reference desk' booster has owner rescue/cancel keys, and reading their code shows *why*: their drop is a
stateful multi-tx process (swap through a router, cursor through holders) that can wedge mid-round, so
they need an un-wedge key. Notably they apply a **tiered trust model** — their Broker Box machines,
where user money sits, are explicitly ownerless ("no key to player funds"); admin exists only over
transient fee flows. We adopt the same principle, but our architecture needs even less trust:

- **No wedge surface.** The Bell has no swap, no router, no rounds, no cursor — `ring()` is one atomic
  O(1) operation. The failure modes their rescue key exists for don't exist here.
- **Bounded blast radius.** The Bell never holds user principal: $ESSEY fees route sender→burn/treasury
  directly, rewards drain continuously via claims. Any bug's exposure is the undistributed pot at that
  moment.
- **Rescue without trust.** `sweep(token)`: permissionless, treasury-fixed destination, and the reward
  token can never be swept — recovers fat-fingered tokens with provably zero power over the pot. (ETH
  cannot enter at all: no `receive`.)
- **Migration = reroute the source, never drain the module.** Fees are routed at their origin (pool,
  the Exchange). To ship Bell v2: deploy it, point new fees at it, and v1 winds down as holders claim out.
  Fund-custody immutability ≠ topology immutability.
- **Known constraint:** `Seat.setHook` is one-shot, so a future Bell won't get transfer callbacks. The
  v2 pattern is **ownership epochs** (record owner at activation; lazily clear on any touch if the owner
  changed) — per-owner Tiers with no hook and no drift beyond a permissionless poke.
- **If admin must exist somewhere** (e.g., rotating a reward lineup), it gets a timelock + events (their
  VRNG conductor migration uses a 3-day timelock — the right shape), never an instant key.

## Phase 5 (founder-prioritized, 2026-08-02): the Case system — stock gacha + two-sided fee engine

CS:GO-case-style mechanic, now an in-scope phase (task #15). **Buy a Case** (in $ESSEY), a provably fair
draw decides its contents, the prize is **stock sealed in a Vault-NFT** (the Seat/Vault primitive we
already built — a Case prize is just a vault with stock in it, tradeable as a bearer note); the holder
keeps/trades it, **borrows against it on `EsseyPool`**, or **sells it back to the system at a discount**.

**Two-sided fees — the point of the mechanic (both feed the Bell's pot):**
- **buy-side fee** on purchase (flat and/or %), and
- **sell-back spread** — resale to the system pays ~95% of oracle value, the ~5% spread is house revenue.
So the engine earns on the round trip — every open *and* every sell-back — not just the entry.

Reference implementation is the reference desk' Broker Box (verified live on the same chain):
tiered tickets, prize table burned into bytecode, **worst-case payout reserved in real inventory per
open case** (a pull can never win an uncovered prize), 95% sell-back with the 5% spread as house
revenue, deed-sealing, ownerless machines. Essey's twists:

- **Provably-solvent gacha** — use the ZK stack to prove the bankroll always covers every open case's
  max prize. "The only case system where the odds AND the bankroll are provable."
- **Two variants to scope, with very different risk profiles:** (a) a 1×/mystery-pack model — you always
  receive fair value in *some* stock, randomness picks *which* (closer to a collectible pack than a
  wager); (b) multiplier-on-money Degen-style rolls (the reference desk' 0.70×–50×, RTP 90%) — a game of
  chance, US-restricted in their deployment for a reason.
- **Open technical dependency:** entropy on Robinhood Chain — no Chainlink VRF on the production path;
  the reference desk built miner-backed DERP + a conductor. Options: their conductor, our own commit-to-future-
  entropy scheme, or a ZK-draw design. Decide at scoping time.
- Fee/spread parameters come from the economics memo, and the cross-product fee-coherence rule applies
  (case fees vs Exchange fees vs Note fees must not create a discount exit).

## Security posture & deferred hardening (from the 3-agent audit gate)

The market layer (Seat/SeatVault/Bell/StockConverter/Note + the EsseyPool diff) went through the
3-agent adversarial gate. Findings and accepted trust assumptions, recorded so they aren't lost:

- **Fixed (round 1 → 2):** the Bell's `claim` reset the converter allowance only on the fail path;
  now reset on **both** paths, so even a converter that reports success while under-pulling can't
  leave a standing allowance over the Bell's balance. Tested (`test_NoDanglingAllowanceOnUnderpullingConverter`).
- **Accepted trust assumption (low-sev liveness):** `Seat._update` calls the transfer hook (the Bell)
  un-try/caught, and `setHook` is one-shot. A *broken* hook would freeze Seat transfers (not Vault
  contents — `execute` only needs `owner()`). The shipped Bell's hook logic is pure state with no
  revert path, so it can't trigger this; and both obvious "fixes" are worse (try/catch silently breaks
  the tier-clears-on-transfer invariant; a replaceable hook adds an admin key against the adminless
  design). Documented as an accepted assumption under the trusted-minter model.
- **HARD REQUIREMENT for Notes-v2 (collateral-in-Vault):** before `SeatVault.execute` custodies
  collateral, it MUST gain a reentrancy guard + a pool-lien check (block withdrawal while a Note's loan
  is open). Today the Vault holds nothing, so there is nothing to protect — this gates that phase.
- **Accepted (informational):** accumulator rounding can transiently strand / defer a few wei (6dp
  reward token, sub-millionth-cent, self-healing on the next ring) — the standard MasterChef dust
  behavior, revert-not-steal.
- **Pre-existing, not introduced:** a blocklisting collateral token could make a liquidation refund
  revert; identical pattern existed before Notes (plain ERC-20 transfer invokes no recipient hook).

## Honest risk flags — what we adapt carefully, not blindly

- **The casino surface (Broker Box / Case variant (b)).** A stake-to-win multiplier machine is reg-hot —
  the reference desk geoblocks it in the US for a reason — and sits in tension with "provably solvent
  lending" branding. Scoping the Case system (above) must treat variant (b) as a separate,
  legally-reviewed decision with jurisdiction gating; variant (a) (mystery-pack, always-fair-value) and
  1× certificate-style purchases ("no game of chance") are the lower-risk on-ramp. The provably-fair
  engine itself (ZK draws) is benign and reusable either way.
- **"Payout" framing.** the reference desk leans on an offshore entity + "these aren't dividends" disclaimers.
  Essey's moat is institutional-grade *trust*; we keep Payouts honestly framed (protocol fees to NFT
  stakers, mechanically LP fees) and don't adopt securities-adjacent language — hence "Payout," never
  "dividend."
- **Meme energy is fickle; proof is durable.** Borrow their engagement *architecture*, point it at trust.
