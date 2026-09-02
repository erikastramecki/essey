import assert from "node:assert/strict";
import { test } from "node:test";
import { BOOTSTRAP, CADENCE_CHAIN, CADENCE_LOCAL, DUST, READY, canPost, decideRun } from "../holder-airdrop/epoch.mjs";

const base = {
  now: 1_000_000,
  prevSnapshotBlock: 500n,
  lastRootAt: 900_000n,
  minEpochInterval: 43_200n,
  lastSnapshotAt: 900_000,
  epochSeconds: 43_200,
  pot: 10_000_000n,
  minPotUsdg: 1_000_000n,
};

test("runs when the cadence has elapsed and the pot clears the floor", () => {
  assert.deepEqual(decideRun(base), { run: true, reason: READY });
});

test("the FIRST run posts nothing — the gate needs a previous snapshot to compare against", () => {
  assert.deepEqual(decideRun({ ...base, prevSnapshotBlock: null }), { run: false, reason: BOOTSTRAP });
  assert.deepEqual(decideRun({ ...base, prevSnapshotBlock: undefined }), { run: false, reason: BOOTSTRAP });
});

test("a zero previous snapshot block is a real snapshot, not a missing one", () => {
  assert.equal(decideRun({ ...base, prevSnapshotBlock: 0n }).run, true);
});

test("holds off while postRoot would revert TooEarly on the chain's own cadence rail", () => {
  assert.equal(decideRun({ ...base, now: 943_199 }).reason, CADENCE_CHAIN);
  assert.equal(decideRun({ ...base, now: 943_200, lastSnapshotAt: 900_000 }).run, true);
});

test("holds off while the configured epoch interval has not elapsed", () => {
  assert.equal(decideRun({ ...base, lastRootAt: 0n, lastSnapshotAt: 999_999 }).reason, CADENCE_LOCAL);
  assert.equal(decideRun({ ...base, lastRootAt: 0n, lastSnapshotAt: 956_800 }).run, true);
});

test("a pot below the buy-side floor does not buy dust-sized stock", () => {
  assert.equal(decideRun({ ...base, pot: 999_999n }).reason, DUST);
  assert.equal(decideRun({ ...base, pot: 1_000_000n }).run, true);
});

test("canPost: the named keeper may post with a bond", () => {
  const r = canPost({
    sender: "0xAbC0000000000000000000000000000000000001",
    keeper: "0xabc0000000000000000000000000000000000001",
    bond: 1n,
    minBond: 1n,
    now: 0,
    lastKeeperRootAt: 0,
    keeperGrace: 86_400,
  });
  assert.deepEqual(r, { ok: true, reason: READY });
});

test("canPost: an under-bonded keeper is refused before it wastes a revert", () => {
  const r = canPost({
    sender: "0xabc0000000000000000000000000000000000001",
    keeper: "0xabc0000000000000000000000000000000000001",
    bond: 0n,
    minBond: 1n,
    now: 0,
    lastKeeperRootAt: 0,
    keeperGrace: 86_400,
  });
  assert.equal(r.ok, false);
  assert.match(r.reason, /below minBond/);
});

test("canPost: a stranger must wait out the keeper grace before the fallback opens", () => {
  const args = {
    sender: "0xDEF0000000000000000000000000000000000002",
    keeper: "0xabc0000000000000000000000000000000000001",
    bond: 5n,
    minBond: 1n,
    lastKeeperRootAt: 1_000,
    keeperGrace: 86_400,
  };
  assert.equal(canPost({ ...args, now: 87_399 }).ok, false);
  assert.equal(canPost({ ...args, now: 87_400 }).ok, true);
});
