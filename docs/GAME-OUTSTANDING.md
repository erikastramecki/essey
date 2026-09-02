# Game-layer outstanding

Open items for the **D.O.N. game / market layer** (Bell, Cases, Degen, Quests, the converters that
feed stock payouts), split out of [OUTSTANDING.md](OUTSTANDING.md) so the protocol list stays
protocol-only. **The Dons director owns this file's content going forward** — it was seeded here (by the
protocol engineer) with the game items lifted verbatim from OUTSTANDING.md so there was no file conflict.

Chain today: the game/market layer runs on **Robinhood Chain testnet (chainId 46630)**, fronted by
essey.xyz. See `DEPLOYMENT-testnet.md` for addresses. The founder directive is that every flow activates
on **mainnet (4663)** with live stock/collateral — the per-flow register is in
[MAINNET-ACTIVATION.md](MAINNET-ACTIVATION.md) (game flows are #4–#8, #10, #11, #13).

---

## What is deployed and exercised (testnet 46630)

- **Seats / Bell / Exchange / Cases / Notes** — the market layer, adversarially audited clean in the
  published market-layer rounds (`docs/audits/market-layer-round-{1..6}.md`).
- **Bell pays real stock** — a default AAPL/NVDA bundle via `BundleConverter`, proven on-chain (AAPL+NVDA
  delivered into a Seat's Vault by a Bell claim). Fails open to USDG when the converter cannot price.
- **Fair-value Cases** and the **Degen Case** — the multiplier gacha (0.65x–50x, ~90% RTP), audited
  clean; entropy is `MockEntropy` on testnet, `Dice` on mainnet.
- **Quest / whitelist** referral graph and leaderboard scoring.

---

## Operational — open now on testnet

- **Feed keeper is not running (game payouts).** The testnet mock Chainlink feeds go stale after ~25h
  (`FEED_HEARTBEAT + GRACE`). When stale, `BundleConverter` reverts, the Bell fails open to USDG, and
  Degen `buy` reverts (fails open). A cron must refresh the USDG/USD feed plus the converter's AAPL/NVDA
  feeds and the Cases/Degen feeds — `cast send <feed> "set(int256,uint256)" <answer> <now>`. The USDG
  feed was refreshed at deploy; nothing beats it on a schedule yet. (The **lending** pool's feeds are a
  separate protocol concern — tracked in OUTSTANDING.md.)

---

## Before mainnet (4663) — game flows

- **Real entropy for Degen.** Mainnet must use the `Dice` VRF source, not `MockEntropy`; address +
  interface are TO-RESOLVE (`docs/MAINNET-CONFIG.md`, "TO-RESOLVE before deploy").
- **Real stock inventory + adminBurn exposure** on every flow holding real Stock Tokens (Bell, Cases,
  Degen). A held-stock position can be burned/rescaled/paused by Robinhood's EOA roles at any moment —
  the same hazard the lending `CollateralReconciler` defends against, applied to game inventory.
- **StaleFeedGuard reconciliation** shared across the game converters and lending
  (`MAINNET-ACTIVATION.md`, cross-flow gating).
- **Scrip → real settlement remap** — the biggest cross-flow game-economy rework (economist task);
  no hardcoded currency in any v2 contract.

---

## Open questions (game)

1. Has `adminBurn` ever actually been used on a Stock Token the game holds? Recoverable from
   `Transfer`-to-zero logs; frequency decides theoretical vs operational.
2. Trading-MCP jurisdiction coverage vs Stock Token availability for the quest/onboarding flow.
