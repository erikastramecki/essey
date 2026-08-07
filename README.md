# Essey — a stock-market club where the odds and the books are both *provable*

Essey is an on-chain stock-market club on **Robinhood Chain** (an Arbitrum Orbit L2). Buy a Seat, earn
Payouts in **real tokenized stock**, open **Cases** for a provably-fair stock draw, borrow against what you
hold, and move any of it **privately**. Every ring of the Bell, every draw, and every loan is a verifiable
on-chain transaction.

**Live demo:** https://essey.xyz

> **Testnet, play money.** Everything here is live on Robinhood Chain **testnet** with play-money assets that
> have **no real value**. Essey is **experimental**. Payouts are protocol fees distributed to Seat holders as
> stock — a mechanical, LP-style fee-share, **not a dividend, not a yield promise**. Nothing here is an offer of
> securities or financial advice.

## What's live

| Surface | What it is |
|---|---|
| **Seats + the Exchange** | 2,222 membership NFTs. Each carries its own on-chain wallet — the **Vault** (ERC-6551). Trade Seats on the Exchange. |
| **The Bell** | The pot (trade fees, royalties, loan interest) rings out to every active Seat's Vault, by Tier — **paid in real tokenized stock**, converted at the claim edge. |
| **Cases** | Open a Case for a **provably-fair** real-stock draw (AAPL / NVDA). The draw only ever decides *which* name, never how much. Keep it, borrow against it, or sell it back. Plus a **Degen** multiplier variant. |
| **Lend** | Supply USDG to earn, or borrow a stablecoin against the stock you win/hold. On-chain LTV enforced against a Chainlink feed. |
| **Essey Private** | A privacy layer: stealth-address payments, shielded pools that hide amounts (USDG, AAPL/NVDA stock, and yield-bearing supply), private transfers with cross-device recovery, and a trustless relayer. Proving runs in your browser; keys never leave your device. |

## What is actually proven today (stated plainly)

"Provable" is the design's north star, not a blanket claim about the live deployment:

| | Status |
|---|---|
| **Provably-fair draws** | Real and live. Cases/Degen settle against on-chain entropy (a mock keeper on testnet; a real entropy oracle on mainnet), so the odds are verifiable, not trusted. |
| **The market-layer contracts** | Audited across multiple adversarial rounds, published fix-first — see [`docs/audits/`](docs/audits/). |
| **Essey Private** | Audited (≥3 independent adversarial agents per change) and the full private-money cycle is proven on-chain on testnet. |
| **Solvency of lending** | On-chain LTV against a Chainlink feed — the same guarantee Aave gives, **not** a proof yet. A formally-verified solvency kernel is the roadmap, not the live enforcement. |
| **Tokenized-stock risk** | The stock-token issuer can pause, rescale (scaled-UI), or burn tokens. The contracts defend against these hazards explicitly (e.g. the shielded-stock pro-rata haircut); it is an inherent risk of a real RWA, stated openly. |

Everything known-open, including what blocks mainnet, is listed in **[`docs/OUTSTANDING.md`](docs/OUTSTANDING.md)**.

## Repo layout

```
rh-chain/        the live product — Solidity contracts on Robinhood Chain (Seats, the Bell, Cases,
                 the converter, lending, and Essey Private: shielded pools + stealth payments)
app/web/         the site (Vite + React) at essey.xyz — every mechanic, live on testnet
circuit/         zk work (Poseidon / IVC R&D toward provable solvency)
mcp/             MCP tooling
docs/            design, LTV & risk framework, interest-rate model, the privacy layer, audits, OUTSTANDING
brand/           brand assets
```

**Legacy (prior iteration, retained for history):** `move/`, `operator/`, `app/sui-sdk/`,
`app/operator-api/`, `app/sui-harness/` are from Essey's earlier Sui RWA-lending design. They are **not** the
current product and are kept for the audit trail only — the live system is `rh-chain/` + `app/web/`.

## Security & audits

Every money-touching change is attacked by multiple independent adversarial agents before it ships; findings
are published **fix-first**, clean or not, in [`docs/audits/`](docs/audits/). [`docs/OUTSTANDING.md`](docs/OUTSTANDING.md)
lists everything we know is unfinished. Secrets (`.env*`, keys) are git-ignored — never committed.
