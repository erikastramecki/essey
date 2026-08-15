#!/usr/bin/env node
// Essey MCP server — lets an AI agent quote, borrow, check health and repay.
//
// This is the half of the product that makes the pitch work: a user connects Robinhood's Trading
// MCP to buy a stock, and connects this one to borrow against it, in a single conversation.
//
//   Robinhood Trading MCP   ->  agent buys AAPL under the user's own credentials
//   Robinhood settlement    ->  Stock Token lands in the user's self-custody wallet
//   Essey MCP (this)        ->  agent quotes and opens a loan against it
//
// Essey never holds the brokerage account and never custodies the collateral before the loan —
// the user's wallet signs. Deliberately: custody would forfeit the non-custodial property and
// bring licensing exposure that the transfer-based design avoids entirely.
//
// MULTI-CHAIN BY DESIGN. `chain` is a parameter, not a constant. Robinhood Chain is implemented
// today; Sui is wired to the existing Move deployment. Adding a chain means adding an adapter,
// not forking this server.
//
//   node mcp/essey-mcp.mjs                        # testnet, addresses defaulted, game tools ready
//   ESSEY_CHAIN=rh-testnet ESSEY_POOL=0x... ESSEY_MARKETS=0x... node mcp/essey-mcp.mjs   # override
//
// Read-only tools work with no key. Anything that moves funds returns UNSIGNED CALLDATA for the
// user's wallet to sign — this server never takes a private key.

import { createPublicClient, http, defineChain, encodeFunctionData, formatUnits, parseUnits } from "viem";
import { GAME_TOOLS, GAME_HANDLERS } from "./essey-game.mjs";

// ---------------------------------------------------------------- chains

const CHAINS = {
  "rh-mainnet": {
    id: 4663,
    label: "Robinhood Chain",
    rpc: "https://rpc.mainnet.chain.robinhood.com",
    explorer: "https://robinhoodchain.blockscout.com",
    asset: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", // USDG
    assetSymbol: "USDG",
  },
  "local-fork": {
    id: 4663,
    label: "Robinhood Chain (local fork)",
    rpc: "http://127.0.0.1:8545",
    explorer: "https://robinhoodchain.blockscout.com",
    asset: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
    assetSymbol: "USDG",
  },
  "rh-testnet": {
    id: 46630,
    label: "Robinhood Chain testnet",
    rpc: "https://rpc.testnet.chain.robinhood.com/rpc",
    explorer: "https://robinhoodchain.blockscout.com",
    asset: process.env.ESSEY_ASSET || "",
    assetSymbol: "USDG",
  },
};

const CHAIN_KEY = process.env.ESSEY_CHAIN || "rh-testnet";
const CFG = CHAINS[CHAIN_KEY];
if (!CFG) throw new Error(`unknown ESSEY_CHAIN "${CHAIN_KEY}" (have: ${Object.keys(CHAINS).join(", ")})`);

// Committed testnet defaults so the server is useful with no configuration. A tester connecting to
// play the game should not have to know an address; ops still overrides both per chain.
const DEFAULTS = {
  "rh-testnet": {
    pool: "0x764525bE0e90cB02afFB93ccA63bB94333c43EEF",
    markets: "0x6dAE0540bcC78756BB7b2e936ACBFA9cA5439732",
  },
};

const POOL = process.env.ESSEY_POOL || DEFAULTS[CHAIN_KEY]?.pool;
const MARKETS = process.env.ESSEY_MARKETS || DEFAULTS[CHAIN_KEY]?.markets;

const chain = defineChain({
  id: CFG.id,
  name: CFG.label,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [CFG.rpc] } },
});
const pub = createPublicClient({ chain, transport: http(CFG.rpc) });

// ---------------------------------------------------------------- abis

const MARKETS_ABI = [
  { type: "function", name: "collateralValue", stateMutability: "view",
    inputs: [{ type: "address" }, { type: "uint256" }],
    outputs: [{ type: "uint256" }, { type: "bool" }] },
  { type: "function", name: "maxBorrow", stateMutability: "view",
    inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "canBorrow", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "canLiquidate", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "isUnderwater", stateMutability: "view",
    inputs: [{ type: "address" }, { type: "uint256" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "market", stateMutability: "view", inputs: [{ type: "address" }],
    outputs: [{ type: "tuple", components: [
      { name: "enabled", type: "bool" }, { name: "ltvBps", type: "uint16" },
      { name: "liqThresholdBps", type: "uint16" }, { name: "liqBonusBps", type: "uint16" },
      { name: "collateralDecimals", type: "uint8" }, { name: "cap", type: "uint128" }] }] },
  { type: "function", name: "assetDecimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
];

const POOL_ABI = [
  { type: "function", name: "borrow", stateMutability: "nonpayable",
    inputs: [{ type: "address" }, { type: "uint256" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "repay", stateMutability: "nonpayable",
    inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [] },
  { type: "function", name: "debtOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
  // Position is { token, collateralRaw, principal, indexSnapshot, collIndexSnapshot } — ONE address
  // and four uint256s. An earlier version of this file declared a leading `borrower` address, which
  // has never existed: EsseyPool.sol:59 says the borrower is deliberately not stored, because the
  // position is a bearer instrument and authority follows note.ownerOf(id) at execution time. The
  // extra field shifted every decode and made essey_health fail against any real pool.
  { type: "function", name: "positions", stateMutability: "view", inputs: [{ type: "uint256" }],
    outputs: [{ type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }] },
  { type: "function", name: "note", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
];

const NOTE_ABI = [
  { type: "function", name: "ownerOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }] },
];

/// Reverts should reach the agent as a sentence it can act on, never as an undecodable selector.
/// `quote` had this discipline from the start; the other three did not, so they leaked raw errors.
function explain(e, fallback) {
  const m = String(e?.shortMessage || e?.message || e);
  if (/out of bounds|position .* does not exist/i.test(m)) return "no such position";
  if (/stale|price|oracle|feed/i.test(m)) return "no usable price right now (stale feed, or the market is closed)";
  if (/insufficient/i.test(m)) return "the pool does not have enough liquidity for this right now";
  return `${fallback} (${m.split("\n")[0].slice(0, 160)})`;
}

const ERC20_ABI = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable",
    inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
];

const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });

// ---------------------------------------------------------------- tools

/// Everything a borrower should know BEFORE borrowing, including the parts that are easy to omit.
async function quote({ stockToken, amount, wallet }) {
  const [mkt, assetDec] = await Promise.all([
    read(MARKETS, MARKETS_ABI, "market", [stockToken]),
    read(MARKETS, MARKETS_ABI, "assetDecimals"),
  ]);
  if (!mkt.enabled) return { ok: false, reason: `${stockToken} is not an enabled market` };

  if (amount === undefined && !wallet)
    return { ok: false, reason: "give either `wallet` (to price its whole balance) or `amount` (to price that many shares)" };
  let raw;
  try {
    raw = amount !== undefined
      ? parseUnits(String(amount), mkt.collateralDecimals)
      : await read(stockToken, ERC20_ABI, "balanceOf", [wallet]);
  } catch (e) { return { ok: false, reason: explain(e, "could not read the collateral balance") }; }
  if (raw === 0n) return { ok: false, reason: "wallet holds none of this Stock Token" };

  const [symbol, canBorrow] = await Promise.all([
    read(stockToken, ERC20_ABI, "symbol"),
    read(MARKETS, MARKETS_ABI, "canBorrow", [stockToken]),
  ]);

  // collateralValue reverts when the price is unusable — a stale/silent oracle or a shut market.
  // Surface that as a REASON rather than an error: "we cannot price this right now" is the
  // honest answer and the borrower can act on it.
  let value, inSession;
  try {
    [value, inSession] = await read(MARKETS, MARKETS_ABI, "collateralValue", [stockToken, raw]);
  } catch (e) {
    return { ok: false, reason: "no usable price right now (stale feed, or the market is closed)", canBorrow: false };
  }
  const max = await read(MARKETS, MARKETS_ABI, "maxBorrow", [stockToken, raw]);

  return {
    ok: true,
    chain: CFG.label,
    collateral: { symbol, amount: formatUnits(raw, mkt.collateralDecimals), raw: raw.toString() },
    collateralValue: `${formatUnits(value, assetDec)} ${CFG.assetSymbol}`,
    maxBorrow: `${formatUnits(max, assetDec)} ${CFG.assetSymbol}`,
    ltv: `${mkt.ltvBps / 100}%`,
    liquidationThreshold: `${mkt.liqThresholdBps / 100}%`,
    marketOpen: inSession,
    canBorrowNow: canBorrow,
    // Stated every time. These are properties of the collateral, not bugs to be fixed, and a
    // borrower who is not told about them cannot price them.
    risks: [
      "Stock Tokens are tokenised DEBT securities from Robinhood Assets (Jersey) Ltd — economic exposure only, no ownership of the underlying share.",
      "Robinhood can burn Stock Tokens from any address, including this pool. Collateral can be destroyed while your loan is open.",
      "The price feed follows US market hours (24/5). Overnight and at weekends there is no fresh price, borrowing is disabled, and a Monday gap cannot be liquidated into.",
      `Borrow well below the ${mkt.ltvBps / 100}% limit: the gap to the ${mkt.liqThresholdBps / 100}% liquidation threshold is what absorbs a weekend move.`,
    ],
    ...(canBorrow ? {} : { whyNot: inSession ? "market open but no fresh price" : "US equity market is closed" }),
  };
}

/// Returns UNSIGNED calldata. This server never holds a key and never signs.
async function borrowTx({ stockToken, collateralAmount, borrowAmount }) {
  const mkt = await read(MARKETS, MARKETS_ABI, "market", [stockToken]);
  const assetDec = await read(MARKETS, MARKETS_ABI, "assetDecimals");
  const raw = parseUnits(String(collateralAmount), mkt.collateralDecimals);
  const debt = parseUnits(String(borrowAmount), assetDec);

  const max = await read(MARKETS, MARKETS_ABI, "maxBorrow", [stockToken, raw]);
  if (debt > max) {
    return { ok: false, reason: `${borrowAmount} exceeds the maximum ${formatUnits(max, assetDec)} for that collateral` };
  }
  return {
    ok: true,
    note: "Two transactions, in order. Sign them with your own wallet — Essey never holds your key.",
    transactions: [
      { step: 1, description: `Approve the pool to take ${collateralAmount} ${await read(stockToken, ERC20_ABI, "symbol")}`,
        to: stockToken, data: encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [POOL, raw] }) },
      { step: 2, description: `Post collateral and borrow ${borrowAmount} ${CFG.assetSymbol}`,
        to: POOL, data: encodeFunctionData({ abi: POOL_ABI, functionName: "borrow", args: [stockToken, raw, debt] }) },
    ],
  };
}

async function health({ positionId }) {
  const id = BigInt(positionId);
  let token, collateralRaw, principal;
  try {
    [token, collateralRaw, principal] = await read(POOL, POOL_ABI, "positions", [id]);
  } catch (e) {
    return { ok: false, reason: explain(e, `could not read position ${positionId}`) };
  }
  if (principal === 0n) return { ok: false, reason: `position ${positionId} is closed or does not exist` };

  // The borrower is not a stored field. The position is a bearer instrument, so the party with
  // repay authority and the right to the returned collateral is whoever holds the Note right now.
  let holder = null;
  try {
    const noteAddr = await read(POOL, POOL_ABI, "note");
    holder = await read(noteAddr, NOTE_ABI, "ownerOf", [id]);
  } catch { /* a closed position has no holder; the rest of the reading still stands */ }
  const [debt, assetDec, mkt] = await Promise.all([
    read(POOL, POOL_ABI, "debtOf", [id]),
    read(MARKETS, MARKETS_ABI, "assetDecimals"),
    read(MARKETS, MARKETS_ABI, "market", [token]),
  ]);
  let value, underwater = null, priceKnown = true;
  try {
    [value] = await read(MARKETS, MARKETS_ABI, "collateralValue", [token, collateralRaw]);
    underwater = await read(MARKETS, MARKETS_ABI, "isUnderwater", [token, collateralRaw, debt]);
  } catch { priceKnown = false; }

  return {
    ok: true, positionId,
    holder,
    holderNote: "Repay authority and the returned collateral follow whoever holds the position's Note NFT, not the original borrower. A transferred Note transfers the position.",
    debt: `${formatUnits(debt, assetDec)} ${CFG.assetSymbol}`,
    collateral: formatUnits(collateralRaw, mkt.collateralDecimals),
    ...(priceKnown
      ? { collateralValue: `${formatUnits(value, assetDec)} ${CFG.assetSymbol}`,
          healthFactor: Number((value * BigInt(mkt.liqThresholdBps)) / 10_000n) / Number(debt),
          underwater }
      : { note: "no fresh price right now — health cannot be evaluated, and liquidation is also disabled" }),
  };
}

async function repayTx({ positionId }) {
  const id = BigInt(positionId);
  const [debt, assetDec] = await Promise.all([
    read(POOL, POOL_ABI, "debtOf", [id]),
    read(MARKETS, MARKETS_ABI, "assetDecimals"),
  ]);
  if (debt === 0n) return { ok: false, reason: "nothing owed" };
  // Pad by 1% and let the contract refund the difference: debt grows every second, so quoting an
  // exact figure makes repayment a race against the clock that the borrower can lose.
  const pad = (debt * 101n) / 100n;
  return {
    ok: true,
    owed: `${formatUnits(debt, assetDec)} ${CFG.assetSymbol}`,
    note: "Approve slightly more than owed; the contract charges only the debt and returns the rest.",
    transactions: [
      { step: 1, description: `Approve ${formatUnits(pad, assetDec)} ${CFG.assetSymbol}`,
        to: CFG.asset, data: encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [POOL, pad] }) },
      { step: 2, description: "Repay and reclaim collateral",
        to: POOL, data: encodeFunctionData({ abi: POOL_ABI, functionName: "repay", args: [id, pad] }) },
    ],
  };
}

// ---------------------------------------------------------------- MCP wire protocol

const TOOLS = [
  { name: "essey_quote", description:
      "Quote a loan against a Robinhood Stock Token. Returns collateral value, max borrow, whether borrowing is currently possible, and the risks of this collateral. Call this before essey_borrow.",
    inputSchema: { type: "object", properties: {
      stockToken: { type: "string", description: "Stock Token contract address" },
      wallet: { type: "string", description: "Wallet address, to price its whole balance. Give this OR amount." },
      amount: { type: "number", description: "Optional: quote this many shares instead of the balance" },
    }, required: ["stockToken"] } },
  { name: "essey_borrow", description:
      "Build the unsigned transactions to post collateral and borrow. Returns calldata for the user's wallet to sign; Essey never holds a key.",
    inputSchema: { type: "object", properties: {
      stockToken: { type: "string" }, collateralAmount: { type: "number" }, borrowAmount: { type: "number" },
    }, required: ["stockToken", "collateralAmount", "borrowAmount"] } },
  { name: "essey_health", description:
      "Current debt, collateral value, health factor and liquidation status for a position.",
    inputSchema: { type: "object", properties: { positionId: { type: "number" } }, required: ["positionId"] } },
  { name: "essey_repay", description:
      "Build the unsigned transactions to repay a position and reclaim collateral.",
    inputSchema: { type: "object", properties: { positionId: { type: "number" } }, required: ["positionId"] } },
];

// borrowTx/repayTx build calldata from live reads, so a bad market or a stale feed surfaces as a
// revert mid-build. Wrap them so the agent gets a sentence instead of a selector.
const guarded = (fn, what) => async (args) => {
  try { return await fn(args); } catch (e) { return { ok: false, reason: explain(e, what) }; }
};

const HANDLERS = {
  essey_quote: guarded(quote, "could not quote this loan"),
  essey_borrow: guarded(borrowTx, "could not build the borrow transactions"),
  essey_health: guarded(health, "could not read this position"),
  essey_repay: guarded(repayTx, "could not build the repay transactions"),
  ...GAME_HANDLERS,
};

// What a connecting client is told before it calls anything. Without this the server looks like four
// lending endpoints and nothing else, and an agent has no reason to know the game exists at all.
const INSTRUCTIONS = `Essey is two products on Robinhood Chain, and this server serves both.

LENDING. A user buys a stock through Robinhood's own MCP, the Stock Token settles into their
self-custody wallet, and essey_quote / essey_borrow let them borrow against it without either
service ever custodying the collateral. essey_quote always returns the real risks; repeat them.

D.O.N. — the game. Players own Don NFTs and play a competitive extraction game against each other.
Scrip sits in one of three places and choosing between them IS the game: banked in the Don's vault
(untouchable, earns nothing), deployed as working capital (earns, partly reachable), or sitting in
the hopper (unbanked winnings, the most exposed money they have). Sending a Don on a job makes it
AWAY for that job's duration, and away is the only state in which another player's raid can land.
Banking is free and total protection, which is why banking is the real skill.

If someone tells you their Don, call don_state — it carries that Don's stat sheet with it. Call
don_sheet for the full sheet, or for a Don they are thinking of buying. If they are choosing a job,
call don_board, which returns live contract odds and expected value at each provision level. Call
don_playbook before giving strategy advice.

HOW TO ADVISE WELL HERE:
- Use the live numbers. Never quote odds or payouts from memory; the board changes.
- Provision is burned at dispatch and only returns through the success branch. Say what a provision
  is really worth before recommending one.
- Weigh return against exposure time, not headline payout. A long job is a long open window.
- Traits are the build the game WILL use, and the sheet is permanently committed — but the deployed
  Phase-0 contracts do not read it yet, so no stat changes any outcome today. Say that plainly
  before giving trait-based advice, and never credit a stat for a result a player just got.
- Never rank Dons by raw power. Every sheet is saturated onto the same Edge Budget, so a rarer Don
  moves where its edge sits, not how much it has. Say what a Don's edge is FOR, never that it wins.
- A Don with no recorded preimage has no sheet. Say so plainly and stop — never infer stats from
  the artwork or the token number.
- Be honest about what nobody can know: a defender's garrison is a hash until revealed, pending raids
  do not name their target, and the randomness does not exist until settlement. You can compute the
  odds; you cannot tell a bait House from a fat one, and you should say so.
- These tools are read-only by design. Never claim to have acted; the player takes every action.

Everything here is public chain data, free to everyone. This server never holds a private key, and
every fund-moving lending tool returns unsigned calldata for the user's own wallet to sign.`;

function send(msg) { process.stdout.write(JSON.stringify(msg) + "\n"); }

let buf = "";
process.stdin.on("data", async (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let req;
    try { req = JSON.parse(line); } catch { continue; }
    try {
      if (req.method === "initialize") {
        send({ jsonrpc: "2.0", id: req.id, result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "essey", version: "0.2.0" },
          instructions: INSTRUCTIONS,
        } });
      } else if (req.method === "tools/list") {
        send({ jsonrpc: "2.0", id: req.id, result: { tools: [...TOOLS, ...GAME_TOOLS] } });
      } else if (req.method === "tools/call") {
        const fn = HANDLERS[req.params.name];
        if (!fn) throw new Error(`unknown tool ${req.params.name}`);
        if (!GAME_HANDLERS[req.params.name] && (!POOL || !MARKETS)) throw new Error("ESSEY_POOL and ESSEY_MARKETS must be set");
        const out = await fn(req.params.arguments || {});
        send({ jsonrpc: "2.0", id: req.id, result: { content: [{ type: "text", text: JSON.stringify(out, null, 2) }] } });
      } else if (req.id !== undefined) {
        send({ jsonrpc: "2.0", id: req.id, error: { code: -32601, message: `unknown method ${req.method}` } });
      }
    } catch (e) {
      send({ jsonrpc: "2.0", id: req.id, error: { code: -32603, message: e.message } });
    }
  }
});

process.stderr.write(`essey-mcp on ${CFG.label} (${CFG.id})  pool=${POOL || "unset"}  markets=${MARKETS || "unset"}\n`);
