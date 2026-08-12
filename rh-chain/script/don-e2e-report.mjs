#!/usr/bin/env node
// don-e2e-report.mjs — turn a DonE2E broadcast artifact into an explorer-linked markdown report.
//
// Reads the forge broadcast log (every tx hash + receipt status) produced by:
//   forge script script/DonE2E.s.sol:DonE2E --broadcast   (writes broadcast/DonE2E.s.sol/<chainId>/run-latest.json)
// and emits a per-journey table of  flow -> actor -> contract -> tx (explorer link) -> pass/fail
// to docs/TESTNET-E2E.md.
//
// Usage (run from the repo root or rh-chain/):
//   node script/don-e2e-report.mjs
//   node script/don-e2e-report.mjs --in broadcast/DonE2E.s.sol/46630/run-latest.json --out ../docs/TESTNET-E2E.md
//   EXPLORER=https://explorer.testnet.chain.robinhood.com/tx/ node script/don-e2e-report.mjs
//
// It labels contracts + routes `approve` txs to the right journey when the stack addresses are in the env
// (DON, DISTRIBUTOR, ESSEY, USDG, BELL, EXCHANGE, RESERVE, LOAN, FEEROUTER, FAUCET) — the same env the
// broadcast used — but works without them too (falls back to a generic contract label).

import fs from "node:fs";
import path from "node:path";

// ----------------------------------------------------------------- args / config
const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, arr) => {
    if (a.startsWith("--")) acc.push([a.slice(2), arr[i + 1]]);
    return acc;
  }, [])
);

const CHAIN = process.env.CHAIN_ID || "46630";
const IN = args.in || `broadcast/DonE2E.s.sol/${CHAIN}/run-latest.json`;
const OUT = args.out || path.join("..", "docs", "TESTNET-E2E.md");
const EXPLORER = process.env.EXPLORER || "https://explorer.testnet.chain.robinhood.com/tx/";

// ----------------------------------------------------------------- stack address labels (optional)
const NAMED = {};
for (const k of ["DON", "DISTRIBUTOR", "ESSEY", "USDG", "BELL", "EXCHANGE", "RESERVE", "LOAN", "FEEROUTER", "FAUCET"]) {
  const v = process.env[k];
  if (v) NAMED[v.toLowerCase()] = k;
}
const nameOf = (addr) => (addr && NAMED[addr.toLowerCase()]) || null;

// ----------------------------------------------------------------- journey classification
// Order defines the section order in the report.
const JOURNEYS = ["SETUP", "FAUCET", "MINT", "STAKE", "BORROW", "REPAY", "RESERVE", "DESK", "OTHER"];

function classify(tx) {
  const fn = (tx.function || "").split("(")[0];
  const to = tx.transaction?.to?.toLowerCase();
  const toName = nameOf(to);

  switch (fn) {
    case "":
    case null:
    case undefined:
      return ["SETUP", "gas-fund wallet (native ETH)"];
    case "drip":
      return ["FAUCET", "drip() — ESSEY + USDG"];
    case "mintCustom":
      return ["MINT", "custom mint (ETH fee)"];
    case "reroll":
      return ["MINT", "reroll traits (ETH fee)"];
    case "mintReserved":
      return ["SETUP", "seed desk float (mintReserved)"];
    case "seed":
      return ["SETUP", "seed exchange inventory"];
    case "setApprovalForAll":
      return ["SETUP", "approve exchange (all Dons)"];
    case "setPublicOpen":
      return ["SETUP", "open custom mint"];
    case "setDrips":
      return ["SETUP", "tune faucet drips"];
    case "transfer":
      return ["SETUP", "fund faucet with ESSEY"];
    case "activate":
      return ["STAKE", "activate Bell tier"];
    case "upgrade":
      return ["STAKE", "upgrade Bell tier"];
    case "borrow":
      return ["BORROW", "borrow (fixed-draw, prepaid ETH)"];
    case "repay":
      return ["REPAY", "repay 1:1 (lien released)"];
    case "buy":
      return ["DESK", "buy (price + 8%)"];
    case "snipe":
      return ["DESK", "snipe (price + 12%)"];
    case "sell":
      return ["DESK", "sell (price − 8%)"];
    case "redeem":
      return ["RESERVE", "redeem Don for floor"];
    case "fund":
      // reserve.fund vs loan.fund — split by target when we know the addresses.
      if (toName === "RESERVE") return ["RESERVE", "fund the floor"];
      if (toName === "LOAN") return ["SETUP", "fund loan pot"];
      return ["RESERVE", "fund"];
    case "approve": {
      // approve() is called ON the token (tx.to = ESSEY/DON); the journey is decided by the SPENDER,
      // which is arguments[0]. Fall back to the token when args are absent.
      const spender = nameOf(Array.isArray(tx.arguments) ? tx.arguments[0] : null);
      if (spender === "BELL") return ["STAKE", "approve ESSEY → Bell"];
      if (spender === "LOAN") return ["REPAY", "approve ESSEY → Loan"];
      if (spender === "EXCHANGE") return ["DESK", "approve → Exchange"];
      if (spender === "RESERVE") return ["RESERVE", "approve → Reserve"];
      if (toName === "ESSEY" || toName === "DON") return ["SETUP", "approve (funding/seed)"];
      return ["OTHER", "approve"];
    }
    default:
      return ["OTHER", fn || "(unknown)"];
  }
}

// ----------------------------------------------------------------- load
if (!fs.existsSync(IN)) {
  console.error(`don-e2e-report: broadcast artifact not found: ${IN}
Run the harness first:  forge script script/DonE2E.s.sol:DonE2E --broadcast  (see how-to at the bottom of DonE2E.s.sol)`);
  process.exit(1);
}
const doc = JSON.parse(fs.readFileSync(IN, "utf8"));
const txs = doc.transactions || [];
const receipts = new Map((doc.receipts || []).map((r) => [(r.transactionHash || "").toLowerCase(), r]));
const chainId = doc.chain ?? CHAIN;

const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "—");
const txLink = (h) => (h ? `[${short(h)}](${EXPLORER}${h})` : "—");
const statusOf = (h) => {
  const r = receipts.get((h || "").toLowerCase());
  if (!r) return "pending";
  return r.status === "0x1" || r.status === 1 ? "pass" : "fail";
};

// ----------------------------------------------------------------- group
const groups = Object.fromEntries(JOURNEYS.map((j) => [j, []]));
let pass = 0, fail = 0, pend = 0;
for (const tx of txs) {
  const [journey, flow] = classify(tx);
  const hash = tx.hash;
  const st = statusOf(hash);
  if (st === "pass") pass++; else if (st === "fail") fail++; else pend++;
  const to = tx.transaction?.to;
  groups[journey].push({
    flow,
    from: tx.transaction?.from,
    to,
    contract: nameOf(to) || short(to),
    hash,
    status: st,
  });
}

// ----------------------------------------------------------------- render
const badge = (s) => (s === "pass" ? "✅ pass" : s === "fail" ? "❌ FAIL" : "⏳ pending");
const now = new Date().toISOString().replace("T", " ").slice(0, 19) + " UTC";

let md = "";
md += `# Essey Don Market — Testnet E2E Report\n\n`;
md += `_Generated ${now} from \`${IN}\` — chain \`${chainId}\`._\n\n`;
md += `Deterministic, multi-wallet end-to-end exercise of the Don v3 market (see \`rh-chain/script/DonE2E.s.sol\`). `;
md += `Every row is a real broadcast transaction from a fresh, throwaway actor wallet; the harness asserts each flow's `;
md += `invariants on-chain (clear revert strings) before the tx is recorded here.\n\n`;

md += `## Summary\n\n`;
md += `| Result | Count |\n|---|---|\n`;
md += `| ✅ pass | ${pass} |\n| ❌ fail | ${fail} |\n| ⏳ pending | ${pend} |\n| **total** | **${txs.length}** |\n\n`;
if (fail === 0 && pend === 0 && txs.length > 0) {
  md += `**All ${txs.length} transactions confirmed successful.**\n\n`;
} else if (fail > 0) {
  md += `> ⚠️ ${fail} transaction(s) FAILED — inspect the flagged rows below.\n\n`;
}

const titles = {
  SETUP: "Setup (deployer: fund + seed the stack)",
  FAUCET: "Faucet",
  MINT: "Mint (custom path + reroll)",
  STAKE: "Stake (Bell tiers)",
  BORROW: "Borrow (fixed-draw term loan)",
  REPAY: "Repay",
  RESERVE: "Reserve (fund floor + redeem)",
  DESK: "Desk swaps (buy / snipe / sell)",
  OTHER: "Other",
};

for (const j of JOURNEYS) {
  const rows = groups[j];
  if (!rows.length) continue;
  const jp = rows.filter((r) => r.status === "pass").length;
  md += `## ${titles[j]}  \n`;
  md += `_${jp}/${rows.length} pass_\n\n`;
  md += `| Flow | Actor | Contract | Tx | Status |\n|---|---|---|---|---|\n`;
  for (const r of rows) {
    md += `| ${r.flow} | \`${short(r.from)}\` | ${r.contract} | ${txLink(r.hash)} | ${badge(r.status)} |\n`;
  }
  md += `\n`;
}

md += `## Not covered on live testnet\n\n`;
md += `- **Liquidation (calendar default)** — needs time travel past \`expiry + 30-day grace\`, impossible on a live chain. `;
md += `Proven in a **fork simulation**: \`forge script script/DonE2E.s.sol:DonE2E --sig "liquidationFork()" --rpc-url rh_testnet\` (no \`--broadcast\`).\n`;
md += `- **feeSink → Bell (USDG)** — the harness proves trade/mint fees REACH the fee sink; converting them to USDG for the Bell is a keeper \`flushEssey\`/\`flushEth\` that needs a live Uniswap-V3 pool, out of scope for this harness.\n`;

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, md);
console.log(`don-e2e-report: wrote ${OUT}  (${txs.length} txs: ${pass} pass / ${fail} fail / ${pend} pending, chain ${chainId})`);
