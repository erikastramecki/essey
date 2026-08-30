# Shielded game BETA — sequenced program plan

**This is a real BETA, not a demo.** Real gameplay on RH mainnet (4663), with shielding treated as
PRODUCTION. A player runs a mission, wins a SMALL amount of real stock, and receives it **shielded** —
shielding is a production feature the player uses for real, at a small initial seed size. Analysis +
sequencing only; deploys nothing, changes no contract, commits nothing. Every claim carries a `file:line`
or is marked UNVERIFIED.

**Founder-accepted, do NOT re-flag:** issuer freeze/pause/clawback/adminBurn on real stablecoins/stock is
FOUNDER-ACCEPTED. The shielded-STOCK pool already socialises an adminBurn loss pro-rata and closes deposits
on impairment (`EsseyShieldedStock.sol:129-135,162-166`); the objective is that shielding WORKS in
production, at a bounded initial seed.

---

## 0. The flow, in one line

Founder seeds a game stock wallet with a LITTLE real stock → player pays small gas + runs a mission →
wins SMALL stock → the winning is delivered SHIELDED (player deposits it into the mainnet shielded-stock
pool and later withdraws to a fresh, unlinkable address).

---

## 1. How the winning becomes "shielded" — routing, not a game-contract change

### The payout path today (plain ERC-20 transfers)

The game payout surfaces move a reward ERC-20 to a wallet/vault with a plain transfer — e.g. `Bell.claim`
pays `reward.safeTransfer(vault, amt)` (`Bell.sol:341`) and rings a tip out with `reward.safeTransfer(
msg.sender, tip)` (`Bell.sol:286`); Cases/Degen settle similarly (`EsseyCases.sol`, `EsseyCasesDegen.sol`).
None of them know anything about the shielded pool.

### The shielded-pool deposit path (what a deposit requires)

`EsseyShieldedStock.transact` with `extAmount > 0` requires, all at once (`EsseyShieldedStock.sol:124-137`):
1. the depositor is gate-approved — `gate.isApproved(msg.sender)` (`:127`),
2. deposits not paused and pool fully backed — solvency gate (`:126,:132`),
3. a valid zk proof committing to an **output NOTE whose secret the depositor holds** (`:136` → `_transact`),
4. `token.safeTransferFrom(msg.sender, pool, amount)` — the depositor pays the stock in (`:133`).

The note secret must be held by the eventual owner of the shielded funds (the player). That is the crux.

### Two ways to deliver "shielded" — and which the beta uses

**Option A — RECOMMENDED for the beta (payout-routing + UX, NO contract change).**
The game pays the small stock to the player's own wallet via the existing payout path (unchanged), then
the PLAYER shields it on `/private`: register account (`EsseyShieldedStock.sol:139-142`) → be gate-approved
(`setApproved` — `EsseyPoolGate.sol:47`, since production runs `openMode=false`) → generate their own note →
`transact(extAmount>0)` depositing the won stock → later `withdraw` to a FRESH address (unlinks the winning
from the exit, semantics shared with the base pool). The player handles the shielding for real. **This needs
zero change to Bell / Cases / MissionBoard — it is a `/private` "shield your winnings" flow plus an
onboarding nudge and gate-approval of players.**

**Option B — NOT for the beta (contract change + handshake).**
A payout contract deposits directly into the pool so the winning lands already-shielded. That requires the
payout contract to be gate-approved, hold the stock, AND call `transact` with a note commitment the player
**pre-supplied** (player generates a note secret client-side, hands the commitment to the payout flow before
payout). Couples the game contracts to the shielded pool, adds a proof-generation handshake, and needs a
payout-contract change + a fresh 3-agent audit. Defer to a later phase.

**Verdict:** the beta uses **Option A**. The link between "win" and "shielded" is a `/private` UX flow, a
routing nudge, and player gate-approval (essey-web-designer) — not a contract change.

---

## 2. The trusted-setup ceremony — ONE full multi-party ceremony secures ALL shielded pools

**Founder ruling: the FULL multi-party ceremony (a counterparty is available), not a bounded solo+cap.**

**One ceremony covers everything shielded.** All three shielded pools share the IDENTICAL zk core — one
circuit (`transaction2`), one verifier (`PoolVerifier2`): `EsseyShieldedStock`'s zk core is "IDENTICAL to
EsseyShieldedPool" (`EsseyShieldedStock.sol:11-12`) and both verify via `IPoolVerifier`/`PoolVerifier2`
(`EsseyShieldedStock.sol:8,55,178`; base `EsseyShieldedPool.sol`). So a single multi-party ceremony on
`transaction2` secures `EsseyShieldedPool` (USDG), `EsseyShieldedStock` (AAPL/NVDA), and `EsseyShieldedSupply`
alike. Each pool still deploys its own verifier INSTANCE from that one generated `PoolVerifier2`
(`DeployShieldedStock.s.sol:32-33`), but there is only ONE ceremony and ONE generation of artifacts.

**Ceremony deliverables:** run the multi-party ceremony on `transaction2` → regenerate `PoolVerifier2.sol`
+ the browser `.wasm`/`.zkey`. All three must be the SAME generation or every proof fails verification
(MAINNET-SHIELDED-SCOPE.md §4, blocker #4). This replaces the current single-contributor zkey
(`DeployShieldedPool.s.sol:20-21`, `rh-chain/src/private/pool/README.md:41-43`), which is a
forge-notes-from-nothing / drain vector on real funds — the hard blocker for a production shielded launch.

**Nothing else on the beta path needs a ceremony.** Base layer, lending, the stealth-address path, and the
game contracts use no zk trusted setup. The `SolvencyVerifier` is a SEPARATE circuit, needed only if the
solvency-proof feature ships later — **out of scope for this beta.**

---

## 3. Dependencies, ORDER, and gates

The base layer is NOT a blocker (already live on mainnet, verified 2026-08-29).

| # | Dependency | Status | Gate to clear | Owner |
|---|---|---|---|---|
| A | **Base layer** (reserve/$ESSEY on mainnet) | ✅ LIVE 2026-08-29 ([[essey-reserve-deposit-address]]) | none — done | — |
| B | **Shielded set on mainnet** | testnet only ([[MAINNET-SHIELDED-SCOPE.md]]) | ONE multi-party ceremony on `transaction2` → regen `PoolVerifier2`+zkey/wasm → deploy shielded set (real USDG/AAPL/NVDA, **openMode=FALSE**) → `setApproved` players → 3-agent config audit → FOUNDER deploy | shielded scope + essey-auditor |
| C | **Game economy on mainnet** (Scrip→small real stock) | testnet Scrip; **scope PENDING** | `docs/GAME-MAINNET-ECONOMY-SCOPE.md` does not exist yet — don-economist to produce: Scrip→small-real-stock remap, mainnet game deploy, small stock inventory, RTP/solvency on tiny real amounts | don-economist |
| D | **Flywheel / AMM** | not built ([[MAINNET-FLYWHEEL-MATH.md]]) | NOT on the beta critical path | — |

**Critical-path note:** the game (C) and shielded set (B) are on TESTNET and MAINNET respectively today —
a player cannot win testnet stock and shield it in a mainnet pool. The beta requires the game payout side on
mainnet with small real stock (C), running into the mainnet shielded-stock pool (B). B and C are the two
parallel critical paths; D is out of scope.

### Beta go-live sequence (founder-set order)

1. **ONE multi-party ceremony on `transaction2`** → regenerate `PoolVerifier2.sol` + browser `.wasm`/`.zkey`
   (same generation). Secures all three shielded pools. *(Gate B, hard blocker cleared.)*
2. **Deploy the shielded set to mainnet** — real USDG `0x5fc5…d168` (6-dec, `MAINNET-CONFIG.md:11`), AAPL
   `0xaF3D…93f9`, NVDA `0xd060…9EEC` (`MAINNET-CONFIG.md:12-13`), **`openMode=false`** (production posture —
   `EsseyPoolGate.sol:16,60`; flip the script's baked `openMode=true` at `DeployShieldedPool.s.sol:41`), then
   `setApproved(player, true)` per approved beta player (`EsseyPoolGate.sol:47`). 3-agent config audit →
   hand founder the exact `forge script` commands (MAINNET-SHIELDED-SCOPE.md §5.5; `DeployShieldedStock.s.sol`
   per stock with `STOCK=<addr>`). **FOUNDER deploys** (gated). Record printed addresses.
3. **Wire the game payout → shielded stock** — the Option-A `/private` "shield your winnings" flow + a
   separate mainnet client (reserve.ts pattern, MAINNET-SHIELDED-SCOPE.md §4), mainnet pool addresses, and
   player gate-approval. essey-web-designer. (Routing/UX, not a contract change.)
4. **The game itself on mainnet** — coordinate the don-economist's `GAME-MAINNET-ECONOMY-SCOPE.md` (C):
   Scrip→small-real-stock remap, mainnet game deploy, small stock seed. FOUNDER deploys the game contracts.
5. **Seed + launch beta:** founder seeds the game stock wallet with a LITTLE real stock; players pay gas,
   run missions, win small stock, shield it via `/private`, withdraw to fresh addresses. **essey-harness**
   proves it on-chain (deposit + withdrawal unlinkable, fresh address funded).
6. **Drop testnet framing** on `/private` only after step 5 is live on mainnet (single-narrative rule).

### Founder-gated decisions

- Every mainnet deploy (shielded set; game contracts) — per-instance.
- Ceremony participants + sign-off (full multi-party, confirmed ONE ceremony).
- The small `maxDeposit` cap value and the seed stock amount / tickers (AAPL and/or NVDA).
- The game-economy remap rulings (via don-economist's scope).
- Which wallet is the game stock inventory (keep separate from reserve/treasury).

### What I can do now WITHOUT any deploy

- This plan + the ceremony runbook (participants, `transaction2` → regen `PoolVerifier2`/zkey/wasm).
- The `/private` "shield your winnings" UX spec + player gate-approval flow → essey-web-designer.
- The Option-A payout-routing map (above) — confirms no game-contract change for the beta.
- 3-agent config-audit prep for the shielded-set mainnet config (essey-auditor).
- Coordinate don-economist to stand up `GAME-MAINNET-ECONOMY-SCOPE.md` (C).

---

## 4. UNVERIFIED / open

- `docs/GAME-MAINNET-ECONOMY-SCOPE.md` does **not exist yet** (confirmed 2026-08-30) — dependency C pending.
- Multi-party ceremony tooling noted but not yet run (`PRIVATE-LENDING-V1-PLAN.md:75-76` via
  MAINNET-SHIELDED-SCOPE.md §5.1).
- Whether the game payout wallet on mainnet is the ops wallet `0x93e6…4B9E` or a dedicated game-stock
  wallet — founder to set.
- Exact mainnet shielded pool addresses — do not exist until the founder deploys (step 2).
- Whether AAPL/NVDA sit in the reserve's genesis basket is a flywheel concern, not a beta blocker.
</content>
