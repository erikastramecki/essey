# Full-stack privacy for Essey — deposits, staking, rewards & lending, amounts AND destinations

_Status: **RESEARCH / DESIGN ONLY.** No contracts changed, nothing committed beyond this doc. Every
load-bearing claim about the existing stack cites `file:line`; external approaches are cited to
sources; everything else is marked **(assessment)**. Grounded in `feat/essey-market-layer` as of
2026-08-12._

**The founder's thesis under test:** _"Nobody has privacy on Robinhood Chain. If we can truly own
private DeFi — deposit capital, make loans, all shielded, amounts AND destinations — that's a moat."_
Willing to delay the current privacy launch to build the real thing **if it is genuinely viable.**

---

## 0. Blunt verdict up front

**VIABLE-WITH-CAVEATS — but the viable thing is narrower and differently-shaped than "shield the
entire stack," and the binding constraint is regulatory, not cryptographic.**

Three findings decide it:

1. **Private _lending_ is genuinely viable and genuinely differentiated, and it is the one place the
   head start pays off.** "Deposit privately, borrow against a hidden position, prove collateral ≥
   `ltv·debt` in zk without revealing amounts" is almost exactly what the **dregg transition/solvency
   circuit already proves end-to-end** (`circuit/poseidon/transition.go:41-91`, validated single-VK
   IVC per `docs/SCOPE-solvency-rollup.md:314-360`), sitting on top of the **already-shipped Nova
   shielded pool** that hides amounts (`EsseyShieldedPool.sol`, testnet-proven per
   `pool/README.md:30-38`). The hardest _research_ question — "does provable private solvency
   actually compose?" — is **retired**. What's left for private lending is mostly _engineering_
   (port gnark→EVM, bind the oracle, unify the note commitment with the pool, ceremony, audit).

2. **Private _staking + pro-rata rewards_ (the Bell) contains a real, unsolved research problem** and
   should **not** gate any launch. The Bell's whole design is a MasterChef accumulator
   `accPerWeight += pot / totalWeight` over **public** `totalWeight` and per-Seat `weight`
   (`Bell.sol:76-80,150-153,272-288`). Hiding the individual weights while keeping the shared
   `totalWeight` correct is the classic **private-shared-mutable-state** problem (concurrent stakers
   all prove against a `totalWeight` others are changing). No piece in the repo solves it, and nobody
   has shipped a production "private MasterChef." It is a fundable _spike_, not a promise.

3. **The moat framing is wrong, and correcting it is what makes the project survivable.** A
   fully-shielded venue that moves **tokenized securities** (RH Stock Tokens) on a **Robinhood-
   affiliated chain**, with an operator/keeper/relayer in the fund-moving path, runs directly into the
   **live** _U.S. v. Storm_ money-transmitting conviction (Aug 2025) and Robinhood's own compliance
   posture. "Absolute privacy" is a non-starter here regardless of cryptography. The only shippable
   target is **compliance-aware confidential DeFi**: private from the public, auditable by the user
   and — on lawful request — a regulator, behind a screened front door. The pieces for that already
   exist in the design (the deposit **gate/ASP**, `EsseyPoolGate.sol`; UTXO notes encrypted to a
   recipient key, which _is_ a viewing-key primitive). That is a real moat — "the only _compliant_
   private DeFi on Robinhood Chain" — and it is the honest one.

**Recommendation: GO on private lending as the v1 primitive; do NOT delay the current launch to build
the whole stack; treat private staking/rewards as research.** Recommended architecture: **(a) extend
the note model** — shielded position/collateral notes accruing/borrowing against public aggregates —
_not_ FHE, _not_ a bespoke app-zkVM. Single biggest risk: **regulatory / chain-operator permission**,
above any crypto risk.

---

## 1. Correction that reframes the whole study: the target chain

The task brief says "Robinhood Chain, an **OP-stack** L2." **That is wrong, and it matters.** Robinhood
Chain is an **Arbitrum Orbit / Nitro** L2, chainId **4663**, ETH gas, blob DA to Ethereum, mainnet
live 2026-07-01 — confirmed both by the repo (`docs/SCOPE-robinhood-chain.md:177`, "Arbitrum Orbit,
EVM") and externally.[^rhchain] Consequences for this study:

- **It is a single-sequencer Orbit chain with a centralized operator (Robinhood).** Every "privacy"
  claim has a sequencer that sees the mempool and orders txs → **the sequencer is a privacy and MEV
  adversary you cannot design away** (§4.6). This is true of Aztec-on-Ethereum too, but here the
  sequencer is the same party that runs the securities venue.
- **There is no FHE coprocessor and no threshold-decryption network on 4663**, and you cannot deploy
  one unilaterally (§b). Day-one integrations are Uniswap, Morpho (lending), Chainlink (95 equity
  feeds), Lighter, BitGo — all _transparent_.[^rhchain] Nobody has privacy here; that part of the
  thesis is true.
- **ERC-4337 account abstraction with session keys + sponsored gas is native**[^rhchain] — directly
  useful for the gasless-withdrawal / fresh-address problem the relayer solves today (§2, §4.5).

---

## 2. The head-start audit — what actually exists, quantified

Two independent zk stacks live in this repo. They have **never been connected**, and connecting them
is the core of the private-lending build.

### 2.1 Stack A — the Nova shielded pool (circom / snarkjs, BN254, EVM) — SHIPPED

Hides **amounts** via a Tornado-Nova UTXO join-split. Proven on RH-chain testnet at production depth
20 (`pool/README.md:30-38`).

- **`EsseyShieldedPool.sol`** — deposit / withdraw / 2→2 transfer; value accounting entirely inside the
  proof; nullifier set; incremental Merkle tree; 7-signal Groth16 verifier
  (`EsseyShieldedPool.sol:36-46,108-183`). **Deposit amount is public** (`extAmount`, `:109-113`);
  **internal transfer amount is hidden** (`extAmount==0`, `:155-183`).
- **`EsseyPoolGate.sol`** — the compliance front door; `isApproved(depositor)` screens funds IN; the
  README calls this the "Veil pattern" — audited money-math untouched, policy in a separate contract
  (`pool/README.md:8-16`). **This is the seat of the compliance-aware design (§5).**
- **`EsseyShieldedStock.sol` / `EsseyShieldedSupply.sol`** — same zk core with a pro-rata solvency
  haircut for burnable stock backing; already handles the RH `adminBurn` hazard class.
- **Stealth (`EsseyStealth*`, ERC-5564/6538)** — hides the **recipient** (`stealth.ts`,
  `EsseyStealthPay.sol`); amount public.
- **Client provers + SDK** — `poolsdk.ts` (note build, join-split proofs, `register`), `stealth.ts`
  (ECDH stealth addresses), relayer `api/relay.ts`. The circom sources + witness/zkey live in
  `rh-chain/circuits-nova/` (plus a local porting workspace, not committed).

**Reusable for private lending, near-wholesale:** the shielded-capital leg (deposit collateral/USDG
privately, hold a hidden-value note, exit via relayer to a fresh address) IS this. **(assessment) ~40–50%
of a private-lending system's plumbing is already here and testnet-proven.**

### 2.2 Stack B — the dregg solvency / IVC prover (gnark / Go, BN254, targets Sui) — VALIDATED, NOT WIRED

Proves **solvency over committed (hidden) values** — exactly the cryptographic heart of private
lending:

- **`transition.go:41-91` (`TransitionCircuit` / `proveBorrow`)** proves, with `old_root`, `new_root`,
  `price` as the _only_ public inputs and **everything about the position private**: (1) the position
  is included in `old_root`; (2) `new_debt = old_debt + amount`, range-bound; (3) the result satisfies
  the dregg solvency rule `enforceSolvent(debt, collateral, ltvBps, price)`; (4) the Merkle update
  touches only that leaf (`:78-90`). The position leaf commits `(pool, borrower, debt, collateral,
  ltvBps, nonce, type)` via Sui-compatible Poseidon (`transition.go:11-25`). **This is precisely
  "borrow against a hidden position, prove collateral ≥ `ltv·debt` in zk."**
- **`solvency.go`** — the standalone single-loan version (2,235 R1CS constraints per
  `SCOPE-solvency-circuit.md:99-107`); **`IVCFold` (`ivc_basecase.go`)** — true single-VK IVC proven
  end-to-end (`SCOPE-solvency-rollup.md:314-360`): one verifying key folds a whole history of solvent
  transitions into one constant-size, EVM-cheap BN254 Groth16 proof.
- **On-chain verifier exists** — `dregg_verifier::verify` wraps groth16/BN254
  (`SCOPE-solvency-circuit.md:8-11`); the exported EVM verifier lands at ~200–220k gas
  (`SCOPE-solvency-rollup.md:96-97`).
- **`DonLoan.sol` already emits the dregg tuple.** `loanTuple()` returns `(facility, borrower,
  debtWhole, floorWhole, ltv, nonce)` in whole-ESSEY units sized to the circuit's 64-bit bounds
  (`DonLoan.sol:244-265`), and the contract's own docstring says every loan stores its canonical
  solvency tuple for the dregg prover (`DonLoan.sol:64-68`). **The lending contract was built with
  this hook in mind.**

**What Stack B does NOT give you (net-new engineering, not research):**
- It is **gnark/Go targeting Sui** (`sui::poseidon`, `sui::groth16`) — **not wired to any EVM contract,
  not to Nova's circom circuits, and not to a live loan on RH chain.** Porting/bridging the transition
  verifier to the BN254 EVM precompile on 4663 and unifying its Poseidon note commitment with Nova's is
  real work.
- **Price is oracle-bound off-chain; the circuit trusts the public `price` input.** On RH chain you
  must bind `price` to the Chainlink feed on-chain at borrow time (`SCOPE-solvency-circuit.md:35-44`).
- **The constraint system is unaudited** ("never audited; a wrong constraint is a silent solvency
  hole," `SCOPE-solvency-circuit.md:94-97`) and the pool zkey is a **single-contributor trusted setup**
  needing a multi-party ceremony before mainnet (`pool/README.md:39-46`).
- **Current RH-chain lending deliberately dropped the ZK layer** and enforces LTV publicly in Solidity
  (`SCOPE-robinhood-chain.md:83-102`) — so private lending is _re-adding_ the ZK layer the port
  removed, now for privacy rather than for oracle-free solvency.

**Quantified head start for private lending (assessment):**

| | State | What it saves |
|---|---|---|
| Private-capital substrate (deposit/hold/transfer/exit, amounts hidden) | **shipped + testnet-proven** | the entire shielded-money leg |
| Private solvency proof (collateral ≥ ltv·debt over hidden values) | **validated E2E, gnark/Sui** | the hardest _research_ risk — retired |
| Constant-size history proof (IVC) | **validated E2E** | future "provably-solvent private pool" story |
| gnark→EVM port + note unification + oracle bind | **net-new** | — |
| Trusted-setup ceremony + formal zk audit | **net-new (pre-mainnet gate)** | — |

**Bottom line:** the two hardest _feasibility_ questions (can amounts be hidden in a pool on this
chain? — yes, shipped; can solvency be proven over hidden values? — yes, validated) are already
answered **yes** in this repo. That is a genuine, unusual head start. The head start does **almost
nothing** for the staking/rewards half (§3, §4.2).

---

## 3. The design-space spectrum, assessed for Robinhood Chain (chainId 4663)

### (a) Extend the note model — shielded notes accruing/borrowing against a public per-unit index — **RECOMMENDED**

**Shape:** every private position is a UTXO **note** committing its private fields (collateral,
debt, weight, `rewardDebt`-style checkpoint). Individuals are hidden inside the note; a **public
aggregate** (pool liquidity, `accPerWeight`, total reserve floor) stays on-chain and public. Actions
are zk state-transitions over the note's committed value against the public aggregate — exactly the
`transition.go` pattern, generalized from "borrow" to "stake / accrue / claim / repay."

- **Lending: fully constructible on the head start.** Deposit collateral into the shielded pool (note),
  then `proveBorrow`-style: prove the note's committed collateral satisfies `collateral·price ≥
  debt/ltv` and mint a hidden debt note, with the public pool paying USDG to a stealth/relayer address.
  Aggregate outstanding debt and pool balance stay public (unavoidable, §4.1). **(assessment) This is
  the leading candidate and it is real.**
- **Rewards: constructible _only_ if the aggregate index stays honest without leaking individuals —
  and that is the open problem.** A note can accrue against a **public** `accPerWeight` index (fine —
  the index is an aggregate). The obstruction is `totalWeight`: the index update
  `accPerWeight += distributed/totalWeight` (`Bell.sol:279`) needs `totalWeight`, and `totalWeight` is
  the _sum of the hidden weights_. Options, all with a real cost (§4.2): publish `totalWeight` (leaks
  the sum; with a small active-Don set the individual weights are recoverable), or maintain
  `totalWeight` privately via a zk accumulator (introduces **concurrent-writer contention** on shared
  state — the hard part). **(assessment) Staking/rewards under the note model is _plausible_ but
  unproven and is the project's one genuine research gamble.**

**Why this shape and not the others: it is the only one that (i) keeps you on Robinhood Chain composing
with real Stock Tokens, (ii) reuses both proven head-start pieces, and (iii) has a natural viewing-key /
selective-disclosure story (notes are already encrypted to a recipient key, §5).**

### (b) FHE (Zama / Fhenix / Inco encrypted state) — **NO for v1; dependency risk too high**

FHE is no longer vaporware: Zama shipped the **first production FHE mainnet Dec 2025** (confidential
USDT on Ethereum, ~20 TPS via an off-chain coprocessor + threshold-decryption network);[^zama] Fhenix
runs CoFHE coprocessors on Base and Arbitrum; Inco offers confidentiality-as-a-service over Zama's
fhEVM.[^fhe] Encrypted-ERC20 and encrypted-state DeFi are technically real today.

**But for Essey on 4663 it fails on dependency and trust:**
- **No FHE coprocessor or threshold-decryption committee exists on Robinhood Chain**, and you cannot
  deploy one — FHEVM needs an off-chain coprocessor network _plus_ an MPC threshold-decryption
  committee (the KMS). You would depend on Zama/Fhenix/Inco standing up infrastructure on a Robinhood
  chain, which does not exist and is not yours to provision.
- **Threshold decryption is a trusted committee** — a new liveness dependency and, worse, a
  **single regulatory chokepoint** (a decryption committee that can be compelled). That is _more_
  exposed than the note model, not less, for a securities venue.
- **It throws away the entire proven zk head start** (both Stack A and Stack B are Groth16/BN254 note
  systems; FHE is a different paradigm).
- **Gas/latency:** ~20 TPS on the coprocessor today,[^zama] with multi-step async decryption — heavy
  for a lending pool that must price against a live feed.

**(assessment) Revisit only if Robinhood/Fhenix bring an FHE coprocessor to 4663 natively; do not bet
the roadmap on it.**

### (c) Private zkRollup / app-zkVM (Aztec / Penumbra / Railgun-style) — **NO; too big and off-chain-of-record**

- **Aztec** reached an Ignition/2.0 mainnet with Noir 1.0 in late-2025/early-2026 — but it is **its own
  L2**, and a **critical vulnerability was disclosed 2026-03-17.**[^aztec] Building Essey on Aztec means
  **leaving Robinhood Chain** — you lose composability with the Stock Tokens, the Chainlink feeds, the
  Morpho/Uniswap ecosystem, and the DonReserve/floor, which is the entire product. Non-starter.
- **Penumbra** is a Cosmos app-chain (shielded DEX/staking) — same "wrong chain" problem, plus it is
  not EVM.
- **Railgun** is the closest reference _pattern_: an on-chain smart-contract privacy system (shielded
  balances + a zk prove-on-spend model) deployable per-EVM-chain, with a built-in **"Private Proofs of
  Innocence"** compliance layer. Worth studying as prior art for the note model and for compliance
  design — but it is still an **amounts-and-recipient note system (the same (a) paradigm)**, not a
  free lunch, and it does not do private _lending/staking accounting_.
- **Building your own app-zkVM on 4663** — a private execution environment with its own sequencer/DA —
  is a **12–18+ month specialist-team effort** and duplicates Aztec. **(assessment) Not justifiable
  when (a) reuses proven in-repo pieces.**

**Recommendation: (a), decisively.** It is the only shape that stays on Robinhood Chain, banks the
head start, and admits compliance. FHE and app-zkVMs are the "delay the launch for a year and maybe
fail" options the founder should _not_ take.

---

## 4. What is truly hideable end-to-end vs not — and the public↔private SEAM

### 4.1 The map

| Quantity | Hideable? | Where it leaks / why not |
|---|---|---|
| **Deposit amount (capital in)** | ⚠️ hidden after entry, **public at the boundary** | Deposits into the pool are public (`extAmount`, `EsseyShieldedPool.sol:109-113`); collateral pulled into a lending pool is a public ERC-20 `Transfer`. You hide it only if it enters as an _internal transfer_ from an already-shielded note. |
| **Held/shielded balance** | ✅ yes | UTXO note, value in-proof (`_transact`, `:155-183`). |
| **Loan principal / collateral / debt (per position)** | ✅ yes (in-circuit) | `transition.go:41-91` proves solvency with all position fields private; only `old_root/new_root/price` public. |
| **Collateral asset _type_** | ⚠️ only if pooled | dregg commits `type` (`transition.go:16,24`); a single-collateral pool leaks the type by construction. Multi-asset pool needed to hide it. |
| **Borrower ↔ receiving address link** | ✅ yes | stealth + relayer to a fresh address (`stealth.ts`, `api/relay.ts`), ERC-4337 sponsored gas on 4663.[^rhchain] |
| **That _some_ borrow/stake happened** | ❌ no | every action is a tx that inserts a commitment + spends a nullifier (`:178-182`). Count and timing are public. |
| **Aggregate pool liquidity / total outstanding debt** | ❌ no | the pool's USDG/ESSEY balance is public ERC-20 state; `lendable()` reads it (`DonLoan.sol:204-206`). |
| **Oracle price used** | ❌ no | must bind to the public Chainlink feed on-chain (§2.2); price is a public circuit input by design (`transition.go:59`). |
| **Per-Don reward entitlement** | ❌ **no, today** | the killer: `weight/totalWeight × distributed` is public from `Bell.sol:76,150-153,272-288` — see `PRIVACY-PAYOUTS-SCOPE.md:44-48`. Hiding it needs §4.2. |
| **Aggregate reward pot per ring** | ❌ no | `Rang(ringer, pot, tip, distributed)` (`Bell.sol:287`). |
| **The reserve floor** | ❌ no | `floorPerDon() = reserve/backedSupply`, both public (`DonReserve.sol:60-62`). |
| **Liquidation event** | ❌ no | collateral hits the public reserve/AMM; `Liquidated(...)` (`DonLoan.sol:135-142,415`). |

### 4.2 The named hard research problems (not hand-waved)

1. **Pro-rata reward distribution over hidden stakes.** The Bell is a MasterChef:
   `accPerWeight += distributed/totalWeight` and each claim pulls `weight·Δacc`
   (`Bell.sol:150-153,279`). To hide `weight` while keeping the index correct you must keep
   `totalWeight` correct. `totalWeight` is the **sum of hidden weights** → either you publish it (leak,
   fatal in a small anonymity set) or maintain it in a zk accumulator. **This is genuinely unsolved in
   production.** Zcash/Nova avoid it because notes never share mutable global state; a reward index
   fundamentally does.
2. **Private shared-mutable-state / concurrent-writer contention.** Every staker's proof is against a
   `totalWeight` (and `accPerWeight`) that other stakers are concurrently mutating. On a single-
   sequencer Orbit chain this is a serialize-or-fail bottleneck (the same class of problem that makes
   private AMMs hard). Needs an explicit ordering/commitment scheme; no in-repo piece addresses it.
3. **The public↔private seam / composability with the public floor & desk.** DonLoan lends against
   `DonReserve.floorPerDon()`, a **public** number (`DonLoan.sol:210-211`, `DonReserve.sol:60-62`), and
   liquidation redeems into the **public** reserve (`DonLoan.sol:415`). A private position that borrows
   against a public floor and liquidates into a public reserve **re-exposes itself at both crossings.**
   Every place shielded value touches the floor/desk/converter/AMM is a leak point by construction.
4. **Nullifier / anonymity-set design for a _lending_ pool.** Tornado anonymity = "your note is
   indistinguishable from others in the tree." A lending pool's notes carry _debt_ and must be _updated_
   (borrow, accrue, repay) not just spent-once — so the note lifecycle is richer than Nova's and the
   anonymity set is the set of open positions, which a curated beta (MEMORY: Merkle-whitelist) makes
   **small** — tens of positions. Small set + public aggregates = weak privacy (§4.4).
5. **Front-running / MEV on shielded loans.** The sequencer (Robinhood) sees the mempool. A shielded
   borrow still reveals a pool interaction and a price read; a liquidation still hits a public venue.
   Encrypted mempool / commit-reveal is a separate build the note model does not provide.

### 4.3 The seam, stated plainly

**Unavoidably public forever:** the existence, count and timing of actions; every aggregate (pool
liquidity, outstanding debt, `accPerWeight`, pot per ring, reserve floor); the oracle price; and every
moment shielded value crosses into or out of the public floor/desk/converter/AMM/reserve. **Hideable:**
per-position amounts and the identity↔address link, _while value stays inside the shielded domain._ The
privacy is real _within_ the pool and evaporates _at the boundary_ — and Essey's product is defined by
its boundaries (the floor, the desk, the Bell). **This is the central honest tension.**

### 4.4 Anonymity set (the quantitative ceiling)

Privacy = set size. Protocol self-deposits of publicly-known sizes add tree leaves but **no anonymity**
(`PRIVACY-PAYOUTS-SCOPE.md:212-235`). A curated beta has tens of positions. Real privacy needs organic
third-party shielding at overlapping denominations + a funded relayer + a mixing/latency window. Even
then the aggregate-and-timing leakage (§4.1) caps amount-privacy independent of set size.

---

## 5. The regulatory dimension — first-class, and the actual binding constraint

### 5.1 The post-Tornado landscape (as of 2026-08)

- **Immutable protocol contracts are likely not OFAC-sanctionable.** The Fifth Circuit
  (_Van Loon v. Treasury_, Nov 2024) held immutable smart contracts are not "property" under IEEPA;
  OFAC **delisted** Tornado Cash's contracts and front-end in **March 2025.**[^delist][^vanloon] Good
  for the _contracts_.
- **But the operator/developer is exposed — and that risk is _proven_, not theoretical.** Roman Storm
  was **convicted Aug 2025 of conspiracy to operate an unlicensed money-transmitting business**
  (5-year max), and DOJ is seeking a **retrial on the money-laundering & sanctions counts, proposed
  Oct 2026.**[^storm] The money-transmitting count is exactly the one that stuck, and it attaches to
  **whoever moves other people's funds** — which is precisely the role of Essey's **keeper / relayer /
  Path-B operator** (`api/relay.ts`, and any pooled-shielding operator in §3(a)). **(assessment) An
  Essey entity running the fund-moving infrastructure of a shielded pool is squarely in the class the
  Storm verdict targeted.**
- **Securities overlay makes it worse, not better.** The collateral and (via the converter) the payouts
  are **tokenized securities** — RH Stock Tokens are Jersey-issued debt tokens
  (`SCOPE-robinhood-chain.md:165-172`). A venue that obscures securities transfers invites FinCEN _and_
  SEC/broker-dealer attention on top of the mixer analysis.
- **The chain operator's permission is probably the real gate.** Robinhood runs the sequencer, the
  `ADMIN_BURNER_ROLE`, `TOKEN_PAUSER_ROLE`, and the deny-list — all live EOAs, deny-list **actively
  used** (246 `Blocked` events) (`SCOPE-robinhood-chain.md:316-340`). Robinhood can block Essey's pool
  address, and a compliance department at a public broker-dealer will not welcome an _unscreened_
  privacy mixer for securities on its own chain. **(assessment) This institutional/relationship risk
  binds before the courtroom risk does.**

### 5.2 Compliance-aware privacy is achievable — and it's the only shippable shape

Serious privacy protocols converged on **selective disclosure**, and Essey already has the primitives:

- **Screened front door (association set / ASP).** Zcash/Aztec/Railgun-style. Already built:
  `EsseyPoolGate.isApproved` screens deposits IN; withdrawals never gated (`EsseyShieldedPool.sol:109-110`,
  `pool/README.md:8-16`). Railgun's "Private Proofs of Innocence" is the mature reference. This keeps
  known-bad funds out without deanonymizing the honest set.
- **Viewing keys / selective disclosure.** Zcash viewing keys and Aztec's model let a user (or a
  regulator they authorize) decrypt _their own_ activity while it stays private to the public.
  **Essey's UTXO notes are already encrypted to a recipient key** (`encryptedOutput1/2`,
  `EsseyShieldedPool.sol:51-58,179-180`; recipient enc pubkey in `poolsdk.ts`) — a per-user viewing key
  that decrypts one's own note history is a _natural derivation_, not a redesign. Add an **audit-export
  path** (user-signed disclosure of a position's full history to a named auditor/regulator).
- **Opt-in transparency** for tax/exchange reporting (mirroring the existing default-private / opt-out
  election shape, `Bell.sol:69-74,209-228`).

**How this changes the architecture (first-class, not bolt-on):** viewing-key derivation, an
audit-export endpoint, and the screened gate become **core components designed in from line one.** It
also **retires the "absolute-privacy moat"** and replaces it with **"the only _compliant_ confidential
DeFi on Robinhood Chain."** That is defensible, honest, and — critically — the version Robinhood's
chain can tolerate hosting. **(assessment) A design that cannot offer selective disclosure should not
ship on this chain at all.**

---

## 6. Effort, phasing, risk

**Research-risk vs engineering-risk:**

- **Retired research risk:** does private solvency compose? (dregg IVC — yes, `SCOPE-solvency-rollup.md`).
  Can amounts be hidden in a pool on 4663? (Nova — yes, shipped).
- **Open research risk:** private pro-rata rewards over hidden weights (§4.2 #1); private shared-state
  contention (#2); anonymity-set bootstrapping (§4.4). **These live entirely in the staking/rewards
  half.**
- **Engineering risk (bounded):** gnark→EVM port of the transition verifier + note-commitment
  unification with Nova; on-chain oracle binding of `price`; collateral escrow reconciliation against
  `adminBurn`/`uiMultiplier`/pause (`SCOPE-robinhood-chain.md:107-160`); multi-party trusted-setup
  ceremony (`pool/README.md:39-46`); formal zk audit of the constraint system + the 3-agent adversarial
  pass; the compliance layer (viewing keys + ASP + audit export).

**Phased plan:**

- **Phase 0 — do NOT delay the current privacy launch.** Ship the already-built shielded settlement
  (Path A stealth-per-Don + funded relayer) per `PRIVACY-PAYOUTS-SCOPE.md:271-279`. It's real, honest
  ("we hide _where_ your earnings go"), and it grows an anonymity set. **(assessment) ~weeks; already
  scoped.**
- **Phase 1 — Private Lending v1 (the real primitive).** Wire Stack B's `proveBorrow` into an EVM
  lending pool on 4663 over Stack A's shielded collateral notes: deposit collateral privately, borrow
  USDG against a **hidden** position with an on-chain-verified zk solvency proof (collateral·price ≥
  ltv·debt), oracle-bound to Chainlink, exit via relayer/stealth. **Public: aggregate liquidity,
  outstanding debt, price, action count. Hidden: per-position amounts + borrower link.** Compliance-aware
  (screened gate + viewing keys) from day one. **(assessment) ~3–5 months to testnet-proven for a 2–3
  person zk-fluent team; then the ceremony + formal audit gate mainnet. This is the "own a real
  privacy primitive" v1, and it reuses both head-start pieces.**
- **Phase 2 — Research spike: private staking/rewards.** Fund a bounded spike on §4.2 #1–#2 (private
  MasterChef / private index with an honest hidden `totalWeight`). **Time-boxed, kill-criteria up
  front, promise nothing.** If it cracks, extend the note model to the Bell; if not, the Bell stays
  public (which is fine — the differentiator is private _lending_, not private clock-in). **(assessment)
  research, 2–4 months to a go/no-go, could fail.**
- **Phase 3 — Full vision** (private deposits + staking + rewards + lending, all shielded) only if
  Phase 2 succeeds AND the regulatory posture holds. **(assessment) 9–15+ months total, one genuine
  open research problem in the critical path.**

**Minimal "own a real primitive" v1 = Phase 1.** The full vision is Phase 3 and carries a research
gamble the v1 does not.

---

## 7. Go / no-go

**GO — on private _lending_ as v1; NO-GO on delaying the current launch to build the whole shielded
stack.**

**The honest case _for_:**
- The two hardest feasibility questions are already answered _yes_ in this repo (Nova pool shipped;
  dregg private-solvency IVC validated E2E). Almost nobody has that head start.
- Private lending against tokenized-stock collateral is a **genuine, first-on-Robinhood-Chain
  differentiator** — nobody there has privacy, and Morpho/Aave-style transparent lending is the
  incumbent.
- The compliance primitives (screened gate, encrypted notes → viewing keys) already exist, so the
  _only survivable_ version is also the _cheapest incremental_ version.

**The honest case _against_:**
- The product is defined by public boundaries (floor, desk, Bell, reserve, converter), and privacy
  **evaporates at every boundary crossing** (§4.3). The shielded domain is an island in a public sea.
- The most-marketed part — "private earnings / private staking" — sits behind the **one unsolved
  research problem** (private pro-rata rewards, §4.2) and a **small anonymity set** (§4.4).
- The whole thing rides on an operator/keeper/relayer moving others' funds — the exact profile the
  **live Storm money-transmitting conviction** targets (§5.1) — for **tokenized securities**, on a
  chain whose operator actively wields a deny-list.

**Single biggest risk — REGULATORY, not cryptographic:** an operator-run shielded venue moving
tokenized securities on a Robinhood-affiliated chain, against the _U.S. v. Storm_ precedent and
Robinhood's own compliance/permission posture. **The chain operator's tolerance is the binding
constraint, and it binds before any court does.** The mitigation is not cryptographic bravado — it is
**compliance-aware design (screened front door + viewing keys + audit export), built in from line one,
and a reframing from "absolute privacy moat" to "the only compliant confidential DeFi on Robinhood
Chain."** Build that, ship private lending first, treat private rewards as research, and the thesis
holds in its honest form.

---

### Sources
[^rhchain]: Robinhood Chain = Arbitrum Orbit/Nitro L2, chainId 4663, ETH gas, blob DA, mainnet 2026-07-01, ERC-4337 session keys, day-one Uniswap/Morpho/Chainlink/Lighter/BitGo. Dwellir, "What Is Robinhood Chain?"; Chainstack, "What is Robinhood Chain?"; thirdweb blog. Corroborated in-repo at `docs/SCOPE-robinhood-chain.md:177`.
[^zama]: Zama shipped the first production FHE mainnet (confidential USDT, Ethereum) 2025-12-30; fhEVM coprocessor (May 2025) ~20 TPS off-chain + threshold-decryption KMS; OpenZeppelin confidential-ERC20 lib. Zama, "fhEVM Coprocessor"; Messari, "Understanding Zama"; KuCoin, "FHE in 2026."
[^fhe]: Fhenix CoFHE coprocessors on Base + Arbitrum; Inco confidentiality-as-a-service over Zama fhEVM (TEE + FHE/MPC). KuCoin FHE 2026 overview.
[^aztec]: Aztec Ignition/2.0 mainnet + Noir 1.0 (late-2025 → Feb 2026); critical vulnerability disclosed 2026-03-17. Aztec, "Launching Aztec 2.0 Rollup" / "Road to Mainnet"; BlockEden, "Aztec Network TGE and Noir 1.0."
[^delist]: OFAC delisted Tornado Cash contracts + front-end from the SDN list 2025-03-21 following the Fifth Circuit. Treasury/DeFi Education Fund; Steptoe; CoinDesk, "Why OFAC Delisted Tornado Cash."
[^vanloon]: _Van Loon v. Treasury_, 5th Cir., Nov 2024 — immutable smart contracts are not "property" under IEEPA. Fifth Circuit opinion 23-50669.
[^storm]: _U.S. v. Storm_ — Roman Storm convicted 2025-08-06 of conspiracy to operate an unlicensed money-transmitting business (Count 2); deadlocked on money-laundering & sanctions; DOJ seeking retrial, proposed Oct 2026. CoinDesk; DOJ SDNY press release; Mayer Brown, "The Tornado Cash Trial's Mixed Verdict"; DeFi Education Fund, "U.S. v. Storm 2026 Update."
