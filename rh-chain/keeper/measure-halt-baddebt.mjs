// What a liquidation OUTAGE costs, in dollars, as a function of the position cap.
//
// Sibling of measure-feed-volatility.mjs, which asks "how far does this name move inside a window
// this long". This one asks the next question: a policy that REFUSES to liquidate for H hours puts a
// book at the threshold on the wrong side of exactly such a window, so how much of the book stops
// being covered by its own collateral. Every input below is either read off the chain here or read
// off a deployed constant with its file:line — nothing is assumed except where the output says so.
//
//   node keeper/measure-halt-baddebt.mjs
//
// Two traps inherited from the sibling and re-checked here: both feeds answer their first ~20 rounds
// on a 1e18 scale before switching to the 1e8 decimals() reports, and the public RPC rate-limits.

const RPC = "https://rpc.mainnet.chain.robinhood.com";
const SEL_ROUND = "0x9a6fc8f5"; // getRoundData(uint80)
const SEL_LATEST = "0xfeaf968c"; // latestRoundData()
const PHASE = 1n << 64n;

// script/DeployMarkets.s.sol:391-396 — the parameters actually proposed for AAPL and NVDA.
const LTV_BPS = 5_000;
const LIQ_THRESHOLD_BPS = 7_500;
const LIQ_BONUS_BPS = 500;
const CAP_USDG = 250_000;
const MAX_POSITION_BPS = 2_000;

// src/EsseyMarkets.sol:401,409,416 — the corroboration design's delay, step and ceiling.
const PRICE_CONFIRM_DELAY_H = 6;
const CONFIRM_STEP_H = 1.5;
// src/EsseyMarkets.sol:399 — the contract's own ceiling on one pauseLiquidation call.
const MAX_LIQUIDATION_PAUSE_H = 24;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function rpc(calls) {
  for (let attempt = 0; attempt < 12; attempt++) {
    const res = await fetch(RPC, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(calls),
    });
    if (res.ok) return res.json();
    await sleep(2000 * (attempt + 1));
  }
  throw new Error("rpc gave up");
}

function decode(hex) {
  const b = hex.slice(2);
  const w = (i) => BigInt("0x" + b.slice(i * 64, i * 64 + 64));
  return { roundId: w(0) & ((1n << 64n) - 1n), answer: w(1), updatedAt: w(3) };
}

async function latestRound(feed) {
  const [r] = await rpc([{ jsonrpc: "2.0", id: 0, method: "eth_call", params: [{ to: feed, data: SEL_LATEST }, "latest"] }]);
  return Number(decode(r.result).roundId);
}

import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";

/// The public RPC rate-limits hard enough that a full two-feed walk fails partway through, so the
/// walk is cached. Delete keeper/.feedcache to force a refetch; the file records the latest round it
/// covers, and a newer latest round refetches on its own.
function cached(name, latest, fn) {
  const dir = "keeper/.feedcache";
  const path = `${dir}/${name}-${latest}.json`;
  if (existsSync(path)) return JSON.parse(readFileSync(path, "utf8"));
  return fn().then((v) => {
    mkdirSync(dir, { recursive: true });
    writeFileSync(path, JSON.stringify(v));
    return v;
  });
}

async function walk(feed, latest) {
  const out = [];
  for (let i = 0; i < latest; i += 10) {
    const calls = [];
    for (let j = 0; j < 10 && i + j < latest; j++) {
      const r = PHASE + BigInt(latest - i - j);
      calls.push({
        jsonrpc: "2.0",
        id: i + j,
        method: "eth_call",
        params: [{ to: feed, data: SEL_ROUND + (r).toString(16).padStart(64, "0") }, "latest"],
      });
    }
    const rs = await rpc(calls);
    await sleep(400);
    for (const r of rs) {
      if (!r.result || r.result === "0x") continue;
      const d = decode(r.result);
      if (d.updatedAt === 0n) continue;
      out.push({ t: Number(d.updatedAt), p: Number(d.answer) / 1e8 });
    }
  }
  out.sort((a, b) => a.t - b.t);
  return out.map((r) => ({ t: r.t, p: r.p > 10_000 ? r.p / 1e8 : r.p }));
}

// ---------------------------------------------------------------- risk algebra

// A position exactly at the liquidation threshold holds collateral worth 1/0.75 of its debt.
const CUSHION_AT_THRESHOLD = 10_000 / LIQ_THRESHOLD_BPS;
// Where a rational liquidator stops: seizing debt+bonus needs collateral worth 1.05x the debt.
const INDIFFERENCE_DROP = 1 - (1 + LIQ_BONUS_BPS / 10_000) / CUSHION_AT_THRESHOLD;
// Where the loss starts: collateral worth less than the debt itself.
const BAD_DEBT_ONSET_DROP = 1 - 1 / CUSHION_AT_THRESHOLD;

/// Fraction of a book sitting AT the threshold that is uncollateralised after a further drop `m`.
/// This is the upper bound on loss for a given drop: a position above the threshold was already
/// liquidatable before the window opened, and one below it carries more cushion than this.
function badDebtFraction(m) {
  return Math.max(0, 1 - CUSHION_AT_THRESHOLD * (1 - m));
}

// ---------------------------------------------------------------- measurement

function gaps(rounds) {
  const g = [];
  for (let i = 1; i < rounds.length; i++) g.push(rounds[i].t - rounds[i - 1].t);
  return g;
}

function perRoundSigmaPct(rounds) {
  const r = [];
  for (let i = 1; i < rounds.length; i++) r.push(Math.log(rounds[i].p / rounds[i - 1].p));
  const mean = r.reduce((a, b) => a + b, 0) / r.length;
  const varr = r.reduce((a, b) => a + (b - mean) ** 2, 0) / (r.length - 1);
  return { sigmaPct: Math.sqrt(varr) * 100, n: r.length };
}

/// Worst ADVERSE (downward) move inside any window of `windowSec`. Signed on purpose: an upward
/// move cannot hurt a lender, and the sibling script's absolute value overstates the risk side.
function worstDrop(rounds, windowSec) {
  let worst = 0, at = 0;
  for (let i = 0; i < rounds.length; i++) {
    for (let k = i + 1; k < rounds.length && rounds[k].t - rounds[i].t <= windowSec; k++) {
      const m = (rounds[i].p - rounds[k].p) / rounds[i].p;
      if (m > worst) { worst = m; at = rounds[i].t; }
    }
  }
  return { worst, at };
}

// ---------------------------------------------------------------- policy exposure

/// The quantity that decides bad debt for every policy: a position whose health was last VERIFIABLE
/// at round i-1 (sitting exactly at the threshold there) is executed against whatever price the
/// policy first permits a seizure at. The drop between those two prices is the policy's exposure.
///
/// Indexing on consecutive rounds is what makes the weekend fall out for free: the dark window IS a
/// long gap between i-1 and i, so a policy that stacks a halt on top of it is measured stacked.
function exposures(rounds, execTimeFor) {
  const out = [];
  for (let i = 1; i < rounds.length; i++) {
    const ref = rounds[i - 1];
    const execT = execTimeFor(rounds, i);
    if (execT === null) continue;
    let k = i;
    while (k + 1 < rounds.length && rounds[k].t < execT) k++;
    const drop = (ref.p - rounds[k].p) / ref.p;
    out.push({ i, refT: ref.t, execT: rounds[k].t, waitH: (rounds[k].t - ref.t) / 3600, drop });
  }
  return out;
}

const POLICY_BASELINE = () => (rounds, i) => rounds[i].t;

/// The current design. A FRESH crossing at round i is not seizable until an observation at least
/// PRICE_CONFIRM_DELAY old also reads underwater, which for a persistent step is 6h after the move.
const POLICY_CORROBORATE = () => (rounds, i) => rounds[i].t + PRICE_CONFIRM_DELAY_H * 3600;

/// A DEVIATION BREAKER MEASURES BETWEEN OBSERVATIONS, NOT BETWEEN FEED ROUNDS — src/EsseyMarkets.sol
/// :580 `_breaker(token, prev, observed, baselineAge)` with MAX_BASELINE_AGE 1h (:394). This matters
/// more than it sounds: these feeds print on DEVIATION, so a fast market prints more rounds, not
/// bigger ones, and the largest round-to-round move in the whole sample is 1.52% against a worst 1h
/// move of 6.80%. A per-round breaker is therefore blind to a crash by construction. Every trip
/// below is computed against the oldest observation still inside `baselineAgeH`.
function trippedAt(rounds, i, theta, baselineAgeH) {
  const cut = rounds[i].t - baselineAgeH * 3600;
  for (let k = i - 1; k >= 0 && rounds[k].t >= cut; k--) {
    if (Math.abs(rounds[i].p - rounds[k].p) / rounds[k].p >= theta) return true;
  }
  return false;
}

/// Liquidation is refused for `holdH` after any trip, and a trip DURING the hold pushes the release
/// out again — a cascading crash is the case that decides this, and the deployed desync hold
/// deliberately does NOT extend (src/EsseyMarkets.sol:600), so modelling the extending variant is
/// modelling the STRICTER of the two candidate simple designs.
function POLICY_HALT(theta, holdH, baselineAgeH = 1) {
  return (rounds, i) => {
    let until = rounds[i].t;
    // A trip at t releases at t+hold; a later trip still inside that window pushes the release out
    // again, so the release time is the fixpoint of "scan everything up to the current release".
    for (let k = i; k < rounds.length && rounds[k].t <= until; k++) {
      if (!trippedAt(rounds, k, theta, baselineAgeH)) continue;
      const end = rounds[k].t + holdH * 3600;
      if (end > until) until = end;
    }
    return until;
  };
}

function tripStats(rounds, theta, holdH, baselineAgeH = 1) {
  let trips = 0, haltedSec = 0, until = 0;
  for (let i = 1; i < rounds.length; i++) {
    if (!trippedAt(rounds, i, theta, baselineAgeH)) continue;
    const end = rounds[i].t + holdH * 3600;
    if (rounds[i].t >= until) trips++;
    haltedSec += Math.max(0, end - Math.max(until, rounds[i].t));
    until = Math.max(until, end);
  }
  const spanDays = (rounds.at(-1).t - rounds[0].t) / 86400;
  return { trips, tripsPerYear: (trips / spanDays) * 365.25, haltedFrac: haltedSec / (spanDays * 86400) };
}

/// How much bigger the WORST OBSERVED EPISODE would have to be before each policy costs anything.
/// The sample holds no move within a factor of two of the 25% onset, so the honest way to state the
/// gap is a scale factor on the real path rather than a probability the sample cannot support.
function stressScale(rounds, execTimeFor, scale) {
  const scaled = rounds.map((r, i) => ({ t: r.t, p: i === 0 ? r.p : 0 }));
  for (let i = 1; i < rounds.length; i++) {
    const ret = Math.log(rounds[i].p / rounds[i - 1].p);
    scaled[i].p = scaled[i - 1].p * Math.exp(ret * scale);
  }
  const ex = exposures(scaled, execTimeFor);
  const worst = ex.reduce((a, b) => (b.drop > a.drop ? b : a));
  return { worstDrop: worst.drop, badDebtFrac: badDebtFraction(worst.drop), at: worst.refT };
}

// ---------------------------------------------------------------- tail simulation

/// Stationary block bootstrap over the OBSERVED (log-return, gap) pairs. Blocks preserve the
/// clustering that makes an i.i.d. draw understate a crash; the gaps are resampled with the returns
/// so a simulated horizon contains dark windows at their observed frequency.
///
/// WHAT THIS CANNOT DO: produce a move larger than the observed returns can stack to. 74 days holding
/// one stress episode does not contain a 25% single-name gap, so the tail below is a LOWER BOUND on
/// the true probability, not an estimate of it. The Student-t sensitivity beside it exists to say how
/// much a fatter tail moves the answer.
function blockBootstrapDrawdown(rounds, horizonH, paths, blockLen, rng) {
  const rets = [], gs = [];
  for (let i = 1; i < rounds.length; i++) {
    rets.push(Math.log(rounds[i].p / rounds[i - 1].p));
    gs.push(rounds[i].t - rounds[i - 1].t);
  }
  const n = rets.length;
  const horizonSec = horizonH * 3600;
  const out = new Float64Array(paths);
  for (let p = 0; p < paths; p++) {
    let elapsed = 0, cum = 0, worst = 0, idx = 0, left = 0;
    while (elapsed < horizonSec) {
      if (left === 0) { idx = Math.floor(rng() * n); left = blockLen; }
      cum += rets[idx];
      elapsed += gs[idx];
      const drop = 1 - Math.exp(cum);
      if (drop > worst) worst = drop;
      idx = (idx + 1) % n;
      left--;
    }
    out[p] = worst;
  }
  return out;
}

/// Student-t sensitivity: same measured per-round sigma, but returns drawn from a t with `nu`
/// degrees of freedom instead of resampled. nu=3 is a deliberately harsh equity tail.
function studentTDrawdown(sigma, roundsPerHorizon, nu, paths, rng) {
  const scale = sigma / Math.sqrt(nu / (nu - 2));
  const out = new Float64Array(paths);
  const normal = () => {
    let u = 0, v = 0;
    while (u === 0) u = rng();
    while (v === 0) v = rng();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  };
  // chi-square(nu) as a sum of nu squared normals; nu is small so this is cheap and exact.
  const chi2 = () => { let s = 0; for (let k = 0; k < nu; k++) { const z = normal(); s += z * z; } return s; };
  for (let p = 0; p < paths; p++) {
    let cum = 0, worst = 0;
    for (let r = 0; r < roundsPerHorizon; r++) {
      cum += scale * normal() * Math.sqrt(nu / chi2());
      const drop = 1 - Math.exp(cum);
      if (drop > worst) worst = drop;
    }
    out[p] = worst;
  }
  return out;
}

function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// Expected bad debt for ONE exposure window, per dollar of book at the threshold.
/// Expected loss per window AND its Monte Carlo standard error — without the second number the
/// between-policy ordering below reads as a finding when it is noise: at p(loss) ~1e-4 even 500k
/// paths land only ~50 losses in a cell.
function expectedLossPerWindow(draws) {
  let sum = 0, sq = 0;
  for (const d of draws) { const l = badDebtFraction(d); sum += l; sq += l * l; }
  const n = draws.length, mean = sum / n;
  return { mean, se: Math.sqrt(Math.max(0, sq / n - mean * mean) / n) };
}

function quantile(draws, q) {
  const a = Array.from(draws).sort((x, y) => x - y);
  return a[Math.min(a.length - 1, Math.floor(q * a.length))];
}

// ---------------------------------------------------------------- run

const FEEDS = {
  AAPL: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0",
  NVDA: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15",
};
const CAPS = [25_000, 50_000, 100_000, 250_000, 1_000_000];
const THETAS = [0.03, 0.05, 0.07];
const HOLDS = [6, 12, 24, 48];

console.log("=".repeat(78));
console.log("RISK ALGEBRA (from script/DeployMarkets.s.sol:391-396)");
console.log(`  ltv ${LTV_BPS}bps  liqThreshold ${LIQ_THRESHOLD_BPS}bps  liqBonus ${LIQ_BONUS_BPS}bps`);
console.log(`  cap ${CAP_USDG.toLocaleString()} USDG  maxPositionBps ${MAX_POSITION_BPS} -> max single position ${(CAP_USDG * MAX_POSITION_BPS / 10_000).toLocaleString()} USDG`);
console.log(`  collateral/debt at threshold      ${CUSHION_AT_THRESHOLD.toFixed(5)}`);
console.log(`  further drop to liquidator indifference  ${(INDIFFERENCE_DROP * 100).toFixed(2)}%`);
console.log(`  further drop to BAD DEBT ONSET          ${(BAD_DEBT_ONSET_DROP * 100).toFixed(2)}%`);
console.log("  bad debt as a share of a book at the threshold:");
for (const m of [0.2125, 0.25, 0.275, 0.3, 0.35, 0.4, 0.5, 0.6]) {
  console.log(`    drop ${(m * 100).toFixed(2).padStart(6)}%  ->  ${(badDebtFraction(m) * 100).toFixed(3).padStart(7)}% of book`);
}

const measured = {};

for (const [name, addr] of Object.entries(FEEDS)) {
  const latest = await latestRound(addr);
  const rounds = await cached(name, latest, () => walk(addr, latest));
  const g = gaps(rounds).sort((a, b) => a - b);
  const maxGapH = g.at(-1) / 3600;
  const spanDays = (rounds.at(-1).t - rounds[0].t) / 86400;
  const { sigmaPct, n } = perRoundSigmaPct(rounds);
  measured[name] = { rounds, maxGapH, spanDays, sigmaPct };

  console.log("\n" + "=".repeat(78));
  console.log(`${name}  ${addr}  latestRound ${latest}`);
  console.log(`  ${rounds.length} rounds  ${new Date(rounds[0].t * 1000).toISOString()} -> ${new Date(rounds.at(-1).t * 1000).toISOString()}  (${spanDays.toFixed(2)}d)`);
  console.log(`  median gap ${g[Math.floor(g.length / 2)]}s   max gap ${maxGapH.toFixed(2)}h   rounds/day ${(rounds.length / spanDays).toFixed(1)}`);
  console.log(`  per-round sigma (log-return sample sd) ${sigmaPct.toFixed(4)}%  n ${n}`);

  console.log("\n  WORST ADVERSE MOVE BY HORIZON  (headroom = 25.00% bad-debt onset / worst)");
  const horizons = [1, 6, 12, 24, 48, 72, Math.ceil(maxGapH), Math.ceil(maxGapH + PRICE_CONFIRM_DELAY_H + CONFIRM_STEP_H), Math.ceil(maxGapH + 24), Math.ceil(maxGapH + 48)];
  for (const h of [...new Set(horizons)].sort((a, b) => a - b)) {
    const { worst, at } = worstDrop(rounds, h * 3600);
    console.log(`    ${String(h).padStart(4)}h   drop ${(worst * 100).toFixed(2).padStart(6)}%   headroom ${(BAD_DEBT_ONSET_DROP / worst).toFixed(2).padStart(6)}x   badDebt ${(badDebtFraction(worst) * 100).toFixed(3)}%   from ${new Date(at * 1000).toISOString()}`);
  }

  console.log("\n  POLICY EXPOSURE ON THE REAL SERIES");
  console.log("  (a book at the threshold at round i-1, executed at the first price the policy allows)");
  const policies = [
    ["baseline (no breaker)", POLICY_BASELINE()],
    [`corroborate ${PRICE_CONFIRM_DELAY_H}h (current)`, POLICY_CORROBORATE()],
  ];
  for (const theta of THETAS) for (const hold of HOLDS) {
    policies.push([`halt theta=${(theta * 100).toFixed(0)}% hold=${hold}h`, POLICY_HALT(theta, hold)]);
  }
  for (const [label, fn] of policies) {
    const ex = exposures(rounds, fn);
    const worst = ex.reduce((a, b) => (b.drop > a.drop ? b : a));
    const maxWait = ex.reduce((a, b) => (b.waitH > a.waitH ? b : a));
    const totalBD = ex.reduce((s, e) => s + badDebtFraction(e.drop), 0);
    console.log(
      `    ${label.padEnd(30)} worstDrop ${(worst.drop * 100).toFixed(2).padStart(6)}%  maxWait ${maxWait.waitH.toFixed(1).padStart(6)}h  badDebtEvents ${totalBD === 0 ? "0" : totalBD.toFixed(4)}`,
    );
  }

  console.log("\n  BREAKER TRIP FREQUENCY (what a simple halt costs in availability)");
  console.log("    deployed MAX_PRICE_DEVIATION_BPS is 2000 over MAX_BASELINE_AGE 1h (EsseyMarkets.sol:365,394)");
  for (const theta of [...THETAS, 0.20]) for (const hold of [24]) {
    const st = tripStats(rounds, theta, hold);
    console.log(`    theta ${(theta * 100).toFixed(0).padStart(2)}%/1h hold ${hold}h  trips ${String(st.trips).padStart(3)} in ${spanDays.toFixed(1)}d  = ${st.tripsPerYear.toFixed(1).padStart(6)}/yr  halted ${(st.haltedFrac * 100).toFixed(1).padStart(5)}% of wall time`);
  }
  console.log("    max round-to-round move " + (Math.max(...rounds.slice(1).map((r, k) => Math.abs(r.p - rounds[k].p) / rounds[k].p)) * 100).toFixed(2) + "%  <- why a PER-ROUND breaker cannot see a crash");

  console.log("\n  STRESS: the real path, every log-return multiplied by `scale`");
  console.log("    scale   worstDrop    baseline    corroborate6h    halt5%/24h    halt5%/48h   (bad debt as % of a book at the threshold)");
  for (const scale of [1, 1.5, 2, 2.5, 3, 4]) {
    const cells = [
      stressScale(rounds, POLICY_BASELINE(), scale),
      stressScale(rounds, POLICY_CORROBORATE(), scale),
      stressScale(rounds, POLICY_HALT(0.05, 24), scale),
      stressScale(rounds, POLICY_HALT(0.05, 48), scale),
    ];
    const { worst } = worstDrop(rounds.map((r, k) => ({ t: r.t, p: r.p })), 88 * 3600);
    const scaledWorst = 1 - Math.pow(1 - worst, scale);
    console.log(
      `    ${scale.toFixed(1).padStart(4)}x  ${(scaledWorst * 100).toFixed(2).padStart(7)}%  ` +
      cells.map((c) => `${(c.badDebtFrac * 100).toFixed(3)}% (${(c.worstDrop * 100).toFixed(2)}%)`.padStart(18)).join(""),
    );
  }
}

// ---------------------------------------------------------------- tail + dollars

console.log("\n" + "=".repeat(78));
console.log("TAIL SIMULATION — probability a book at the threshold takes a loss in one window");
const PATHS = 200_000;
const BLOCK = 12;

const scenarios = [];
for (const [name, m] of Object.entries(measured)) {
  const roundsPerDay = m.rounds.length / m.spanDays;
  // Each policy's exposure window is the feed's own dark window plus whatever the policy adds on
  // top. The dark window is not the policy's fault, but it is the floor every policy stacks onto.
  const windows = [
    ["baseline (dark window only)", m.maxGapH, 8766 / m.maxGapH],
    [`corroborate ${PRICE_CONFIRM_DELAY_H}h`, m.maxGapH + PRICE_CONFIRM_DELAY_H + CONFIRM_STEP_H, 8766 / (m.maxGapH + PRICE_CONFIRM_DELAY_H + CONFIRM_STEP_H)],
    ["halt 24h", m.maxGapH + MAX_LIQUIDATION_PAUSE_H, 8766 / (m.maxGapH + MAX_LIQUIDATION_PAUSE_H)],
    ["halt 48h (one re-trip)", m.maxGapH + 2 * MAX_LIQUIDATION_PAUSE_H, 8766 / (m.maxGapH + 2 * MAX_LIQUIDATION_PAUSE_H)],
  ];
  console.log(`\n  ${name}  (dark window ${m.maxGapH.toFixed(1)}h, ${roundsPerDay.toFixed(1)} rounds/day, sigma ${m.sigmaPct.toFixed(4)}%/round)`);
  for (const [label, horizonH, windowsPerYear] of windows) {
    const rng = mulberry32(0xc0ffee);
    const boot = blockBootstrapDrawdown(m.rounds, horizonH, PATHS, BLOCK, rng);
    const pLoss = boot.reduce((s, d) => s + (d > BAD_DEBT_ONSET_DROP ? 1 : 0), 0) / PATHS;
    const eLoss = expectedLossPerWindow(boot);

    const rpt = Math.max(2, Math.round((roundsPerDay / 24) * horizonH));
    const rngT = mulberry32(0xbeef);
    const T_PATHS = 500_000;
    const t3 = studentTDrawdown(m.sigmaPct / 100, rpt, 3, T_PATHS, rngT);
    const nLossT = t3.reduce((s, d) => s + (d > BAD_DEBT_ONSET_DROP ? 1 : 0), 0);
    const pLossT = nLossT / T_PATHS;
    const eLossT = expectedLossPerWindow(t3);

    scenarios.push({ name, label, horizonH, windowsPerYear, eLoss, eLossT, pLoss, pLossT });
    console.log(
      `    ${label.padEnd(28)} H=${horizonH.toFixed(1).padStart(6)}h  p99.9 drop ${(quantile(boot, 0.999) * 100).toFixed(2).padStart(5)}%  p(loss) boot ${pLoss.toExponential(2)}  t3 ${pLossT.toExponential(2)} (${nLossT} of ${T_PATHS})  E[loss/window] boot ${(eLoss.mean * 1e6).toFixed(2)}ppm  t3 ${(eLossT.mean * 1e6).toFixed(2)} +/- ${(eLossT.se * 1e6).toFixed(2)}ppm`,
    );
  }
}

console.log("\n" + "=".repeat(78));
console.log("EXPECTED ANNUAL BAD DEBT, USD — book held continuously AT the threshold (upper bound)");
console.log("  boot = block bootstrap of observed returns (tail-light by construction)");
console.log("  t3   = Student-t(3) at the same measured per-round sigma (harsh-tail sensitivity)");
for (const cap of CAPS) {
  console.log(`\n  cap ${cap.toLocaleString()} USDG per market`);
  for (const s of scenarios) {
    const boot = s.eLoss.mean * s.windowsPerYear * cap;
    const t3 = s.eLossT.mean * s.windowsPerYear * cap;
    const t3se = s.eLossT.se * s.windowsPerYear * cap;
    console.log(`    ${s.name} ${s.label.padEnd(28)} boot $${boot.toFixed(2).padStart(10)}   t3 $${t3.toFixed(2).padStart(10)} +/- $${t3se.toFixed(2)}`);
  }
}

console.log("\n" + "=".repeat(78));
console.log("THE DELTA — what buying back 18 hours of availability is worth, MEASURED");
console.log("  Every policy inherits the feed's own dark window. The only thing a policy CHOOSES is");
console.log("  how many hours it adds on top, so the delta is the extra adverse move inside them.");
for (const [name, m] of Object.entries(measured)) {
  const base = m.maxGapH;
  const rows = [
    ["dark window only", base],
    [`+ corroborate ${PRICE_CONFIRM_DELAY_H}h + step`, base + PRICE_CONFIRM_DELAY_H + CONFIRM_STEP_H],
    ["+ halt 24h", base + 24],
    ["+ halt 48h", base + 48],
    ["+ halt 72h", base + 72],
  ];
  console.log(`\n  ${name}  dark window ${base.toFixed(2)}h`);
  let prev = null;
  for (const [label, h] of rows) {
    const { worst } = worstDrop(m.rounds, h * 3600);
    const inc = prev === null ? 0 : worst - prev;
    prev = worst;
    console.log(
      `    ${label.padEnd(28)} H=${h.toFixed(1).padStart(6)}h  worst drop ${(worst * 100).toFixed(2).padStart(6)}%  incremental ${(inc * 100).toFixed(2).padStart(6)}pp  bad debt ${(badDebtFraction(worst) * 100).toFixed(3)}% of book  = $${Math.round(badDebtFraction(worst) * CAP_USDG).toLocaleString()} at the 250k cap`,
    );
  }
}

console.log("\n" + "=".repeat(78));
console.log("CROSSOVER — how much worse than reality the worst observed episode must get");
console.log("  before each policy costs a dollar. Scale multiplies every log return on the real path.");
for (const [name, m] of Object.entries(measured)) {
  console.log(`\n  ${name}`);
  for (const [label, fn] of [
    ["baseline (no breaker)", POLICY_BASELINE()],
    [`corroborate ${PRICE_CONFIRM_DELAY_H}h (current)`, POLICY_CORROBORATE()],
    ["halt 5%/1h, 24h hold", POLICY_HALT(0.05, 24)],
    ["halt 5%/1h, 48h hold", POLICY_HALT(0.05, 48)],
    ["halt 3%/1h, 24h hold", POLICY_HALT(0.03, 24)],
  ]) {
    let first = null;
    for (let sc = 1; sc <= 8.001; sc += 0.05) {
      if (stressScale(m.rounds, fn, sc).badDebtFrac > 0) { first = sc; break; }
    }
    const at6 = stressScale(m.rounds, fn, 6);
    console.log(
      `    ${label.padEnd(30)} first loss at ${first === null ? " >8.00" : first.toFixed(2)}x   at 6x: drop ${(at6.worstDrop * 100).toFixed(2).padStart(6)}%  bad debt ${(at6.badDebtFrac * 100).toFixed(3).padStart(7)}%  = $${Math.round(at6.badDebtFrac * CAP_USDG).toLocaleString()} at the 250k cap`,
    );
  }
}

console.log("\n" + "=".repeat(78));
console.log("WORST SINGLE EVENT, USD — a book at the threshold takes a drop of `m` inside the window");
console.log("  (parametric beyond what 74 days can show; the measured worst is printed above)");
const HEADER = ["drop"].concat(CAPS.map((c) => "$" + (c / 1000) + "k"));
console.log("    " + HEADER.map((h) => h.padStart(12)).join(""));
for (const m of [0.25, 0.275, 0.30, 0.35, 0.40, 0.50, 0.60]) {
  const row = [(m * 100).toFixed(1) + "%"].concat(CAPS.map((c) => "$" + Math.round(badDebtFraction(m) * c).toLocaleString()));
  console.log("    " + row.map((h) => h.padStart(12)).join(""));
}

console.log("\n" + "=".repeat(78));
console.log("WHICH CAP ACTUALLY BINDS — the pool enforces min(static, depth oracle)");
console.log("  EsseyMarkets.sol:223-227 borrowCap = min(Market.cap, health.effectiveCap);");
console.log("  MarketHealthOracle.sol:97,157 effectiveCap targets capFractionBps/BPS of measured depth.");
const CAP_FRACTION_BPS = 3_333;
console.log("    " + ["static cap", "inert below depth", "1 position (20% of cap)", "that position as % of depth at the binding depth"].map((h) => h.padStart(24)).join(""));
for (const cap of CAPS) {
  const bindDepth = cap * 10_000 / CAP_FRACTION_BPS;
  const pos = cap * MAX_POSITION_BPS / 10_000;
  console.log("    " + [
    "$" + cap.toLocaleString(),
    "$" + Math.round(bindDepth).toLocaleString(),
    "$" + pos.toLocaleString(),
    ((MAX_POSITION_BPS / 10_000) * (CAP_FRACTION_BPS / 10_000) * 100).toFixed(2) + "%",
  ].map((h) => h.padStart(24)).join(""));
}
console.log("  The last column is constant: while the ORACLE binds, one position is always");
console.log("  maxPositionBps x capFractionBps of measured depth, whatever the static cap says.");
console.log("  A liquidation into that share is the real liquidity constraint on maxPositionBps.");
console.log("  There is NO force-deleverage path: marketBorrows falls only on repay (EsseyPool.sol:635)");
console.log("  and close (:857), so a cap that shrinks during a crash cannot shrink standing debt.");
console.log("  Standing exposure is therefore bounded by max-over-time of min(static, oracle), and the");
console.log("  static cap is the ceiling of that — which is why the tables below index on it.");

console.log("\n" + "=".repeat(78));
console.log("THE SAME TABLE FOR A BOOK AT ORIGINATION MAX LTV (50%), cushion 2.00x — the other bracket");
console.log("  A fresh max-LTV position needs a 33.33% drop just to REACH the threshold, so bad debt");
console.log("  starts at 50%. Reality sits between this and the at-threshold table above; the design");
console.log("  bound is the at-threshold one, this is what a young book actually looks like.");
const maxLtvFrac = (m) => Math.max(0, 1 - (10_000 / LTV_BPS) * (1 - m));
console.log("    " + ["drop"].concat(CAPS.map((c) => "$" + c / 1000 + "k")).map((h) => h.padStart(12)).join(""));
for (const m of [0.30, 0.40, 0.50, 0.55, 0.60, 0.70]) {
  const row = [(m * 100).toFixed(1) + "%"].concat(CAPS.map((c) => "$" + Math.round(maxLtvFrac(m) * c).toLocaleString()));
  console.log("    " + row.map((h) => h.padStart(12)).join(""));
}

console.log("\n" + "=".repeat(78));
console.log("WRONGFUL SEIZURE — the loss BOTH designs exist to prevent, for scale");
console.log("  test/GLendR4.t.sol:373-375: a half-landed 2:1 split leg on a market unobserved for one");
console.log("  hour was harvested for 10,988bps of the debt ($1,618.18 free profit on $1,472.67).");
console.log("  It scales linearly with the book, and it is not bounded by any cushion.");
console.log("    " + ["", "per position (20% of cap)", "whole book"].map((h) => h.padStart(26)).join(""));
for (const cap of CAPS) {
  const pos = cap * MAX_POSITION_BPS / 10_000;
  console.log("    " + [`cap $${cap.toLocaleString()}`, "$" + Math.round(1.0988 * pos).toLocaleString(), "$" + Math.round(1.0988 * cap).toLocaleString()].map((h) => h.padStart(26)).join(""));
}

console.log("\n" + "=".repeat(78));
console.log("AFFORDABLE CAP — invert the table: cap = tolerance / badDebtFraction(design drawdown)");
console.log("  ASSUMPTION, for the founder to correct: tolerance is stated ACROSS BOTH markets.");
const TOLS = [10_000, 25_000, 50_000, 100_000];
console.log("    " + ["design drawdown", "% of book"].concat(TOLS.map((t) => "tol $" + t / 1000 + "k")).map((h) => h.padStart(16)).join(""));
for (const m of [0.30, 0.35, 0.40, 0.50, 0.60]) {
  const f = badDebtFraction(m);
  const row = [(m * 100).toFixed(0) + "%", (f * 100).toFixed(2) + "%"].concat(
    TOLS.map((t) => "$" + Math.round(t / 2 / f).toLocaleString() + "/mkt"),
  );
  console.log("    " + row.map((h) => h.padStart(16)).join(""));
}

console.log("\n" + "=".repeat(78));
console.log("ISSUER RESIDUAL — neither design covers this");
console.log("  adminBurn / pause / clawback act on the collateral token itself, so the loss is not a");
console.log("  function of any price window. Sized as a share of the collateral backing the book.");
console.log("    " + ["burn"].concat(CAPS.map((c) => "$" + (c / 1000) + "k")).map((h) => h.padStart(12)).join(""));
for (const b of [0.01, 0.05, 0.10, 0.25, 0.50, 1.00]) {
  // A book at the threshold is backed by CUSHION_AT_THRESHOLD dollars of collateral per dollar of
  // debt; a burn of share `b` destroys that much of it, and anything past the cushion is bad debt.
  const loss = Math.max(0, 1 - CUSHION_AT_THRESHOLD * (1 - b));
  const row = [(b * 100).toFixed(0) + "%"].concat(CAPS.map((c) => "$" + Math.round(loss * c).toLocaleString()));
  console.log("    " + row.map((h) => h.padStart(12)).join(""));
}
console.log("  NOTE: at max LTV (50%) rather than at the threshold the cushion is 2.0x, so the burn");
console.log("  share that starts a loss is 50% instead of 25%. Both rows are printed in the doc.");
