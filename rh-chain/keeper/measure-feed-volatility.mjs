// Re-derive PRICE_CONFIRM_DELAY from the feeds, instead of taking the constant's word for it.
//
// The delay spends the distance between the liquidation threshold and liquidator indifference —
// 21.25% at the listed 5000/7500/500 — so the question it answers is "how far does this name move
// inside a window that long". Run it before listing a market, and again if a listed feed's cadence
// changes: PRICE_CONFIRM_DELAY is a shared, non-upgradeable constant across every market, so it has
// to be set against the WORST listed name, not the first one measured.
//
// Two traps this walk found on 4663, both worth knowing before trusting any historical read:
//   - both AAPL and NVDA return their first ~20 rounds scaled 1e18 rather than the 1e8 decimals()
//     reports, then switch (2026-06-23T13:48 UTC). Normalised below; a naive read mis-prices 1e10.
//   - the public RPC rate-limits hard, hence the backoff. Do not run it against the same node as a
//     forked test suite; they starve each other.
//
//   node keeper/measure-feed-volatility.mjs
const RPC = "https://rpc.mainnet.chain.robinhood.com";
const SEL = "0x9a6fc8f5"; // getRoundData(uint80)
const PHASE = (1n << 64n);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function batch(calls) {
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

function enc(round) {
  return SEL + round.toString(16).padStart(64, "0");
}

function dec(hex) {
  const b = hex.slice(2);
  const w = (i) => BigInt("0x" + b.slice(i * 64, i * 64 + 64));
  return { answer: w(1), updatedAt: w(3) };
}

async function walk(feed, latest, n) {
  const out = [];
  for (let i = 0; i < n; i += 20) {
    const calls = [];
    for (let j = 0; j < 20 && i + j < n; j++) {
      const r = PHASE + BigInt(latest - i - j);
      calls.push({ jsonrpc: "2.0", id: i + j, method: "eth_call", params: [{ to: feed, data: enc(r) }, "latest"] });
    }
    const rs = await batch(calls);
    await sleep(150);
    for (const r of rs) {
      if (!r.result || r.result === "0x") continue;
      const d = dec(r.result);
      if (d.updatedAt === 0n) continue;
      out.push({ t: Number(d.updatedAt), p: Number(d.answer) / 1e8 });
    }
  }
  out.sort((a, b) => a.t - b.t);
  return out;
}

/// Both feeds' first ~20 rounds answer on a 1e18 scale before switching to the 1e8 decimals()
/// reports. Left raw, the transition reads as a 100% move and swamps every window.
function normalise(rounds) {
  return rounds.map((r) => ({ t: r.t, p: r.p > 10_000 ? r.p / 1e8 : r.p }));
}

/// Per-round dispersion, stated with its ESTIMATOR because the register carried this pair for a
/// round with no method attached and it was not reproducible from anything here (R5 INFO-3). Sample
/// standard deviation of log returns between consecutive rounds, in percent.
function perRoundSigmaPct(rounds) {
  const r = [];
  for (let i = 1; i < rounds.length; i++) r.push(Math.log(rounds[i].p / rounds[i - 1].p));
  const mean = r.reduce((a, b) => a + b, 0) / r.length;
  const varr = r.reduce((a, b) => a + (b - mean) ** 2, 0) / (r.length - 1);
  return { sigmaPct: Math.sqrt(varr) * 100, n: r.length };
}

function worstMove(rounds, windowSec) {
  let worst = 0, at = 0;
  for (let i = 0; i < rounds.length; i++) {
    let j = i;
    while (j + 1 < rounds.length && rounds[j + 1].t - rounds[i].t <= windowSec) j++;
    if (j === i) continue;
    for (let k = i + 1; k <= j; k++) {
      const m = Math.abs(rounds[k].p - rounds[i].p) / rounds[i].p;
      if (m > worst) { worst = m; at = rounds[i].t; }
    }
  }
  return { worst, at };
}

const feeds = {
  AAPL: ["0x6B22A786bAa607d76728168703a39Ea9C99f2cD0", 555],
  NVDA: ["0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15", 981],
};

for (const [name, [addr, latest]] of Object.entries(feeds)) {
  const rounds = normalise(await walk(addr, latest, latest));
  const gaps = [];
  for (let i = 1; i < rounds.length; i++) gaps.push(rounds[i].t - rounds[i - 1].t);
  gaps.sort((a, b) => a - b);
  console.log(`\n=== ${name} (${addr}) ===`);
  console.log(`rounds ${rounds.length}  from ${new Date(rounds[0].t * 1000).toISOString()} to ${new Date(rounds.at(-1).t * 1000).toISOString()}`);
  console.log(`span days ${((rounds.at(-1).t - rounds[0].t) / 86400).toFixed(2)}`);
  console.log(`median gap s ${gaps[Math.floor(gaps.length / 2)]}  max gap h ${(gaps.at(-1) / 3600).toFixed(2)}`);
  // 21.25% is what the delay spends at 5000/7500/500: liquidation threshold (debt / 0.75) down to
  // liquidator indifference (1.05 x debt). Anything approaching it at the chosen horizon is bad debt.
  const { sigmaPct, n } = perRoundSigmaPct(rounds);
  console.log(`per-round sigma (log-return sample sd) ${sigmaPct.toFixed(4)}%  n ${n}`);
  // 72h is the horizon the design actually carries, not 6h: the feed goes dark ~25h after Friday's
  // close and a position healthy at that last print cannot be seized until PRICE_CONFIRM_DELAY of
  // Monday observations have aged in — Friday 20:00 UTC to Monday ~19:30 UTC (R5 MED-1).
  for (const h of [1, 2, 4, 6, 8, 12, 24, 48, 72]) {
    const { worst, at } = worstMove(rounds, h * 3600);
    const headroom = (0.2125 / worst).toFixed(2);
    console.log(
      `worst ${String(h).padStart(2)}h move  ${(worst * 100).toFixed(2)}%  ${headroom}x inside the 21.25% buffer   from ${new Date(at * 1000).toISOString()}`,
    );
  }
}
