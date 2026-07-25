# Essey MCP server

The half of the product that makes the pitch work. A user connects Robinhood's Trading MCP to buy
a stock and this one to borrow against it — in a single conversation.

```
Robinhood Trading MCP  ->  agent buys AAPL under the user's own credentials
Robinhood settlement   ->  Stock Token lands in the user's self-custody wallet
Essey MCP (this)       ->  agent quotes and opens a loan against it
```

Essey never holds the brokerage account and never custodies collateral before the loan. Tools that
move funds return **unsigned calldata** for the user's wallet to sign; this server never takes a
private key.

```bash
npm install
ESSEY_CHAIN=rh-testnet ESSEY_POOL=0x… ESSEY_MARKETS=0x… node essey-mcp.mjs
```

| Tool | Does |
|---|---|
| `essey_quote` | Collateral value, max borrow, whether borrowing is possible now, and the risks |
| `essey_borrow` | Unsigned approve + borrow calldata |
| `essey_health` | Debt, collateral value, health factor, liquidation status |
| `essey_repay` | Unsigned approve + repay calldata |

**`essey_quote` always returns the risks** — Jersey debt token, `adminBurn`, the 24/5 price feed,
and why to borrow well under the limit. A borrower who is not told cannot price them.

**Multi-chain by design.** `chain` is a parameter, not a constant: Robinhood Chain is implemented,
and the Sui deployment plugs in as another adapter. Adding a chain means adding an adapter, not
forking the server.
