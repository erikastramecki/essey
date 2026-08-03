# Market layer — adversarial audit round 6 (on-chain Seat art)

**Target:** `rh-chain/src/market/SeatArt.sol` + the `setArt`/`tokenURI` additions to `Seat.sol` and the
`setSeatArt` passthrough in `MintDistributor.sol`.
· **Date:** 2026-08-03 · **Result:** 3 rounds, 2 LOWs + 5 hardenings found and fixed, final round **CLEAN** on all three lenses.

Three lenses per round: wiring/one-shot regression; rendering/output integrity; integration/marketplace
semantics. The renderer touches two previously-certified contracts, so the regression lens re-verified
their invariants byte-level.

## What was added

Fully on-chain metadata — no IPFS, no server, no bait-and-switch surface. The hallmark E-monogram in
gold on ink, the Seat number as a certificate ("SEAT Nº 0001"), and a **live Tier read from the Bell**:
gold pips appear as the owner stakes and vanish the block a resale clears the tier. The metadata
description bakes in the two facts a secondary buyer most needs — the Vault address and that Tier
clears on transfer. Wiring follows the hook pattern: `setArt` is one-shot and minter-gated, with the
distributor passthrough (the immutable-minter lesson, applied the first time instead of re-learned).

## What the gate caught

- **The codeless-Bell brick (LOW, found independently by two lenses, both empirically probed).** A call
  to a codeless address "succeeds" with empty returndata and the tuple decode then reverts *outside*
  the try/catch — so the claimed fail-open was false exactly when it mattered, and a typo'd immutable
  Bell address would have bricked `tokenURI` for all 2,222 Seats forever. *Fixed twice over:* the
  constructor rejects a codeless bell, and `_tierOf` short-circuits on `code.length` so fail-open is
  genuinely true.
- **The wrong-Bell permanent lie (LOW).** Nothing forced the art's Bell to be the Seat's transfer hook;
  a mismatch would render a tier that never clears — precisely what the metadata promises can't happen.
  *Fixed:* the constructor requires `seat.hook() == bell`, which also pins the deploy order for free.
- **The codeless-hook transfer brick (LOW, round 2).** Auditing the art guard surfaced that `setHook`
  itself accepted a codeless address — which would brick *every transfer* with the one-shot consumed.
  *Fixed:* the same guard, mirrored.
- **Hardenings:** `setArt` rejects codeless renderers (an accidental EOA would have made `tokenURI`
  revert forever); the zero-address passthrough no-op no longer emits a lying event; the hardcoded
  "2,222" reads `maxSupply()` dynamically; the tier-pip row was 6px off the number's centerline (the
  render lens computed the rotation geometry to sub-pixel: centers now sit at exactly x=200).

## Verified properties

JSON strict-parses and SVG XML-parses on real decoded output; no attacker-influenceable text exists in
any interpolation; the Bell tuple decode is pinned to the actual struct layout (a future reorder fails
loudly, never renders weight as tier); render is deterministic and byte-identical for identical state;
claims/rings never move the art (only tier is read); ~300–430k gas per render, far under any eth_call
cap; XML numeric entities instead of raw UTF-8 (charset-sniffing-proof). Accepted residuals: marketplace
*image caching* can briefly show a seller's cleared tier (no contract can fix a cache; the embedded
description warns of exactly this), and a bell-less renderer deployed against a hooked Seat
under-renders only — the harmless direction.

## What was NOT covered

Not deployed. The market-layer deploy sequence (distributor → Seat → Bell → hook → art → mint) is
enforced by the constructor guards but not yet scripted — write the script before any real deploy.
Tests: `rh-chain` 271/271 (16 for the art stack).
