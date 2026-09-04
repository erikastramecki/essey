import assert from "node:assert/strict";
import { test } from "node:test";
import { ContractFunctionExecutionError, ContractFunctionRevertedError } from "viem";
import { classifyMarket, MAX_DARK_AGE, priceState, revertName } from "../keeper-health.mjs";

const AAPL = "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9";

// The deployed constants: EsseyMarkets.PRICE_CONFIRM_DELAY / MAX_CONFIRM_AGE / MAX_BASELINE_AGE.
const NOW = 1_800_000_000n;
const CONST = { now: NOW, delay: 21_600n, maxAge: 32_400n, maxBaseline: 3_600n, maxDark: MAX_DARK_AGE };

// The registry answering, and the registry refusing for the ONE reason that is the exchange calendar.
const READS = { readable: true, revert: null };
const WEEKEND = { readable: false, revert: "PriceStale" };
const at = (o) => ({ token: AAPL, ...CONST, ...o });
const fatals = (r) => r.filter((f) => f.fatal).map((f) => f.line);
const infos = (r) => r.filter((f) => !f.fatal).map((f) => f.line);

test("a keeper observing a readable feed says nothing at all", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - 300n, price: READS }));
  assert.deepEqual(r, []);
});

// THE R6 LOW-1 CASE, with the numbers measured on the fork: a healthy weekend, keeper observing on
// its 300s tick throughout, feed dark. `confirmedObservedAt` age 24,900s (inside the 32,400s
// ceiling — the delay line is being warmed) against `seenPriceAt` age 108,000s. This exited 1 for
// ~40h of every 168h, and an alarm that is red a quarter of the time gets muted.
test("a dark feed under an observing keeper is reported, not alarmed", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - 108_000n, price: WEEKEND }));
  assert.deepEqual(fatals(r), []);
  assert.equal(infos(r).length, 1);
  assert.match(infos(r)[0], /FEED DARK/);
  assert.match(infos(r)[0], /the keeper IS calling/);
});

// The mute must not cost the signal it was muting. Same stale baseline, but the price READS — so the
// keeper is not reading a feed that is answering, which is the actual failure BREAKER BLIND names.
test("the same stale baseline while the price reads stays fatal", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - 108_000n, price: READS }));
  assert.equal(fatals(r).length, 1);
  assert.match(fatals(r)[0], /BREAKER BLIND/);
  assert.match(fatals(r)[0], /the price READS/);
});

// R4 HIGH-2's world, and the one the downgrade must never swallow: the keeper has stopped calling.
// The corroborated observation ages past the ceiling whether or not the feed is dark.
test("a keeper that stopped observing is fatal even while the feed is dark", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 200_000n, seenAt: NOW - 200_000n, price: WEEKEND }));
  assert.equal(fatals(r).length, 1);
  assert.match(fatals(r)[0], /UNOBSERVED/);
  assert.match(infos(r)[0], /the stopped keeper UNOBSERVED already names/);
});

test("a keeper that stopped observing a READABLE feed raises both", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 200_000n, seenAt: NOW - 200_000n, price: READS }));
  assert.equal(fatals(r).length, 2);
  assert.match(fatals(r)[0], /UNOBSERVED/);
  assert.match(fatals(r)[1], /BREAKER BLIND/);
});

test("a market whose delay line has never filled is fatal and says nothing else", () => {
  const r = classifyMarket(at({ confirmedAt: 0n, seenAt: 0n, price: WEEKEND }));
  assert.equal(r.length, 1);
  assert.match(fatals(r)[0], /UNCORROBORATED/);
});

// The ring running AHEAD of its own cadence should be impossible; it is fatal so it is visible.
test("a corroborated observation younger than the delay is fatal", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 100n, seenAt: NOW - 100n, price: READS }));
  assert.equal(fatals(r).length, 1);
  assert.match(fatals(r)[0], /PREMATURE/);
});

// Both ceilings at their exact boundary, in both directions, because "inside the window" is the
// whole verdict and an off-by-one in either flips a market between silent and unliquidatable.
test("the age ceiling is inclusive and one second past it is not", () => {
  assert.deepEqual(fatals(classifyMarket(at({ confirmedAt: NOW - 32_400n, seenAt: NOW - 300n, price: READS }))), []);
  assert.match(
    fatals(classifyMarket(at({ confirmedAt: NOW - 32_401n, seenAt: NOW - 300n, price: READS })))[0],
    /UNOBSERVED/,
  );
});

test("the baseline ceiling is inclusive and one second past it is not", () => {
  assert.deepEqual(fatals(classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - 3_600n, price: READS }))), []);
  assert.match(
    fatals(classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - 3_601n, price: READS })))[0],
    /BREAKER BLIND/,
  );
});

test("the delay floor is inclusive at the boundary", () => {
  assert.deepEqual(fatals(classifyMarket(at({ confirmedAt: NOW - 21_600n, seenAt: NOW - 300n, price: READS }))), []);
  assert.match(
    fatals(classifyMarket(at({ confirmedAt: NOW - 21_599n, seenAt: NOW - 300n, price: READS })))[0],
    /PREMATURE/,
  );
});

// R7 LOW-1 A. The downgrade used to have no upper bound at all: 40h / 80h / 168h / 720h / 8760h all
// exited 0 printing "this is the 24/5 feed's own schedule". Both sides of the ceiling, because the
// number decides whether a fortnight of a frozen market is reported or alarmed.
test("a dark feed at the calendar ceiling is still reported", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - MAX_DARK_AGE, price: WEEKEND }));
  assert.deepEqual(fatals(r), []);
  assert.match(infos(r)[0], /FEED DARK {2}the price is unreadable/);
});

test("one second past the calendar ceiling it is fatal", () => {
  const r = classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - MAX_DARK_AGE - 1n, price: WEEKEND }));
  assert.equal(fatals(r).length, 1);
  assert.match(fatals(r)[0], /FEED DARK TOO LONG/);
  assert.deepEqual(infos(r), []);
});

// The PoC's own durations. 79.74h is the worst gap either listed feed has produced and the longest
// closure the exchange calendar can make; everything past four days is not a schedule.
test("the durations the round-7 PoC walked are alarmed above four days", () => {
  const hours = (h) => fatals(classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - BigInt(h) * 3_600n, price: WEEKEND })));
  assert.deepEqual(hours(40), []);
  assert.deepEqual(hours(80), []);
  for (const h of [168, 720, 8_760]) assert.match(hours(h)[0], /FEED DARK TOO LONG/);
});

// R7 LOW-1 B. `priceOf` refuses four reachable ways and only ONE of them is the weekend. The other
// three are a silent or misconfigured aggregator — the failure StaleFeedGuard exists to catch — and
// the feed is append-only, so this alarm is the whole of the operator's warning.
test("only PriceStale is the exchange calendar; the other refusals are fatal", () => {
  const refusal = (name) => classifyMarket(at({
    confirmedAt: NOW - 24_900n, seenAt: NOW - 14_400n, price: { readable: false, revert: name },
  }));
  assert.deepEqual(fatals(refusal("PriceStale")), []);
  for (const name of ["PriceNotPositive", "RoundIncomplete", "FeedNotConfigured"]) {
    const f = fatals(refusal(name));
    assert.equal(f.length, 1);
    assert.match(f[0], /FEED BROKEN/);
    assert.match(f[0], new RegExp(`refuses with ${name}`));
  }
});

// A revert nobody has classified — a new registry error, or the asymmetric transport failure the
// same-contract probe cannot settle — must not inherit the weekend's exemption.
test("a refusal with no decodable registry error is fatal, not dark", () => {
  const r = classifyMarket(at({
    confirmedAt: NOW - 24_900n, seenAt: NOW - 14_400n, price: { readable: false, revert: null },
  }));
  assert.match(fatals(r)[0], /FEED BROKEN {2}priceOf refuses with no decodable registry error/);
});

// Comparing a duration against `undefined` is silently false forever, which is the fail-open this
// finding IS. Refuse to classify instead.
test("classifying without a ceiling throws rather than never alarming", () => {
  assert.throws(
    () => classifyMarket({ token: AAPL, ...CONST, maxDark: undefined, confirmedAt: NOW - 24_900n, seenAt: NOW - 999_999n, price: WEEKEND }),
    /maxDark/,
  );
});

// Real viem errors, built the way `readContract` builds them, because the decode is the finding: the
// name is present ONLY when the ABI carries the error definition (verified against a live anvil
// revert, receipt gate-receipts/glend-r7-fixes).
const ABI = [
  { type: "function", name: "priceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "error", name: "PriceStale", inputs: [{ type: "uint256" }, { type: "uint256" }, { type: "bool" }] },
  { type: "error", name: "PriceNotPositive", inputs: [{ type: "int256" }] },
];
const PRICE_STALE = "0xa97df0c700000000000000000000000000000000000000000000000000000000000177000000000000000000000000000000000000000000000000000000000000015f900000000000000000000000000000000000000000000000000000000000000000";
const ROUND_INCOMPLETE = "0x69a81429"; // deliberately NOT in ABI above
const viemRevert = (data) =>
  new ContractFunctionExecutionError(new ContractFunctionRevertedError({ abi: ABI, data, functionName: "priceOf" }), {
    abi: ABI, functionName: "priceOf", args: [AAPL],
  });
const reverts = (data) => () => Promise.reject(viemRevert(data));
const transport = () => Promise.reject(new Error("HTTP request failed: 503"));

test("a price the registry answers reads as readable", async () => {
  assert.deepEqual(await priceState(async () => [1n, 8, true], () => assert.fail("not probed")), READS);
});

// The registry's own freshness bound, not a heuristic: `priceOf` reverting IS the state `_syncPrice`
// records nothing for, and the probe proves the node was answering when it did.
test("a revert with the node still answering reads as not readable, and names itself", async () => {
  assert.deepEqual(await priceState(reverts(PRICE_STALE), async () => 1n), WEEKEND);
});

test("a revert the ABI cannot decode is not readable and not named", async () => {
  assert.deepEqual(await priceState(reverts(ROUND_INCOMPLETE), async () => 1n), { readable: false, revert: null });
});

test("revertName reads the decoded name out of viem's own error chain", () => {
  assert.equal(revertName(viemRevert(PRICE_STALE)), "PriceStale");
  assert.equal(revertName(new Error("PriceStale(96000, 90000, false)")), null);
});

// The fail-OPEN this seam would otherwise be. Swallowing a dead RPC as "not readable" downgrades
// BREAKER BLIND on a hiccup, on the one check R4 HIGH-2 was closed with.
test("a transport failure propagates instead of reading as not readable", async () => {
  await assert.rejects(() => priceState(reverts(PRICE_STALE), transport), /503/);
});

test("a transport failure on the first read propagates too", async () => {
  await assert.rejects(() => priceState(transport, transport), /503/);
});

// The asymmetric case the probe CANNOT settle (R7 LOW-1's caution): the heavy `priceOf` failing on
// transport while the one-SLOAD `seenPriceAt` succeeds. It used to read as the weekend.
test("a transport failure the cheap probe survives is unreadable and unnamed, so it alarms", async () => {
  const price = await priceState(transport, async () => 1n);
  assert.deepEqual(price, { readable: false, revert: null });
  assert.match(fatals(classifyMarket(at({ confirmedAt: NOW - 24_900n, seenAt: NOW - 14_400n, price })))[0], /FEED BROKEN/);
});
