# Outstanding

Everything known-open, as of 2026-08-04. Written down so none of it lives only in someone's head.
This doc's whole point is the list of what is not finished; a "clean" line here means "not yet
disproven," not "done."

## Where the stack actually is

The full market layer is **deployed and live on Robinhood Chain testnet** (chainId 46630), fronted
by essey.xyz. See `DEPLOYMENT-testnet.md` for addresses. Deployed and exercised on-chain:

- **Seats / Bell / Exchange / Cases / Notes** — the market layer, adversarially audited clean in the
  published market-layer rounds.
- **Bell pays real stock** — a default AAPL/NVDA bundle via `BundleConverter`, proven on-chain
  (AAPL+NVDA delivered into a Seat's Vault by a Bell claim). Fails open to USDG when the converter
  cannot price.
- **Fair-value Cases** and the **Degen Case** — the multiplier gacha (0.65x-50x, ~90% RTP), audited
  clean; entropy is `MockEntropy` on testnet, `Dice` on mainnet.
- **Quest / whitelist** referral graph and leaderboard scoring.
- **Lending pool (EsseyPool)** — supply/withdraw live; borrowing is timelock-gated open (see below).

What is **not** done: none of this is on **mainnet**, and the deployed lending path enforces LTV
**on-chain in Solidity**, not with a ZK circuit. The dregg/ZK design is a retired pivot (Archived
section at the bottom); it does not gate the shipped product.

---

## Blockers before any mainnet deployment

**1. Testnet only; mainnet is unproven.** The market layer and Degen Case are audited clean in the
published market-layer rounds and running on testnet, but the gate for mainnet is three auditors
clean in the same round on the **mainnet-bound** configuration, and mainnet uses real USDG
(6-decimal), the `Dice` entropy source, and the operator multisig instead of the throwaway deployer.
None of that has had a clean round yet.

**2. Open borrowing is not switched on.** The AAPL/NVDA collateral markets are PROPOSED behind the
2-day parameter timelock; borrowing opens **2026-08-05 ~18:55 UTC**, at which point someone must call
`markets.commitMarket(aapl)` / `commitMarket(nvda)`. Supply/withdraw work now; borrow/liquidate do
not until commit. The Solidity findings below are against the code on the borrowing path, so they
are reconciled below rather than closed.

**3. Republish caveats.** Any layout change to `EsseyPool` / positions still forces a fresh package
and a new `VITE_POOL`; treat redeploys as new addresses, not in-place upgrades.

**4. ~~`README.md` claims "provably safe."~~ FIXED.** The README leads with a "What is actually
proven today" table separating the design's goal from what the deployment enforces. With the ZK path
retired, "proven" today means the on-chain Solidity LTV enforcement and the published audits — not a
batch proof. Keep the table honest as scope changes.

---

## Open findings

### Solidity (`rh-chain/`) — the deployed path

| Severity | Item |
|---|---|
| critical | A watched token returning a non-boolean `paused()` word makes `abi.decode` panic inside `accrue()`, freezing **every** entry point — including liquidation — until a single admin EOA resets the array. |
| high | Pro-rata collateral is correct on CLOSE but wrong on OPEN: the denominator is live, so anyone who borrows **after** a burn is charged for it. |
| high | The decimals fix moved the trust into two operator-typed fields that nothing cross-checks against the token's real `decimals()`. A one-character typo reproduces the original 1e12 drain. |
| high | `accrue()` runs **after** OZ computes the share price in all four ERC4626 paths, so pending interest is extractable — and flash-loanable. |
| medium | Pause suspends interest **pool-wide** and forgives it permanently, so an unrelated token's pause hands every borrower a free loan. |
| medium | DST intersection does not handle the ~3 half-day early closes per year. |
| medium | The holiday guard false-rejects on EDT days whose only print lands in the 13:30–14:30 opening hour — and because `canLiquidate` shares the flag, that is a liquidation outage. |
| medium | `resumeGrace` at 6× `gapThreshold` turns routine keeper jitter into a permanent liquidation DoS. |
| medium | ~50 mutations survive a green suite, including `MIN_RISK_GAP_BPS` and `PARAM_TIMELOCK`. |

**Status.** The market layer around this code (Seats/Bell/Exchange/Cases/Notes and the Degen Case)
is deployed on testnet and audited clean in the published market-layer rounds. The findings above are
against the **borrowing path**, which is deployed but not yet switched on (open borrowing is
timelock-gated to ~2026-08-05, Blocker 2). They must be closed with a clean round before that path is
trusted on mainnet. The track record still says caution: multiple prior rounds saw a shipped fix
either not work or introduce a new defect, or a commit-message claim disproven by the next round.

---

## Operational

**Open now, on testnet:**

- **Feed keeper is not running.** The testnet mock Chainlink feeds go stale after ~25h
  (`FEED_HEARTBEAT + GRACE`). When stale, `BundleConverter` reverts, the Bell fails open to USDG, and
  Degen `buy` reverts (fails open). A cron must refresh the USDG/USD feed plus the converter's
  AAPL/NVDA feeds (and the Cases/degen feeds) — `cast send <feed> "set(int256,uint256)" <answer>
  <now>`. The USDG feed was refreshed at deploy; nothing beats it on a schedule yet. **The borrowing
  pool's feeds are not in this keeper** and must be added before open borrowing (Blocker 2) is
  trusted.

**Before mainnet:**

- **Deploy the `LivenessOracle` keeper** under a supervisor with alerting. It exists, is tested, and
  is deployed on testnet, but no supervised keeper is beating it. A silently dead keeper degrades to
  "liquidations off" — safe, but an outage.
- **Split the keys.** On testnet, admin/treasury/seeder/bankroll are all the one throwaway deployer,
  and the keeper's hot key must not be the cold guardian key. Mainnet moves control to the operator
  multisig; that separation is unbuilt.
- **Sequencer uptime feed.** Robinhood's docs say Chainlink provides one for Robinhood Chain; it is
  not on Chainlink's canonical list, not in the feed directory, and every contract from Chainlink's
  deployer on that chain resolves to a price feed. Either locate it (ask
  `chain-developers-group@robinhood.com`) or keep running on the keeper.
- **Verify who holds `ADMIN_BURNER_ROLE`.** On-chain it is a plain EOA with no multisig and no
  timelock — one key can destroy collateral inside a live pool. That is unmitigated on-chain and
  should be priced into LTV and disclosed to borrowers.

---

## Open questions

1. Can Robinhood's Trading MCP place the equity orders that become Stock Tokens, in the
   jurisdictions we care about? The agent half of the MVP is untested end-to-end.
2. Chainlink feed heartbeats are 86400s / 0.5% today. `rh-chain/script/fetch-feeds.mjs` fails loudly
   if that changes — but nothing runs it on a schedule yet.
3. Has `adminBurn` ever actually been used? Recoverable from `Transfer`-to-zero logs; frequency
   decides whether it is theoretical or operational.

---

## Archived (retired Sui/ZK pivot)

These were live blockers under the earlier Sui + ZK design. **v1 lending ships without the dregg
circuit** — LTV is enforced on-chain in Solidity — so none of the below gates the deployed product.
Kept for the audit trail, not as current work.

- **No round ever came back clean on the Move/ZK code.** Six Move rounds and one Solidity round
  against that design; none met the three-clean gate.
- **The ZK layer was never audited, and could not be.** `circuit/` held a Poseidon gadget and no
  constraint system — no `.zkey`, `.r1cs`, `.ptau` or `.wasm` anywhere. The most load-bearing part of
  the old "provably safe" claim was the one nobody could check. Retired with the pivot to on-chain
  Solidity LTV.
- **Both circuits needed re-proving upstream.** `dregg_lending` could not originate and `settle_batch`
  could not succeed until then; `perloan-prep/RUNBOOK-terms-binding.md` still specified the pre-fix
  8-term preimage. Moot without the circuit in the deployed path.
- **Move findings (`move/`):** `disburse_entry` handing a cap holder the whole `pool.cap` against zero
  collateral (a trust-model question); `repay` demanding exact equality against a growing debt with no
  on-chain debt view (fixed by construction in the Solidity port); faucet rate limit bypassable by
  address casing/padding (devnet only). None apply to the Solidity deployment.
- **Sui republish / key co-location:** the Sui `Pool`/`Position`/`OperatorCap` layout churn and the
  Sui keeper co-locating `OperatorCap` with the signing key were Sui-specific and no longer relevant.
