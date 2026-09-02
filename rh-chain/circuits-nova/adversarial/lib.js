"use strict";

// Shared primitives for the adversarial witness suite. Poseidon is taken from
// circomlibjs so the JS commitment/nullifier hashing matches the circuit's
// Poseidon exactly; a mismatch would make the *valid* baseline fail witness
// generation, which is the suite's built-in canary.

const { execFileSync } = require("child_process");
const { mkdtempSync, writeFileSync, rmSync } = require("fs");
const { tmpdir } = require("os");
const { join } = require("path");

const CIRCOMLIBJS = process.env.CIRCOMLIBJS_PATH || "circomlibjs";
const { buildPoseidon } = require(CIRCOMLIBJS);

const FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const LEVELS = 20;

const HARNESS_DIR = __dirname;
const WASM = join(HARNESS_DIR, "build", "transaction2_js", "transaction2.wasm");
const WITNESS_CALC = join(HARNESS_DIR, "build", "transaction2_js", "witness_calculator.js");
const ZKEY = join(HARNESS_DIR, "build", "harness_final.zkey");
const VKEY = join(HARNESS_DIR, "build", "vkey.json");

let _poseidon = null;
async function poseidonReady() {
  if (!_poseidon) _poseidon = await buildPoseidon();
  return _poseidon;
}

// All hashing goes through circomlibjs; F.toObject returns a canonical bigint.
function hash(inputs) {
  const F = _poseidon.F;
  return F.toObject(_poseidon(inputs.map((x) => BigInt(x))));
}

function mod(x) {
  const r = BigInt(x) % FIELD;
  return r < 0n ? r + FIELD : r;
}

function keypair(privateKey) {
  const pk = mod(privateKey);
  return { privateKey: pk, publicKey: hash([pk]) };
}

function commitment(amount, pubKey, blinding) {
  return hash([amount, pubKey, blinding]);
}

function signature(privateKey, commit, merklePath) {
  return hash([privateKey, commit, merklePath]);
}

function nullifier(commit, merklePath, sig) {
  return hash([commit, merklePath, sig]);
}

// A depth-LEVELS tree whose empty siblings are the zero-subtree hashes, with a
// single real leaf at index 0. Enough to exercise the in-circuit Merkle proof;
// on-chain root validity (isKnownRoot) is a contract concern, out of scope here.
function singleLeafTree(leaf, zeroBase = 0n) {
  const zeros = [mod(zeroBase)];
  for (let i = 1; i <= LEVELS; i++) zeros.push(hash([zeros[i - 1], zeros[i - 1]]));

  const pathElements = [];
  let cur = mod(leaf);
  for (let i = 0; i < LEVELS; i++) {
    pathElements.push(zeros[i]);
    cur = hash([cur, zeros[i]]); // pathIndices bit = 0 => leaf on the left
  }
  return { root: cur, pathElements, pathIndices: 0n };
}

// A fully-valid dummy (zero-amount) input. The circuit disables the Merkle check
// when inAmount == 0, so no real tree membership is needed for these.
function dummyInput(privateKey, blinding) {
  const kp = keypair(privateKey);
  const commit = commitment(0n, kp.publicKey, blinding);
  const merklePath = 0n;
  const sig = signature(kp.privateKey, commit, merklePath);
  return {
    amount: 0n,
    privateKey: kp.privateKey,
    blinding: mod(blinding),
    pathIndices: 0n,
    pathElements: new Array(LEVELS).fill(0n),
    commitment: commit,
    nullifier: nullifier(commit, merklePath, sig),
  };
}

// A real spendable input of `amount`, sitting at index 0 of its own tree.
function realInput(privateKey, blinding, amount) {
  const kp = keypair(privateKey);
  const commit = commitment(amount, kp.publicKey, blinding);
  const tree = singleLeafTree(commit);
  const sig = signature(kp.privateKey, commit, tree.pathIndices);
  return {
    amount: mod(amount),
    privateKey: kp.privateKey,
    blinding: mod(blinding),
    pathIndices: tree.pathIndices,
    pathElements: tree.pathElements,
    commitment: commit,
    nullifier: nullifier(commit, tree.pathIndices, sig),
    root: tree.root,
  };
}

function output(pubKeyOwner, blinding, amount) {
  const pubKey = typeof pubKeyOwner === "object" ? pubKeyOwner.publicKey : mod(pubKeyOwner);
  return {
    amount: mod(amount),
    pubKey,
    blinding: mod(blinding),
    commitment: commitment(mod(amount), pubKey, mod(blinding)),
  };
}

// Assemble the circuit input.json object from 2 inputs + 2 outputs.
function buildInput({ root, publicAmount, extDataHash, ins, outs }) {
  const s = (x) => mod(x).toString();
  return {
    root: s(root),
    publicAmount: s(publicAmount),
    extDataHash: s(extDataHash),
    inputNullifier: ins.map((i) => s(i.nullifier)),
    inAmount: ins.map((i) => s(i.amount)),
    inPrivateKey: ins.map((i) => s(i.privateKey)),
    inBlinding: ins.map((i) => s(i.blinding)),
    inPathIndices: ins.map((i) => s(i.pathIndices)),
    inPathElements: ins.map((i) => i.pathElements.map(s)),
    outputCommitment: outs.map((o) => s(o.commitment)),
    outAmount: outs.map((o) => s(o.amount)),
    outPubkey: outs.map((o) => s(o.pubKey)),
    outBlinding: outs.map((o) => s(o.blinding)),
  };
}

// Run the wasm witness calculator. The generated calculator evaluates every
// circuit constraint; a violated `===` throws here. So a throw == the R1CS is
// unsatisfiable for these inputs == no honest proof exists for this assignment.
async function calcWitness(input, outPath) {
  const wc = require(WITNESS_CALC);
  const { readFileSync, writeFileSync } = require("fs");
  const calculator = await wc(readFileSync(WASM));
  const buff = await calculator.calculateWTNSBin(input, 0);
  writeFileSync(outPath, buff);
}

function prove(wtnsPath, dir) {
  const proof = join(dir, "proof.json");
  const pub = join(dir, "public.json");
  execFileSync("snarkjs", ["groth16", "prove", ZKEY, wtnsPath, proof, pub], { stdio: "pipe" });
  return { proof, pub };
}

function verify(pubPath, proofPath) {
  try {
    const out = execFileSync("snarkjs", ["groth16", "verify", VKEY, pubPath, proofPath], {
      stdio: "pipe",
    }).toString();
    return /OK!/.test(out);
  } catch {
    return false;
  }
}

function tmp() {
  return mkdtempSync(join(tmpdir(), "advzk-"));
}

module.exports = {
  FIELD,
  LEVELS,
  VKEY,
  ZKEY,
  poseidonReady,
  hash,
  mod,
  keypair,
  commitment,
  signature,
  nullifier,
  singleLeafTree,
  dummyInput,
  realInput,
  output,
  buildInput,
  calcWitness,
  prove,
  verify,
  tmp,
  writeFileSync,
  rmSync,
  join,
};
