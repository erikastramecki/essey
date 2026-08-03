# Market layer — adversarial audit round 2 ($ESSEY token + the Exchange)

**Target:** `rh-chain/src/market/EsseyToken.sol` (the access token) + `EsseyExchange.sol` (the Seat AMM)
· **Date:** 2026-08-03 · **Result:** 1 hardening applied, re-audit **CLEAN.**

Three independent auditors (token/adminless; Exchange money-paths; Exchange↔Bell↔Seat integration +
economics). Same gate rule as always: all three clean in the same round before push; a fix re-runs
every auditor from scratch.

---

## $ESSEY token (`EsseyToken.sol`)

Verified against the actual inherited OpenZeppelin v5.6.1 source:
- **Fixed supply, mint-only-at-construction** — `_mint` is internal and never re-exposed; entire
  2,222,222,222e18 minted once to a non-zero treasury; `burn`/`burnFrom` only ever decrease supply.
- **Fully adminless** — inheritance is `ERC20, ERC20Burnable, ERC20Permit → EIP712, Nonces, Context`.
  No owner / mint / pause / upgrade / blocklist anywhere. Nothing for a key to do.
- **Standard non-replayable permit** — unmodified OZ EIP-2612 (single-use nonces, chainid-guarded
  domain separator, malleability-rejecting recovery).
- **Callback-free** — no `_update`/`_transfer` override, so no fee-on-transfer/rebasing. Safe as the
  Bell's fee token and the Exchange's price/reserve asset (1:1 transfers, no accumulator/AMM drift).

## The Exchange (`EsseyExchange.sol`)

A two-sided flat-price Seat vault-AMM. Verified sound:
- **Inventory accounting** — the swap-and-pop array keeps `_idxPlus1[id] != 0 ⟺ id ∈ _inv`, fixes up the
  swapped-in element before `pop()`, and the last-element self-case ends correctly at 0. Double-add is
  impossible (transfers revert if the id isn't owned), double-remove unreachable (guards).
- **Value conservation** — every Seat delivered is gated by full payment first; every $ESSEY paid out is
  gated by a real Seat pulled in; the `fee==0` early-return skips only the fee leg. No under-pay path, no
  reserve drain; a buy→sell round trip is $ESSEY-neutral and strictly fee-negative.
- **Fee routing** — `toBell + toTreasury == fee` exactly (no dust leak), and because `feeToken ==
  bell.reward()` the booster transfer raises `Bell.pot()`. Verified end-to-end (buy → ring → claim into a
  Vault).
- **Reentrancy** — all entrypoints `nonReentrant`, strict CEI on buy/snipe; the only hook-firing call
  (`seat.transferFrom` → `Bell.onSeatTransfer`) never calls back into the Exchange; the tokens are
  callback-free.
- **Seeder** — add-only; can never touch the reserve, fees, or others' assets.
- **Integration** — fee-feeds-pot coupling can't be gamed (direct donations are fee-negative), tier /
  weight / payout state stays correct across the Exchange hop (sell clears, buy inherits a clean tier-0
  Seat, `pendingStored` never double-counts), and a Seat's Vault is untouchable while parked in inventory
  (the Exchange has no path to the owner-gated `SeatVault.execute`).

---

## Hardening applied (from round 1 → 2)

**Deployment-coherence guard.** The Exchange constructor now asserts
`address(bell_.seat()) == address(seat_)`, making a mis-wired deploy (Exchange pointed at a Bell that
rewards a *different* Seat collection, silently sending fees to an unrelated pot) **un-deployable**
rather than merely a deploy-script check. Not attacker-exploitable, but the "provably-safe, no-footguns"
posture the protocol stands for. Re-audited from scratch by all three: correct, can't reject a valid
deploy, adds no new surface.

## Accepted design tradeoffs (informational, not defects)

- **Flat-price bearer leakage.** The Exchange prices every Seat identically, but a Seat carries its Vault
  (and any unclaimed `pendingStored`). A careless seller who doesn't drain/claim before selling
  surrenders that value to the buyer — inherent to any vault-bearing NFT's secondary sale, not a protocol
  loss (reserve/pot untouched). UX must warn sellers to claim + drain the Vault before selling.
- **JIT tier activation before a ring.** Standard accumulator-staking MEV; deterred by the non-refundable
  $ESSEY activation sink (half burned) and `minRing`. No fix for v1.

## What was NOT covered

Research build; not deployed. The Case system, the Seat mint-distributor + on-chain art, and the
website are scoped but unbuilt. The loan-interest→Bell reserve routing (an `EsseyPool` addition) is
designed but not yet implemented.
