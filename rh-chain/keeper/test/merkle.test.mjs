import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { buildTree, hashPair, leafHash, proofFor, verifyProof } from "../holder-airdrop/merkle.mjs";

const FIXTURE = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "test", "fixtures", "holder-airdrop-root.json");
const fixture = JSON.parse(readFileSync(FIXTURE, "utf8"));

const T = "0x1111111111111111111111111111111111111111";
const holder = (n) => `0x${n.toString(16).padStart(40, "0")}`;
const leaf = (n) => leafHash({ epoch: 0n, holder: holder(n), token: T, amount: BigInt(n) + 1n });

test("the pair hash is commutative — argument order cannot change a root", () => {
  const a = leaf(1);
  const b = leaf(2);
  assert.equal(hashPair(a, b), hashPair(b, a));
});

test("a leaf is bound to all four fields, so no field can be swapped in a proof", () => {
  const base = { epoch: 0n, holder: holder(1), token: T, amount: 5n };
  const h = leafHash(base);
  assert.notEqual(h, leafHash({ ...base, epoch: 1n }));
  assert.notEqual(h, leafHash({ ...base, holder: holder(2) }));
  assert.notEqual(h, leafHash({ ...base, token: holder(9) }));
  assert.notEqual(h, leafHash({ ...base, amount: 6n }));
});

test("a single-leaf tree is its own root and verifies with an empty proof", () => {
  const only = leaf(1);
  const tree = buildTree([only]);
  assert.equal(tree.root, only);
  assert.deepEqual(proofFor(tree, only), []);
  assert.equal(verifyProof(only, [], tree.root), true);
});

test("every leaf in an odd-sized tree still proves — the promoted node is not orphaned", () => {
  for (const n of [1, 2, 3, 5, 7, 9, 17, 33]) {
    const leaves = Array.from({ length: n }, (_, i) => leaf(i));
    const tree = buildTree(leaves);
    for (const l of leaves) {
      assert.equal(verifyProof(l, proofFor(tree, l), tree.root), true, `n=${n} leaf ${l} failed`);
    }
  }
});

test("a leaf not in the tree does not verify with another leaf's proof", () => {
  const leaves = [leaf(1), leaf(2), leaf(3)];
  const tree = buildTree(leaves);
  const forged = leaf(99);
  assert.equal(verifyProof(forged, proofFor(tree, leaves[0]), tree.root), false);
});

test("input order does not change the root — the tree sorts its leaves", () => {
  const leaves = [leaf(1), leaf(2), leaf(3), leaf(4), leaf(5)];
  const a = buildTree(leaves).root;
  const b = buildTree([...leaves].reverse()).root;
  const c = buildTree([leaves[2], leaves[0], leaves[4], leaves[1], leaves[3]]).root;
  assert.equal(a, b);
  assert.equal(a, c);
});

test("a duplicate leaf is REJECTED — the second copy would be an unclaimable dead entry", () => {
  assert.throws(() => buildTree([leaf(1), leaf(2), leaf(1)]), /duplicate leaf/);
});

test("an empty leaf set is rejected rather than producing a root nobody can claim against", () => {
  assert.throws(() => buildTree([]), /empty leaf set/);
});

test("changing one leaf changes the root", () => {
  const base = buildTree([leaf(1), leaf(2), leaf(3)]).root;
  const nudged = buildTree([leaf(1), leaf(2), leafHash({ epoch: 0n, holder: holder(2), token: T, amount: 4n })]).root;
  assert.notEqual(base, nudged);
});

test("the committed fixture still reproduces its own root and proofs", () => {
  const hashes = fixture.claims.map((c) =>
    leafHash({ epoch: BigInt(fixture.epoch), holder: c.holder, token: c.token, amount: BigInt(c.amount) }),
  );
  const tree = buildTree(hashes);
  assert.equal(tree.root, fixture.root, "fixture is stale — re-run make-fixture.mjs and re-run the Solidity test");
  for (const c of fixture.claims) {
    const h = leafHash({ epoch: BigInt(fixture.epoch), holder: c.holder, token: c.token, amount: BigInt(c.amount) });
    assert.equal(h, c.leaf);
    assert.equal(verifyProof(h, c.proof, fixture.root), true);
  }
});
