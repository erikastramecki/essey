# Outstanding — protocol

Everything known-open on the **protocol** side (base layer, lending, shielded), as of 2026-09-01.
Written down so none of it lives only in someone's head. A "clean" line here means "not yet disproven,"
not "done." Game/market-layer open items live in [GAME-OUTSTANDING.md](GAME-OUTSTANDING.md).

## Where the stack actually is

- **Base layer — LIVE on mainnet (chainId 4663).** $ESSEY (`0x3157…1610`) and EsseyReserve
  (`0xd970…05A7b`) are deployed and adminless. Fixed supply 8,888,888,888e18, a 12-token equity basket
  plus the FLR bootstrap position, redemption in units (not dollars) with a 5% exit fee, floor ratchets
  up only. Full description: [BASE-LAYER.md](BASE-LAYER.md). Register flow #1
  ([MAINNET-ACTIVATION.md](MAINNET-ACTIVATION.md)).
- **Fee hook — code gate MET, not yet deployed.** `EsseyReserveHook` (default split **45 floor / 40 holders
  / 15 dons** — `script/DeployEsseyV4Pool.s.sol:47-49`; corrected 2026-09-02 from an inherited "50/40/10",
  which was the RAILS mistaken for the SPLIT; NO burn; rails `MIN_RESERVE_BPS=4000` /
  `MAX_HOLDERS_BPS=5000` / `MAX_DONS_BPS=2000`) passed three
  consecutive clean 3-agent rounds on byte-identical code
  (`docs/audits/esseyreservehook-gate-2026-08-31.md`). Ships with the mainnet launch.
- **Lending — ported to `rh-chain`, built-not-audited (gate 0 of 3), NOT deployed on any chain.** The `RobinhoodMainnet` (4663) path is
  ported and reconciled from the essey-markets reference; StaleFeedGuard reconciled behavior-preserving;
  three consecutive clean 3-agent rounds; pushed public (`MAINNET-ACTIVATION.md`, Update 4). No borrow is
  live on mainnet.
- **Shielded / private — testnet (46630), mainnet-blocked.** Real blockers stand before real value; see
  the shielded section below and [ESSEY-PRIVATE.md](ESSEY-PRIVATE.md).

The deployed lending path enforces LTV **on-chain in Solidity** against a Chainlink feed, not with a ZK
circuit. The dregg/ZK design is a retired pivot (Archived section at the bottom); it does not gate any
shipped product.

---

## Blockers before lending goes live on mainnet

**1. Vault mainnet-fork test pending.** The lending yield vault (10% performance fee, 20% cap, 50/50
split) is code-sound but has not yet passed a mainnet-fork test against real Stock Tokens and real feeds.
That fork run is the standing gate before the founder-gated deploy.

**2. Founder-gated mainnet deploy.** The lending contracts are public and undeployed; the audit gate stands at 0 of 3. Deploy
needs a funded deployer, the admin/guardian roles assigned to the operator multisig (not a throwaway
deployer), and the founder's per-instance authorization. Never self-deploy.

**3. Multiply deferred.** Leveraged borrow (`EsseyMultiply`) needs a mainnet DEX router + a production
`ISwapAdapter`. Uniswap V3 SwapRouter02 is live on 4663 (`0xcaf681…5cb2`) and USDG↔NVDA is deep, but the
swap adapter + a one-line `deadline`-drop ABI fix are unbuilt (`MAINNET-ACTIVATION.md`, Update 4). Base
borrow/repay/liquidate needs no DEX and ships without it.

**4. Republish caveats.** Any layout change to `EsseyPool` / positions forces a fresh package and a new
`VITE_POOL`; treat redeploys as new addresses, not in-place upgrades. A redeploy silently orphans every
consumer — see `DEPLOY-CHECKLIST.md`.

---

## Shielded — mainnet blockers (do NOT deploy real funds until these clear)

Per [MAINNET-ACTIVATION.md](MAINNET-ACTIVATION.md) (Update 2, lines ~90–104) and
[ESSEY-PRIVATE.md](ESSEY-PRIVATE.md):

1. **HARD BLOCKER — trusted setup.** The deployed zkey is single-contributor
   (`DeployShieldedPool.s.sol:20-21`) → **proofs are forgeable, the pool is drainable with real money**.
   Requires a multi-party ceremony + regenerated verifier/zkey/wasm before ANY mainnet value.
2. **Config — `openMode=true` baked into the deploy script** (`DeployShieldedPool.s.sol:41`) while the
   gate says it MUST be false in production (`EsseyPoolGate.sol:17`). Fix before deploy.
3. **USDG admin surface.** The plain-USDG pool has NO haircut (`EsseyShieldedPool.sol:169-177`). USDG is
   pausable, per-address freezable, and an upgradeable EIP-1967 proxy (verified on-chain,
   `MAINNET-ACTIVATION.md` Update 3), so a pause/freeze/upgrade against the pool could brick or seize
   funds with no pro-rata defense. Shielded STOCK already handles issuer adminBurn via a pro-rata haircut
   (`EsseyShieldedStock.sol:162-166`); shielded USDG does not.
4. **Frontend decimals + client.** USDG is 6-dec but hardcoded 18 (`private.tsx:13-14`, `live.ts:277`);
   `/private` needs its own mainnet client (the `reserve.ts:21-23` pattern).

---

## Lending open findings — audit trail (borrow path, `rh-chain/`)

The findings below were raised on the borrow path during the port and are **8 of 9 FIXED (2026-08-09)**,
each with a regression test; the batch passed a borrow-path clean round and the collateral-index rewrite
additionally passed a dedicated 3-agent audit + a 20k-run solvency fuzz. Kept as the audit trail behind
the ported lending code.

| Finding | Resolution |
|---|---|
| critical — `paused()` panic freeze | ✅ `6b11a73` decode a raw word (not `bool`) + gas-cap |
| high — pro-rata wrong on OPEN | ✅ `3f01603`+`6cae026` per-token collateral **index**; positions snapshot it, so post-burn depositors are insulated; payout clamped to live balance |
| high — decimals trust fields | ✅ `6b11a73` cross-check vs real `token.decimals()`/`feed.decimals()` at propose+commit |
| high — interest extractable pre-share-price | ✅ `38f6075` accrue() before the ERC4626 preview |
| medium — pause forgives interest pool-wide | ✅ `656dc1c` narrowed to a **borrow-asset** pause only |
| medium — half-day early close | ⚠️ **ACCEPTED for MVP** — GAP-absorbed (`MIN_RISK_GAP_BPS`); if ever fixed, use a fail-CLOSED keeper session flag, not an on-chain early-close table |
| medium — EDT holiday liquidation outage | ✅ `7af8cce` holiday threshold = earliest open (13:30 UTC) |
| medium — `resumeGrace` jitter DoS | ✅ `fb6cd37`, then SUPERSEDED — the ratio guard was replaced by absolute ceilings (`MAX_GAP_THRESHOLD` 1h / `MAX_RESUME_GRACE` 6h, `LivenessOracle.sol`). No `4×` guard exists; R4 LOW-4 found this line still claiming one |
| medium — mutation survivors | ✅ `cef0046` pinned the timelock/gap boundaries + constant values |

---

## Operational — before mainnet

- **Deploy the `LivenessOracle` keeper** under `keeper/xyz.essey.liveness-keeper.plist` with alerting. It
  exists, is tested, and is deployed on testnet, but no supervised keeper is beating it on a mainnet
  target. It now carries a SECOND duty: it is the only standalone caller of `syncMultiplier`, so a market
  it does not observe has no corroborated price and cannot be liquidated (R4 HIGH-2). Both halves fail
  closed — a stale heartbeat closes the liveness gate within `gapThreshold`, an un-refreshed observation
  ages past `MAX_CONFIRM_AGE` — so a dead keeper is an outage on both, never a fail-open. Verify with
  `keeper/check-liveness-keeper.mjs`, which asks the chain per market rather than asking `ps`.
- **Split the keys.** On testnet, admin/treasury/seeder/bankroll are all one throwaway deployer, and the
  keeper's hot key must not be the cold guardian key. Mainnet moves control to the operator multisig;
  that separation is unbuilt.
- **Sequencer uptime feed.** Robinhood's docs claim Chainlink provides one for Robinhood Chain; it is not
  on Chainlink's canonical list and could not be located. `StaleFeedGuard` ships the sequencer check
  DISABLED and relies on the keeper heartbeat. Either locate the feed (ask
  `chain-developers-group@robinhood.com`) or ship on the keeper and disclose (accepted).
- **`ADMIN_BURNER_ROLE` is a plain EOA** on the Stock Tokens — no multisig, no timelock. One key can
  destroy collateral inside a live pool. This is unmitigated on-chain (it is Robinhood's, not ours),
  must be priced into LTV, and disclosed to borrowers. Full hazard analysis:
  [SCOPE-robinhood-chain.md §2.1](SCOPE-robinhood-chain.md).

---

## Open questions

1. Can Robinhood's Trading MCP place the equity orders that become Stock Tokens, in the jurisdictions we
   care about? The agent half of the lending MVP is untested end-to-end.
2. Chainlink feed heartbeats are 86400s / 0.5% today. `rh-chain/script/fetch-feeds.mjs` fails loudly if
   that changes — but nothing runs it on a schedule yet.
3. Has `adminBurn` ever actually been used? Recoverable from `Transfer`-to-zero logs; frequency decides
   whether it is theoretical or operational.

---

## Archived (retired Sui/ZK pivot)

These were live blockers under the earlier Sui + ZK design. **v1 lending ships without the dregg
circuit** — LTV is enforced on-chain in Solidity — so none of the below gates the deployed product. Kept
for the audit trail, not as current work.

- **No round ever came back clean on the Move/ZK code.** Six Move rounds and one Solidity round against
  that design; none met the three-clean gate (`docs/audits/sui-rounds-1-6.md`).
- **The ZK layer was never audited, and could not be.** `circuit/` held a Poseidon gadget and no
  constraint system — no `.zkey`, `.r1cs`, `.ptau` or `.wasm`. Retired with the pivot to on-chain
  Solidity LTV.
- **Move findings (`move/`)** and the **Sui republish / key co-location** items were Sui-specific and no
  longer relevant to the Solidity deployment.
