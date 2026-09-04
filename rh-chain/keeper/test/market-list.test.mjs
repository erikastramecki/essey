import assert from "node:assert/strict";
import { test } from "node:test";
import { reconcileMarkets } from "../market-list.mjs";

const AAPL = "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9";
const NVDA = "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC";
const STRANGER = "0x000000000000000000000000000000000000dEaD";

// THE R4 HIGH-2 CASE. A hand-typed list holding one of two committed markets used to produce no
// warning at all, and the market it omitted stopped being observed.
test("a committed market missing from the env list is observed anyway, and named", () => {
  const r = reconcileMarkets({ discovered: [AAPL, NVDA], configured: [AAPL] });
  assert.deepEqual(r.tokens, [AAPL, NVDA]);
  assert.deepEqual(r.missing, [NVDA]);
  assert.deepEqual(r.unknown, []);
});

test("an env address the registry never committed is dropped, and named", () => {
  const r = reconcileMarkets({ discovered: [AAPL], configured: [AAPL, STRANGER] });
  assert.deepEqual(r.tokens, [AAPL]);
  assert.deepEqual(r.unknown, [STRANGER]);
});

// The runbook produced this state on every market: ESSEY_MARKETS set, MARKET_TOKENS never mentioned.
test("an empty env list still observes every committed market", () => {
  const r = reconcileMarkets({ discovered: [AAPL, NVDA], configured: [] });
  assert.deepEqual(r.tokens, [AAPL, NVDA]);
  assert.deepEqual(r.missing, [AAPL, NVDA]);
});

test("checksum and lowercase spellings of the same address are one market", () => {
  const r = reconcileMarkets({ discovered: [AAPL, AAPL.toLowerCase()], configured: [AAPL.toLowerCase()] });
  assert.deepEqual(r.tokens, [AAPL]);
  assert.deepEqual(r.missing, []);
  assert.deepEqual(r.unknown, []);
});

// A registry with nothing committed must be distinguishable from a healthy one by the caller.
test("no committed markets yields an empty duty", () => {
  const r = reconcileMarkets({ discovered: [], configured: [AAPL] });
  assert.deepEqual(r.tokens, []);
  assert.deepEqual(r.unknown, [AAPL]);
});

// THE R5 MED-2 CASE, and the one every case above shares a blind spot for: they all pass a COMPLETE
// `discovered`. A short-but-successful scan is the failure mode nothing here could see, because the
// supervisor derived its subject from the same query and passed `configured: []` besides.
test("a SHORT scan is named, and the market it omitted is still inspected", () => {
  const r = reconcileMarkets({ discovered: [AAPL], configured: [AAPL, NVDA] });
  assert.deepEqual(r.tokens, [AAPL], "the keeper's chain-derived duty is still what the scan returned");
  assert.deepEqual(r.unknown, [NVDA], "and the disagreement is named");
  assert.deepEqual(r.inspect, [AAPL, NVDA], "but a supervisor inspects both");
});

test("inspect is the union in both directions, and never duplicates a market", () => {
  const r = reconcileMarkets({ discovered: [AAPL, NVDA], configured: [AAPL, STRANGER] });
  assert.deepEqual(r.inspect, [AAPL, NVDA, STRANGER]);
  assert.deepEqual(r.missing, [NVDA], "committed, not declared");
  assert.deepEqual(r.unknown, [STRANGER], "declared, not returned by the scan");
});

test("inspect folds the two spellings of one address into one market", () => {
  const r = reconcileMarkets({ discovered: [AAPL], configured: [AAPL.toLowerCase(), NVDA] });
  assert.deepEqual(r.inspect, [AAPL, NVDA], "not three entries");
});

test("with the scan complete and the list matching it, there is nothing extra to inspect", () => {
  const r = reconcileMarkets({ discovered: [AAPL, NVDA], configured: [NVDA, AAPL] });
  assert.deepEqual(r.inspect, [AAPL, NVDA]);
  assert.deepEqual(r.missing, []);
  assert.deepEqual(r.unknown, []);
});
