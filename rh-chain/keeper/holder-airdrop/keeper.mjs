// Holder-airdrop keeper for HolderDistributor (src/market/HolderDistributor.sol).
//
//   ESSEY_TOKEN=0x… HOLDER_DISTRIBUTOR=0x… BASKET_REGISTRY=0x… USDG=0x… \
//   ESSEY_TOKEN_FIRST_BLOCK=… node keeper/holder-airdrop/keeper.mjs
//
// Reads and plans by default. It sends nothing without EXECUTE=1 and KEEPER_PRIVKEY, and even then it can
// only (a) spend the distributor's USDG on a registry-committed stock that lands in the distributor, and
// (b) post a root. It has no withdraw, cannot name a payout recipient, and cannot reach another epoch's
// stock — the containment is per-epoch reserved accounting, not the keeper's good behaviour.
import { readFileSync } from "node:fs";
import { formatUnits } from "viem";
import {
  DISTRIBUTOR_ABI,
  ERC20_ABI,
  publicClientFor,
  readBaskets,
  readReserved,
  walletClientFor,
} from "./chain.mjs";
import { describe, loadConfig } from "./config.mjs";
import { resolveBar } from "./eligibility.mjs";
import { decideRun, READY } from "./epoch.mjs";
import { applyTransfers, emptyLedger, fetchTransfers, snapshotAt } from "./ledger.mjs";
import { buildManifest, planEpoch, verifyLeavesMatchRoot } from "./manifest.mjs";
import { resolvePreferences } from "./preferences.mjs";
import { loadState, saveState, writeManifest } from "./state.mjs";

const ts = () => new Date().toISOString();
const log = (msg) => console.log(`${ts()}  ${msg}`);

async function snapshot(client, cfg, block) {
  const logs = await fetchTransfers(client, {
    token: cfg.token,
    fromBlock: cfg.tokenFirstBlock,
    toBlock: block,
    window: cfg.logWindow,
  });
  return snapshotAt(applyTransfers(emptyLedger(cfg.tokenFirstBlock), logs, block));
}

async function loadPreferences(cfg, asOf) {
  if (!cfg.preferencesFile) return new Map();
  const entries = JSON.parse(readFileSync(cfg.preferencesFile, "utf8"));
  return resolvePreferences(entries, { chainId: cfg.chainId, distributor: cfg.distributor, asOf });
}

export async function runOnce(cfg, clients = {}) {
  const client = clients.client ?? publicClientFor(cfg);
  const state = loadState(cfg.stateDir);
  const head = (await client.getBlockNumber()) - cfg.confirmations;
  const now = Number((await client.getBlock({ blockNumber: head })).timestamp);

  const read = (functionName, args = []) =>
    client.readContract({ address: cfg.distributor, abi: DISTRIBUTOR_ABI, functionName, args });
  const [epoch, lastRootAt, minEpochInterval, pot] = await Promise.all([
    read("currentBuyEpoch"),
    read("lastRootAt"),
    read("minEpochInterval"),
    client.readContract({ address: cfg.usdg, abi: ERC20_ABI, functionName: "balanceOf", args: [cfg.distributor] }),
  ]);

  const decision = decideRun({
    now,
    prevSnapshotBlock: state.prevSnapshotBlock,
    lastRootAt,
    minEpochInterval,
    lastSnapshotAt: state.lastSnapshotAt,
    epochSeconds: cfg.epochSeconds,
    pot,
    minPotUsdg: cfg.minPotUsdg,
  });
  if (!decision.run) {
    log(`skip epoch ${epoch}: ${decision.reason}`);
    if (state.prevSnapshotBlock === null) {
      saveState(cfg.stateDir, { ...state, prevSnapshotBlock: head, lastSnapshotAt: now });
      log(`recorded bootstrap snapshot at block ${head}`);
    }
    return { posted: false, reason: decision.reason };
  }

  const totalSupply = await client.readContract({ address: cfg.token, abi: ERC20_ABI, functionName: "totalSupply" });
  const barWei = resolveBar({ barWei: cfg.barWei, barBps: cfg.barBps, totalSupply });
  const [prev, curr, baskets] = await Promise.all([
    snapshot(client, cfg, state.prevSnapshotBlock),
    snapshot(client, cfg, head),
    readBaskets(client, cfg.registry),
  ]);
  const preferences = await loadPreferences(cfg, now);

  const inputs = {
    prev,
    curr,
    barWei,
    exclusions: cfg.exclusions,
    preferences,
    baskets,
    defaultBasketId: cfg.defaultBasketId,
    usdgPot: pot,
  };
  const plan = planEpoch(inputs);
  log(
    `epoch ${epoch}: pot ${formatUnits(pot, 6)} USDG, ${plan.weights.holders.length} eligible above ` +
      `${formatUnits(barWei, 18)} ESSEY, ${plan.buys.length} buy legs`,
  );
  if (plan.weights.holders.length === 0 || plan.buys.length === 0) {
    log("skip: nothing to distribute");
    return { posted: false, reason: "nothing to distribute" };
  }

  const wallet = clients.wallet ?? walletClientFor(cfg);
  if (!wallet) {
    for (const buy of plan.buys) log(`  DRY-RUN settleBuy(${buy.token}, ${buy.usdg})`);
    log("  DRY-RUN postRoot pending — set EXECUTE=1 and KEEPER_PRIVKEY to send");
    return { posted: false, reason: "dry-run", plan };
  }

  for (const buy of plan.buys) {
    const hash = await wallet.writeContract({
      address: cfg.distributor,
      abi: DISTRIBUTOR_ABI,
      functionName: "settleBuy",
      args: [buy.token, buy.usdg],
    });
    await client.waitForTransactionReceipt({ hash, timeout: 120_000 });
    log(`  bought ${buy.token} with ${buy.usdg} USDG  ${hash}`);
  }

  const reserved = await readReserved(client, cfg.distributor, epoch, plan.buys.map((b) => b.token));
  const { manifest } = buildManifest({
    ...inputs,
    chainId: cfg.chainId,
    distributor: cfg.distributor,
    token: cfg.token,
    epoch,
    reserved,
  });
  if (!verifyLeavesMatchRoot(manifest)) throw new Error("keeper: built a root its own leaves do not reproduce");

  const rootHash = await wallet.writeContract({
    address: cfg.distributor,
    abi: DISTRIBUTOR_ABI,
    functionName: "postRoot",
    args: [manifest.root],
  });
  await client.waitForTransactionReceipt({ hash: rootHash, timeout: 120_000 });
  const path = writeManifest(cfg.stateDir, manifest);
  saveState(cfg.stateDir, { prevSnapshotBlock: head, lastSnapshotAt: now, lastEpochPosted: epoch });
  log(`posted root ${manifest.root} for epoch ${epoch}  ${rootHash}  manifest ${path}`);
  return { posted: true, reason: READY, manifest };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    const cfg = loadConfig();
    log(`holder-airdrop keeper up  ${describe(cfg)}`);
    await runOnce(cfg);
  } catch (err) {
    console.error(`${ts()}  ABORT  ${err instanceof Error ? err.message.slice(0, 300) : "unknown"}`);
    process.exit(2);
  }
}
