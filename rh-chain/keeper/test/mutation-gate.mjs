// Mutation gate: a test whose name reads correctly but passes against a broken implementation is worse
// than no test. This breaks each invariant deliberately, in every direction that matters, and requires
// the suite to go RED. A SURVIVOR is a defect — it means nothing pins that behaviour.
//
//   node keeper/test/mutation-gate.mjs
//
// Every mutation asserts its anchor matched exactly once, so a silent no-op cannot pass for a kill.
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
// The airdrop module is the bulk of this. A name carrying a path separator is resolved from
// `keeper/` instead, so the liveness supervisor's classifier is mutated by the same gate.
const SRC = (f) => (f.includes("/") ? join(ROOT, f) : join(ROOT, "holder-airdrop", f));

const MUTATIONS = [
  // --- the two-snapshot holding gate ---
  ["gate: MAX instead of MIN", "eligibility.mjs", "before < now ? before : now", "before < now ? now : before"],
  ["gate: drop the previous snapshot", "eligibility.mjs", "before < now ? before : now", "now"],
  ["gate: drop the current snapshot", "eligibility.mjs", "before < now ? before : now", "before"],
  ["gate: sum instead of min", "eligibility.mjs", "before < now ? before : now", "before + now"],
  ["order: allow snapshots out of order", "eligibility.mjs", "if (prev.block >= curr.block) {", "if (false) {"],
  ["order: allow the same block twice", "eligibility.mjs", "prev.block >= curr.block", "prev.block > curr.block"],

  // --- the eligibility bar ---
  ["bar: exclusive at the boundary", "eligibility.mjs", "if (weight < bar) continue;", "if (weight <= bar) continue;"],
  ["bar: inverted comparison", "eligibility.mjs", "if (weight < bar) continue;", "if (weight > bar) continue;"],
  ["bar: guard removed", "eligibility.mjs", "if (weight < bar) continue;", ""],
  ["bar: zero-bar guard removed", "eligibility.mjs", 'if (bar <= 0n) throw new Error("eligibility: bar must be positive");', ""],

  // --- exclusions ---
  ["exclusions: guard removed", "eligibility.mjs", "if (excluded.has(account)) continue;", ""],
  ["exclusions: guard inverted", "eligibility.mjs", "if (excluded.has(account)) continue;", "if (!excluded.has(account)) continue;"],
  ["exclusions: zero address no longer implicit", "eligibility.mjs", "const set = new Set([getAddress(ZERO)]);", "const set = new Set();"],

  // --- bar resolution ---
  ["bar: bps applied against the wrong denominator", "eligibility.mjs", "BigInt(barBps)) / 10_000n", "BigInt(barBps)) / 1_000n"],

  // --- allocation ---
  ["apportion: remainder never distributed", "allocate.mjs", "for (let i = 0; leftover > 0n; i++, leftover--) byRemainder[i].amount += 1n;", ""],
  ["apportion: over-allocate by one wei each", "allocate.mjs", "out[i].amount = num / sum;", "out[i].amount = num / sum + 1n;"],
  ["apportion: comparator loses tie ordering", "allocate.mjs", "return x < y ? -1 : x > y ? 1 : 0;", "return x < y ? -1 : 1;"],
  ["allocate: zero-amount leaves emitted", "allocate.mjs", "if (amount === 0n) continue;", ""],
  ["allocate: solvency assertion disabled", "allocate.mjs", "if (total > have) throw", "if (false) throw"],
  ["baskets: unknown preference drops the holder", "allocate.mjs", "wanted !== undefined && baskets.has(wanted) ? wanted : defaultBasketId", "wanted !== undefined ? wanted : defaultBasketId"],
  ["baskets: preference ignored entirely", "allocate.mjs", "wanted !== undefined && baskets.has(wanted) ? wanted : defaultBasketId", "defaultBasketId"],

  // --- merkle ---
  ["merkle: pair hash no longer commutative", "merkle.mjs", "return BigInt(a) < BigInt(b) ? keccak256(concatHex([a, b])) : keccak256(concatHex([b, a]));", "return keccak256(concatHex([a, b]));"],
  ["merkle: single-hashed leaf", "merkle.mjs", "return keccak256(inner);", "return inner;"],
  ["merkle: leaves no longer sorted", "merkle.mjs", "const sorted = [...leaves].sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : BigInt(a) > BigInt(b) ? 1 : 0));", "const sorted = [...leaves];"],
  ["merkle: duplicate leaves accepted", "merkle.mjs", "if (sorted[i] === sorted[i - 1]) throw", "if (false) throw"],
  ["merkle: epoch dropped from the leaf", "merkle.mjs", "[BigInt(epoch), holder, token, BigInt(amount)]", "[0n, holder, token, BigInt(amount)]"],
  ["merkle: holder and token swapped", "merkle.mjs", "[BigInt(epoch), holder, token, BigInt(amount)]", "[BigInt(epoch), token, holder, BigInt(amount)]"],

  // --- ledger ---
  ["ledger: replayed blocks silently double-count", "ledger.mjs", "if (block <= floor) throw", "if (false) throw"],
  ["ledger: credit and debit swapped", "ledger.mjs", "credit(ledger.balances, getAddress(log.args.from), -value);", "credit(ledger.balances, getAddress(log.args.from), value);"],
  ["ledger: future logs folded into the snapshot", "ledger.mjs", "if (block > through) throw", "if (false) throw"],

  // --- epoch gating ---
  ["epoch: bootstrap guard removed — first run would post on one snapshot", "epoch.mjs", "if (prevSnapshotBlock === null || prevSnapshotBlock === undefined) return { run: false, reason: BOOTSTRAP };", ""],
  ["epoch: bootstrap guard treats block 0 as missing", "epoch.mjs", "prevSnapshotBlock === null || prevSnapshotBlock === undefined", "!prevSnapshotBlock"],
  ["epoch: dust floor becomes exclusive", "epoch.mjs", "if (BigInt(pot) < BigInt(minPotUsdg))", "if (BigInt(pot) <= BigInt(minPotUsdg))"],
  ["epoch: chain cadence rail ignored", "epoch.mjs", "if (BigInt(now) < BigInt(lastRootAt) + BigInt(minEpochInterval)) return { run: false, reason: CADENCE_CHAIN };", ""],
  ["epoch: bond check removed", "epoch.mjs", "if (BigInt(bond) < BigInt(minBond))", "if (false)"],
  ["epoch: fallback grace ignored", "epoch.mjs", "if (!isKeeper && BigInt(now) < BigInt(lastKeeperRootAt) + BigInt(keeperGrace)) {", "if (false) {"],

  // --- preferences ---
  ["preferences: signature never verified", "preferences.mjs", "  return verifyTypedData({", "  return true;\n  return verifyTypedData({"],
  ["preferences: expiry ignored", "preferences.mjs", "if (BigInt(entry.deadline) < BigInt(asOf)) return false;", ""],
  ["preferences: lowest nonce wins", "preferences.mjs", "if (seen && seen.nonce >= nonce) continue;", "if (seen && seen.nonce <= nonce) continue;"],

  // --- the service loop ---
  ["keeper: snapshot taken at an unconfirmed head", "keeper.mjs", "const head = (await client.getBlockNumber()) - cfg.confirmations;", "const head = await client.getBlockNumber();"],
  ["keeper: snapshot window never advances", "keeper.mjs", "saveState(cfg.stateDir, { prevSnapshotBlock: head, lastSnapshotAt: now, lastEpochPosted: epoch });", "saveState(cfg.stateDir, { prevSnapshotBlock: state.prevSnapshotBlock, lastSnapshotAt: now, lastEpochPosted: epoch });"],
  ["keeper: posts something other than the manifest's root", "keeper.mjs", "args: [manifest.root],", "args: [manifest.snapshots.curr.digest],"],
  ["keeper: sends transactions without a wallet check", "keeper.mjs", "if (!wallet) {", "if (false) {"],

  // --- the liveness supervisor's verdict (G-LEND R6 LOW-1) ---
  ["health: BREAKER BLIND fatal again regardless of readability — red ~40h every week", "./keeper-health.mjs", "if (price.readable) {", "if (true) {"],
  ["health: BREAKER BLIND never fatal, so the mute costs the signal", "./keeper-health.mjs", "if (price.readable) {", "if (false) {"],
  ["health: a dark feed alarms instead of reporting", "./keeper-health.mjs", "say(false, `FEED DARK  the price is unreadable", "say(true, `FEED DARK  the price is unreadable"],
  ["health: observation ceiling becomes exclusive", "./keeper-health.mjs", "const observing = confAge <= maxAge;", "const observing = confAge < maxAge;"],
  ["health: observation ceiling inverted", "./keeper-health.mjs", "const observing = confAge <= maxAge;", "const observing = confAge >= maxAge;"],
  ["health: a stopped keeper is reported, not alarmed", "./keeper-health.mjs", "say(true, `UNOBSERVED", "say(false, `UNOBSERVED"],
  ["health: baseline ceiling becomes exclusive", "./keeper-health.mjs", "if (baseAge <= maxBaseline) return out;", "if (baseAge < maxBaseline) return out;"],
  ["health: baseline checked on every market, healthy or not", "./keeper-health.mjs", "if (baseAge <= maxBaseline) return out;", ""],
  ["health: the delay floor becomes inclusive", "./keeper-health.mjs", "} else if (confAge < delay) {", "} else if (confAge <= delay) {"],
  ["health: a never-filled delay line falls through to the age tests", "./keeper-health.mjs", "if (confirmedAt === 0n) {", "if (false) {"],
  ["health: a dead RPC reads as a dark feed (fail open)", "./keeper-health.mjs", "    await probeSameContract();\n    return { readable: false", "    return { readable: false"],
  ["health: a reverting price reads as readable anyway", "./keeper-health.mjs", "return { readable: false, revert: revertName(err) };", "return { readable: true, revert: null };"],

  // --- unreadable is the schedule only for the schedule's REASON, and only for as long as the
  // --- schedule can last (G-LEND R7 LOW-1). Both halves, both directions.
  ["health: any refusal is the weekend again", "./keeper-health.mjs", "if (price.revert !== SCHEDULE_REVERT) {", "if (false) {"],
  ["health: the revert test is inverted", "./keeper-health.mjs", "if (price.revert !== SCHEDULE_REVERT) {", "if (price.revert === SCHEDULE_REVERT) {"],
  ["health: the weekend becomes a BROKEN aggregator's error", "./keeper-health.mjs", 'const SCHEDULE_REVERT = "PriceStale";', 'const SCHEDULE_REVERT = "PriceNotPositive";'],
  ["health: a broken aggregator is reported, not alarmed", "./keeper-health.mjs", "say(true, `FEED BROKEN", "say(false, `FEED BROKEN"],
  ["health: an undecodable revert inherits the weekend's exemption", "./keeper-health.mjs", "?.data?.errorName ?? null;", "?.data?.errorName ?? SCHEDULE_REVERT;"],
  ["health: nothing is ever decodable", "./keeper-health.mjs", 'if (typeof err?.walk !== "function") return null;', "return null;"],
  ["health: the dark ceiling is dropped (unbounded again)", "./keeper-health.mjs", "} else if (baseAge > maxDark) {", "} else if (false) {"],
  ["health: the dark ceiling is inverted", "./keeper-health.mjs", "} else if (baseAge > maxDark) {", "} else if (baseAge < maxDark) {"],
  ["health: the dark ceiling becomes inclusive", "./keeper-health.mjs", "} else if (baseAge > maxDark) {", "} else if (baseAge >= maxDark) {"],
  ["health: a fortnight of darkness is reported, not alarmed", "./keeper-health.mjs", "say(true, `FEED DARK TOO LONG", "say(false, `FEED DARK TOO LONG"],
  ["health: MAX_DARK_AGE widened to a year", "./keeper-health.mjs", "export const MAX_DARK_AGE = 345_600n;", "export const MAX_DARK_AGE = 31_536_000n;"],
  ["health: MAX_DARK_AGE tightened below an ordinary weekend", "./keeper-health.mjs", "export const MAX_DARK_AGE = 345_600n;", "export const MAX_DARK_AGE = 86_400n;"],
  ["health: classifying with no ceiling at all is allowed", "./keeper-health.mjs", 'if (typeof maxDark !== "bigint") throw new Error("classifyMarket: maxDark (seconds, bigint) is required");', ""],

  // --- config ---
  ["config: EXECUTE armed by any truthy value", "config.mjs", 'execute: env.EXECUTE === "1",', "execute: Boolean(env.EXECUTE),"],
  ["config: describe leaks the signing key", "config.mjs", "const { privateKey, ...rest } = cfg;", "const rest = cfg;"],
  ["config: EXECUTE without a key is allowed", "config.mjs", 'if (cfg.execute && !cfg.privateKey) throw new Error("config: EXECUTE=1 needs KEEPER_PRIVKEY");', ""],
];

function runSuite() {
  const r = spawnSync("node", ["--test", "test/*.test.mjs"], { cwd: ROOT, encoding: "utf8", shell: true });
  return r.status === 0;
}

if (!runSuite()) {
  console.error("the suite is RED before any mutation — fix that first");
  process.exit(2);
}

const survivors = [];
for (const [name, file, from, to] of MUTATIONS) {
  const path = SRC(file);
  const original = readFileSync(path, "utf8");
  const occurrences = original.split(from).length - 1;
  if (occurrences !== 1) {
    console.error(`ANCHOR  ${name}: matched ${occurrences} times in ${file}, expected exactly 1`);
    process.exit(2);
  }
  writeFileSync(path, original.replace(from, to));
  let green;
  try {
    green = runSuite();
  } finally {
    writeFileSync(path, original);
  }
  if (green) survivors.push(name);
  console.log(`${green ? "SURVIVED" : "killed  "}  ${name}`);
}

console.log(`\n${MUTATIONS.length - survivors.length}/${MUTATIONS.length} mutants killed`);
if (survivors.length > 0) {
  console.log("SURVIVORS (nothing pins these):");
  for (const s of survivors) console.log(`  - ${s}`);
}
process.exit(survivors.length === 0 ? 0 : 1);
