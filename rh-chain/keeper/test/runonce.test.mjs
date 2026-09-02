import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { getAddress, keccak256, toHex } from "viem";
import { loadConfig } from "../holder-airdrop/config.mjs";
import { runOnce } from "../holder-airdrop/keeper.mjs";
import { verifyLeavesMatchRoot } from "../holder-airdrop/manifest.mjs";
import { verifyProof } from "../holder-airdrop/merkle.mjs";
import { leafHash } from "../holder-airdrop/merkle.mjs";

const ESSEY = getAddress("0x315790B57C19141B34C4653a91b096Cf3f071610");
const DIST = getAddress("0x00000000000000000000000000000000000d1547");
const REG = getAddress("0x0000000000000000000000000000000000000123");
const USDG = getAddress("0x00000000000000000000000000000000000005d6");
const AAPL = getAddress("0x000000000000000000000000000000000000AAa1");
const NVDA = getAddress("0x000000000000000000000000000000000000bB02");
const HOLD = getAddress("0x0000000000000000000000000000000000000A11");
const FARMER = getAddress("0x0000000000000000000000000000000000000d44");
const TREASURY = getAddress("0x93e6e42CcC676614FB3635b0983d60F35dDE4B9E");

const BAR = (8_888_888_888n * 10n ** 18n) / 1_000n;
const POT = 1_000_000_000_000n;
const FIRST = 100n;

const transfer = (block, logIndex, from, to, value) => ({
  address: ESSEY,
  blockNumber: BigInt(block),
  logIndex,
  transactionHash: keccak256(toHex(`${block}:${logIndex}`)),
  topics: [
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
    `0x${from.slice(2).toLowerCase().padStart(64, "0")}`,
    `0x${to.slice(2).toLowerCase().padStart(64, "0")}`,
  ],
  data: `0x${value.toString(16).padStart(64, "0")}`,
});

const ZERO = "0x0000000000000000000000000000000000000000";

/// Genesis mint at 101, then the farmer buys in at 900 — after the first snapshot but before the second.
const LOGS = [
  transfer(101, 0, ZERO, TREASURY, BAR * 10_000n),
  transfer(102, 0, TREASURY, HOLD, BAR * 20n),
  transfer(900, 0, TREASURY, FARMER, BAR * 500n),
];

function stubClient({ head, now, epoch = 0n, lastRootAt = 0n, pot = POT }) {
  const bought = new Map();
  return {
    bought,
    async getBlockNumber() {
      return head;
    },
    async getBlock() {
      return { timestamp: BigInt(now) };
    },
    async getLogs({ fromBlock, toBlock }) {
      return LOGS.filter((l) => l.blockNumber >= fromBlock && l.blockNumber <= toBlock);
    },
    async waitForTransactionReceipt() {
      return { status: "success" };
    },
    async readContract({ address, functionName, args }) {
      if (address === USDG && functionName === "balanceOf") return pot;
      if (address === ESSEY && functionName === "totalSupply") return 8_888_888_888n * 10n ** 18n;
      if (address === REG && functionName === "basketCount") return 2n;
      if (address === REG && functionName === "basketOf") {
        return args[0] === 0n ? ["core", [AAPL, NVDA], [6_000, 4_000], true] : ["chips", [NVDA], [10_000], true];
      }
      if (address === DIST && functionName === "currentBuyEpoch") return epoch;
      if (address === DIST && functionName === "lastRootAt") return lastRootAt;
      if (address === DIST && functionName === "minEpochInterval") return 43_200n;
      if (address === DIST && functionName === "reserved") return bought.get(getAddress(args[1])) ?? 0n;
      throw new Error(`stub: unhandled read ${functionName} on ${address}`);
    },
  };
}

function stubWallet(client) {
  const sent = [];
  return {
    sent,
    async writeContract({ functionName, args }) {
      sent.push({ functionName, args });
      if (functionName === "settleBuy") {
        const token = getAddress(args[0]);
        client.bought.set(token, (client.bought.get(token) ?? 0n) + args[1]); // mock converter: 1:1
      }
      return keccak256(toHex(`${functionName}:${sent.length}`));
    },
  };
}

function cfgIn(dir) {
  return loadConfig({
    ESSEY_TOKEN: ESSEY,
    ESSEY_TOKEN_FIRST_BLOCK: String(FIRST),
    HOLDER_DISTRIBUTOR: DIST,
    BASKET_REGISTRY: REG,
    USDG,
    EXCLUSIONS: TREASURY,
    STATE_DIR: dir,
  });
}

const scratch = () => mkdtempSync(join(tmpdir(), "airdrop-keeper-"));

test("the FIRST run posts NOTHING and only records a snapshot", async () => {
  const dir = scratch();
  const client = stubClient({ head: 500n, now: 1_000_000 });
  const wallet = stubWallet(client);
  const result = await runOnce(cfgIn(dir), { client, wallet });

  assert.equal(result.posted, false);
  assert.match(result.reason, /two-snapshot gate needs one epoch of history/);
  assert.deepEqual(wallet.sent, []);
  const state = JSON.parse(readFileSync(join(dir, "holder-airdrop-state.json"), "utf8"));
  assert.equal(state.prevSnapshotBlock, "470"); // head minus the 30-block confirmation lag
});

test("the SECOND run buys the plan, posts a root, and writes a reproducible manifest", async () => {
  const dir = scratch();
  const first = stubClient({ head: 500n, now: 1_000_000 });
  await runOnce(cfgIn(dir), { client: first, wallet: stubWallet(first) });

  const client = stubClient({ head: 1_000n, now: 1_100_000 });
  const wallet = stubWallet(client);
  const result = await runOnce(cfgIn(dir), { client, wallet });

  assert.equal(result.posted, true);
  const buys = wallet.sent.filter((s) => s.functionName === "settleBuy");
  const posts = wallet.sent.filter((s) => s.functionName === "postRoot");
  assert.equal(posts.length, 1);
  assert.equal(buys.reduce((s, b) => s + b.args[1], 0n), POT, "the whole pot was spent");
  assert.equal(posts[0].args[0], result.manifest.root);
  assert.equal(verifyLeavesMatchRoot(result.manifest), true);

  const written = readdirSync(dir).filter((f) => f.startsWith("root-epoch-"));
  assert.deepEqual(written, ["root-epoch-0.json"]);
});

test("a wallet that arrived between the two snapshots gets NO leaf", async () => {
  const dir = scratch();
  const first = stubClient({ head: 500n, now: 1_000_000 });
  await runOnce(cfgIn(dir), { client: first, wallet: stubWallet(first) });
  const client = stubClient({ head: 1_000n, now: 1_100_000 });
  const { manifest } = await runOnce(cfgIn(dir), { client, wallet: stubWallet(client) });

  assert.equal(manifest.leaves.some((l) => getAddress(l.holder) === FARMER), false, "the farmer was paid");
  assert.equal(manifest.leaves.every((l) => getAddress(l.holder) === HOLD), true);
  assert.equal(manifest.snapshots.prev.block, "470");
  assert.equal(manifest.snapshots.curr.block, "970");
});

test("the excluded treasury wallet is never credited despite holding most of the supply", async () => {
  const dir = scratch();
  const first = stubClient({ head: 500n, now: 1_000_000 });
  await runOnce(cfgIn(dir), { client: first, wallet: stubWallet(first) });
  const client = stubClient({ head: 1_000n, now: 1_100_000 });
  const { manifest } = await runOnce(cfgIn(dir), { client, wallet: stubWallet(client) });

  assert.equal(manifest.leaves.some((l) => getAddress(l.holder) === TREASURY), false);
  for (const leaf of manifest.leaves) {
    const h = leafHash({
      epoch: BigInt(manifest.epoch),
      holder: leaf.holder,
      token: leaf.token,
      amount: BigInt(leaf.amount),
    });
    assert.notEqual(h, null);
  }
});

test("the snapshot window ADVANCES — epoch N's current snapshot becomes epoch N+1's previous", async () => {
  const dir = scratch();
  const first = stubClient({ head: 500n, now: 1_000_000 });
  await runOnce(cfgIn(dir), { client: first, wallet: stubWallet(first) });
  const second = stubClient({ head: 1_000n, now: 1_100_000 });
  await runOnce(cfgIn(dir), { client: second, wallet: stubWallet(second) });

  const third = stubClient({ head: 2_000n, now: 1_200_000, epoch: 1n, lastRootAt: 1_100_000n });
  const { manifest } = await runOnce(cfgIn(dir), { client: third, wallet: stubWallet(third) });
  assert.equal(manifest.snapshots.prev.block, "970", "the window did not advance to the last snapshot");
  assert.equal(manifest.snapshots.curr.block, "1970");
  assert.equal(manifest.epoch, "1");
});

test("a dry run with no wallet plans the buys but sends nothing", async () => {
  const dir = scratch();
  const first = stubClient({ head: 500n, now: 1_000_000 });
  await runOnce(cfgIn(dir), { client: first, wallet: stubWallet(first) });
  const client = stubClient({ head: 1_000n, now: 1_100_000 });
  const result = await runOnce(cfgIn(dir), { client });

  assert.equal(result.posted, false);
  assert.equal(result.reason, "dry-run");
  assert.ok(result.plan.buys.length > 0);
  assert.deepEqual(readdirSync(dir).filter((f) => f.startsWith("root-epoch-")), []);
});

test("a pot below the buy floor posts nothing", async () => {
  const dir = scratch();
  const first = stubClient({ head: 500n, now: 1_000_000 });
  await runOnce(cfgIn(dir), { client: first, wallet: stubWallet(first) });
  const client = stubClient({ head: 1_000n, now: 1_100_000, pot: 999_999n });
  const wallet = stubWallet(client);
  const result = await runOnce(cfgIn(dir), { client, wallet });

  assert.match(result.reason, /dust/);
  assert.deepEqual(wallet.sent, []);
});

test("every leaf in the posted manifest proves against the posted root", async () => {
  const dir = scratch();
  const first = stubClient({ head: 500n, now: 1_000_000 });
  await runOnce(cfgIn(dir), { client: first, wallet: stubWallet(first) });
  const client = stubClient({ head: 1_000n, now: 1_100_000 });
  const wallet = stubWallet(client);
  const { manifest } = await runOnce(cfgIn(dir), { client, wallet });

  const { proofsFor } = await import("../holder-airdrop/manifest.mjs");
  for (const leaf of manifest.leaves) {
    const [proof] = proofsFor(manifest, leaf.holder).filter((p) => p.token === leaf.token);
    const h = leafHash({
      epoch: BigInt(manifest.epoch),
      holder: leaf.holder,
      token: leaf.token,
      amount: BigInt(leaf.amount),
    });
    assert.equal(verifyProof(h, proof.proof, manifest.root), true);
  }
});
