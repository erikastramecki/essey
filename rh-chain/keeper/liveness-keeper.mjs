// Liveness keeper for Robinhood Chain.
//
// Posts a heartbeat to LivenessOracle on a schedule. Liquidations on Essey require a recent
// heartbeat, so if this process — or the chain — stops, liquidations disable themselves with no
// transaction needed. That inversion is deliberate: a keeper that tries to PAUSE on an outage
// cannot send its pause transaction, because the chain it would send it to is down. It could only
// act after restart, racing the same backlog as the liquidation bots, and it would lose.
//
// It also OBSERVES each market on the same beat, and that half is now load-bearing on the SEIZURE
// path, not just on uptime. EsseyMarkets values a liquidation against a delay line of observations
// (PRICE_CONFIRM_DELAY), and an observation older than MAX_CONFIRM_AGE stops being usable — so a
// market this process does not observe cannot be liquidated at all. It fails closed, which is the
// safe direction, but it is an outage and it must page someone.
//
// G-LEND R4 HIGH-2: the market list is DERIVED from the registry's own MarketCommitted logs, not
// typed into an env var. A hand-typed list that held one of two markets produced no warning at all
// and left the second market's breaker measuring drift; the runbook did not even mention the
// variable, so following it literally produced that state on every market.
//
//   RH_RPC=... KEEPER_PRIVKEY=0x... LIVENESS_ORACLE=0x... ESSEY_MARKETS=0x... \
//   [MARKET_TOKENS=0x...,0x...] [MARKETS_FROM_BLOCK=0] node keeper/liveness-keeper.mjs
//
// Run it under the supervisor unit in keeper/essey-liveness-keeper.service. Alert on WARN and
// ALERT lines.
import { createWalletClient, createPublicClient, http, defineChain, parseAbiItem } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { reconcileMarkets } from "./market-list.mjs";

const RPC = process.env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com";
const ORACLE = process.env.LIVENESS_ORACLE;
const MARKETS = process.env.ESSEY_MARKETS;
const PK = process.env.KEEPER_PRIVKEY;
if (!ORACLE || !PK) {
  console.error("LIVENESS_ORACLE and KEEPER_PRIVKEY are required");
  process.exit(1);
}
// Not optional any more: without the registry there is no observation duty, and without observation
// every listed market's corroborated price ages out and liquidation stops.
if (!MARKETS) {
  console.error("ESSEY_MARKETS is required — without it no market is observed and liquidation halts");
  process.exit(1);
}

// Beat at 1/3 of gapThreshold, so two consecutive failures still leave margin. Beating SLOWER
// than gapThreshold makes every beat look like an outage and re-arms resumeGrace indefinitely.
const GAP_THRESHOLD = Number(process.env.GAP_THRESHOLD || 900);
const INTERVAL = Math.floor((GAP_THRESHOLD / 3) * 1000);
const FROM_BLOCK = BigInt(process.env.MARKETS_FROM_BLOCK || 0);
const REDISCOVER_EVERY = Math.max(1, Math.floor(3600_000 / INTERVAL));

const rhChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});

const abi = [
  { type: "function", name: "heartbeat", inputs: [], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "lastHeartbeat", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "liquidationsAllowed", inputs: [], outputs: [{ type: "bool" }], stateMutability: "view" },
  { type: "function", name: "secondsUntilLiquidationsAllowed", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
];

const marketsAbi = [
  { type: "function", name: "syncMultiplier", inputs: [{ type: "address" }], outputs: [], stateMutability: "nonpayable" },
];

const marketCommitted = parseAbiItem("event MarketCommitted(address indexed token, uint16 ltvBps, uint16 liqThresholdBps)");

const account = privateKeyToAccount(PK);
const pub = createPublicClient({ chain: rhChain, transport: http(RPC) });
const wallet = createWalletClient({ account, chain: rhChain, transport: http(RPC) });

const ts = () => new Date().toISOString();
const envTokens = (process.env.MARKET_TOKENS || "").split(",").map((t) => t.trim()).filter(Boolean);

let tokens = [];
let beatFailures = 0;
const observeFailures = new Map();

/// Every token the registry has ever committed. Disabled markets stay in the set on purpose:
/// disableMarket stops new borrows only, and their open positions still need to be liquidatable.
async function discoverMarkets() {
  const logs = await pub.getLogs({ address: MARKETS, event: marketCommitted, fromBlock: FROM_BLOCK, toBlock: "latest" });
  return [...new Set(logs.map((l) => l.args.token))];
}

/// The env list is a CROSS-CHECK, never the source of truth. A market on chain that the operator
/// did not list is observed anyway and said out loud; a listed market the chain does not know is
/// said out loud and dropped.
async function refreshMarkets({ required }) {
  let discovered;
  try {
    discovered = await discoverMarkets();
  } catch (e) {
    console.error(`${ts()}  ALERT market discovery failed: ${e.shortMessage || e.message}`);
    if (required && envTokens.length === 0) {
      console.error(`${ts()}  ALERT no market list and no MARKET_TOKENS fallback — refusing to start`);
      process.exit(1);
    }
    if (tokens.length === 0) tokens = envTokens;
    return;
  }
  const r = reconcileMarkets({ discovered, configured: envTokens });
  if (r.tokens.length === 0) {
    console.error(`${ts()}  ALERT the registry has committed no markets — nothing to observe`);
  }
  if (envTokens.length > 0 && r.missing.length > 0) {
    console.error(`${ts()}  ALERT MARKET_TOKENS is missing ${r.missing.length} committed market(s): ${r.missing.join(",")} — observing them anyway`);
  }
  if (r.unknown.length > 0) {
    console.error(`${ts()}  ALERT MARKET_TOKENS names ${r.unknown.length} address(es) the registry never committed: ${r.unknown.join(",")} — dropped`);
  }
  tokens = r.tokens;
}

async function beat() {
  try {
    const hash = await wallet.writeContract({ address: ORACLE, abi, functionName: "heartbeat" });
    await pub.waitForTransactionReceipt({ hash, timeout: 60_000 });
    const [allowed, until] = await Promise.all([
      pub.readContract({ address: ORACLE, abi, functionName: "liquidationsAllowed" }),
      pub.readContract({ address: ORACLE, abi, functionName: "secondsUntilLiquidationsAllowed" }),
    ]);
    beatFailures = 0;
    const state = allowed ? "liquidations ENABLED" : `liquidations DISABLED (${until}s of grace left)`;
    console.log(`${ts()}  beat ok  ${state}  ${hash}`);
    // A gap the keeper itself caused is worth surfacing loudly — it is indistinguishable
    // on-chain from a chain outage, and someone should know which one it actually was.
    if (!allowed && until > 0) console.warn(`${ts()}  WARN post-gap grace in effect for ${until}s`);
  } catch (e) {
    beatFailures++;
    console.error(`${ts()}  WARN heartbeat failed (${beatFailures}x): ${e.shortMessage || e.message}`);
    if (beatFailures >= 2) {
      console.error(`${ts()}  ALERT two consecutive failures — liquidations will disable in ~${GAP_THRESHOLD}s`);
    }
  }
}

// Sequential, and never inside beat()'s try: an observation that fails must not suppress the
// heartbeat, because the heartbeat is the one whose absence disables liquidations.
async function observe() {
  for (const token of tokens) {
    try {
      const hash = await wallet.writeContract({
        address: MARKETS,
        abi: marketsAbi,
        functionName: "syncMultiplier",
        args: [token],
      });
      await pub.waitForTransactionReceipt({ hash, timeout: 60_000 });
      observeFailures.set(token, 0);
    } catch (e) {
      const n = (observeFailures.get(token) || 0) + 1;
      observeFailures.set(token, n);
      console.error(`${ts()}  WARN observe ${token} failed (${n}x): ${e.shortMessage || e.message}`);
      // R4 HIGH-2: this used to log and stop. An unobserved market's corroborated price ages past
      // MAX_CONFIRM_AGE and its breaker baseline past MAX_BASELINE_AGE — a liquidation outage on
      // that market, and one nothing else in the system reports.
      if (n >= 2) console.error(`${ts()}  ALERT ${token} unobserved ${n}x — its liquidations will halt`);
    }
  }
}

// Self-scheduling rather than setInterval (R4 LOW-3): a tick is 60s x (markets + 1) in the worst
// case, so at four markets it would overlap itself, and both halves send from the same account —
// the same pending nonce resolved twice drops one transaction, and the heartbeat is in that race.
let ticks = 0;
async function tick() {
  if (ticks > 0 && ticks % REDISCOVER_EVERY === 0) await refreshMarkets({ required: false });
  ticks++;
  await beat();
  await observe();
  setTimeout(tick, INTERVAL);
}

console.log(`${ts()}  liveness keeper up  oracle=${ORACLE}  registry=${MARKETS}  signer=${account.address}  every ${INTERVAL / 1000}s`);
await refreshMarkets({ required: true });
console.log(`${ts()}  observing ${tokens.length} committed market(s): ${tokens.join(",") || "(none)"}`);
await tick();
