"use strict";

// Adversarial witness suite for the Essey shielded-pool circuit
// (Transaction(20,2,2) — Tornado-Nova fork). Threat model: a malicious prover
// with unlimited compute who controls every private input. For each attack we
// craft the witness the attacker WANTS and confirm the circuit refuses to prove
// it. A malicious witness that produces a VERIFYING proof is a CRITICAL finding.
//
// Two rejection mechanisms are exercised:
//   witness-reject : the wasm calculator evaluates all constraints, so a
//                    violated `===` throws -> the R1CS is unsatisfiable for that
//                    assignment -> no honest proof can exist.
//   pubsig-binding : from a VALID proof, mutate a public signal and re-verify;
//                    a proof that still verifies for a changed statement means
//                    that public signal is not bound.
//
// Add a case by pushing to TESTS. This file is meant to be grown by essey-zk-auditor.

const L = require("./lib");

const OWNER = L; // alias for readability in output builders below

function section(t) {
  console.log("\n" + "=".repeat(72) + "\n" + t + "\n" + "=".repeat(72));
}

// ---- witness-reject harness -------------------------------------------------
// expectReject: the circuit MUST refuse. Returns a result record.
async function witnessReject(name, buildInputObj) {
  const dir = L.tmp();
  const wtns = L.join(dir, "w.wtns");
  const inputPath = L.join(dir, "input.json");
  let record = { name, category: "witness-reject" };
  try {
    const input = buildInputObj();
    L.writeFileSync(inputPath, JSON.stringify(input, null, 2));
    await L.calcWitness(input, wtns);
  } catch (e) {
    const msg = (e && e.message ? e.message : String(e)).split("\n")[0].slice(0, 120);
    record.status = "REJECTED_OK";
    record.detail = "witness generation threw: " + msg;
    L.rmSync(dir, { recursive: true, force: true });
    return record;
  }
  // Witness generated despite the fraud -> try to actually prove + verify it.
  try {
    const { proof, pub } = L.prove(wtns, dir);
    const ok = L.verify(pub, proof);
    record.status = ok ? "PROVED_CRITICAL" : "REJECTED_OK";
    record.detail = ok
      ? "MALICIOUS WITNESS PRODUCED A VERIFYING PROOF"
      : "witness built but proof failed verification";
  } catch (e) {
    record.status = "REJECTED_OK";
    record.detail = "prove step failed: " + (e.message || String(e)).split("\n")[0].slice(0, 100);
  }
  L.rmSync(dir, { recursive: true, force: true });
  return record;
}

// ---- valid baseline + pubsig-binding ---------------------------------------
async function validBaseline(name, buildInputObj) {
  const dir = L.tmp();
  const wtns = L.join(dir, "w.wtns");
  let record = { name, category: "baseline" };
  try {
    const input = buildInputObj();
    await L.calcWitness(input, wtns);
    const { proof, pub } = L.prove(wtns, dir);
    const ok = L.verify(pub, proof);
    record.status = ok ? "VALID_OK" : "CANARY_FAIL";
    record.detail = ok ? "valid tx proved and verified" : "valid tx FAILED to verify (harness/Poseidon mismatch)";
    record._dir = dir; // keep for pubsig mutation
    record._pub = pub;
    record._proof = proof;
  } catch (e) {
    record.status = "CANARY_FAIL";
    record.detail = "valid baseline threw: " + (e.message || String(e)).split("\n")[0].slice(0, 140);
    L.rmSync(dir, { recursive: true, force: true });
  }
  return record;
}

// Mutate each public signal of a valid proof and confirm verification fails.
async function pubsigBinding(baselineRecord) {
  const results = [];
  if (baselineRecord.status !== "VALID_OK") {
    return [{ name: "pubsig-binding (skipped)", category: "pubsig-binding", status: "ERROR", detail: "no valid baseline" }];
  }
  const fs = require("fs");
  const orig = JSON.parse(fs.readFileSync(baselineRecord._pub, "utf8"));
  const labels = ["root", "publicAmount", "extDataHash", "inputNullifier[0]", "inputNullifier[1]", "outputCommitment[0]", "outputCommitment[1]"];
  for (let i = 0; i < orig.length; i++) {
    const mutated = orig.slice();
    mutated[i] = (L.mod(BigInt(orig[i]) + 12345n)).toString();
    const mpath = baselineRecord._pub + `.mut${i}.json`;
    fs.writeFileSync(mpath, JSON.stringify(mutated));
    const stillVerifies = L.verify(mpath, baselineRecord._proof);
    results.push({
      name: `pubsig binding: ${labels[i]}`,
      category: "pubsig-binding",
      status: stillVerifies ? "PROVED_CRITICAL" : "REJECTED_OK",
      detail: stillVerifies ? "proof verifies for a MUTATED public signal (unbound!)" : "mutation rejected (signal bound)",
    });
  }
  L.rmSync(baselineRecord._dir, { recursive: true, force: true });
  return results;
}

async function main() {
  await L.poseidonReady();

  // Shared honest actors.
  const alice = L.keypair(111111n);
  const bob = L.keypair(222222n);
  const attacker = L.keypair(999999n);

  const results = [];

  section("BASELINE (canaries) — these MUST pass/verify");

  // Baseline 1: pure deposit. 2 dummy zero inputs, publicAmount=100, outputs 60+40.
  const depositBuild = () => {
    const ins = [L.dummyInput(101n, 1n), L.dummyInput(102n, 2n)];
    const outs = [L.output(alice, 555n, 60n), L.output(bob, 666n, 40n)];
    return L.buildInput({ root: 0n, publicAmount: 100n, extDataHash: 1n, ins, outs });
  };
  const depositBase = await validBaseline("valid deposit (2 dummy in, out 60+40, pub=100)", depositBuild);
  results.push(depositBase);

  // Baseline 2: spend of a real note. 1 real input(100) + 1 dummy, pub=0, out 70+30.
  const realIn = L.realInput(333333n, 4242n, 100n);
  const spendBuild = () => {
    const ins = [realIn, L.dummyInput(103n, 3n)];
    const outs = [L.output(alice, 777n, 70n), L.output(bob, 888n, 30n)];
    return L.buildInput({ root: realIn.root, publicAmount: 0n, extDataHash: 7n, ins, outs });
  };
  const spendBase = await validBaseline("valid spend (real note 100 -> 70+30, pub=0)", spendBuild);
  results.push(spendBase);

  section("ATTACKS — each MUST be rejected; a verifying proof = CRITICAL");

  // (a) VALUE CREATION: outputs (700+300)=1000 while sumIns+publicAmount=100.
  results.push(await witnessReject("(a) value creation: out 700+300 vs in 0 + pub 100", () => {
    const ins = [L.dummyInput(101n, 1n), L.dummyInput(102n, 2n)];
    const outs = [L.output(alice, 555n, 700n), L.output(bob, 666n, 300n)];
    return L.buildInput({ root: 0n, publicAmount: 100n, extDataHash: 1n, ins, outs });
  }));

  // (a') SUBTLER value creation on the spend path: real in 100 -> out 100+100.
  results.push(await witnessReject("(a') value creation on spend: 100 in -> 100+100 out", () => {
    const ins = [realIn, L.dummyInput(103n, 3n)];
    const outs = [L.output(alice, 777n, 100n), L.output(bob, 888n, 100n)];
    return L.buildInput({ root: realIn.root, publicAmount: 0n, extDataHash: 7n, ins, outs });
  }));

  // (b) INTRA-TX DUPLICATE NULLIFIER: spend the SAME real note twice in one tx.
  results.push(await witnessReject("(b) duplicate nullifier: same note as both inputs", () => {
    const dup = L.realInput(333333n, 4242n, 100n); // identical -> identical nullifier
    const ins = [dup, dup];
    const outs = [L.output(alice, 777n, 120n), L.output(bob, 888n, 80n)];
    return L.buildInput({ root: dup.root, publicAmount: 0n, extDataHash: 7n, ins, outs });
  }));

  // (c) FORGED MERKLE ROOT: real (nonzero) input but claim a root the path can't reach.
  results.push(await witnessReject("(c) forged merkle root: root != recomputed path root", () => {
    const ins = [realIn, L.dummyInput(103n, 3n)];
    const outs = [L.output(alice, 777n, 70n), L.output(bob, 888n, 30n)];
    return L.buildInput({ root: L.mod(realIn.root + 1n), publicAmount: 0n, extDataHash: 7n, ins, outs });
  }));

  // (c') FORGED MERKLE PATH: correct root but a tampered sibling element.
  results.push(await witnessReject("(c') forged merkle path: tampered pathElements[0]", () => {
    const bad = { ...realIn, pathElements: realIn.pathElements.slice() };
    bad.pathElements = bad.pathElements.slice();
    bad.pathElements[0] = L.mod(BigInt(realIn.pathElements[0]) + 1n);
    const ins = [bad, L.dummyInput(103n, 3n)];
    const outs = [L.output(alice, 777n, 70n), L.output(bob, 888n, 30n)];
    return L.buildInput({ root: realIn.root, publicAmount: 0n, extDataHash: 7n, ins, outs });
  }));

  // (d) FORGED OWNERSHIP: spend alice's note providing the ATTACKER's private key.
  results.push(await witnessReject("(d) forged ownership: spend note with wrong privkey", () => {
    // real note owned by 333333; attacker supplies a different privkey but keeps
    // the victim's commitment/path/nullifier. Circuit recomputes commitment from
    // attacker pubkey -> leaf mismatch -> merkle root check fails.
    const forged = { ...realIn, privateKey: attacker.privateKey };
    const ins = [forged, L.dummyInput(103n, 3n)];
    const outs = [L.output(attacker, 777n, 70n), L.output(attacker, 888n, 30n)];
    return L.buildInput({ root: realIn.root, publicAmount: 0n, extDataHash: 7n, ins, outs });
  }));

  // (d') FORGED NULLIFIER: inputNullifier not equal to Poseidon(commit,path,sig).
  results.push(await witnessReject("(d') forged nullifier: inputNullifier tampered", () => {
    const forged = { ...realIn, nullifier: L.mod(realIn.nullifier + 1n) };
    const ins = [forged, L.dummyInput(103n, 3n)];
    const outs = [L.output(alice, 777n, 70n), L.output(bob, 888n, 30n)];
    return L.buildInput({ root: realIn.root, publicAmount: 0n, extDataHash: 7n, ins, outs });
  }));

  // (e) 248-BIT OVERFLOW: an output amount above 2^248 with a matching commitment.
  results.push(await witnessReject("(e) overflow: outAmount = 2^248 (> 248-bit range)", () => {
    const big = 1n << 248n;
    const ins = [L.dummyInput(101n, 1n), L.dummyInput(102n, 2n)];
    const outs = [L.output(alice, 555n, big), L.output(bob, 666n, L.mod(100n - big))];
    // sumOuts = big + (100-big) = 100 (mod p); pub=100 balances -> only the range
    // check on outAmount[0] stands between this and minted value.
    return L.buildInput({ root: 0n, publicAmount: 100n, extDataHash: 1n, ins, outs });
  }));

  // (e') NEGATIVE-AMOUNT ALIASING: outAmount = p-100 (== -100) to wrap the sum.
  results.push(await witnessReject("(e') aliasing: outAmount = FIELD-100 (negative)", () => {
    const neg = L.mod(-100n); // FIELD - 100
    const ins = [L.dummyInput(101n, 1n), L.dummyInput(102n, 2n)];
    const outs = [L.output(alice, 555n, neg), L.output(bob, 666n, 200n)];
    // sumOuts = (p-100) + 200 = p+100 == 100 (mod p); pub=100 balances the field
    // equation, but outAmount[0] is ~254-bit -> Num2Bits(248) must reject.
    return L.buildInput({ root: 0n, publicAmount: 100n, extDataHash: 1n, ins, outs });
  }));

  section("PUBLIC-SIGNAL BINDING — mutate a valid proof's public inputs");
  const bindResults = await pubsigBinding(depositBase);
  for (const r of bindResults) results.push(r);
  // spend baseline dir cleanup
  if (spendBase._dir) L.rmSync(spendBase._dir, { recursive: true, force: true });

  // ---- report ----
  section("RESULTS");
  let critical = 0, canary = 0;
  for (const r of results) {
    const flag =
      r.status === "PROVED_CRITICAL" ? "CRITICAL" :
      r.status === "CANARY_FAIL" ? "CANARY-FAIL" :
      r.status === "VALID_OK" ? "ok" :
      r.status === "REJECTED_OK" ? "rejected" : r.status;
    if (r.status === "PROVED_CRITICAL") critical++;
    if (r.status === "CANARY_FAIL") canary++;
    console.log(`[${flag.padEnd(11)}] ${r.name}\n              -> ${r.detail}`);
  }
  section("VERDICT");
  console.log(`baselines: ${results.filter(r => r.status === "VALID_OK").length} verified, ${canary} canary-fail`);
  console.log(`attacks:   ${results.filter(r => r.status === "REJECTED_OK").length} rejected, ${critical} CRITICAL`);
  if (canary > 0) {
    console.log("\nCANARY FAILED — the harness could not prove a valid tx; results below are unreliable.");
    process.exit(2);
  }
  if (critical > 0) {
    console.log("\nCRITICAL: at least one malicious witness produced a verifying proof or an unbound public signal.");
    process.exit(1);
  }
  console.log("\nAll attacks rejected and all valid baselines verified.");
}

main().catch((e) => {
  console.error("harness error:", e);
  process.exit(3);
});
