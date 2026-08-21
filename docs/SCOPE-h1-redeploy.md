# SCOPE — shipping the H-1 fix to the live testnet stack

Written 2026-08-21. Facts read live at block ~41.68M / RH testnet 46630 unless marked otherwise.

## The constraint that shapes everything

`GameController.sealed_() = true` (VERIFIED on chain). So a module cannot be re-pointed instantly —
it is `queueModule` → wait `TIMELOCK` → `executeModule`, and `TIMELOCK() = 172800` = **2 days**.

That gives two paths, and they differ by more than time.

| | Path A — module swap | Path B — fresh stack |
|---|---|---|
| wall clock | **2 days** (timelock) | same day |
| game state (balances, deeds, houses, hoppers, missions) | **PRESERVED** | **LOST** |
| attestations (85 of 191 Dons) | **PRESERVED** | must re-attest all |
| what can change | only what lives in RaidEngine | anything |
| tester progress | intact | wiped |

**Recommendation: Path A**, because the stated goal is re-engaging testers and Path B deletes
everything they have built. The 2-day wait is cheaper than the goodwill.

## What Path A can and cannot carry

`RaidEngine` binds `affinity` as an **immutable** (`RaidEngine.sol:91`), as does `MissionBoard`
(`:88`). So:

- **CAN ship in Path A:** the H-1 fix. It is entirely inside RaidEngine.
- **CANNOT ship in Path A:** the `hdFlat` re-denomination and the `edgeOf` cleanup. Those live in
  `AffinityRegistry` / `AffinityTraits`. A new registry means new engines bound to it, which means
  a new registry with an empty `_sheet` — i.e. **re-attesting all 191 Dons**.

That is the real fork. H-1 alone is cheap and non-destructive. Trait math is not.

## Pre-flight — VERIFIED today

- **No raids are in flight.** 13 raids total: 10 `Committed`, 3 `Settled`, **0 `Revealed`**. A swap
  strands no live raid.
- **10 of 13 raids were abandoned at reveal** — see the UX finding below. Their commit fees sit in
  the old engine; `forfeit` reclaims them and should be run before the swap or they are orphaned.
- Missions: 199 dispatched, none past due unsettled. Keeper healthy under launchd.
- `missionBudget` 1,414,490 — roughly 7 days at the observed ~195k/day.

## The work, in order

1. **Review + commit the H-1 fix.** Currently uncommitted: `RaidEngine.sol`, `HouseEscrow.sol`,
   `test/GameRaid.t.sol`, `script/GameE2E.s.sol`. 131/131 game tests pass; all three exploit PoCs
   verified dead by the coordinator, control cases still land.
2. **Deploy the new RaidEngine.** Constructor takes ten addresses and validates none of them
   (L-1 in the 08-16 audit) — check every one by hand against the live stack before broadcasting.
3. **`forfeit` the 10 abandoned raids** on the old engine so the fees are not orphaned.
4. **`queueModule(RAID_MODULE, newEngine)`.** Public `ModuleQueued` event, 2-day clock starts.
5. **Wait 2 days.** Nothing else blocks; the game keeps running on the old engine.
6. **`executeModule(RAID_MODULE)`.**
7. **Keeper — two NEW duties, and this is the part that breaks if skipped.** Under the fix, `reveal`
   no longer draws the roll when a garrison is present. Something must call `requestRoll`:
   - draw as soon as `garrisonRevealed && rollRequestedAt == 0`
   - draw at the floor at `revealedAt + 3600`
   Both need `--value $fee`; the old `floorSettle` was free. **Ship the picker without these and
   garrisoning becomes near-total raid immunity.** Update `game-keeper.sh`, then restart the launchd
   job (`launchctl kickstart -k`) — the file, the process AND `.keeper-state` are three separate
   things (see `DEPLOY-CHECKLIST.md`).
8. **Off-chain consumers**, all currently pointing at the old engine:
   `app/web/src/game/gameAbi.ts:83` (`floorSettle` → `requestRoll(uint64) payable returns (uint64)`,
   add `rollRequestedAt`), `:96` comment, `app/web/src/game/raid.tsx:169,206`,
   `app/web/src/game/gameChain.ts:32`, `docs/TESTNET-GAME-E2E.md` rows 11 and F-B,
   `docs/GAME-GUIDE.md:566`.
9. **MCP** — standing rule, same commit as the game change. The instructions already claim "the
   randomness does not exist until settlement", which was FALSE for garrisoned raids under the old
   engine and becomes TRUE under the fix. No code change needed; the copy goes from wrong to right.
10. **Run the checklist:** `check-board.py`, `check-keeper.sh`, `check-deploy-assets.sh`, then the
    section A.8 copy + MCP reconciliation.

## The UX finding that may matter more than H-1

**10 of 13 raids never reached reveal — 77% abandonment.** The reveal window is `[10, 40]` minutes
after commit (`REVEAL_DELAY` / `REVEAL_WINDOW`), so completing a raid requires coming back for a
second transaction inside a 30-minute slot. Players are paying the commit fee and not returning.

H-1 is a correctness fix for an exploit nobody has yet run. **This is a live product failure, and it
is the thing standing between testers and the raid loop.** It is not in scope for this redeploy, but
it should be scoped next, and the options are cheap: widen the window, notify at the open, or let the
keeper reveal on the player's behalf from a stored preimage.

## Out of scope for this redeploy, by name

Trait magnitude (needs re-scoping — the caps buy 0.00pp), the `hdFlat` re-denomination and `edgeOf`
cleanup (need a new registry), the garrison picker (needs the keeper duties above shipped first),
`mintCustom`'s arbitrary-combo hole (needs a founder ruling), the stale
`AffinityRegistry.controller()`, and removing the dead `HouseEscrow.applyDamage`.
