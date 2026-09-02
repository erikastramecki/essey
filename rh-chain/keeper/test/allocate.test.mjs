import assert from "node:assert/strict";
import { test } from "node:test";
import { allocate, apportion, assertWithinReserved, planBuys, resolveBaskets } from "../holder-airdrop/allocate.mjs";

const A = "0xAAaAaAaAAAaAaAAaAAaAaaAAAaAAaaAAAAaaAAaa";
const B = "0xbBbBBBBbbBBBbbbBbbBbbbbbBBbBbbbbBbBbbBBb";
const C = "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC";
const AAPL = "0x1111111111111111111111111111111111111111";
const NVDA = "0x2222222222222222222222222222222222222222";

const baskets = new Map([
  [0, { tokens: [AAPL, NVDA], bps: [5_000, 5_000] }],
  [1, { tokens: [NVDA], bps: [10_000] }],
]);
const holders = (...rows) => rows.map(([holder, weight]) => ({ holder, weight }));

test("apportion sums EXACTLY to the total, never over", () => {
  const parts = [
    { key: A, w: 1n },
    { key: B, w: 1n },
    { key: C, w: 1n },
  ];
  const out = apportion(100n, parts);
  assert.equal(out.reduce((s, o) => s + o.amount, 0n), 100n);
  assert.deepEqual(out.map((o) => o.amount).sort(), [33n, 33n, 34n]);
});

test("apportion gives the remainder to the largest fractional part, ties broken by key", () => {
  const out = apportion(10n, [
    { key: A, w: 1n },
    { key: B, w: 1n },
    { key: C, w: 1n },
  ]);
  assert.deepEqual(out, [{ key: A, amount: 4n }, { key: B, amount: 3n }, { key: C, amount: 3n }]);
});

test("apportion is deterministic: the same inputs give the same split every time", () => {
  const parts = [
    { key: A, w: 7n },
    { key: B, w: 11n },
    { key: C, w: 13n },
  ];
  const first = apportion(1_000_003n, parts);
  for (let i = 0; i < 20; i++) assert.deepEqual(apportion(1_000_003n, parts), first);
});

test("apportion with zero total weight allocates nothing rather than dividing by zero", () => {
  const out = apportion(100n, [
    { key: A, w: 0n },
    { key: B, w: 0n },
  ]);
  assert.deepEqual(out.map((o) => o.amount), [0n, 0n]);
});

test("an unknown or retired basket preference falls back to the default, it does not drop the holder", () => {
  const assigned = resolveBaskets({
    holders: holders([A, 10n], [B, 10n]),
    preferences: new Map([[A, 99]]),
    baskets,
    defaultBasketId: 0,
  });
  assert.equal(assigned.get(A), 0);
  assert.equal(assigned.get(B), 0);
});

test("a valid preference moves the holder into that basket", () => {
  const assigned = resolveBaskets({
    holders: holders([A, 10n]),
    preferences: new Map([[A, 1]]),
    baskets,
    defaultBasketId: 0,
  });
  assert.equal(assigned.get(A), 1);
});

test("an uncommitted default basket is refused at plan time", () => {
  assert.throws(
    () => resolveBaskets({ holders: holders([A, 1n]), baskets, defaultBasketId: 7 }),
    /default basket 7 is not committed/,
  );
});

test("the buy plan splits the pot by basket weight then by basket bps", () => {
  const assigned = new Map([
    [A, 0],
    [B, 1],
  ]);
  const { buys } = planBuys({ holders: holders([A, 1n], [B, 1n]), assigned, baskets, usdgPot: 1_000n });
  assert.deepEqual(buys, [
    { token: AAPL, usdg: 250n },
    { token: NVDA, usdg: 750n },
  ]);
});

test("the whole pot is planned — buy legs sum to the pot", () => {
  const assigned = new Map([
    [A, 0],
    [B, 1],
    [C, 0],
  ]);
  const { buys } = planBuys({ holders: holders([A, 3n], [B, 5n], [C, 7n]), assigned, baskets, usdgPot: 999_999n });
  assert.equal(buys.reduce((s, b) => s + b.usdg, 0n), 999_999n);
});

test("allocation attributes exactly what was reserved and never one wei more", () => {
  const assigned = new Map([
    [A, 0],
    [B, 0],
  ]);
  const { contributions } = planBuys({ holders: holders([A, 1n], [B, 3n]), assigned, baskets, usdgPot: 1_000n });
  const reserved = new Map([
    [AAPL, 400n],
    [NVDA, 401n],
  ]);
  const leaves = allocate({ epoch: 0n, holders: holders([A, 1n], [B, 3n]), assigned, contributions, reserved });
  const owed = assertWithinReserved(leaves, reserved);
  assert.equal(owed.get(AAPL), 400n);
  assert.equal(owed.get(NVDA), 401n);
  assert.equal(leaves.find((l) => l.holder === A && l.token === AAPL).amount, 100n);
  assert.equal(leaves.find((l) => l.holder === B && l.token === AAPL).amount, 300n);
});

test("a token bought for one basket is never handed to another basket's holders", () => {
  const assigned = new Map([
    [A, 0],
    [B, 1],
  ]);
  const { contributions } = planBuys({ holders: holders([A, 1n], [B, 1n]), assigned, baskets, usdgPot: 1_000n });
  const reserved = new Map([[AAPL, 1_000n]]);
  const leaves = allocate({ epoch: 0n, holders: holders([A, 1n], [B, 1n]), assigned, contributions, reserved });
  assert.deepEqual(
    leaves.map((l) => [l.holder, l.token, l.amount]),
    [[A, AAPL, 1_000n]],
  );
});

test("zero-amount legs are dropped — _settle reverts on amount 0 and would brick the batch", () => {
  const assigned = new Map([
    [A, 0],
    [B, 0],
  ]);
  const { contributions } = planBuys({ holders: holders([A, 1n], [B, 10n ** 30n]), assigned, baskets, usdgPot: 1_000n });
  const reserved = new Map([[AAPL, 5n]]);
  const leaves = allocate({
    epoch: 0n,
    holders: holders([A, 1n], [B, 10n ** 30n]),
    assigned,
    contributions,
    reserved,
  });
  assert.equal(leaves.some((l) => l.amount === 0n), false);
  assert.equal(leaves.some((l) => l.holder === A), false);
});

test("leaves come out in canonical (token, holder) order for any holder ordering", () => {
  const assigned = new Map([
    [A, 0],
    [B, 0],
    [C, 0],
  ]);
  const rows = holders([C, 1n], [A, 1n], [B, 1n]);
  const { contributions } = planBuys({ holders: rows, assigned, baskets, usdgPot: 1_000n });
  const reserved = new Map([
    [AAPL, 300n],
    [NVDA, 300n],
  ]);
  const leaves = allocate({ epoch: 0n, holders: rows, assigned, contributions, reserved });
  assert.deepEqual(
    leaves.map((l) => `${l.token}:${l.holder}`),
    [`${AAPL}:${A}`, `${AAPL}:${B}`, `${AAPL}:${C}`, `${NVDA}:${A}`, `${NVDA}:${B}`, `${NVDA}:${C}`],
  );
});

test("assertWithinReserved catches an over-attributed token", () => {
  const reserved = new Map([[AAPL, 100n]]);
  const leaves = [
    { epoch: 0n, holder: A, token: AAPL, amount: 60n },
    { epoch: 0n, holder: B, token: AAPL, amount: 41n },
  ];
  assert.throws(() => assertWithinReserved(leaves, reserved), /over-attributes/);
});
