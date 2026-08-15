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
node essey-mcp.mjs
```

Testnet addresses are committed as defaults, so that is the whole setup. `ESSEY_CHAIN`,
`ESSEY_POOL`, `ESSEY_MARKETS` and `ESSEY_SITE` override them; none is required.

## Playing D.O.N. with an agent

The other half of this server is the game. Point Claude at it and it can read your Don, price a
job, and tell you what your build is actually for.

| Tool | Does |
|---|---|
| `don_state` | One Don's live position: banked / deployed / hopper Scrip, away or home, House tier, garrison slots — and its stat sheet |
| `don_sheet` | The stat sheet on its own: archetype, every stat the traits grant, and what each one does. Works for any Don, including one you are thinking of buying |
| `don_board` | The live job board with contract odds, payouts, and expected value at each provision level |
| `don_playbook` | How the game works, the decisions you actually face, and an explicit list of what nobody can know |

### Connect it to Claude

Add this to your MCP config — in Claude Desktop that is `claude_desktop_config.json`, in Claude Code
`.mcp.json` — with the path changed to wherever you cloned this repo:

```json
{
  "mcpServers": {
    "essey": {
      "command": "node",
      "args": ["/absolute/path/to/assay/mcp/essey-mcp.mjs"]
    }
  }
}
```

Restart Claude, then try: *"Don #7 is mine — what is it good at, and which job should I run?"*

### What it will not do

Traits are the build, but every sheet is saturated onto the same **Edge Budget**: a rarer Don shifts
*where* its edge sits, never *how much* it has. So the server refuses to rank Dons by raw power —
that question has no answer, and answering it would sell someone a Don on a false premise. It will
tell you what a Don's edge is **for**.

It also cannot see a garrison before it is revealed, cannot see who has a raid committed against
whom, and cannot predict any outcome — the randomness does not exist until settlement. A Don whose
trait preimage was never recorded has no sheet at all, and the server says so rather than guessing.

**Everything here is testnet play money.**

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
