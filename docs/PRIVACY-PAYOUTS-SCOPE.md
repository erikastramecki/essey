# Private-by-default earnings payouts to Dons — feasibility & architecture scope

_Status: RESEARCH / DESIGN. No contracts changed. Grounded in the deployed code as of `feat/essey-market-layer`
(2026-08-12). Every load-bearing claim cites `file:line`; inferences are marked **(inferred)**._

**The founder's vision:** money earned on the platform is delivered to Dons through Essey's shielded mechanisms
**by default**, unless a holder opts out into the transparent (public) payout.

**One-paragraph verdict up front.** It **partially works, and it hides less than the framing implies.** The privacy
rails (shielded pool, shielded stock, stealth pay, relayer) are real and proven E2E on testnet. But the thing the
vision wants to hide — *how much each Don earned* — is **not hidden by routing the settlement through a shielded
rail**, because the Bell computes entitlements with a fully public MasterChef accumulator over **public** stakes and
weights (`Bell.sol:76-80,150-153,272-288`). Any observer can already compute "Don #123, owned by `0xabc`, is owed
`weight/totalWeight × pot` this ring" *before a single token moves*. A shielded payout therefore hides the
**settlement transaction and the post-payout address link**, not the **entitlement**. That still has value (it breaks
the on-chain trail from Don → spendable balance, and it lets a holder receive to an address never linked to their
Don), but it is a weaker claim than "private earnings," and the founder should accept that ceiling before committing.
There is also **no Bell→privacy adapter today** (grep of `rh-chain/src/market/` for shielded/stealth: none), and the
shielded-pool path **cannot be driven on-chain by the Bell** — it needs an off-chain operator that holds a note secret
and builds proofs. The **stealth-per-Don** path is the smaller, buildable-first option.

---

## 1. Ground truth — how earnings reach Dons TODAY (fully public)

The pipeline, end to end, with the public surface of each hop:

1. **Fees → USDG → Bell.** `DonFeeRouter` accumulates ETH (mint/reroll fees) and $ESSEY (70% of AMM trade fees),
   swaps both to USDG, and forwards **only** to the immutable `bell` (`DonFeeRouter.sol:58,199-202`). Emits
   `FlushedEth(ethIn, usdgToBell)` / `FlushedEssey(esseyIn, usdgToBell)` (`:88-89`) — **fee inflow amounts are public.**
2. **Pot accrues in the Bell.** USDG sits as `pot() = balanceOf − reserved` (`Bell.sol:145-147`).
3. **Ring.** When `pot ≥ minRing`, anyone rings: one division credits the O(1) accumulator
   `accPerWeight += distributed/totalWeight`, `reserved += credited` (`Bell.sol:272-288`). Emits
   `Rang(ringer, pot, tip, distributed)` (`:85,287`) — **the whole pot per ring is public.**
4. **Per-Seat accrual.** Each Don's claimable is `weight × accPerWeight/PRECISION − rewardDebt`
   (`Bell.sol:150-153`). `weight` is the Don's tier weight, set publicly at `activate`/`upgrade`
   (`Bell.sol:168-203`, events `Activated`/`Upgraded`). `totalWeight` is public (`:76`).
5. **Claim.** `claim(id)` checkpoints, then `_deliver`s the amount to `vaultOf(id)` — the Don's ERC-6551-style
   token-bound account, whose `owner()` is the current NFT holder (`Bell.sol:297-323`, `SeatVault.sol:20`,
   `Don.sol:150`). Optionally routed through the `converter` into elected stock, still delivered to the same vault
   (`Bell.sol:329-342`). Emits `Claimed(id, amount, vault)` and `ClaimConverted/ClaimFellBack` (`:86-89`) — **the
   tokenId, the amount, and the destination vault are all public and mutually linked.**

**The crux (this dominates the whole design):** steps 3–4 mean **each Don's per-ring earning is deterministic public
information** — `share = weight/totalWeight × distributed` — derivable by anyone from on-chain weights *before* the
claim. And `vaultOf(id)` is a deterministic function of the tokenId (`Don.sol:126,150`, `Clones.cloneDeterministic`),
and `ownerOf(id)` is public ERC-721 state. So today the observer knows **who, how much, and where** with zero
cryptography. Privacy has to fight *all three* of those, and only some are fightable.

---

## 2. The privacy rails that exist (verified working E2E)

All proven on Robinhood Chain testnet with real proofs — see `docs/TESTNET-PRIVATE-E2E.md`.

- **`EsseyShieldedPool`** (Tornado-Nova port, hides amounts). `transact(proof, extData)`:
  - **Deposit** (`extAmount > 0`): `gate.isApproved(msg.sender)` **required**, `≤ maximumDepositAmount`, pulls token
    from `msg.sender`. **The deposit amount is PUBLIC** (`EsseyShieldedPool.sol:108-113`).
  - **Internal transfer** (`extAmount == 0`): rewrites UTXO notes, **amount hidden**, no token movement, **not gated**
    (`:114`, `_transact:155-183`). The client builder addresses the output note to *another party's* spend+enc pubkey
    (`poolsdk.ts:607-664`, `recipientSpendPub`/`recipientEncPub`) — so a note **can** be handed to a third party.
  - **Withdraw** (`extAmount < 0`): pays `recipient`, **never gated** (`:169-172`). Amount public in the transfer.
  - **`register(Account)`** publishes a recipient's spend+enc pubkey so senders can address notes to them
    (`EsseyShieldedPool.sol:117-120`, `poolsdk.ts:518` `packAccountKey`). **A recipient must have registered a
    shielded key before anyone can send them a shielded note.**
- **`EsseyShieldedStock`** — identical zk core, plus a pro-rata solvency haircut for the burnable stock backing
  (`EsseyShieldedStock.sol:124-137,195-237`). Same deposit-amount-public / transfer-amount-hidden shape.
- **`EsseyPoolGate`** — the deposit front door; `isApproved(depositor)` (allow-list or `openMode`)
  (`EsseyPoolGate.sol:42-64`). **openMode MUST be false in production** (`:23`).
- **`EsseyStealthPay` / `Announcer` / `Registry`** (ERC-5564/6538, hides the RECIPIENT). `pay()` transfers
  `msg.sender → stealthAddress` directly and announces (`EsseyStealthPay.sol:37-49`). **The amount is PUBLIC** in the
  `PrivatePaid` event and the ERC-20 Transfer (`:25,48`). The stealth address + ephemeral pubkey are computed
  **off-chain by the sender** via secp256k1 ECDH against the recipient's registered meta-address
  (`stealth.ts:116-138`) — **a contract cannot do this on-chain.** Recipient must have registered an ERC-6538
  meta-address (`EsseyStealthRegistry.sol:45-48`).
- **Relayer** — `api/relay.ts` submits a client-built withdraw/transfer so the tx originates from the relayer, not the
  user, letting funds land at a fresh gas-unfunded address (`api/relay.ts:1-8,78-91`). **Production GAP: `RELAYER_PK`
  is unset in Vercel** (`docs/TESTNET-PRIVATE-E2E.md:83-111`); the dedicated wallet `0x1Ed2…C23c` is funded, nonce 0.

**There is no wiring between the Bell and any of these.** Confirmed: `grep -rl "Shielded\|Stealth" rh-chain/src/market/`
returns nothing relevant. The payout adapter in §4 **does not exist**.

---

## 3. Feasibility of private disbursement — the two paths

### Path A — Stealth-per-Don (hide WHO, amount public)

**Mechanism.** For each Don being paid, an off-chain keeper reads the holder's registered ERC-6538 meta-address,
generates a one-time stealth address + ephemeral pubkey (`stealth.ts:116`), and the payout lands at that stealth
address with an announcement. A new claim variant — call it `claimTo(id, stealthAddress, ephemeralPubKey, metadata)`
— would checkpoint the Don's pending exactly like `claim` (`Bell.sol:297-303`) but `safeTransfer` to the supplied
stealth address and emit the ERC-5564 announcement instead of delivering to `vaultOf(id)`.

**Requires:**
- **NEW contract path** on the Bell (a `claimTo`/announce variant). Small, but it *is* a change to the audited reward
  engine, and it breaks the "rewards travel with the NFT in its vault" invariant (`SeatVault.sol:9-12`) — the money
  now goes to a fresh EOA the holder controls, not the token-bound vault. That is a product decision, not just plumbing.
- **Recipient pre-registration:** each Don holder registers an ERC-6538 meta-address (one tx, gasless-capable via
  `registerKeysOnBehalf`, `EsseyStealthRegistry.sol:53-80`).
- **Off-chain at claim time:** the keeper computes the stealth address + ephemeral pubkey (cannot be on-chain —
  secp256k1 ECDH). So a permissionless `claim` can no longer be the private path; a **trusted keeper** (or the holder's
  own client) must construct the stealth target. If the holder's client does it, it stays trustless but stops being
  "automatic/default." If a keeper does it for auto-default, the **keeper learns the (Don → stealth address) mapping**
  it constructs — privacy is against the chain, not the keeper.

**What it hides:** the on-chain link between the Don/holder and the receiving address. **What it does NOT hide:** the
amount (public in `PrivatePaid`), and — critically — since the entitlement `weight/totalWeight × pot` is already
public and the announcement is timed to the ring, an observer can often **re-link** the stealth payment to the Don by
matching the amount (§4).

**Constructible with today's contracts?** The stealth contracts, yes, unchanged. But it needs the **new Bell
`claimTo` entrypoint** and an **off-chain keeper**. Not achievable by wiring existing pieces alone.

### Path B — Shielded-pool lump-deposit + internal splits (hide amounts)

**Why a lump, not per-Don deposits.** A per-Don shielded deposit reveals *that Don's amount* (`extAmount` is public,
`EsseyShieldedPool.sol:109-112`). To hide per-Don amounts you must deposit the **whole distributable pot as ONE public
lump** (only the aggregate — already public via `Rang` — is revealed), then perform **internal transfers**
(`extAmount == 0`, amount hidden) that split notes to each recipient's registered shielded key.

**Is lump-then-split constructible with today's `transact`?** **Structurally yes, mechanically painful.** The
2-input/2-output join-split (`README.md:35`, "2-input join-split only") produces exactly **one recipient note + one
change note** per internal transfer (`poolsdk.ts:649-664`). So splitting to **N** Dons requires **N sequential
internal transfers**, each consuming the running change note and emitting one note to the next recipient — O(N) proofs
and O(N) txs, serialized (each depends on the prior change note's new index). At a full ring with dozens–hundreds of
active Dons this is heavy. The 16-input circuit that would batch this is explicitly **a later add** (`README.md:35`).

**Requires:**
- **The Bell (or an adapter) must be an approved depositor** at the gate (`EsseyPoolGate.setApproved`,
  `EsseyShieldedPool.sol:110`). Fine — but see the custody problem next.
- **A note secret + a prover.** A shielded deposit's output note is a UTXO whose blinding/amount are **secrets held by
  the depositor**, and every subsequent split proof needs those secrets (`poolsdk.ts:337-343,633-664`). **A contract
  cannot hold a secret or build a Groth16 proof.** So the Bell **cannot** deposit-and-split on-chain. This path
  **requires an off-chain operator/service** that (a) takes custody of the distributable pot, (b) builds the deposit
  proof, (c) builds N split proofs to registered recipient keys. **This is entirely new plumbing and introduces a
  custody + trust step the current push-payout does not have.**
- **Recipient pre-registration:** each Don holder must `register()` a shielded spend+enc key (`:117`) *and* the
  operator must know it. A Don that never registered cannot be paid privately → must fall back to public (the opt-out).
- **`maximumDepositAmount` cap** (`:111`): a large pot lump may exceed the cap, forcing multiple public deposits
  (still only aggregate leakage) — a config/UX wrinkle, not a blocker.
- **Recipients still must withdraw** to spend — ideally via the relayer to a fresh address (needs `RELAYER_PK`, §2).

**The honest limitation baked into Path B:** the operator that builds the split proofs **knows every recipient's
amount** (it computed the distribution and the note plaintexts). Privacy is **against the chain observer, not the
operator.** And the operator is a **trusted custodian in-flight**. This is a materially different trust model from the
current trust-minimized Bell.

**Illustrative pseudocode (design only — not production):**

```
// OFF-CHAIN operator service, per ring:
pot = readRingDistributable()                 // public aggregate (from Rang)
shares = { id -> weight[id]/totalWeight * pot } for each active, registered Don   // public-derivable
depositProof = buildDepositProof(opKey, sum(shares))        // ONE public deposit == pot
submit(pool.transact(depositProof, extAmount = pot))        // gate.isApproved(operator) required
runningNote = depositNote
for id in Dons:                                             // O(N) serialized internal transfers
    (proof, sentNote, change) = buildTransferProof(opKey, runningNote,
                                   shares[id], recipientSpendPub[id], recipientEncPub[id])
    submit(pool.transact(proof, extAmount = 0))             // amount HIDDEN
    runningNote = change
// each Don later: buildWithdrawProof(...) via relayer -> fresh address
```

---

## 4. Threat model / privacy ceiling — brutally honest

**Unavoidably public, regardless of path:**
- **Fee collection** — `DonFeeRouter` events + USDG→Bell transfers (`DonFeeRouter.sol:88-89`).
- **Aggregate pot per ring** — `Rang(ringer, pot, tip, distributed)` (`Bell.sol:287`).
- **The candidate/recipient set** — the staked+activated Dons, via `Activated/Upgraded/TierCleared` and the public
  `seats` mapping + `totalWeight` (`Bell.sol:65,76,82-84`).
- **Each Don's exact entitlement** — `weight/totalWeight × distributed`, computable from public weights
  (`Bell.sol:150-153`). **This is the ceiling-defining fact.**
- **Timing** — payouts cluster around each ring; the announcement/deposit/split txs are contemporaneous with `Rang`.

**What each path actually hides:**

| | Amount per Don | Don → receiving-address link | Aggregate | Candidate set | Timing |
|---|---|---|---|---|---|
| Today (public claim) | ❌ public | ❌ linked (vault==f(id)) | ❌ | ❌ | ❌ |
| **Path A (stealth)** | ❌ public | ✅ hidden (until amount-matched) | ❌ | ❌ | ❌ |
| **Path B (lump+split)** | ⚠️ hidden on-chain* | ✅ hidden (until amount/timing-matched) | ❌ | ❌ | ❌ |

\* Hidden from the chain observer, **not** from the operator, and re-derivable by anyone via the public-weight
entitlement (see below).

**Correlation / deanonymization risks (the reason the ✅s are soft):**
- **Entitlement fingerprinting (the big one).** Because per-Don shares are public and deterministic, a stealth payment
  or a withdrawal of amount `X` can be matched to "the Don whose share this ring was `X`." Path A's amount is public,
  so this is near-trivial when shares are distinct. Path B hides the split amounts on-chain, but a **later withdrawal**
  of a note re-exposes an amount that can be matched to a share. Unique tier/weight combinations → unique shares →
  re-linkable.
- **Per-ring timing.** A payout batch that appears right after each `Rang` and touches exactly the active-Don count is
  self-labeling as "the payout," shrinking the observer's search space to the known candidate set.
- **Small anonymity set.** A beta with a curated whitelist (see MEMORY: Merkle-whitelist beta) may have only tens of
  active Dons — the anonymity set is the active-Don set, which is public and small.
- **Deposit-amount fingerprinting** (Path B): the lump equals the public pot, and any cap-forced sub-deposits are
  public — trivially attributable to the protocol.

**What a chain observer can infer even with the private path on:** the aggregate earned, the full list of who *could*
have been paid, each candidate's *entitlement*, and the *timing*. What they genuinely lose: the concrete settlement
address the holder ends up controlling, and — for Path B, absent a matching withdrawal — the confirmation of the exact
figure on-chain. **Real amount privacy would require hiding the stakes/weights themselves** (a shielded
staking/accounting layer — a new, much larger circuit), which is **not built** and out of scope here.

---

## 5. Anonymity-set / "liquidity" strategy

**A shielded pool needs an anonymity SET, not AMM liquidity.** Privacy = "your note is indistinguishable from the
others in the tree." The relevant resource is **the count of independent, same-denomination deposits/notes you blend
into**, not swap liquidity. Tornado-style privacy is entirely about set size.

- **"Payouts-are-deposits by default" does NOT automatically create a real set.** Protocol self-deposits (Path B's
  lump) are **known to be the protocol** and their amounts are the public pot — they add tree leaves but **not
  anonymity**, because an observer trivially separates "protocol payout leaves" from "organic user leaves." A pool
  whose deposits are all protocol payouts of publicly-known sizes offers little.
- **Real anonymity requires organic third-party deposits** at overlapping denominations and times — i.e. ordinary
  users shielding USDG for their own reasons, whose notes are indistinguishable from payout notes. That is the same
  `/private` deposit flow that already works (`docs/TESTNET-PRIVATE-E2E.md` flow (a)).
- **The relayer is load-bearing.** Without gasless withdrawal (`RELAYER_PK`, currently a **production gap**), a
  recipient must fund the withdrawal address with gas from a linkable wallet — re-linking themselves and defeating the
  point. A single relayer is also a **trusted liveness dependency** and sees withdrawal recipient/amount/timing.
- **`maximumDepositAmount`** caps the lump and nudges toward uniform denominations — mildly helpful for
  indistinguishability, mildly annoying for a big pot.
- **Bootstrapping real volume (answering the founder's literal question):** you cannot manufacture privacy from
  protocol self-deposits. Options: (1) make the standalone `/private` shield the **default UX for holding USDG on the
  platform** (not just payouts) so organic deposits accumulate; (2) standardize denominations so payout notes and
  organic notes are the same size; (3) fund + turn on the relayer so withdrawals don't self-doxx; (4) accept a
  **latency/mixing window** — hold notes and let holders withdraw at uncorrelated times rather than immediately at
  ring time (immediate withdrawal re-links via timing). Even with all four, the **entitlement-fingerprinting** ceiling
  (§4) stands: privacy of *amount* is capped by the public accounting, independent of set size.

---

## 6. End-to-end gap list to "full spin"

1. **Bell → private-rail payout adapter — DOES NOT EXIST.** Needs to be built. Two shapes:
   - **Path A:** a new `Bell.claimTo(id, stealthAddress, ephemeralPubKey, metadata)` entrypoint (checkpoint like
     `claim`, transfer to the stealth addr, announce) + an off-chain keeper that derives the stealth target from the
     holder's meta-address. *Touches the audited Bell.*
   - **Path B:** a payout that routes the distributable to an **off-chain operator/service** which deposits the lump
     and builds N internal-transfer split proofs to registered recipient keys. *New custody + prover service, plus the
     operator must be gate-approved.* No pure-on-chain form exists.
2. **Recipient key registration UX.** Every Don holder must register — an ERC-6538 meta-address (Path A) or a shielded
   spend+enc key (Path B). Gasless registration exists (`registerKeysOnBehalf` / `registerAndTransact`) but the
   **default-on** promise fails for any unregistered Don → must fall back to public.
3. **Default-on + opt-out toggle.** A per-Don election (mirroring `payoutElections`, `Bell.sol:69-74,209-228`) storing
   "private | public" with **private as the default** — but note default-private is only honorable if the holder has
   registered a key (gap #2), so the real default is "private **if registered**, else public."
4. **Relayer funding.** Set `RELAYER_PK` in Vercel and redeploy (`docs/TESTNET-PRIVATE-E2E.md:101-111`); without it the
   private path's withdrawal leg self-doxxes.
5. **Audit + E2E on the NEW path.** Whichever adapter is built is unaudited and unproven; needs the 3-agent adversarial
   pass + a testnet E2E like `docs/TESTNET-PRIVATE-E2E.md`. Path B additionally inherits the pool's **pre-mainnet
   gates**: a real **multi-party trusted setup** and a **formal zk audit** (`pool/README.md:39-46`) — not yet done.
6. **Product decision: vault semantics.** Both paths break "earnings live in the Don's token-bound vault and travel
   with the NFT" (`SeatVault.sol:9-12`). Confirm that's acceptable before building.

---

## 7. Recommendation

**Build Path A (stealth-per-Don) first.** Rationale: it is the smaller, mostly-additive build (one new Bell
entrypoint + a keeper reusing the already-proven stealth SDK), it needs **no** off-chain custody of funds, it inherits
no trusted-setup/zk-audit gate, and it delivers the most *legible* privacy win — "your earnings don't land at an
address anyone can tie to your Don." It is honest about its ceiling (amount public) and doesn't overpromise.

**Phased plan:**
- **Phase 0 (unblock, no new contract):** fund + enable the relayer (`RELAYER_PK`); ship ERC-6538/shielded-key
  **registration** into the Don onboarding UX so a set can accumulate. Ship the standalone `/private` shield as the
  default way to *hold* USDG (grows a real anonymity set independent of payouts).
- **Phase 1 (Path A):** add `Bell.claimTo` + announce; add the per-Don **private-by-default (if-registered) / opt-out**
  election; build the keeper; 3-agent audit + testnet E2E. Ship.
- **Phase 2 (Path B, only if amount-hiding is truly required):** design the off-chain deposit+split operator, accept
  the custody/operator-trust model, and either wait for the **16-input circuit** (to avoid O(N) serialized transfers)
  and the **multi-party trusted setup + formal zk audit** before mainnet, or explicitly scope it testnet-only.

**Blunt verdict — does the vision really work, what are we missing?** The *plumbing* works: the rails are real and
proven. But **"private earnings" is a weaker guarantee than it sounds**, and the founder should internalize the single
hard limitation before committing:

> **The Bell's earnings math is public by construction. Any observer can compute each Don's exact per-ring earning
> from on-chain stakes and weights, before any payout moves. No settlement-layer privacy (stealth or shielded) changes
> that. We can hide *where the money lands* and *whether the exact figure is confirmed on-chain*; we cannot hide *what
> each Don earned* without also shielding the staking/accounting layer — a new, unbuilt, much larger zk system.**

Everything else (adapter, registration UX, relayer, audit) is buildable, sequenced work. The **single biggest risk /
limitation** is exactly that ceiling: **entitlement fingerprinting from public weights re-links "private" payouts to
Dons by amount**, so a privacy claim stated as "we hide how much you earn" would be **overstated and would not survive
adversarial analysis.** State it as "we hide where your earnings go," and the vision holds.
