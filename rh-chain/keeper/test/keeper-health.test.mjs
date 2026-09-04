import assert from "node:assert/strict";
import { test } from "node:test";
import { classifyMarket, priceReadable } from "../keeper-health.mjs";

const AAPL = "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9";

// The deployed constants: EsseyMarkets.PRICE_CONFIRM_DELAY / MAX_CONFIRM_AGE / MAX_BASELINE_AGE.
const NOW = 1_800_000_000n;
const CONST = { now: NOW, delay: 21_600n, maxAge: 32_400n, maxBaseline: 3_600n };
const at = (o) => ({ token: AAPL, ...CONST, ...o });
const fatals = (r) => r.filter((f) => f.fatal).map((f) => f.line);
const infos = (r) => r.filter((f) => !f.fatal).map((f) => f.line);

test("a keeper observing a readable feed says nothing at all", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - 300n, priceReadable: true }));
  assert.deepEqual(r, []);
});

// THE R6 LOW-1 CASE, with the numbers measured on the fork: a healthy weekend, keeper observing on
// its 300s tick throughout, feed dark. `confirmedObservedAt` age 24,900s (inside the 32,400s
// ceiling — the delay line is being warmed) against `seenPriceAt` age 108,000s. This exited 1 for
// ~40h of every 168h, and an alarm that is red a quarter of the time gets muted.
test("a dark feed under an observing keeper is reported, not alarmed", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - 108_000n, priceReadable: false }));
  assert.deepEqual(fatals(r), []);
  assert.equal(infos(r).length, 1);
  assert.match(infos(r)[0], /FEED DARK/);
  assert.match(infos(r)[0], /the keeper IS calling/);
});

// The mute must not cost the signal it was muting. Same stale baseline, but the price READS — so the
// keeper is not reading a feed that is answering, which is the actual failure BREAKER BLIND names.
test("the same stale baseline while the price reads stays fatal", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - 108_000n, priceReadable: true }));
  assert.equal(fatals(r).length, 1);
  assert.match(fatals(r)[0], /BREAKER BLIND/);
  assert.match(fatals(r)[0], /the price READS/);
});

// R4 HIGH-2's world, and the one the downgrade must never swallow: the keeper has stopped calling.
// The corroborated observation ages past the ceiling whether or not the feed is dark.
test("a keeper that stopped observing is fatal even while the feed is dark", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 200_000n, seenAt: NOW - 200_000n, priceReadable: false }));
  assert.equal(fatals(r).length, 1);
  assert.match(fatals(r)[0], /UNOBSERVED/);
  assert.match(infos(r)[0], /the stopped keeper UNOBSERVED already names/);
});

test("a keeper that stopped observing a READABLE feed raises both", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 200_000n, seenAt: NOW - 200_000n, priceReadable: true }));
  assert.equal(fatals(r).length, 2);
  assert.match(fatals(r)[0], /UNOBSERVED/);
  assert.match(fatals(r)[1], /BREAKER BLIND/);
});

test("a market whose delay line has never filled is fatal and says nothing else", () => {
  const r = classifyMarket(at({ confirmedAt: 0n, seenAt: 0n, priceReadable: false }));
  assert.equal(r.length, 1);
  assert.match(fatals(r)[0], /UNCORROBORATED/);
});

// The ring running AHEAD of its own cadence should be impossible; it is fatal so it is visible.
test("a corroborated observation younger than the delay is fatal", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 100n, seenAt: NOW - 100n, priceReadable: true }));
  assert.equal(fatals(r).length, 1);
  assert.match(fatals(r)[0], /PREMATURE/);
});

// Both ceilings at their exact boundary, in both directions, because "inside the window" is the
// whole verdict and an off-by-one in either flips a market between silent and unliquidatable.
test("the age ceiling is inclusive and one second past it is not", () => {
  assert.deepEqual(fatals(classifyMarket(at({ confirmedAt: NOW - 32_400n, seenAt: NOW - 300n, priceReadable: true }))), []);
  assert.match(
    fatals(classifyMarket(at({ confirmedAt: NOW - 32_401n, seenAt: NOW - 300n, priceReadable: true })))[0],
    /UNOBSERVED/,
  );
});

test("the baseline ceiling is inclusive and one second past it is not", () => {
  assert.deepEqual(fatals(classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - 3_600n, priceReadable: true }))), []);
  assert.match(
    fatals(classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - 3_601n, priceReadable: true })))[0],
    /BREAKER BLIND/,
  );
});

test("the delay floor is inclusive at the boundary", () => {
  assert.deepEqual(fatals(classifyMarket(at({ confirmedAt: NOW - 21_600n, seenAt: NOW - 300n, priceReadable: true }))), []);
  assert.match(
    fatals(classifyMarket(at({ confirmedAt: NOW - 21_599n, seenAt: NOW - 300n, priceReadable: true })))[0],
    /PREMATURE/,
  );
});

const revert = () => Promise.reject(new Error("PriceStale(96000, 90000, false)"));
const transport = () => Promise.reject(new Error("HTTP request failed: 503"));

test("a price the registry answers reads as readable", async () => {
  assert.equal(await priceReadable(async () => [1n, 8, true], () => assert.fail("not probed")), true);
});

// The registry's own freshness bound, not a heuristic: `priceOf` reverting IS the state `_syncPrice`
// records nothing for, and the probe proves the node was answering when it did.
test("a revert with the node still answering reads as not readable", async () => {
  assert.equal(await priceReadable(revert, async () => 1n), false);
});

// The fail-OPEN this seam would otherwise be. Swallowing a dead RPC as "not readable" downgrades
// BREAKER BLIND on a hiccup, on the one check R4 HIGH-2 was closed with.
test("a transport failure propagates instead of reading as not readable", async () => {
  await assert.rejects(() => priceReadable(revert, transport), /503/);
});

test("a transport failure on the first read propagates too", async () => {
  await assert.rejects(() => priceReadable(transport, transport), /503/);
});
