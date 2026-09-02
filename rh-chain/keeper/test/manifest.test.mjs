import assert from "node:assert/strict";
import { test } from "node:test";
import { getAddress } from "viem";
import { buildManifest, planEpoch, proofsFor, verifyLeavesMatchRoot, verifyManifest } from "../holder-airdrop/manifest.mjs";
import { leafHash, verifyProof } from "../holder-airdrop/merkle.mjs";

const AAPL = getAddress("0x000000000000000000000000000000000000AAa1");
const NVDA = getAddress("0x000000000000000000000000000000000000bB02");
const DIST = getAddress("0x00000000000000000000000000000000000d1547");
const ESSEY = getAddress("0x315790B57C19141B34C4653a91b096Cf3f071610");
const A = getAddress("0x0000000000000000000000000000000000000A11");
const B = getAddress("0x0000000000000000000000000000000000000b22");
const C = getAddress("0x0000000000000000000000000000000000000C33");

const BAR = (8_888_888_888n * 10n ** 18n) / 1_000n;
const baskets = new Map([
  [0, { tokens: [AAPL, NVDA], bps: [6_000, 4_000] }],
  [1, { tokens: [NVDA], bps: [10_000] }],
]);

function inputs(overrides = {}) {
  return {
    chainId: 4663,
    distributor: DIST,
    token: ESSEY,
    epoch: 3n,
    prev: {
      block: 100n,
      balances: new Map([
        [A, BAR * 10n],
        [B, BAR * 4n],
        [C, BAR * 2n],
      ]),
    },
    curr: {
      block: 200n,
      balances: new Map([
        [A, BAR * 10n],
        [B, BAR * 40n],
        [C, BAR * 2n],
      ]),
    },
    barWei: BAR,
    exclusions: [],
    preferences: new Map([[C, 1]]),
    baskets,
    defaultBasketId: 0,
    usdgPot: 1_000_000_000_000n,
    reserved: new Map([
      [AAPL, 500_000_000_000n],
      [NVDA, 500_000_000_000n],
    ]),
    ...overrides,
  };
}

test("the same inputs produce the same root, every time", () => {
  const first = buildManifest(inputs()).manifest.root;
  for (let i = 0; i < 25; i++) assert.equal(buildManifest(inputs()).manifest.root, first);
});

test("map insertion order does not move the root", () => {
  const base = buildManifest(inputs()).manifest;
  const shuffled = buildManifest(
    inputs({
      prev: {
        block: 100n,
        balances: new Map([
          [C, BAR * 2n],
          [A, BAR * 10n],
          [B, BAR * 4n],
        ]),
      },
      reserved: new Map([
        [NVDA, 500_000_000_000n],
        [AAPL, 500_000_000_000n],
      ]),
    }),
  ).manifest;
  assert.equal(shuffled.root, base.root);
});

test("a different bar produces a different root — the knob is really load-bearing", () => {
  const base = buildManifest(inputs()).manifest.root;
  const raised = buildManifest(inputs({ barWei: BAR * 3n })).manifest.root;
  assert.notEqual(raised, base);
});

test("a different epoch produces a different root — a root cannot be replayed into another epoch", () => {
  assert.notEqual(buildManifest(inputs({ epoch: 4n })).manifest.root, buildManifest(inputs()).manifest.root);
});

test("the manifest's leaves hash to the manifest's root", () => {
  const { manifest } = buildManifest(inputs());
  assert.equal(verifyLeavesMatchRoot(manifest), true);
});

test("a tampered leaf amount breaks the manifest's own self-check", () => {
  const { manifest } = buildManifest(inputs());
  manifest.leaves[0].amount = String(BigInt(manifest.leaves[0].amount) + 1n);
  assert.equal(verifyLeavesMatchRoot(manifest), false);
});

test("verifyManifest reproduces the published root from the declared snapshots", () => {
  const args = inputs();
  const { manifest } = buildManifest(args);
  const result = verifyManifest(manifest, { prev: args.prev, curr: args.curr, baskets });
  assert.equal(result.ok, true);
  assert.equal(result.root, manifest.root);
});

test("verifyManifest FAILS when the snapshot really held different balances", () => {
  const args = inputs();
  const { manifest } = buildManifest(args);
  const lied = { block: 200n, balances: new Map([...args.curr.balances, [A, BAR * 3n]]) };
  const result = verifyManifest(manifest, { prev: args.prev, curr: lied, baskets });
  assert.equal(result.ok, false);
  assert.notEqual(result.root, manifest.root);
});

test("verifyManifest refuses a snapshot taken at a block the manifest never named", () => {
  const args = inputs();
  const { manifest } = buildManifest(args);
  assert.throws(
    () => verifyManifest(manifest, { prev: { ...args.prev, block: 101n }, curr: args.curr, baskets }),
    /prev snapshot block mismatch/,
  );
});

test("the manifest records the snapshot blocks in order and the gate's own parameters", () => {
  const { manifest } = buildManifest(inputs());
  assert.equal(manifest.snapshots.prev.block, "100");
  assert.equal(manifest.snapshots.curr.block, "200");
  assert.equal(manifest.eligibility.barWei, String(BAR));
  assert.equal(manifest.eligibility.barMode, "inclusive");
  assert.equal(manifest.usdgPot, "1000000000000");
});

test("snapshot digests differ when the balances differ at the same block", () => {
  const args = inputs();
  const a = buildManifest(args).manifest.snapshots.curr.digest;
  const b = buildManifest(
    inputs({ curr: { block: 200n, balances: new Map([...args.curr.balances, [A, BAR * 11n]]) } }),
  ).manifest.snapshots.curr.digest;
  assert.notEqual(a, b);
});

test("planEpoch and buildManifest agree — the pot is bought on the weighting the root pays on", () => {
  const args = inputs();
  const plan = planEpoch(args);
  const { manifest } = buildManifest(args);
  const perToken = new Map();
  for (const l of manifest.leaves) perToken.set(l.token, (perToken.get(l.token) ?? 0n) + BigInt(l.amount));
  for (const buy of plan.buys) assert.ok(perToken.has(buy.token), `${buy.token} was bought but nobody was credited`);
});

test("proofsFor hands a holder proofs that verify against the published root", () => {
  const { manifest } = buildManifest(inputs());
  const proofs = proofsFor(manifest, A);
  assert.ok(proofs.length > 0);
  for (const p of proofs) {
    const leaf = leafHash({ epoch: BigInt(manifest.epoch), holder: A, token: p.token, amount: BigInt(p.amount) });
    assert.equal(verifyProof(leaf, p.proof, manifest.root), true);
  }
});

test("a root that over-attributes a token is refused at build time", () => {
  assert.throws(
    () => buildManifest(inputs({ reserved: new Map([[AAPL, 500_000_000_000n]]), usdgPot: 0n })),
    /empty leaf set|over-attributes/,
  );
});
