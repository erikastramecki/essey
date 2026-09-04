// Is the liveness keeper doing its job? Not "is the process up".
//
// The 2026-08-15 lesson (check-keeper.sh) applies here with more at stake: that keeper was up,
// logging steadily, and resolving nothing for eleven hours. This one can be up, beating, and
// observing NOTHING — which is G-LEND R4 HIGH-2 exactly, and it is invisible in `ps` and in the log
// unless someone reads it.
//
// And it must not take the KEEPER'S word for which markets exist. G-LEND R5 MED-2: both processes
// derived the list from one `getLogs`, so a replica answering short but successfully covered 1 of 2
// committed markets and printed OK. MARKET_TOKENS is REQUIRED here and is the independent source:
// every market it names is read on chain whether or not the scan found it, and disagreement FAILS.
//
// So this checks the SYMPTOM, on chain, per market:
//   - the heartbeat is inside gapThreshold                     (liquidations are enabled at all)
//   - the corroborated observation is inside its age window    (this market can be liquidated)
//   - the breaker baseline is inside MAX_BASELINE_AGE          (this market's breaker can arm)
// Any of those false means that market is unprotected or unliquidatable, whatever the process is
// doing. Read-only: no key, safe to run from anywhere, exits non-zero when something is wrong.
//
// The third one is qualified by whether the PRICE READS — see keeper-health.mjs. A 24/5 feed is dark
// ~40h of every 168h and the unqualified check was red for all of it (R6 LOW-1).
//
//   RH_RPC=... LIVENESS_ORACLE=0x... ESSEY_MARKETS=0x... node keeper/check-liveness-keeper.mjs
import { createPublicClient, http, defineChain, parseAbiItem } from "viem";
import { classifyMarket, priceReadable } from "./keeper-health.mjs";
import { reconcileMarkets } from "./market-list.mjs";

const RPC = process.env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com";
const ORACLE = process.env.LIVENESS_ORACLE;
const MARKETS = process.env.ESSEY_MARKETS;
const CONFIGURED = (process.env.MARKET_TOKENS || "").split(",").map((t) => t.trim()).filter(Boolean);
if (!ORACLE || !MARKETS) {
  console.error("LIVENESS_ORACLE and ESSEY_MARKETS are required");
  process.exit(2);
}
// Optional here was the defect: with no declared list there is nothing to disagree WITH, and a short
// scan reads as a healthy short list. A supervisor with no independent source is not a supervisor.
if (CONFIGURED.length === 0) {
  console.error("MARKET_TOKENS is required: it is this check's independent source of truth for the");
  console.error("market set. Without it a short log scan is indistinguishable from a healthy one.");
  process.exit(2);
}
const FROM_BLOCK = BigInt(process.env.MARKETS_FROM_BLOCK || 0);

const rhChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});
const pub = createPublicClient({ chain: rhChain, transport: http(RPC) });

const u = (name, inputs = []) => ({ type: "function", name, inputs, outputs: [{ type: "uint256" }], stateMutability: "view" });
const addr = { type: "address" };
const oracleAbi = [
  u("lastHeartbeat"),
  u("gapThreshold"),
  { type: "function", name: "liquidationsAllowed", inputs: [], outputs: [{ type: "bool" }], stateMutability: "view" },
];
const marketsAbi = [
  u("PRICE_CONFIRM_DELAY"),
  u("MAX_CONFIRM_AGE"),
  u("MAX_BASELINE_AGE"),
  u("confirmedObservedAt", [addr]),
  u("seenPriceAt", [addr]),
  // The registry's own freshness bound rather than a timestamp heuristic: this reverts PriceStale
  // past the market's maxStaleness, and reverting is exactly the state `_syncPrice` records nothing
  // for. Asked per market, so "dark" is the feed's answer and not this file's guess.
  {
    type: "function",
    name: "priceOf",
    inputs: [addr],
    outputs: [{ type: "uint256" }, { type: "uint8" }, { type: "bool" }],
    stateMutability: "view",
  },
];
const marketCommitted = parseAbiItem("event MarketCommitted(address indexed token, uint16 ltvBps, uint16 liqThresholdBps)");

const read = (address, abi, functionName, args) => pub.readContract({ address, abi, functionName, args });

const logs = await pub.getLogs({ address: MARKETS, event: marketCommitted, fromBlock: FROM_BLOCK, toBlock: "latest" });
const { tokens, missing, unknown, inspect } = reconcileMarkets({
  discovered: logs.map((l) => l.args.token),
  configured: CONFIGURED,
});

const [last, gap, allowed, delay, maxAge, maxBaseline] = await Promise.all([
  read(ORACLE, oracleAbi, "lastHeartbeat"),
  read(ORACLE, oracleAbi, "gapThreshold"),
  read(ORACLE, oracleAbi, "liquidationsAllowed"),
  read(MARKETS, marketsAbi, "PRICE_CONFIRM_DELAY"),
  read(MARKETS, marketsAbi, "MAX_CONFIRM_AGE"),
  read(MARKETS, marketsAbi, "MAX_BASELINE_AGE"),
]);

const block = await pub.getBlock();
const now = block.timestamp;
let bad = 0;
const fail = (line) => {
  console.log(line);
  bad++;
};

const beatAge = now - last;
if (last === 0n) fail("NEVER BEAT  the oracle has no heartbeat at all");
else if (beatAge > gap) fail(`STALE BEAT  ${beatAge}s since the last heartbeat, gapThreshold ${gap}s`);
if (!allowed) fail("LIQUIDATIONS OFF  liquidationsAllowed() is false");

if (tokens.length === 0) fail("NO MARKETS  the registry has committed none, or the log scan found none");
// A short scan and a stale env list are indistinguishable from here, so both are named and both fail.
// The market is inspected on chain either way, which is what makes this more than an alarm.
if (unknown.length > 0) {
  fail(`SCAN DISAGREES  MARKET_TOKENS names ${unknown.length} address(es) the log scan did not return: ${unknown.join(",")}`);
  console.log("            either the scan came back SHORT (a lagging replica) or the list is wrong — inspected below regardless.");
}
if (missing.length > 0) {
  fail(`LIST STALE  the registry committed ${missing.length} market(s) MARKET_TOKENS does not name: ${missing.join(",")}`);
}

let dark = 0;
for (const token of inspect) {
  const [confirmedAt, seenAt] = await Promise.all([
    read(MARKETS, marketsAbi, "confirmedObservedAt", [token]),
    read(MARKETS, marketsAbi, "seenPriceAt", [token]),
  ]);
  const readable = await priceReadable(
    () => read(MARKETS, marketsAbi, "priceOf", [token]),
    () => read(MARKETS, marketsAbi, "seenPriceAt", [token]),
  );
  const findings = classifyMarket({
    token, confirmedAt, seenAt, now, delay, maxAge, maxBaseline, priceReadable: readable,
  });
  for (const f of findings) {
    if (f.fatal) fail(f.line);
    else {
      console.log(f.line);
      dark++;
    }
  }
}

if (bad) {
  console.log(`--- LIVENESS KEEPER: NOT WORKING (${bad}) ---`);
  console.log("check the process, then MARKET_TOKENS vs the MarketCommitted log, then the RPC.");
  process.exit(1);
}
console.log(`--- LIVENESS KEEPER: OK --- beat ${beatAge}s ago, ${inspect.length} market(s) observed and corroborated`);
console.log(`    scan and MARKET_TOKENS agree on all ${inspect.length}.${dark ? ` ${dark} dark, which is the feed's schedule, not the keeper's.` : ""}`);
