# Runbook — testnet to first loan

The local rig needs **no wallet at all**. Only a real mainnet loan does, and it is small: a few
dollars of gas, $50-100 of USDG to fund the pool, and a fraction of one AAPL share bought through
Robinhood.

## 0. Prove it first (no wallet, no gas)

```bash
cd rh-chain
forge test                                                        # 85 unit tests
forge test --match-path test/ForkMvp.t.sol \
  --fork-url https://rpc.mainnet.chain.robinhood.com -vv           # the MVP path on real state
```

The fork test deploys the stack against live mainnet, funds a pool with real USDG, borrows against
a real AAPL Stock Token priced by the real Chainlink feed, and repays. If that passes, the only
things testnet adds are your key and real block times.

## 1. Or run the whole thing locally, free

Robinhood Chain **testnet has none of the tokens** — no USDG, no Stock Tokens, no Chainlink feeds
(checked; all three addresses are undeployed there). Mocking all three would prove less than a fork
of mainnet does, so the zero-cost rig forks mainnet instead:

```bash
cd rh-chain && bash script/local-fork.sh
```

Forks mainnet, deploys the stack, serves out the 2-day timelock, jumps to a session open, and beats
the keeper through the grace period. Prints the MCP command when `canBorrow` is true. Real AAPL,
real USDG, real mainnet price, anvil's prefunded keys — **no wallet, no gas, no money.**

The one synthetic part is the price feed's *timestamp*: forking pins the real feed's `updatedAt` at
fork height and the timelock forces the clock past it, so `AlwaysFreshFeed` reports the real
mainnet price at the current block time. Fork-only, and labelled as such.

## 2. Deploy for real

```bash
export PK=0x…                       # a testnet key
cd rh-chain
FOUNDRY_PROFILE=script forge script script/Deploy.s.sol \
  --rpc-url rh_testnet --broadcast --private-key $PK
```

Set `USDG`, `STOCK`, `FEED` in env if the testnet addresses differ from mainnet's. Every decimal is
read from the chain and asserted, so a wrong address fails loudly rather than deploying a market
that misprices by 1e12.

Record the three printed addresses.

## 3. Start the clock and the keeper

The market is **proposed, not live** — there is a 2-day timelock. Start it now; it runs while you
do everything else.

```bash
cd rh-chain/keeper && npm install
LIVENESS_ORACLE=<liveness> ESSEY_MARKETS=<markets> KEEPER_PRIVKEY=$PK \
  RH_RPC=https://rpc.testnet.chain.robinhood.com/rpc node liveness-keeper.mjs
```

`ESSEY_MARKETS` is not optional. This command used to omit it, which meant following this runbook
literally left every market unobserved — G-LEND R4 HIGH-2. The keeper reads the market list from the
registry itself, so nothing has to be re-typed when a market is listed.

Liquidations stay disabled until the keeper has been beating for the grace period, AND until the
observation delay line has filled (`PRICE_CONFIRM_DELAY`, 6 hours). Both are deliberate: a fresh
deployment has not proven liveness, and it has no price it has watched stand.

Check it is working — per market, on chain, not by looking at the process:

```bash
LIVENESS_ORACLE=<liveness> ESSEY_MARKETS=<markets> MARKET_TOKENS=<stock>[,<stock>...] \
  RH_RPC=https://rpc.testnet.chain.robinhood.com/rpc node check-liveness-keeper.mjs
```

`MARKET_TOKENS` is REQUIRED for the check (it stays optional for the keeper) and must list every
committed market. It is this check's INDEPENDENT source of truth: G-LEND R5 MED-2 found the check
deriving its list from the same `getLogs` the keeper does, so an RPC replica answering short —
successfully, which is what neither the 10,000-log cap nor a 429 produces — covered 1 of 2 markets
and exited 0. Every address named here is now read on chain whether or not the scan returned it, and
any disagreement between the two lists exits non-zero. **Add a market to this variable in the same
change that commits it.**

**What a healthy weekend prints, so nobody wires this to a pager and then turns it off.** The 24/5
feeds are unreadable for roughly 40h of every 168h — from Friday's close plus `maxStaleness` (25h)
until Monday's open — and the check reports that as `FEED DARK` and still exits **0**. It is not an
alarm: the keeper is demonstrably calling (`confirmedObservedAt` stays inside `MAX_CONFIRM_AGE`,
because the delay line is warmed through the outage), and every gate behind an unreadable price is
already closed — no borrow, no seizure, no write-off. G-LEND R6 LOW-1: this used to be a fatal
`BREAKER BLIND` for the whole dark window, which is red a quarter of the time, and an alarm that is
red a quarter of the time gets muted. **`BREAKER BLIND` is now raised only when the registry's own
`priceOf` ANSWERS and the baseline is still stale** — the keeper not reading a feed that is
answering. `UNOBSERVED` is unchanged and stays fatal whether or not the feed is dark: that is the
line that says the keeper has stopped.

**And `FEED DARK` is bounded on both axes, because a downgrade granted on the word "unreadable"
covers a broken oracle too (G-LEND R7 LOW-1).** Two further fatal lines:

- **`FEED BROKEN`** — `priceOf` refuses with anything other than `PriceStale`. It reverts four
  reachable ways on 4663, and only `PriceStale` is the exchange calendar; `PriceNotPositive`,
  `RoundIncomplete` and `FeedNotConfigured` are a silent or misconfigured aggregator. So is a revert
  the ABI cannot decode — including the asymmetric case where the heavy `priceOf` fails on transport
  while the one-`SLOAD` probe succeeds. **The error definitions in `marketsAbi` are load-bearing:**
  viem decodes `errorName` only for errors the ABI declares.
- **`FEED DARK TOO LONG`** — unreadable for more than `MAX_DARK_AGE` (4 days, override with
  `FEED_DARK_CEILING`). The worst gap either listed feed has produced is 79.74h AAPL / 76.09h NVDA,
  both of them the 2026-07-02 → 2026-07-06 window — Thursday to Monday, because 4 July 2026 fell on a
  Saturday and was observed the Friday. That three-day shape is the longest closure the US equity
  calendar makes; ordinary weekends in the same sample measure 52-58h. Reproduce with
  `node keeper/measure-feed-volatility.mjs`, which now prints the five worst gaps with their dates.

Both matter more than the noise they replace because **the feed is append-only per market** —
`commitMarket` reverts `FeedIsImmutable` — so the remedy for a broken aggregator is onboarding a new
listing behind `PARAM_TIMELOCK`, and the alarm is the whole of the operator's warning.

After 2 days:

```bash
cast send <markets> "commitMarket(address)" <stock> --rpc-url rh_testnet --private-key $PK
```

## 4. Borrow, from an agent

```bash
cd mcp && npm install
ESSEY_CHAIN=rh-testnet ESSEY_POOL=<pool> ESSEY_MARKETS=<markets> node essey-mcp.mjs
```

Register it with your MCP client alongside Robinhood's Trading MCP. Then, in one conversation:

1. *"Buy 10 shares of AAPL"* → Robinhood Trading MCP, under your own credentials
2. wait for settlement → the Stock Token lands in your self-custody wallet
3. *"What can I borrow against my AAPL?"* → `essey_quote`
4. *"Borrow $500"* → `essey_borrow` returns unsigned calldata; your wallet signs
5. *"How's my loan?"* → `essey_health`
6. *"Repay it"* → `essey_repay`

Step 4 is the moment the MVP exists.

## Known limits at this stage

Testnet, one lender, one borrower. `docs/OUTSTANDING.md` lists every open finding — none blocks a
single-user demo, and all of them start mattering the moment real users arrive.
