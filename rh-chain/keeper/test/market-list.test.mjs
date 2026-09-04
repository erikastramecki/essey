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
