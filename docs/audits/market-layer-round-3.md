# Market layer — adversarial audit round 3 (the MintDistributor)

**Target:** `rh-chain/src/market/MintDistributor.sol` — the Seat's sole minter and whitelist mint engine.
· **Date:** 2026-08-03 · **Result:** 2 hardenings applied, re-audit **CLEAN.**

Three independent auditors, each a distinct adversarial lens: (1) Merkle allowlist correctness + free-mint
accounting, (2) deploy-order safety + admin trust bounds, (3) reentrancy + Seat integration. Same gate as
always: all three clean in the same round before push; any fix re-runs every auditor from scratch. This
contract earned a third round because its deploy-order constraint is **unfixable after deploy** — the Seat's
`minter` is immutable, so the distributor must be deployed first and passed in as the minter, forever.

---

## The MintDistributor (`MintDistributor.sol`)

A free-mint whitelist distributor, and the Seat collection's only minter. Verified sound:

- **Merkle allowlist, per stage.** `leaf = keccak256(bytes.concat(keccak256(abi.encode(account, stage,
  allocation))))` — the double-hash matches OpenZeppelin's `merkle-tree` builder and domain-separates a leaf
  (double-keccak) from an internal node (single commutative-keccak pair), so no internal node can be passed
  off as a leaf. The leaf is *computed by the contract* from typed args (`abi.encode`, three fixed 32-byte
  words — no `encodePacked` ambiguity) with `msg.sender` as the account, so a caller can neither inject a raw
  leaf nor replay another wallet's proof. A zero/uninitialized root is unspendable — no proof yields a
  computed root of `0`.
- **Exactly-once free mint.** `claim` is gas-only (non-payable, no price path), mints the attested
  `allocation` to `msg.sender` only, once per `(stage, account)` via `claimed`. The `claimed` flag is set
  before the mint loop (strict CEI), the whole loop is `nonReentrant`, and `Seat.SoldOut` is the hard
  ceiling — an over-committed stage reverts the claim atomically rather than over-minting.
- **Bounded admin.** Roots are timelocked (`proposeRoot` → public-review window → `commitRoot`); the admin can
  never mint by fiat beyond the immutable `reserveCap` (Exchange float + partner tranche); `mintReserved` is
  the only non-Merkle mint path and its cap math is overflow-safe (0.8 checked) and CEI-ordered. No owner over
  funds, no pause, no upgrade, no `delegatecall`/`selfdestruct`.
- **Deploy-order lock enforced on-chain.** `initSeat` is one-shot and reverts unless `seat.minter() ==
  address(this)` — a mis-ordered deploy is rejected at wiring time, not discovered live. Never calling it
  leaves the contract inert (claims revert `SeatNotSet`), never unsafe.
- **Reentrancy.** The only untrusted callback is `_safeMint`'s `onERC721Received` to the claimer; it fires
  inside the `nonReentrant` span and hits `AlreadyClaimed` besides. The Seat's transfer hook never fires on a
  mint (`from == 0`), so a wired Bell has no path back into a claim. The per-Seat Vault clone is CREATE2
  deployer-bound (un-front-runnable), and `Seat.setHook` stores an address with no call-out at set time.

---

## Hardenings applied (round 1 → 3)

**1. Non-zero root timelock (constructor).** The constructor now reverts `ZeroTimelock()` on
`rootTimelock == 0`. A zero timelock would let a root be proposed and committed in the same block, silently
voiding the public-review window the trust model advertises; it also kept `pendingEta == 0` unambiguous as
the "nothing pending" sentinel. Not attacker-exploitable — a deploy-config footgun made un-deployable, in the
same spirit as the round-2 Exchange coherence guard.

**2. `setSeatHook` passthrough.** Because the distributor is the Seat's *immutable* minter, it is the only
address that can ever call the minter-gated `Seat.setHook`. Without a passthrough the Bell could never be
wired and Seat transfers could never fire `onSeatTransfer` — the mechanism that clears a Seat's tier/weight
on resale (the very behavior the round-2 Exchange audit relied on). This was a **deploy-unfixable defect**;
`setSeatHook` (admin-gated, `SeatNotSet`-guarded, and one-shot via the Seat's own `HookAlreadySet`) resolves
it. All three auditors re-confirmed it adds no mint power, no reentrancy path, and no new deploy-order hazard.

## Accepted design tradeoffs (informational, not defects)

- **Over-committed stages are first-come-first-served.** If the indexer publishes allocations summing past
  remaining `maxSupply`, early claimers drain supply and late ones revert `SoldOut`. A distribution-fairness
  property of a curated free mint, backstopped (not corrupted) by `SoldOut`; the fix is off-chain — keep
  committed allocations within supply.
- **Large allocations mint atomically.** Each Seat mint also deploys a Vault clone, so a single oversized
  allocation could exceed block gas and be unclaimable. Self-isolated (only that wallet), admin-authored, and
  avoided by the binary-floor design (allocation ≈ 1). No partial-claim path is added, to keep the
  exactly-once invariant minimal.
- **Trusted hook.** `setSeatHook` is one-shot and the hook is invoked uncondition­ally on every true transfer,
  so a hostile/reverting hook set by the admin would brick secondary transfers. This sits inside the trust
  boundary `Seat.sol` already documents (the hook is trusted infrastructure; a reverting hook is a deployment
  bug), cannot affect minting (`from == 0` skips the hook), and the hook *must* be settable for the Bell to
  attach. Gated to the admin multisig.

## What was NOT covered

Research build; not deployed. On-chain Seat metadata/art (the other half of the mint-distribution task), the
Case system, and the website are scoped but unbuilt. The loan-interest→Bell reserve routing (an `EsseyPool`
addition) is designed but not yet implemented. Tests: `rh-chain` 189/189 green (32 for the MintDistributor).
