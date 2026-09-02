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

---

## 5. GAP ANALYSIS — "is it just waiting for the ceremony?" (2026-08-30)

**Founder's question:** seed ~$20–25 of real stock to fund the first batch of Dons gameplay —
**mission first, then PvP raids — all gameplay + payouts shielded**. Where are we, what's missing,
and is it just waiting for the ceremony?

### THE HEADLINE (read this first)

**No. It is NOT just waiting for the ceremony.** There are **two parallel critical paths**, and the
one nobody has been costing is a real BUILD:

1. **Ceremony + shielded-set mainnet deploy** — the "shielded" half. *Ceremony-gated + founder-gated.*
2. **A real-token-custody House-layer BUILD** — the **mission** (and later raid) half. The mission /
   raid / House stack runs on the **Scrip custom ledger** (`mint`/`burn`/`move`), which a real RH
   Stock ERC-20 **cannot service**. This is engineering weeks, a fresh 3-agent audit, and a founder
   deploy — **not the ceremony, not a config flip.** *Build → audit → founder-gated.*

For a **mission-first** beta, path 2 is on the critical path next to path 1. The beta goes live when
**both** are done. **Correcting the record:** the earlier "Option A, no game-contract change" framing
(§1) and the economy scope's "config not redesign, Scrip-removal satisfied at the type level"
(`GAME-MAINNET-ECONOMY-SCOPE.md:103-105`) are **true for the payout example they used (Bell → the
player's wallet, `Bell.sol:341`) but NOT for missions.** Bell pays a real ERC-20; MissionBoard does
not. Winning a *mission* is not a Bell payout. See bucket 3.

### Bucket 1 — DONE (verified in the tree today)

| Item | State | Cite |
|---|---|---|
| **Mission provision-only shape** (removes the minted base leg → no mint dependency, self-backing) | CODED | `MissionBoard.sol:227-230` (two shapes; provision-only "NOTHING mints"), depart HOLDS provision `:287-289`, resolve pays by `move` not mint `:434-437` |
| **Degen payout-asset pricing** (value-faucet guard; real-share settlement) | CODED | `EsseyCasesDegen.sol:101` `pricedInPayoutAsset`, guard `:159-162` (`casePrice < E[payout]` reverts when priced in-asset), payout in shares `:81-83,283`, pull-based `owed` shares `:105,310` |
| **EsseyCasesDegen is genuinely real-ERC-20 custody** (the ONE game sink already mainnet-shaped) | VERIFIED | `IERC20 payoutStock` + `SafeERC20` `:64,81`, `safeTransferFrom` in `:237,252`, reserve = held balance `:224`. No Scrip. |
| **Bell + DonReserve are real ERC-20 (config-ready, not a redesign)** | VERIFIED | `Bell.sol:36-37` `IERC20 essey/reward`; `DonReserve.sol:30` `IERC20 essey` |
| **Shielded winnings need NO game-contract change** (player shields own winning; a payout contract cannot forge the recipient's note) | VERIFIED | `EsseyShieldedStock.sol:124-138` (deposit needs the recipient's own zk proof + gate approval); §1 Option A above; economy scope §5d |

### Bucket 2 — CEREMONY-BLOCKED (waits only on ceremony + shielded deploy)

Truly and only gated by the trusted-setup ceremony + the shielded mainnet deploy — no build beyond it:

| Item | Why ceremony-only | Cite |
|---|---|---|
| **Shielded-stock mainnet deploy** (AAPL/NVDA pool, `openMode=false`, `setApproved` players) | Contracts exist + testnet-proven; single-contributor zkey is the one hard blocker | testnet addrs `DEPLOYMENT-testnet.md:37-38`; blocker `MAINNET-SHIELDED-SCOPE.md:19-22,167-168` (`DeployShieldedPool.s.sol:20-21`) |
| **Payout→shield wiring** (the `/private` "shield your winnings" flow + player gate-approval) | Routing/UX only; Option A, no contract change | §1 Option A; `EsseyPoolGate.sol:47` `setApproved` |
| **Relayer** | **Optional** for the beta — withdrawals self-submit at `RELAYER_FEE=0`; a relayer only adds gasless UX (needs founder `RELAYER_PK`) | `MAINNET-SHIELDED-SCOPE.md:14-16,90-101` (`live.ts:835-838`) |

Confirmed **not** on the beta path: the `SolvencyVerifier` circuit (separate; out of scope,
`SHIELDED-GAME-BETA-PLAN.md §2`), the flywheel/AMM.

### Bucket 3 — BUILD REQUIRED (the House-layer rebuild — NOT the ceremony) 🔴 critical path

**The finding, grounded:** the mission / raid / House stack is built on the **Scrip custom internal
ledger**, not a real ERC-20. Every value move is a Scrip primitive that a real RH Stock ERC-20 has no
equivalent for:

- `IScrip` = `mint(to,amt)` / `burn(from,amt)` / `move(from,to,amt)` — an **owner-minted, force-movable
  internal ledger** (`GameTypes.sol:44-48`); `Scrip.mint/burn/move` are all `onlyModule` (`Scrip.sol:76,85,98`).
- **MissionBoard** holds `IScrip scrip` (`:80`). Even the **provision-only** ("real-asset shape") path
  still calls `scrip.burn(vault, dispatchFee)` (`:281`), `scrip.move(vault, this, provision)` (`:289`),
  and `scrip.move(this, escrow, payout)` (`:437`). A real stock token exposes **none** of `move`/`burn`
  callable by the board.
- **HouseEscrow** holds `IScrip scrip` (`:37`): deploy/bank via `move` (`:181,202`), fee via `burn`
  (`:215`), raid settle via `burn`+`move` (`:257-258,284-285`), stipend + pending via `mint` (`:161,347`).
- **RaidEngine** holds `IScrip scrip` (`:58`): commit fee `move` (`:219`), `burn` (`:270,509`).
- **No real-ERC-20→IScrip custody adapter exists in the tree** (grep: only the interface + HouseEscrow).

**What "provision-only" actually fixed:** it removed the *mint* (solvency) dependency for missions. It
did **not** remove the *custody* dependency — provision-only missions still ride `scrip.move`/`scrip.burn`.

**So to run a real-stock MISSION beta, one of two builds is required (founder ruling):**
- **(a) Real-asset custody rework** of MissionBoard (+ HouseEscrow, + RaidEngine for raids): hold a real
  ERC-20, provision via `transferFrom`, pay via `transfer`, fee via transfer-to-treasury (not `burn`),
  Don "vault"/House ledgers become real-stock custody. Honest, matches [[essey-scrip-removed]] ("real
  ERC-20, no synthetic currency"). Bigger diff, fresh tests + 3-agent audit.
- **(b) An IScrip-conformant custody wrapper** over the real stock (deposit stock → 1:1-backed internal
  credit; `move`/`burn` operate on the wrapper; withdraw redeems). Keeps the three contracts unchanged
  but **reintroduces a synthetic "currency"** — direct tension with the Scrip-removal rule. Needs a
  founder ruling that a 1:1-backed wrapper is acceptable, plus its own audit.

**Effort — INFERRED (PM estimate, not a line-by-line scope):** either route is a genuine
build → 3-agent audit → founder deploy, i.e. **weeks of essey-protocol-engineer + essey-auditor work**,
not a config flip. *Load-bearing VERIFIED claim: a build is required (the `IScrip` vs `IERC20` interface
mismatch is verified above). The week-count is INFERRED* — what would settle it is a don-designer /
protocol-engineer scope of the chosen route (a/b).

**Is it the critical path?** For a **mission-first** beta: **YES**, parallel to the ceremony. The
ceremony is founder-schedulable (participants); the custody build is engineering weeks. Whichever
finishes last gates go-live.

### Bucket 4 — NOT SCOPED (flag only)

**PvP / raid mainnet flow** — a separate don-designer + protocol-engineer task, not scoped here.
Dependencies it will carry (grounded): the **same** House-layer real-custody build as bucket 3
(`RaidEngine.sol:58`, `HouseEscrow.sol:37` are IScrip); **burn→route** reclassification of raid tax +
commit fee at the real-asset fee matrix (economy scope §3d, today `RaidEngine.sol:270,509` / `HouseEscrow.sol:257`
`burn`); **real entropy** (Dice, not MockEntropy — register #8, `RaidEngine.sol:5` `IEntropy`); and the
known **trait mis-calibration** (competitive, not solvency — [[essey-trait-balance-broken]]). Founder
asked mission-first, so raids follow the mission build; flag, don't build now.

### Bucket 5 — $20–25 SEED feasibility (grounded in the economy scope)

**Reservation law (§0):** the seed sets **stall probability, not solvency** — a sink reverts rather
than overpays (`MissionBoard.sol:280-283`, `EsseyCasesDegen.sol:219-221`). So the question is "how much
play before it stalls," per sink:

- **Provision-only MISSIONS (the recommended mainnet shape): seed = 0.** The provision self-backs
  (`worst ≤ provision`, `MissionBoard.sol:285-289`); the house never funds a mission payout, it takes a
  +10% edge (economy scope §4b: "Provision-only model: seed = 0"). So **$20–25 is not a mission bankroll
  at all** — with provision-only, missions need no seed. The real use of $20–25 becomes **starter stock
  to distribute to the ~15-Don cohort so players have something to provision with** (a distribution
  decision, not a solvency one) — or, if a subsidized base leg is kept, a subsidy tranche (below).
- **If missions keep a subsidized base leg** (the tranche `AssetPaymaster`, economy scope §3c/§4b): at
  `successUnits = 0.01 AAPL`, peak reservation ≈ 0.15 AAPL and bleed ≈ ~1 share/day. $20–25 ≈
  **0.087–0.11 AAPL** (AAPL ≈ $230, display-only mark A2) — roughly **a week-plus of subsidized base
  wage at pilot scale** before reseed. Enough for a small pilot; it *is* a bleed the fee loop must cover.
- **The GACHA is NOT fundable at $20–25, even calibrated.** Best calibrated ladder (10×-cap, ref 0.02
  AAPL) reserves **0.2 AAPL ≈ $46 per open** (economy scope §4a). $20–25 < $46 → it **cannot reserve a
  single open**. So a $20–25 budget points at **provision-only missions**, not the gacha — which aligns
  with the founder's mission-first instinct. *(Dollar marks are display-only, A2; the share reservations
  are the load-bearing figures.)*

### The ordered critical path to a live shielded mission-beta

| # | Step | Gate |
|---|---|---|
| 1 | **Founder ruling: House-layer route (a) rework vs (b) wrapper** — unblocks the build | 🔵 FOUNDER-GATED |
| 2 | **Trusted-setup ceremony** on `transaction2` → regen `PoolVerifier2` + zkey/wasm | 🟣 CEREMONY (+ founder participants) |
| 3 | **Build the real-asset House/mission custody** (chosen route) + tests | 🟠 BUILD (protocol-engineer) |
| 4 | **3-agent audit** — shielded mainnet CONFIG **and** the new custody contracts (clean same round) | 🟠 AUDIT (essey-auditor) |
| 5 | **Deploy shielded set to mainnet** (`openMode=false`, real AAPL/NVDA, `setApproved` players) | 🔵 FOUNDER DEPLOY |
| 6 | **Deploy the real-asset mission/House contracts to mainnet** + seed $20–25 starter stock | 🔵 FOUNDER DEPLOY |
| 7 | **Wire payout → `/private` shield flow** + player gate-approval (essey-web-designer) | 🟢 UX (no contract change) |
| 8 | **essey-harness proves it on-chain** (run mission → win → shield → withdraw to fresh addr, unlinkable) | 🟢 VERIFY |
| 9 | **Drop testnet framing** on `/private` + game surfaces — only after step 8 is live | 🟢 COPY |

Steps 2 and 3 run **in parallel**; both must land before 4. That parallelism is the whole answer:
**the ceremony is necessary but not sufficient — the House-layer build sits beside it on the path.**

### Register / stale-doc deltas (for the deployment-manager to reconcile)

- `docs/GAME-MAINNET-ECONOMY-SCOPE.md` **now EXISTS** (read 2026-08-30, dated 2026-08-30). The register
  line 181 and this plan's §4 both say it does not — **now stale**; dependency C's scope is delivered.
- **Correction to carry into the register:** economy scope `:103-105` lumps `MissionBoard.sol:80` and
  `RaidEngine.sol:58` with Bell/DonReserve as "settable token address, config not redesign." Verified
  above: those two (+ `HouseEscrow.sol:37`) are **`IScrip`, not `IERC20`** — a real stock token does not
  implement `move`/`mint`/`burn`, so they are a **redesign**, not config. Bell + DonReserve are correctly
  config-ready. Mark the House/mission/raid custody as BUILD REQUIRED in the register, not config.
</content>
