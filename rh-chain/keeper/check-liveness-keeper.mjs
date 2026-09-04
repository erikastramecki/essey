// Is the liveness keeper doing its job? Not "is the process up".
//
// The 2026-08-15 lesson (check-keeper.sh) applies here with more at stake: that keeper was up,
// logging steadily, and resolving nothing for eleven hours. This one can be up, beating, and
// observing NOTHING — which is G-LEND R4 HIGH-2 exactly, and it is invisible in `ps` and in the log
// unless someone reads it.
//
// So this checks the SYMPTOM, on chain, per market:
//   - the heartbeat is inside gapThreshold                     (liquidations are enabled at all)
//   - the corroborated observation is inside its age window    (this market can be liquidated)
//   - the breaker baseline is inside MAX_BASELINE_AGE          (this market's breaker can arm)
// Any of those false means that market is unprotected or unliquidatable, whatever the process is
// doing. Read-only: no key, safe to run from anywhere, exits non-zero when something is wrong.
//
//   RH_RPC=... LIVENESS_ORACLE=0x... ESSEY_MARKETS=0x... node keeper/check-liveness-keeper.mjs
import { createPublicClient, http, defineChain, parseAbiItem } from "viem";
import { reconcileMarkets } from "./market-list.mjs";

const RPC = process.env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com";
const ORACLE = process.env.LIVENESS_ORACLE;
const MARKETS = process.env.ESSEY_MARKETS;
if (!ORACLE || !MARKETS) {
  console.error("LIVENESS_ORACLE and ESSEY_MARKETS are required");
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
];
const marketCommitted = parseAbiItem("event MarketCommitted(address indexed token, uint16 ltvBps, uint16 liqThresholdBps)");

const read = (address, abi, functionName, args) => pub.readContract({ address, abi, functionName, args });

const logs = await pub.getLogs({ address: MARKETS, event: marketCommitted, fromBlock: FROM_BLOCK, toBlock: "latest" });
const { tokens } = reconcileMarkets({ discovered: logs.map((l) => l.args.token), configured: [] });

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

for (const token of tokens) {
  const [confirmedAt, seenAt] = await Promise.all([
    read(MARKETS, marketsAbi, "confirmedObservedAt", [token]),
    read(MARKETS, marketsAbi, "seenPriceAt", [token]),
  ]);
  if (confirmedAt === 0n) {
    fail(`${token}  UNCORROBORATED  the delay line has never filled — liquidation is refused`);
    continue;
  }
  const confAge = now - confirmedAt;
  // Too old is the keeper having stopped observing; too young means the ring is running ahead of
  // its own cadence, which should be impossible and is worth seeing if it ever happens.
  if (confAge > maxAge) fail(`${token}  UNOBSERVED  corroborated observation is ${confAge}s old, ceiling ${maxAge}s — liquidation is refused`);
  else if (confAge < delay) fail(`${token}  PREMATURE  corroborated observation is only ${confAge}s old, floor ${delay}s`);
  const baseAge = now - seenAt;
  if (baseAge > maxBaseline) fail(`${token}  BREAKER BLIND  baseline is ${baseAge}s old, MAX_BASELINE_AGE ${maxBaseline}s — a split leg will not arm it`);
}

if (bad) {
  console.log(`--- LIVENESS KEEPER: NOT WORKING (${bad}) ---`);
  console.log("check the process, then MARKET_TOKENS vs the MarketCommitted log, then the RPC.");
  process.exit(1);
}
console.log(`--- LIVENESS KEEPER: OK --- beat ${beatAge}s ago, ${tokens.length} market(s) observed and corroborated`);
