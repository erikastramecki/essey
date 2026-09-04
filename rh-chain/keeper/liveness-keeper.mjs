// Liveness keeper for Robinhood Chain.
//
// Posts a heartbeat to LivenessOracle on a schedule. Liquidations on Essey require a recent
// heartbeat, so if this process — or the chain — stops, liquidations disable themselves with no
// transaction needed. That inversion is deliberate: a keeper that tries to PAUSE on an outage
// cannot send its pause transaction, because the chain it would send it to is down. It could only
// act after restart, racing the same backlog as the liquidation bots, and it would lose.
//
// It also OBSERVES each market on the same beat. EsseyMarkets' desync breaker compares consecutive
// observations, not consecutive feed rounds, and the five pool paths that observe all revert when
// the guard fires and take their write with them — so without a standalone caller the only durable
// observations are whatever traffic happens to produce, and across a quiet week the breaker measures
// drift instead of a discontinuity (G-LEND R3 MED-1). syncMultiplier is permissionless and
// non-reverting; the contract's MAX_BASELINE_AGE is what makes an outage here safe rather than
// silently wrong, so this is the liveness half of that pair, not the whole of it.
//
//   RH_RPC=... KEEPER_PRIVKEY=0x... LIVENESS_ORACLE=0x... \
//   ESSEY_MARKETS=0x... MARKET_TOKENS=0xAAPL,0xNVDA node keeper/liveness-keeper.mjs
//
// Run it under a supervisor (systemd / pm2 / a container restart policy). Alert on the WARN lines:
// a keeper that dies silently degrades to "liquidations off", which is safe but is an outage of
// its own and should page someone.
import { createWalletClient, createPublicClient, http, defineChain } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC = process.env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com";
const ORACLE = process.env.LIVENESS_ORACLE;
const PK = process.env.KEEPER_PRIVKEY;
if (!ORACLE || !PK) {
  console.error("LIVENESS_ORACLE and KEEPER_PRIVKEY are required");
  process.exit(1);
}

// Beat at 1/3 of gapThreshold, so two consecutive failures still leave margin. Beating SLOWER
// than gapThreshold makes every beat look like an outage and re-arms resumeGrace indefinitely.
const GAP_THRESHOLD = Number(process.env.GAP_THRESHOLD || 900);
const INTERVAL = Math.floor((GAP_THRESHOLD / 3) * 1000);

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

const MARKETS = process.env.ESSEY_MARKETS;
const TOKENS = (process.env.MARKET_TOKENS || "").split(",").map((t) => t.trim()).filter(Boolean);
if (MARKETS && TOKENS.length === 0) console.warn("ESSEY_MARKETS set with no MARKET_TOKENS — nothing will be observed");
if (!MARKETS) console.warn("ESSEY_MARKETS unset — the desync breaker will only see traffic-driven observations");

const marketsAbi = [
  { type: "function", name: "syncMultiplier", inputs: [{ type: "address" }], outputs: [], stateMutability: "nonpayable" },
];

const account = privateKeyToAccount(PK);
const pub = createPublicClient({ chain: rhChain, transport: http(RPC) });
const wallet = createWalletClient({ account, chain: rhChain, transport: http(RPC) });

const ts = () => new Date().toISOString();
let consecutiveFailures = 0;

async function beat() {
  try {
    const hash = await wallet.writeContract({ address: ORACLE, abi, functionName: "heartbeat" });
    await pub.waitForTransactionReceipt({ hash, timeout: 60_000 });
    const [allowed, until] = await Promise.all([
      pub.readContract({ address: ORACLE, abi, functionName: "liquidationsAllowed" }),
      pub.readContract({ address: ORACLE, abi, functionName: "secondsUntilLiquidationsAllowed" }),
    ]);
    consecutiveFailures = 0;
    const state = allowed ? "liquidations ENABLED" : `liquidations DISABLED (${until}s of grace left)`;
    console.log(`${ts()}  beat ok  ${state}  ${hash}`);
    // A gap the keeper itself caused is worth surfacing loudly — it is indistinguishable
    // on-chain from a chain outage, and someone should know which one it actually was.
    if (!allowed && until > 0) console.warn(`${ts()}  WARN post-gap grace in effect for ${until}s`);
  } catch (e) {
    consecutiveFailures++;
    console.error(`${ts()}  WARN heartbeat failed (${consecutiveFailures}x): ${e.shortMessage || e.message}`);
    if (consecutiveFailures >= 2) {
      console.error(`${ts()}  ALERT two consecutive failures — liquidations will disable in ~${GAP_THRESHOLD}s`);
    }
  }
}

// Sequential, and never inside beat()'s try: an observation that fails must not suppress the
// heartbeat, because the heartbeat is the one whose absence disables liquidations.
async function observe() {
  if (!MARKETS) return;
  for (const token of TOKENS) {
    try {
      const hash = await wallet.writeContract({
        address: MARKETS,
        abi: marketsAbi,
        functionName: "syncMultiplier",
        args: [token],
      });
      await pub.waitForTransactionReceipt({ hash, timeout: 60_000 });
    } catch (e) {
      console.error(`${ts()}  WARN observe ${token} failed: ${e.shortMessage || e.message}`);
    }
  }
}

async function tick() {
  await beat();
  await observe();
}

console.log(`${ts()}  liveness keeper up  oracle=${ORACLE}  signer=${account.address}  every ${INTERVAL / 1000}s`);
console.log(`${ts()}  observing ${TOKENS.length} market(s) on the same beat  markets=${MARKETS || "(none)"}`);
await tick();
setInterval(tick, INTERVAL);
