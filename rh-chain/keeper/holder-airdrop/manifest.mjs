import { getAddress, keccak256, toHex } from "viem";
import { allocate, assertWithinReserved, planBuys, resolveBaskets } from "./allocate.mjs";
import { BAR_MODE, computeWeights } from "./eligibility.mjs";
import { buildTree, leafHash, proofFor } from "./merkle.mjs";

export const SPEC = "essey-holder-airdrop-root/1";

/// The epoch's buy plan: who is eligible, which basket each is in, and how much USDG each token leg
/// should spend. Runs BEFORE the buys. buildManifest re-derives exactly this from the same inputs, so the
/// root can never be attributed on a different weighting than the one the pot was bought against.
export function planEpoch({ prev, curr, barWei, exclusions = [], preferences = new Map(), baskets, defaultBasketId, usdgPot }) {
  const weights = computeWeights({ prev, curr, barWei, exclusions });
  const assigned = resolveBaskets({ holders: weights.holders, preferences, baskets, defaultBasketId });
  const plan = planBuys({ holders: weights.holders, assigned, baskets, usdgPot });
  return { weights, assigned, ...plan };
}

/// The published artifact. Everything the root depends on is in here in canonical form, so anyone with
/// an RPC can re-derive the same root and object inside the challenge window — which is the ONLY
/// correctness backstop the raw token allows (no checkpoints => no on-chain fraud proof of a snapshot).
export function buildManifest({
  chainId,
  distributor,
  token,
  epoch,
  prev,
  curr,
  barWei,
  exclusions = [],
  preferences = new Map(),
  baskets,
  defaultBasketId,
  usdgPot,
  reserved,
}) {
  const { weights, assigned, contributions } = planEpoch({
    prev,
    curr,
    barWei,
    exclusions,
    preferences,
    baskets,
    defaultBasketId,
    usdgPot,
  });
  const leaves = allocate({ epoch, holders: weights.holders, assigned, contributions, reserved });
  assertWithinReserved(leaves, reserved);
  const hashes = leaves.map(leafHash);
  const tree = buildTree(hashes);

  const manifest = {
    spec: SPEC,
    chainId: Number(chainId),
    distributor: getAddress(distributor),
    token: getAddress(token),
    epoch: String(epoch),
    snapshots: {
      prev: { block: String(prev.block), digest: snapshotDigest(prev) },
      curr: { block: String(curr.block), digest: snapshotDigest(curr) },
    },
    eligibility: {
      barWei: String(barWei),
      barMode: BAR_MODE,
      exclusions: exclusions.map(getAddress).sort(),
      eligibleHolders: weights.holders.length,
      totalWeight: String(weights.totalWeight),
    },
    usdgPot: String(usdgPot),
    baskets: serializeBaskets(baskets, defaultBasketId),
    preferences: [...preferences.entries()]
      .map(([holder, id]) => ({ holder: getAddress(holder), basketId: String(id) }))
      .sort((a, b) => (a.holder.toLowerCase() < b.holder.toLowerCase() ? -1 : 1)),
    reserved: [...reserved.entries()]
      .map(([t, v]) => ({ token: getAddress(t), amount: String(v) }))
      .sort((a, b) => (a.token.toLowerCase() < b.token.toLowerCase() ? -1 : 1)),
    leaves: leaves.map((l) => ({ holder: l.holder, token: l.token, amount: String(l.amount) })),
    root: tree.root,
  };
  return { manifest, tree, leaves, hashes, weights, assigned, contributions };
}

/// Recompute the root from ONLY what the manifest declares plus independently rebuilt snapshots.
/// Returns { ok, root, expected } — a challenger runs this and slashes on a mismatch.
export function verifyManifest(manifest, { prev, curr, baskets }) {
  if (manifest.spec !== SPEC) throw new Error(`manifest: unknown spec ${manifest.spec}`);
  if (String(prev.block) !== manifest.snapshots.prev.block) throw new Error("manifest: prev snapshot block mismatch");
  if (String(curr.block) !== manifest.snapshots.curr.block) throw new Error("manifest: curr snapshot block mismatch");
  const rebuilt = buildManifest({
    chainId: manifest.chainId,
    distributor: manifest.distributor,
    token: manifest.token,
    epoch: BigInt(manifest.epoch),
    prev,
    curr,
    barWei: BigInt(manifest.eligibility.barWei),
    exclusions: manifest.eligibility.exclusions,
    preferences: new Map(manifest.preferences.map((p) => [getAddress(p.holder), Number(p.basketId)])),
    baskets: baskets ?? deserializeBaskets(manifest.baskets),
    defaultBasketId: Number(manifest.baskets.defaultBasketId),
    usdgPot: BigInt(manifest.usdgPot),
    reserved: new Map(manifest.reserved.map((r) => [getAddress(r.token), BigInt(r.amount)])),
  });
  return { ok: rebuilt.manifest.root === manifest.root, root: rebuilt.manifest.root, expected: manifest.root };
}

/// Cheap offline check: do the manifest's own leaves actually hash to its own root?
export function verifyLeavesMatchRoot(manifest) {
  const hashes = manifest.leaves.map((l) =>
    leafHash({ epoch: BigInt(manifest.epoch), holder: l.holder, token: l.token, amount: BigInt(l.amount) }),
  );
  return buildTree(hashes).root === manifest.root;
}

export function proofsFor(manifest, holder) {
  const target = getAddress(holder);
  const hashes = manifest.leaves.map((l) =>
    leafHash({ epoch: BigInt(manifest.epoch), holder: l.holder, token: l.token, amount: BigInt(l.amount) }),
  );
  const tree = buildTree(hashes);
  return manifest.leaves
    .map((l, i) => ({ ...l, hash: hashes[i] }))
    .filter((l) => getAddress(l.holder) === target)
    .map((l) => ({ epoch: manifest.epoch, token: l.token, amount: l.amount, proof: proofFor(tree, l.hash) }));
}

export function snapshotDigest(snapshot) {
  const body = [...snapshot.balances.entries()]
    .sort(([a], [b]) => (a.toLowerCase() < b.toLowerCase() ? -1 : 1))
    .map(([a, v]) => `${a.toLowerCase()}:${v}`)
    .join("\n");
  return keccak256(toHex(`${snapshot.block}\n${body}`));
}

function serializeBaskets(baskets, defaultBasketId) {
  return {
    defaultBasketId: String(defaultBasketId),
    committed: [...baskets.entries()]
      .sort(([a], [b]) => Number(a) - Number(b))
      .map(([id, b]) => ({ id: String(id), tokens: b.tokens.map(getAddress), bps: b.bps.map(Number) })),
  };
}

function deserializeBaskets(serialized) {
  return new Map(serialized.committed.map((b) => [Number(b.id), { tokens: b.tokens, bps: b.bps }]));
}

export { deserializeBaskets };
