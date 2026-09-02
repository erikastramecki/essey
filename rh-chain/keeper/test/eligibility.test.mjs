import assert from "node:assert/strict";
import { test } from "node:test";
import { computeWeights, resolveBar } from "../holder-airdrop/eligibility.mjs";

const A = "0x1111111111111111111111111111111111111111";
const B = "0x2222222222222222222222222222222222222222";
const C = "0x3333333333333333333333333333333333333333";
const ZERO = "0x0000000000000000000000000000000000000000";
const BAR = 8_888_888_888_000_000_000_000_000n; // 0.1% of 8_888_888_888e18

const snap = (block, entries) => ({ block: BigInt(block), balances: new Map(entries) });
const weightOf = (result, holder) => result.holders.find((h) => h.holder === holder)?.weight ?? null;

test("credits the MINIMUM of the two snapshots, not the later one", () => {
  const r = computeWeights({
    prev: snap(100, [[A, BAR * 3n]]),
    curr: snap(200, [[A, BAR * 10n]]),
    barWei: BAR,
  });
  assert.equal(weightOf(r, A), BAR * 3n);
});

test("credits the MINIMUM when the balance fell, not the earlier one", () => {
  const r = computeWeights({
    prev: snap(100, [[A, BAR * 10n]]),
    curr: snap(200, [[A, BAR * 3n]]),
    barWei: BAR,
  });
  assert.equal(weightOf(r, A), BAR * 3n);
});

test("a wallet that only appears at the second snapshot earns NOTHING", () => {
  const r = computeWeights({
    prev: snap(100, [[A, BAR]]),
    curr: snap(200, [
      [A, BAR],
      [B, BAR * 1000n],
    ]),
    barWei: BAR,
  });
  assert.equal(weightOf(r, B), null);
  assert.deepEqual(
    r.holders.map((h) => h.holder),
    [A],
  );
  assert.equal(r.totalWeight, BAR);
});

test("a wallet that exits before the second snapshot earns NOTHING", () => {
  const r = computeWeights({
    prev: snap(100, [
      [A, BAR],
      [B, BAR * 1000n],
    ]),
    curr: snap(200, [[A, BAR]]),
    barWei: BAR,
  });
  assert.equal(weightOf(r, B), null);
  assert.equal(r.totalWeight, BAR);
});

test("exactly at the bar is ELIGIBLE and one wei under is NOT", () => {
  const r = computeWeights({
    prev: snap(100, [
      [A, BAR],
      [B, BAR - 1n],
    ]),
    curr: snap(200, [
      [A, BAR],
      [B, BAR - 1n],
    ]),
    barWei: BAR,
  });
  assert.equal(weightOf(r, A), BAR);
  assert.equal(weightOf(r, B), null);
});

test("the bar is applied to the GATED weight, not to either raw balance", () => {
  const r = computeWeights({
    prev: snap(100, [[A, BAR * 5n]]),
    curr: snap(200, [[A, BAR - 1n]]),
    barWei: BAR,
  });
  assert.equal(weightOf(r, A), null);
});

test("the zero address is excluded even when it is never named", () => {
  const r = computeWeights({
    prev: snap(100, [
      [ZERO, BAR * 100n],
      [A, BAR],
    ]),
    curr: snap(200, [
      [ZERO, BAR * 100n],
      [A, BAR],
    ]),
    barWei: BAR,
  });
  assert.deepEqual(
    r.holders.map((h) => h.holder),
    [A],
  );
});

test("configured exclusions leave the denominator, they do not merely get zero", () => {
  const withPool = computeWeights({
    prev: snap(100, [
      [A, BAR],
      [C, BAR * 9n],
    ]),
    curr: snap(200, [
      [A, BAR],
      [C, BAR * 9n],
    ]),
    barWei: BAR,
  });
  const withoutPool = computeWeights({
    prev: snap(100, [
      [A, BAR],
      [C, BAR * 9n],
    ]),
    curr: snap(200, [
      [A, BAR],
      [C, BAR * 9n],
    ]),
    barWei: BAR,
    exclusions: [C],
  });
  assert.equal(withPool.totalWeight, BAR * 10n);
  assert.equal(withoutPool.totalWeight, BAR);
  assert.equal(withoutPool.holders.length, 1);
});

test("snapshots supplied out of order are REJECTED, never silently reordered", () => {
  assert.throws(
    () => computeWeights({ prev: snap(200, [[A, BAR]]), curr: snap(100, [[A, BAR]]), barWei: BAR }),
    /out of order/,
  );
  assert.throws(
    () => computeWeights({ prev: snap(100, [[A, BAR]]), curr: snap(100, [[A, BAR]]), barWei: BAR }),
    /out of order/,
  );
});

test("holder order is canonical and independent of map insertion order", () => {
  const forward = computeWeights({
    prev: snap(1, [
      [C, BAR],
      [A, BAR],
      [B, BAR],
    ]),
    curr: snap(2, [
      [B, BAR],
      [C, BAR],
      [A, BAR],
    ]),
    barWei: BAR,
  });
  assert.deepEqual(
    forward.holders.map((h) => h.holder),
    [A, B, C],
  );
});

test("resolveBar: 10 bps of the on-chain supply is the founder's 0.1% bar", () => {
  assert.equal(resolveBar({ barBps: 10, totalSupply: 8_888_888_888n * 10n ** 18n }), BAR);
  assert.equal(resolveBar({ barWei: 123n, barBps: 10, totalSupply: 1n }), 123n);
  assert.throws(() => resolveBar({ barBps: 10 }), /totalSupply/);
});

test("a zero or negative bar is rejected — it would make every dust wallet eligible", () => {
  assert.throws(() => computeWeights({ prev: snap(1, []), curr: snap(2, []), barWei: 0n }), /bar must be positive/);
});
