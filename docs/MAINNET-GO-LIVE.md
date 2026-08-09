# Mainnet go-live plan

The sequenced path from where the stack is today (audited-clean market layer on Robinhood Chain
**testnet**, fronted by essey.xyz) to a **curated live beta on mainnet with real money**. Every phase
lists its exit **gate** — the thing that must be true before the next phase starts. Gates are hard: a
phase is not "done" because the code merged, it's done when the gate is met.

This plan supersedes nothing in `OUTSTANDING.md`; it *sequences* it. When an item here closes, mark it
in `OUTSTANDING.md` too, so the two never drift.

**Non-negotiables that hold across every phase**
- Money code moves only after **3 independent adversarial audits return clean in the same round** (the
  standing gate). A fix re-opens the round.
- Messaging stays honest: real money, beta, at-risk, not financial advice, not an offer of securities.
- **Securities counsel signs off before "earn revenue from your Seat" becomes a headline** marketing
  claim (the revenue-share is the security-sensitive surface — decided 2026-08-08).
- Contracts stay **adminless** where they already are. Nothing in this plan adds an owner/pause to a
  contract that doesn't have one — including the beta gate (see Phase 5).

---

## Phase 0 — Finish the fee model *(in flight)*

The Mancer-style revenue-share flywheel. Contract written + tested; not yet audited or deployed.

- **#50** per-Seat payout-asset toggle (stock vs USDG) — UI only, feature already on-chain.
- **#51** `FeeRouter.sol` (60% Bell / 20% bankroll / 20% ops) — ✅ built, 9/9 tests, 100% coverage.
- **#52** 3-agent audit of the FeeRouter + the redeploy set.
- **#53** redeploy Exchange/Cases/Degen → router + migrate reserves/inventory *(high blast radius)*.
- **#54** revenue-share headline UI + `TOKENOMICS.md` v2 + docs consolidation.

**Gate:** router + redeploy set audited clean (same round); split verified on-chain (a real fee lands
60/20/20); docs describe the deployed reality, not the old "100% to Bell."

## Phase 1 — Close the borrowing-path findings

The 9 open Solidity findings in `OUTSTANDING.md` are all on the **borrow/liquidate** path (supply/
withdraw are clean and live). They gate open borrowing, on any network.

- **critical** — non-boolean `paused()` word panics `abi.decode` inside `accrue()`, freezing every
  entry point incl. liquidation until an admin EOA resets the array.
- **high** — pro-rata collateral wrong on OPEN (post-burn borrowers overcharged); decimals trust-fields
  uncrosschecked (a typo reproduces the 1e12 drain); `accrue()` runs after ERC4626 share-price →
  interest extractable/flash-loanable.
- **medium** — pool-wide pause forgives interest; DST/half-day-close gaps; `resumeGrace` DoS; ~50
  surviving mutations.
- Also: **`canBorrow` UI gap** — testnet AAPL/NVDA mocks lack `uiMultiplier()`, so borrow is closed in
  the app. Real mainnet stock tokens must expose it (or the read must be made resilient).

**Gate:** all findings fixed; **3 auditors clean in the same round on the borrowing path**; mutation
survivors driven down; `commitMarket(aapl/nvda)` rehearsed on testnet with borrow+liquidate exercised.

## Phase 2 — Mainnet-config audit round

The audited config is the *testnet* one. Mainnet differs in ways that have historically broken things.

- Real **6-decimal USDG** (not the 18-dec mock), the **`Dice`** entropy source (not `MockEntropy`), the
  **operator multisig** (not the throwaway deployer), real Chainlink feeds + heartbeats.
- Re-run the full suite against that config; re-audit the deltas.

**Gate:** 3 auditors clean in the same round on the **mainnet-bound** configuration. No prior round has
met this yet — it is the true mainnet gate.

## Phase 3 — Keepers running as supervised crons

Today nothing beats these on a schedule; on mainnet a dead keeper is an outage.

- **Feed keeper** — refresh USDG + converter AAPL/NVDA feeds (+ Cases/Degen) before the ~25h staleness
  window; **add the borrow-pool feeds** (not currently covered).
- **DCA keeper** — `dca-keeper.sh` exists but is unscheduled; run it, simulate-before-send.
- **`LivenessOracle` keeper** — supervised, with alerting; a silent death = liquidations off.
- **Sequencer-uptime feed** — locate Robinhood Chain's (ask `chain-developers-group@robinhood.com`) or
  keep running on the keeper and disclose.

**Gate:** every keeper runs under a supervisor with alerting; a killed keeper pages someone; feeds
demonstrably never go stale across a 48h soak.

## Phase 4 — Key management

Testnet runs everything from one throwaway deployer. Mainnet cannot.

- **Split keys** — admin / treasury / seeder / bankroll move to the **operator multisig**; the keeper's
  hot key is never the cold guardian key.
- **`ADMIN_BURNER_ROLE`** — today a plain EOA can destroy collateral in a live pool. Put it behind the
  multisig + a timelock, **or** disclose it as an unmitigated trust assumption priced into LTV.

**Gate:** no single EOA can move funds or burn collateral; role holders documented on-chain and in
`DEPLOYMENT`.

## Phase 5 — Beta-access system *(new build — decided 2026-08-09)*

Access = **curation of the existing whitelist Merkle root**. No new gate, no new admin on the contracts:
Seat minting is already root-gated, so an approved wallet minting a Seat *is* the beta entry.

- **On-site request form** — connect wallet + one contact handle (email or @). Minimal data; the wallet
  is public, the contact is stored off-chain, privately (not on-chain, not in a URL).
- **Approval queue** — founder reviews requests, approves/declines. Simple admin view; no secrets in the
  client.
- **Root pipeline** — approved wallets batch into the next Merkle root, committed on-chain behind the
  existing parameter **timelock** (so the allowlist change is itself auditable/recomputable). Reuse the
  quest whitelist tooling; do not fork it.
- **Copy** — the beta is explicitly gated, real-money, at-risk; approval ≠ endorsement or advice.

**Gate:** a stranger can request from essey.xyz; an approval lands their wallet in a committed root; that
wallet (and only approved ones) can mint a Seat on mainnet; declined/pending cannot. Contracts unchanged.

## Phase 6 — Mainnet deploy + seed

- Deploy the full stack with the multisig config; verify addresses; update `DEPLOYMENT` + `live.ts`.
- Seed: Seat inventory + $ESSEY reserve, converter stock reserves, bankroll, FeeRouter wiring.
- Commit the **initial approved beta cohort** as the first mainnet root.
- **Smoke-test every path with tiny real amounts** before opening: buy/sell a Seat, ring the Bell (both
  payout assets), open a Case (Safe + Degen), supply/withdraw, one DCA fill, one shielded deposit/
  withdraw, one fee flushed 60/20/20, and — once Phase 1 closes — one borrow + one liquidation.

**Gate:** every path exercised on mainnet with real funds and the expected on-chain result; solvency
invariants hold; the fee actually split 60/20/20 on-chain.

## Phase 7 — Live beta + testing loop

- Open to the approved cohort in **waves** (start ~10–25 wallets), small position caps.
- Monitor continuously: solvency invariants, keeper liveness, feed freshness, converter fail-open rate,
  Bell ring health, FeeRouter flushes.
- Tight feedback loop: triage → fix → (audit if money code) → redeploy. Grow the cohort only when a wave
  is quiet.

**Gate to "general beta":** N waves with zero solvency/keeper incidents; the pre-mainnet checklist fully
green; counsel sign-off on public revenue-share messaging.

---

## Owner / status snapshot

| Phase | Blocks mainnet? | State |
|---|---|---|
| 0 fee model | no (product) | in flight — router built |
| 1 borrow findings | **yes** | open — 9 findings |
| 2 mainnet-config audit | **yes** | not started (the true gate) |
| 3 keepers | **yes** | scripts exist, unscheduled |
| 4 key management | **yes** | single deployer today |
| 5 beta-access | no (gating UX) | new build, decided |
| 6 deploy + seed | — | after 1–4 |
| 7 live beta | — | the goal |

**Critical path to mainnet:** Phase 1 → Phase 2 → Phase 4 (+ Phase 3) → Phase 6. Phases 0 and 5 run in
parallel and don't block the deploy, but Phase 5 must land before real users arrive in Phase 7.
