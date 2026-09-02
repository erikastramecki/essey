// Independent root verifier — the thing that makes the keeper's correctness checkable by anyone.
//
//   ESSEY_TOKEN=… HOLDER_DISTRIBUTOR=… BASKET_REGISTRY=… USDG=… ESSEY_TOKEN_FIRST_BLOCK=… \
//   node keeper/holder-airdrop/verify-root.mjs keeper-state/root-epoch-0.json
//
// Rebuilds both snapshots from the token's Transfer history at the blocks the manifest names, replays the
// eligibility gate and the allocation, and compares roots. A mismatch inside the challenge window is what
// the guardian slashes on (challengeRoot, src/market/HolderDistributor.sol:194). Read-only: no key, no send.
import { readFileSync } from "node:fs";
import { publicClientFor, readBaskets } from "./chain.mjs";
import { loadConfig } from "./config.mjs";
import { applyTransfers, emptyLedger, fetchTransfers, snapshotAt } from "./ledger.mjs";
import { verifyLeavesMatchRoot, verifyManifest } from "./manifest.mjs";

const path = process.argv[2];
if (!path) {
  console.error("usage: node keeper/holder-airdrop/verify-root.mjs <manifest.json>");
  process.exit(2);
}

const manifest = JSON.parse(readFileSync(path, "utf8"));
const cfg = loadConfig();
const client = publicClientFor(cfg);

async function snapshot(block) {
  const logs = await fetchTransfers(client, {
    token: cfg.token,
    fromBlock: cfg.tokenFirstBlock,
    toBlock: BigInt(block),
    window: cfg.logWindow,
  });
  return snapshotAt(applyTransfers(emptyLedger(cfg.tokenFirstBlock), logs, BigInt(block)));
}

if (!verifyLeavesMatchRoot(manifest)) {
  console.error(`FAIL  the manifest's own leaves do not hash to its root ${manifest.root}`);
  process.exit(1);
}

const [prev, curr, baskets] = await Promise.all([
  snapshot(manifest.snapshots.prev.block),
  snapshot(manifest.snapshots.curr.block),
  readBaskets(client, cfg.registry),
]);
const result = verifyManifest(manifest, { prev, curr, baskets });

console.log(`manifest  ${path}`);
console.log(`epoch     ${manifest.epoch}`);
console.log(`snapshots prev ${manifest.snapshots.prev.block} -> curr ${manifest.snapshots.curr.block}`);
console.log(`bar       ${manifest.eligibility.barWei} wei (${manifest.eligibility.barMode})`);
console.log(`holders   ${manifest.eligibility.eligibleHolders} eligible, ${manifest.leaves.length} leaves`);
console.log(`published ${result.expected}`);
console.log(`recomputed ${result.root}`);
console.log(result.ok ? "OK  root reproduces from chain data" : "FAIL  root does NOT reproduce — challengeable");
process.exit(result.ok ? 0 : 1);
