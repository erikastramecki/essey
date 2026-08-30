# Mainnet shielded-transfer scope — Robinhood Chain (chainId 4663)

Scope for one **live shielded transfer** on RH mainnet. Directive: founder, 2026-08-30 — no testnet.
Every factual claim carries a `file:line` or an on-chain fact. Unprovable items are marked UNVERIFIED.
Scoping only — nothing here deploys, edits contracts, or commits.

Today the whole `/private` flow is testnet (46630): contracts in `docs/DEPLOYMENT-testnet.md:24-38`,
frontend pinned to `NET.chainId=46630` (`app/web/src/live.ts:14-21`).

---

## 0. TL;DR / decision surface

- **Minimal live shielded USDG transfer** needs ONE deploy: the shielded-USDG pool stack (hasher +
  verifier + gate + pool) pointed at real USDG. A relayer is **not** required — withdrawals self-submit
  at `RELAYER_FEE = 0` (`app/web/src/live.ts:1040`, `:835-838`).
- **Real mainnet USDG exists and is verified:** `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, **6 decimals**,
  "Global Dollar" (`docs/MAINNET-CONFIG.md:11`, `:134`, `:165`). Not the gating dependency.
- **The gating dependency is the TRUSTED SETUP**, not an asset address. The deployed zkey is a
  **single-contributor** Groth16 setup (`rh-chain/script/DeployShieldedPool.s.sol:20-21`,
  `rh-chain/src/private/pool/README.md:41-43`). On real funds that is a forge-notes-from-nothing / drain
  vector. **Hard blocker #1.**
- **Second structural blocker:** `NET` in `live.ts` is shared by the ENTIRE app (game/Dons/lending),
  which is testnet-only — "nothing of ours is deployed on mainnet" (`docs/MAINNET-CONFIG.md:121`). You
  cannot flip `NET` to 4663; `/private` needs its own mainnet client (the `reserve.ts` pattern).

---

## 1. Contracts to deploy to mainnet

### Minimal path — shielded USDG (hide-amounts) transfer

Deployed together by `rh-chain/script/DeployShieldedPool.s.sol:33-51`:

| Contract | File | Constructor args |
|---|---|---|
| Poseidon(2) hasher | raw bytecode `circuits-nova/build/Hasher2.bytecode.txt` | none — `create` from bytecode (`DeployShieldedPool.s.sol:25-31,39`) |
| Groth16 verifier | `rh-chain/src/private/pool/PoolVerifier2.sol` | none (`:40`) — **must match the ceremony zkey**, see §5 |
| `EsseyPoolGate` | `rh-chain/src/private/pool/EsseyPoolGate.sol` | `(operator, openMode)` (`EsseyPoolGate.sol:33`); script passes `(msg.sender, true)` (`DeployShieldedPool.s.sol:41`) |
| `EsseyShieldedPool` | `rh-chain/src/private/pool/EsseyShieldedPool.sol` | `(verifier2, LEVELS=20, hasher, USDG, gate, admin=msg.sender, maxDeposit)` (`EsseyShieldedPool.sol:89-103`, `DeployShieldedPool.s.sol:42-44`) |
| `MerkleTreeWithHistory` | inherited by the pool (`EsseyShieldedPool.sol:36`) | not separately deployed |

**Config decisions the script bakes in (both need a ruling before a mainnet run):**
- `openMode=true` (`DeployShieldedPool.s.sol:41`) means anyone can deposit. The gate's own contract says
  this MUST be false in production (`EsseyPoolGate.sol:16`, `:60`). For a single controlled smoke test
  openMode=true is operationally fine; as a standing compliance posture it is not. If false, the founder
  must `setApproved(founderAddr, true)` before depositing (`EsseyPoolGate.sol:47`). **Founder ruling.**
- `maxDeposit = type(uint256).max` (`DeployShieldedPool.s.sol:36`). Consider a bounded cap for a first
  live pool via `configureLimits` (`EsseyShieldedPool.sol:185`). **Founder ruling.**

A shielded "transfer" can be realised either as **deposit → withdraw to a fresh address** (unlinks
deposit from withdrawal, `EsseyShieldedPool.sol:105-115,169-172`) or an **in-pool 2→2 transfer** to
another registered user (`live.ts:850-868`). Deposit→withdraw is the simplest single-actor proof.

### Fuller set (not needed for the first USDG transfer)

| Pool | File | Deploy script | Extra args / prerequisite |
|---|---|---|---|
| Shielded STOCK — AAPL, NVDA (one pool each) | `rh-chain/src/private/pool/EsseyShieldedStock.sol` | `DeployShieldedStock.s.sol` (per-token, `STOCK` env, `:29-37`) | real stock token address (§2) |
| Shielded SUPPLY (private yield) | `rh-chain/src/private/pool/EsseyShieldedSupply.sol` | `DeployShieldedSupply.s.sol` (`USDG`+`LENDING_POOL` env, `:28-37`) | **requires a mainnet ERC-4626 EsseyPool first** — not deployed (`docs/MAINNET-CONFIG.md:121`) |
| Stealth-address pay (ERC-5564/6538) | `EsseyStealthAnnouncer.sol` / `EsseyStealthRegistry.sol` / `EsseyStealthPay.sol` | `DeployStealth.s.sol:14-25` | none — no args, no funds, permissionless (`DeployStealth.s.sol:5`) |

Note on the stealth trio: it is a **separate product**, not a shielded pool — **amounts are public**
on-chain; it only hides the recipient link (`app/web/src/private.tsx:4-6`, `EsseyStealthPay.sol:11-17`).
If "shielded transfer" means hide-amounts, it is the pool; if it means an unlinkable payment, it is the
stealth path. Each hasher/verifier is deployed fresh per pool (`DeployShieldedStock.s.sol:32-33`).

---

## 2. Mainnet config — real-asset wiring that replaces testnet mocks

All addresses below are marked "verified against live mainnet 2026-08-11, read-only" in
`docs/MAINNET-CONFIG.md:119-120`; re-confirm with `cast` at deploy time (recall is not evidence).

| Asset | Mainnet address | Facts | Cite |
|---|---|---|---|
| **USDG** | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | **6 decimals**, symbol USDG, "Global Dollar", code present | `MAINNET-CONFIG.md:11`, `:134`, `:165` |
| **AAPL** | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | 18-dec, `uiMultiplier()=1e18`, pausable, not paused | `MAINNET-CONFIG.md:12`, `:183` |
| **NVDA** | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | 18-dec, `uiMultiplier()=1e18` | `MAINNET-CONFIG.md:13`, `:184` |
| RPC / chain | `https://rpc.mainnet.chain.robinhood.com` / 4663 | `cast chain-id → 4663` | `rh-chain/foundry.toml:23`, `MAINNET-CONFIG.md:164` |

- Testnet used an 18-dec mock USDG (`docs/DEPLOYMENT-testnet.md:62`, `:78`); mainnet USDG is **6-dec** —
  this is the decimals fix in §4. **Beacon/interface check for stock:** the shielded-stock solvency math is
  raw-balance vs raw-balance and is `uiMultiplier`-agnostic (`EsseyShieldedStock.sol:39-46`), so a normal
  split/dividend (which moves only the multiplier) does not perturb it. Still confirm `uiMultiplier()`
  exists on the live token before deploying a stock pool (already true per `MAINNET-CONFIG.md:12-13`).

### Relayer (mainnet)

The relayer is a Vercel serverless function (`app/web/api/relay.ts`), trustless — `extDataHash` binds
recipient/relayer/fee into the proof, so it can only submit the exact tx or refuse (`relay.ts:4-8`).
It hardcodes testnet and must change for mainnet:

- `RPC` and `CHAIN` are testnet literals (`relay.ts:14-15`) → mainnet RPC + chain 4663.
- `ALLOWED_POOLS` are the four testnet pool addresses (`relay.ts:19-24`) → mainnet pool addresses.
- `MIN_FEE = 0` (`relay.ts:25`) → production MUST set a gas-covering minimum + rate-limit (`relay.ts:25`, `:83`).
- **Vercel env `RELAYER_PK`** — a DEDICATED, non-privileged key (`relay.ts:10`, `:63`). **Founder provides
  and funds it with mainnet gas ETH; never handled here.**
- The relayer wallet address is also pinned in the frontend as `ADDR.poolRelayer` (`live.ts:63-64`).

**The relayer is optional for the first transfer** — self-submission is a valid path (`live.ts:835-838`).
Defer it unless the founder specifically wants gasless / tx-origin hiding on the first run.

---

## 3. Real-asset risks not present on testnet

### (a) Issuer `adminBurn` on shielded REAL stock — handled by design

`EsseyShieldedStock` defends a burnable backing that a vanilla Nova pool cannot: a **pro-rata haircut**.
`totalShielded` tracks expected backing (`EsseyShieldedStock.sol:61`, `:134`); a withdrawal pays
`noteValue * balanceOf / totalShielded` (`quoteHaircut`, `:162-166`; applied `:214-230`); a deposit
**solvency gate** refuses new deposits into an impaired pool (`:132`); the ratio is monotonically
non-decreasing so losses are order-independent (`:24-37`). Identity behaviour when solvent (`:29`).
**Stated pre-mainnet assumption to verify (`:39-46`):** the pool reads ANY `balanceOf` drop below
`totalShielded` as an adminBurn loss — correct only if raw balance falls *solely* by adminBurn, never by a
corporate action implemented as a raw burn. Verify against the live token's behaviour before a stock pool
goes live. UNVERIFIED here (needs the issuer's contract behaviour).

### (b) Shielded USDG path — the plain pool has NO haircut

`EsseyShieldedPool` assumes its ERC-20 backing is inviolable — it has no `totalShielded`, no haircut, and
pays each withdrawal in full first-come-first-served (`EsseyShieldedPool.sol:169-177`; contrast the stock
pool's rationale at `EsseyShieldedStock.sol:14-20`). **Open question:** can real USDG
`0x5fc5…d168` **freeze/blacklist/pause/burn** the pool's address? If yes, a plain shielded USDG pool can
be bricked or drained with no pro-rata protection, and USDG should arguably use the haircut (stock)
variant or the risk be accepted explicitly. USDG's admin surface is **UNVERIFIED** — settle by reading the
live token's code (freeze/blacklist/mint-burn roles) before shielding real USDG. This is a §5 audit item.

### (c) Stealth path with real funds

Zero custody — `msg.sender → stealthAddress` directly, the contract holds nothing (`EsseyStealthPay.sol:14-18`),
so no burn/haircut concern. Real-fund caveats: (i) **de-anonymisation** — the stealth address is gas-funded
from the main wallet and swept to `to`, both on-chain edges; the relayer/paymaster that would remove the
funding link is "a later phase," not built (`live.ts:755-759`). (ii) **Finality** — sweep waits on the
receipt and reverts on non-success (`live.ts:778-780`); legacy gas pricing with a 200k limit
(`live.ts:768-770`). (iii) EOA-only — keys derive from a deterministic signature; smart-contract wallets
are refused before any funds can be received (`live.ts:315-320`).

---

## 4. `/private` re-wire (frontend)

- **Do NOT flip `NET`** (`live.ts:14-21`) — it is shared by the game/Dons/lending flows in the same file,
  which are testnet-only (`docs/MAINNET-CONFIG.md:121`). Add a **separate mainnet viem client** for the
  shielded flow, exactly as `app/web/src/reserve.ts:21-23,71-77` already does for the mainnet reserve read
  layer. This keeps the rest of the app on testnet.
- **`ADDR` shielded entries** (`live.ts:56-64`): replace `shieldedPool`, `shieldedPoolGate`,
  `shieldedStockAapl`, `shieldedStockNvda`, `shieldedSupply`, `poolRelayer` with the mainnet deploys.
- **`SHIELDED_POOLS`** (`live.ts:276-281`): set USDG `decimals: 6` (currently `18`), mainnet pool
  addresses, and mainnet `deployBlock` scan floors. The hardcoded-18 bug over-sends by 1e12× — flagged in
  code at `app/web/src/private.tsx:13-14`.
- **`api/relay.ts`**: the changes in §2 (RPC/CHAIN/ALLOWED_POOLS/MIN_FEE, `RELAYER_PK`).
- **Prover artifacts**: `poolsdk` loads the `.wasm` / `.zkey` (gitignored, rebuilt — `README.md:48-52`).
  After the ceremony (§5) these AND `PoolVerifier2.sol` must all be the same generation, or every proof
  fails verification.
- **Honest framing — remove ONLY after mainnet contracts are live:** the "testnet only / Experimental"
  copy at `private.tsx:4`, `:6`, `:260`, `:262`, `:270`, `:276`, `:281`, `:408`. Do not remove earlier
  (single-narrative rule, per project memory).

---

## 5. Audit + deploy sequence (ordered)

Hard gates first — these are not optional for **real funds**:

1. **Trusted-setup ceremony (BLOCKER).** Replace the single-contributor zkey with a real multi-party
   ceremony (`README.md:41-43`, `DeployShieldedPool.s.sol:20-21`; tooling noted `PRIVATE-LENDING-V1-PLAN.md:75-76`).
   Regenerate the zkey → regenerate `PoolVerifier2.sol` + the browser `.wasm`/`.zkey`. Without this, whoever
   ran the setup can forge notes and drain the pool.
2. **Formal zk circuit audit** by a specialist (`README.md:44`) — pre-mainnet gate.
3. **3-agent audit of the MAINNET CONFIG** (contracts were testnet-audited; the config + real-asset
   assumptions were not). Must cover: 6-dec USDG handled end-to-end in pool + SDK; `openMode` posture;
   `maxDeposit` cap; **real-USDG admin surface** (§3b) — is the plain pool safe against USDG
   freeze/blacklist/burn?; stock `adminBurn` assumption (§3a); relayer `MIN_FEE`/rate-limit. Standard gate:
   all 3 agents clean in the same round (project memory: pre-push security-audit gate).
4. **Verify real USDG behaviour on-chain** (`cast`) — decimals (expect 6), and whether it can freeze/burn
   the pool. This decides §3b.
5. **Founder deploys** (founder-gated; not self-deployed). Minimal USDG pool, from `rh-chain/`:
   ```
   USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 PK=$MAINNET_DEPLOYER_PK \
   forge script script/DeployShieldedPool.s.sol --rpc-url rh_mainnet \
     --broadcast --private-key $PK --gas-estimate-multiplier 300
   ```
   (`rh_mainnet` alias: `foundry.toml:23`. Requires `circuits-nova/build/Hasher2.bytecode.txt` present
   locally — gitignored — `DeployShieldedPool.s.sol:26`.) Record the four printed addresses
   (`DeployShieldedPool.s.sol:47-50`). If `openMode=false` was chosen (§1), then also
   `cast send <gate> "setApproved(address,bool)" <founder> true`.
   Fuller set (only if in scope): `DeployShieldedStock.s.sol` per stock (`STOCK=<addr>`); supply pool
   requires a mainnet lending pool first.
6. **Re-wire frontend** per §4; deploy the web app + set Vercel `RELAYER_PK` only if the relayer is in scope.
7. **Verify a live shielded transfer** with a tiny real USDG amount: unlock → deposit → withdraw to a fresh
   address (self-submit). Confirm on the explorer that the deposit and withdrawal are unlinkable and the
   fresh address received USDG. (Adversarial-harness discipline: prove it on-chain, don't assert it.)
8. **Remove testnet/experimental framing** (§4) once step 7 passes.

### Hard blockers / unknowns

| # | Blocker | Cite | Resolution |
|---|---|---|---|
| 1 | Single-contributor trusted setup → forgeable proofs on real funds | `README.md:41-43`, `DeployShieldedPool.s.sol:20-21` | Multi-party ceremony + regenerate verifier/zkey/wasm |
| 2 | `NET` is shared with the testnet-only rest of the app | `live.ts:14-21`, `MAINNET-CONFIG.md:121` | Separate mainnet client for `/private` (`reserve.ts` pattern) |
| 3 | Real-USDG admin surface (freeze/blacklist/burn) unknown; plain pool has no haircut | `EsseyShieldedPool.sol:169-177`; UNVERIFIED | Read USDG code; if burnable, use haircut variant or accept risk |
| 4 | Deploy artifacts (zkey/wasm/hasher bytecode) gitignored | `README.md:48-52`, `DeployShieldedPool.s.sol:26` | Rebuild from the ceremony; keep verifier/zkey/wasm same generation |
| 5 | USDG decimals hardcoded 18 in the pool list | `live.ts:277`, `private.tsx:13-14` | Set 6 |

---

## 6. Minimal path to "one live shielded transfer"

Shortest sequence, USDG only, no relayer:

1. Ceremony + config audit + verify USDG admin surface (§5 steps 1–4). *(unavoidable for real funds)*
2. Founder deploys the shielded-USDG pool stack pointed at real USDG (§5 step 5, one command).
3. If `openMode=false`, `setApproved(founder)`.
4. Frontend: separate mainnet client + the four mainnet addresses + USDG `decimals: 6` (§4). Skip
   `api/relay.ts` and `RELAYER_PK`.
5. Founder: unlock → deposit small USDG → withdraw to a fresh address, self-submitted (`live.ts:835-838`).

**Full multi-pool flow** additionally: AAPL + NVDA shielded-stock pools (two more deploys; the adminBurn
haircut is already built, `EsseyShieldedStock.sol`), the shielded-supply pool (needs a mainnet ERC-4626
lending pool deployed first), and the relayer (Vercel `RELAYER_PK` + funded mainnet wallet + `MIN_FEE>0`
+ rate-limit). None of these are on the critical path to the founder's single shielded transfer.
