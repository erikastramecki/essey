// Browser-compatible prover SDK for the Essey shielded pool.
//
// UTXO/keypair model + Merkle tree + extData hashing, matched EXACTLY to the
// deployed EsseyShieldedPool.sol / MerkleTreeWithHistory.sol (depth-20 circuit,
// transaction2.wasm / transaction2.zkey). Ported from the reference nova-port
// SDK to the app's stack:
//   - Poseidon via circomlibjs `buildPoseidon` (async, cached once).
//   - Randomness via `globalThis.crypto.getRandomValues` (browser + node Web Crypto).
//   - extDataHash via viem `keccak256` + `encodeAbiParameters` (NOT ethers).
//   - Proving via `snarkjs.groth16.fullProve`.
//
// MONEY-CRITICAL: a wrong commitment / nullifier / root => failed txs or lost
// notes. The proving semantics here are verified end-to-end against the deployed
// verification key.

import { buildPoseidon } from "circomlibjs";
import { keccak256, encodeAbiParameters, bytesToHex, hexToBytes } from "viem";
// snarkjs ships as CommonJS with named exports (`groth16`, ...); use a namespace
// import so it resolves under both vite (browser) and node ESM.
import * as snarkjs from "snarkjs";
// Phase-2 on-chain encrypted notes: secp256k1 ECIES (ephemeral ECDH -> HKDF-SHA256
// -> XChaCha20-Poly1305). All @noble subpath ESM imports resolve under vite (browser)
// and node — same libs the stealth layer already ships.
import { secp256k1 } from "@noble/curves/secp256k1";
import { bytesToNumberBE, numberToBytesBE } from "@noble/curves/abstract/utils";
import { keccak_256 } from "@noble/hashes/sha3";
import { hkdf } from "@noble/hashes/hkdf";
import { sha256 } from "@noble/hashes/sha256";
import { xchacha20poly1305 } from "@noble/ciphers/chacha";
import { concatBytes, randomBytes } from "@noble/hashes/utils";

// ---- Constants (must match the deployed pool exactly) ----
export const FIELD_SIZE =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;
// keccak256("tornado") % FIELD_SIZE
export const ZERO_VALUE =
  21663839004416932945382355908790599225266501822907911457504978515578255421292n;
const LEVELS = 20;

const DEFAULT_WASM_URL = "/pool/transaction2.wasm";
const DEFAULT_ZKEY_URL = "/pool/transaction2.zkey";

// ---- Exported API types ----
export interface PoolKeypair {
  privkey: bigint;
  pubkey: bigint;
}
export interface PoolNote {
  amount: string;
  blinding: string;
  index: number; // pubkey re-derived from the keypair
}
export interface ProofCalldata {
  a: [bigint, bigint];
  b: [[bigint, bigint], [bigint, bigint]];
  c: [bigint, bigint];
  root: bigint;
  inputNullifiers: [bigint, bigint];
  outputCommitments: [bigint, bigint];
  publicAmount: bigint;
  extDataHash: bigint;
}
export interface PoolExtData {
  recipient: `0x${string}`;
  extAmount: bigint;
  relayer: `0x${string}`;
  fee: bigint;
  encryptedOutput1: `0x${string}`;
  encryptedOutput2: `0x${string}`;
}

// ---- Poseidon (cached once) ----
type HashFn = (arr: Array<bigint | string | number>) => bigint;
let _H: HashFn | null = null;

export async function initPool(): Promise<void> {
  if (_H) return;
  const poseidon = await buildPoseidon();
  const F = poseidon.F;
  _H = (arr) => BigInt(F.toString(poseidon(arr.map((x) => BigInt(x)))));
}

function H(arr: Array<bigint | string | number>): bigint {
  if (!_H) throw new Error("poolsdk not initialised: call initPool() first");
  return _H(arr);
}

// ---- Portable randomness: 31 field-safe bytes (<254 bits) ----
function randField(): bigint {
  const b = new Uint8Array(31);
  globalThis.crypto.getRandomValues(b);
  let hex = "";
  for (const x of b) hex += x.toString(16).padStart(2, "0");
  return BigInt("0x" + hex);
}

// ---- Keypair / Utxo model (tornado-nova) ----
class Keypair {
  privkey: bigint;
  pubkey: bigint;
  // `pubkeyOverride` builds an output-only keypair for a RECIPIENT whose spend
  // pubkey is known but whose privkey is not (private transfers). Such a keypair
  // can never spend (privkey stays 0), only receive a commitment.
  constructor(privkey: bigint = randField(), pubkeyOverride?: bigint) {
    this.privkey = BigInt(privkey);
    this.pubkey = pubkeyOverride !== undefined ? BigInt(pubkeyOverride) : H([this.privkey]); // pubkey = Poseidon(privkey)
  }
  // signature = Poseidon(privKey, commitment, merklePath)
  sign(commitment: bigint, merklePath: bigint): bigint {
    return H([this.privkey, commitment, merklePath]);
  }
}

class Utxo {
  amount: bigint;
  keypair: Keypair;
  blinding: bigint;
  index: number;
  private _commitment?: bigint;
  private _nullifier?: bigint;
  constructor(opts: {
    amount?: bigint;
    keypair?: Keypair;
    blinding?: bigint;
    index?: number;
  } = {}) {
    this.amount = BigInt(opts.amount ?? 0n);
    this.keypair = opts.keypair ?? new Keypair();
    this.blinding = BigInt(opts.blinding ?? randField());
    this.index = opts.index ?? 0;
  }
  // commitment = Poseidon(amount, pubkey, blinding)
  getCommitment(): bigint {
    if (this._commitment === undefined) {
      this._commitment = H([this.amount, this.keypair.pubkey, this.blinding]);
    }
    return this._commitment;
  }
  // nullifier = Poseidon(commitment, index, sign(priv, commitment, index))
  getNullifier(): bigint {
    if (this._nullifier === undefined) {
      const signature = this.keypair.privkey
        ? this.keypair.sign(this.getCommitment(), BigInt(this.index))
        : 0n;
      this._nullifier = H([this.getCommitment(), BigInt(this.index), signature]);
    }
    return this._nullifier;
  }
}

// ---- Merkle tree, matched to MerkleTreeWithHistory.sol ----
// zeros(0)=ZERO_VALUE, zeros(i)=Poseidon(zeros(i-1),zeros(i-1)). Sparse build so
// depth 20 is feasible. Insert-in-pairs => same roots as the contract.
class MerkleTree {
  levels: number;
  zeros: bigint[];
  leaves: bigint[];
  constructor(levels: number) {
    this.levels = levels;
    this.zeros = [ZERO_VALUE];
    for (let i = 1; i <= levels; i++) {
      this.zeros.push(H([this.zeros[i - 1], this.zeros[i - 1]]));
    }
    this.leaves = [];
  }
  insert(leaf: bigint) {
    this.leaves.push(BigInt(leaf));
  }
  private _build(): Array<Map<number, bigint>> {
    const cur = new Map<number, bigint>();
    this.leaves.forEach((v, i) => cur.set(i, v));
    const layers: Array<Map<number, bigint>> = [cur];
    for (let l = 0; l < this.levels; l++) {
      const prev = layers[l];
      const next = new Map<number, bigint>();
      const parents = new Set<number>();
      for (const idx of prev.keys()) parents.add(idx >> 1);
      for (const p of parents) {
        const left = prev.has(2 * p) ? prev.get(2 * p)! : this.zeros[l];
        const right = prev.has(2 * p + 1) ? prev.get(2 * p + 1)! : this.zeros[l];
        next.set(p, H([left, right]));
      }
      layers.push(next);
    }
    return layers;
  }
  root(): bigint {
    const layers = this._build();
    const top = layers[this.levels];
    return top.has(0) ? top.get(0)! : this.zeros[this.levels];
  }
  path(index: number): { pathElements: string[]; pathIndices: number } {
    const layers = this._build();
    const pathElements: string[] = [];
    let idx = index;
    let pathIndices = 0;
    for (let l = 0; l < this.levels; l++) {
      const sibIdx = idx % 2 === 0 ? idx + 1 : idx - 1;
      const layer = layers[l];
      const sibling = layer.has(sibIdx) ? layer.get(sibIdx)! : this.zeros[l];
      pathElements.push(sibling.toString());
      if (idx % 2 === 1) pathIndices |= 1 << l;
      idx = idx >> 1;
    }
    return { pathElements, pathIndices };
  }
}

// ---- extDataHash: uint256(keccak256(abi.encode(ExtData))) % FIELD_SIZE ----
// ExtData = (address recipient, int256 extAmount, address relayer, uint256 fee,
//            bytes encryptedOutput1, bytes encryptedOutput2)
function getExtDataHash(ext: PoolExtData): bigint {
  const encoded = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "recipient", type: "address" },
          { name: "extAmount", type: "int256" },
          { name: "relayer", type: "address" },
          { name: "fee", type: "uint256" },
          { name: "encryptedOutput1", type: "bytes" },
          { name: "encryptedOutput2", type: "bytes" },
        ],
      },
    ],
    [
      {
        recipient: ext.recipient,
        extAmount: ext.extAmount,
        relayer: ext.relayer,
        fee: ext.fee,
        encryptedOutput1: ext.encryptedOutput1,
        encryptedOutput2: ext.encryptedOutput2,
      },
    ],
  );
  return BigInt(keccak256(encoded)) % FIELD_SIZE;
}

// calculatePublicAmount(extAmount, fee): (extAmount-fee>=0)? it : FIELD - abs
function calculatePublicAmount(extAmount: bigint, fee: bigint): bigint {
  const p = BigInt(extAmount) - BigInt(fee);
  return p >= 0n ? p : FIELD_SIZE - -p;
}

// ---- Keypair derivation (deterministic, like the stealth keys) ----
// privkey = keccak256(signature) % FIELD ; pubkey = Poseidon(privkey)
export function deriveKeypair(signatureHex: string): PoolKeypair {
  const sig = (signatureHex.startsWith("0x") ? signatureHex : "0x" + signatureHex) as `0x${string}`;
  const privkey = BigInt(keccak256(sig)) % FIELD_SIZE;
  const pubkey = H([privkey]);
  return { privkey, pubkey };
}

// ---- snarkjs proving + calldata assembly ----
// publicSignals order (circuit: public [root, publicAmount, extDataHash,
// inputNullifier, outputCommitment]):
//   [0] root, [1] publicAmount, [2] extDataHash,
//   [3] inputNullifier[0], [4] inputNullifier[1],
//   [5] outputCommitment[0], [6] outputCommitment[1]
function assembleCalldata(proof: any, publicSignals: string[]): ProofCalldata {
  // G2 point b needs its coordinate pairs swapped for the Solidity verifier
  // (this is exactly what snarkjs exportSolidityCallData does).
  const a: [bigint, bigint] = [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])];
  const b: [[bigint, bigint], [bigint, bigint]] = [
    [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])],
    [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])],
  ];
  const c: [bigint, bigint] = [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])];
  return {
    a,
    b,
    c,
    root: BigInt(publicSignals[0]),
    publicAmount: BigInt(publicSignals[1]),
    extDataHash: BigInt(publicSignals[2]),
    inputNullifiers: [BigInt(publicSignals[3]), BigInt(publicSignals[4])],
    outputCommitments: [BigInt(publicSignals[5]), BigInt(publicSignals[6])],
  };
}

function buildCircuitInput(
  root: bigint,
  publicAmount: bigint,
  extDataHash: bigint,
  inputs: Utxo[],
  inPathElements: string[][],
  inPathIndices: number[],
  outputs: Utxo[],
) {
  return {
    root: root.toString(),
    publicAmount: publicAmount.toString(),
    extDataHash: extDataHash.toString(),
    inputNullifier: inputs.map((x) => x.getNullifier().toString()),
    inAmount: inputs.map((x) => x.amount.toString()),
    inPrivateKey: inputs.map((x) => x.keypair.privkey.toString()),
    inBlinding: inputs.map((x) => x.blinding.toString()),
    inPathIndices: inPathIndices.map((x) => x.toString()),
    inPathElements,
    outputCommitment: outputs.map((x) => x.getCommitment().toString()),
    outAmount: outputs.map((x) => x.amount.toString()),
    outPubkey: outputs.map((x) => x.keypair.pubkey.toString()),
    outBlinding: outputs.map((x) => x.blinding.toString()),
  };
}

async function prove(
  input: ReturnType<typeof buildCircuitInput>,
  opts?: { wasmUrl?: string; zkeyUrl?: string },
): Promise<ProofCalldata> {
  const wasm = opts?.wasmUrl ?? DEFAULT_WASM_URL;
  const zkey = opts?.zkeyUrl ?? DEFAULT_ZKEY_URL;
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(input, wasm, zkey);
  return assembleCalldata(proof, publicSignals);
}

// ---- Deposit ----
// 2 zero-amount dummy inputs (fresh keypairs, merkle check disabled), output[0]
// = a real note {amount, random blinding, kp.pubkey} at index allLeaves.length,
// output[1] = zero. extAmount=+amount, fee=0, recipient/relayer=0, encOut=0x.
export async function buildDepositProof(
  kp: PoolKeypair,
  encKp: PoolEncKeypair,
  amount: bigint,
  allLeaves: bigint[],
  opts?: { wasmUrl?: string; zkeyUrl?: string },
): Promise<{ proof: ProofCalldata; ext: PoolExtData; note: PoolNote }> {
  if (amount <= 0n) throw new Error("deposit amount must be positive");

  const tree = new MerkleTree(LEVELS);
  for (const leaf of allLeaves) tree.insert(leaf);
  const root = tree.root();

  // Two zero-amount dummy inputs. Distinct keypairs => distinct nullifiers.
  const inputs = [new Utxo({ amount: 0n, index: 0 }), new Utxo({ amount: 0n, index: 0 })];
  const inPathElements = inputs.map(() => new Array(LEVELS).fill("0"));
  const inPathIndices = [0, 0];

  const noteIndex = allLeaves.length;
  const noteKeypair = new Keypair(kp.privkey);
  const out0 = new Utxo({ amount, keypair: noteKeypair, index: noteIndex });
  const out1 = new Utxo({ amount: 0n, index: noteIndex + 1 });
  const outputs = [out0, out1];

  const ext: PoolExtData = {
    recipient: "0x0000000000000000000000000000000000000000",
    extAmount: amount,
    relayer: "0x0000000000000000000000000000000000000000",
    fee: 0n,
    // The deposit note (out0) encrypted to the depositor's OWN enc key, so it is
    // recoverable on a fresh device by scanning NewCommitment events. out1 is the
    // zero note => no ciphertext. The extDataHash below covers this, so the
    // contract's keccak(abi.encode(ExtData)) check still passes.
    encryptedOutput1: encryptNote(out0.amount, out0.blinding, encKp.encPub),
    encryptedOutput2: "0x",
  };
  const extDataHash = getExtDataHash(ext);
  const publicAmount = calculatePublicAmount(amount, 0n);

  const input = buildCircuitInput(
    root,
    publicAmount,
    extDataHash,
    inputs,
    inPathElements,
    inPathIndices,
    outputs,
  );
  const proof = await prove(input, opts);

  const note: PoolNote = {
    amount: out0.amount.toString(),
    blinding: out0.blinding.toString(),
    index: noteIndex,
  };
  return { proof, ext, note };
}

// ---- Withdraw ----
// input[0] = the stored real note (merkle path from tree(allLeaves).path(index)),
// input[1] = zero dummy. output[0] = change note if change>0 else zero,
// output[1] = zero. extAmount = -withdrawAmount, recipient set.
export async function buildWithdrawProof(
  kp: PoolKeypair,
  encKp: PoolEncKeypair,
  note: PoolNote,
  withdrawAmount: bigint,
  recipient: `0x${string}`,
  allLeaves: bigint[],
  opts?: { wasmUrl?: string; zkeyUrl?: string },
): Promise<{ proof: ProofCalldata; ext: PoolExtData; changeNote: PoolNote | null }> {
  const noteAmount = BigInt(note.amount);
  if (withdrawAmount <= 0n) throw new Error("withdraw amount must be positive");
  if (withdrawAmount > noteAmount) throw new Error("withdraw amount exceeds note balance");

  const tree = new MerkleTree(LEVELS);
  for (const leaf of allLeaves) tree.insert(leaf);
  const root = tree.root();
  const { pathElements, pathIndices } = tree.path(note.index);

  const noteKeypair = new Keypair(kp.privkey);
  const inNote = new Utxo({
    amount: noteAmount,
    keypair: noteKeypair,
    blinding: BigInt(note.blinding),
    index: note.index,
  });
  // Sanity: reconstructed commitment must equal the leaf actually in the tree.
  if (inNote.getCommitment() !== allLeaves[note.index]) {
    throw new Error("note commitment does not match the leaf at its index");
  }

  const inZero = new Utxo({ amount: 0n, index: 0 });
  const inputs = [inNote, inZero];
  const inPathElements = [pathElements, new Array(LEVELS).fill("0")];
  const inPathIndices = [pathIndices, 0];

  const change = noteAmount - withdrawAmount;
  const changeIndex = allLeaves.length;
  const out0 =
    change > 0n
      ? new Utxo({ amount: change, keypair: noteKeypair, index: changeIndex })
      : new Utxo({ amount: 0n, index: changeIndex });
  const out1 = new Utxo({ amount: 0n, index: changeIndex + 1 });
  const outputs = [out0, out1];

  const ext: PoolExtData = {
    recipient,
    extAmount: -withdrawAmount,
    relayer: "0x0000000000000000000000000000000000000000",
    fee: 0n,
    // Encrypt the change note (out0) to self so it survives a device wipe. If there
    // is no change (full withdraw), out0 is the zero note => no ciphertext.
    encryptedOutput1:
      change > 0n ? encryptNote(out0.amount, out0.blinding, encKp.encPub) : "0x",
    encryptedOutput2: "0x",
  };
  const extDataHash = getExtDataHash(ext);
  const publicAmount = calculatePublicAmount(-withdrawAmount, 0n);

  const input = buildCircuitInput(
    root,
    publicAmount,
    extDataHash,
    inputs,
    inPathElements,
    inPathIndices,
    outputs,
  );
  const proof = await prove(input, opts);

  const changeNote: PoolNote | null =
    change > 0n
      ? { amount: out0.amount.toString(), blinding: out0.blinding.toString(), index: changeIndex }
      : null;
  return { proof, ext, changeNote };
}

// ============================================================================
// Phase 2 — on-chain encrypted notes (cross-device recovery + receiving from
// others) and in-pool private transfers.
//
// Two INDEPENDENT keys per user, both deterministic from ONE wallet signature:
//   - the SPEND key (Poseidon, deriveKeypair)   — controls note ownership in the
//     zk circuit (commitment = Poseidon(amount, spendPub, blinding)).
//   - the ENC key (secp256k1, deriveEncKeypair)  — decrypts the notes a sender
//     encrypts to you and posts on-chain in NewCommitment.encryptedOutput.
// The pair is published via register(packAccountKey(spendPub, encPub)) so anyone
// can pay you privately; recovery/scan needs only your wallet signature.
// ============================================================================

// ECIES over secp256k1: ephemeral ECDH -> HKDF-SHA256(shared_x) -> XChaCha20-Poly1305.
// Wire format (bytes): R(33 compressed) || nonce(24) || ciphertext+tag(80) = 137.
// Plaintext = amount(32 BE) || blinding(32 BE) = 64 bytes.
const NOTE_HKDF_INFO = new TextEncoder().encode("essey-pool-note-v1");
const NOTE_R_LEN = 33;
const NOTE_NONCE_LEN = 24;
const NOTE_PT_LEN = 64;
const NOTE_CT_LEN = NOTE_PT_LEN + 16; // XChaCha20-Poly1305 tag
const NOTE_BLOB_LEN = NOTE_R_LEN + NOTE_NONCE_LEN + NOTE_CT_LEN; // 137

export interface PoolEncKeypair {
  encPriv: Uint8Array; // secp256k1 scalar, 32 bytes
  encPub: Uint8Array; // 33-byte compressed point
}

export interface ChainCommitment {
  commitment: bigint;
  index: number;
  encryptedOutput: `0x${string}`;
}

// encPriv = keccak256(sig || "enc") reduced into [1, n-1] (a valid secp256k1
// scalar). Deterministic, and distinct from BOTH the Poseidon spend key
// (keccak256(sig) % BN254_FIELD) and the Phase-0 stealth keys (keccak of
// seed||0x00 / seed||0x01), because the "enc" domain tag never collides with a
// single appended byte.
export function deriveEncKeypair(signatureHex: string): PoolEncKeypair {
  const sig = (signatureHex.startsWith("0x") ? signatureHex : "0x" + signatureHex) as `0x${string}`;
  const material = keccak_256(concatBytes(hexToBytes(sig), new TextEncoder().encode("enc")));
  const n = secp256k1.CURVE.n;
  const scalar = (bytesToNumberBE(material) % (n - 1n)) + 1n; // in [1, n-1], never 0
  const encPriv = numberToBytesBE(scalar, 32);
  const encPub = secp256k1.getPublicKey(encPriv, true); // 33-byte compressed
  return { encPriv, encPub };
}

// 32-byte spendPub || 33-byte encPub = 65 bytes, for on-chain register(Account).
export function packAccountKey(spendPub: bigint, encPub: Uint8Array): `0x${string}` {
  if (encPub.length !== 33) throw new Error("encPub must be 33-byte compressed");
  return bytesToHex(concatBytes(numberToBytesBE(spendPub, 32), encPub));
}

export function unpackAccountKey(blob: `0x${string}`): { spendPub: bigint; encPub: Uint8Array } {
  const b = hexToBytes(blob);
  if (b.length !== 65) throw new Error("account key blob must be 65 bytes");
  return { spendPub: bytesToNumberBE(b.slice(0, 32)), encPub: b.slice(32, 65) };
}

// ECIES encrypt. Fresh ephemeral key + fresh nonce every call.
export function encryptNote(amount: bigint, blinding: bigint, recipientEncPub: Uint8Array): `0x${string}` {
  const ephPriv = secp256k1.utils.randomPrivateKey();
  const R = secp256k1.getPublicKey(ephPriv, true); // 33-byte compressed ephemeral point
  const sharedX = secp256k1.getSharedSecret(ephPriv, recipientEncPub, true).slice(1); // 32-byte x of shared point
  const key = hkdf(sha256, sharedX, undefined, NOTE_HKDF_INFO, 32);
  const nonce = randomBytes(NOTE_NONCE_LEN);
  const plaintext = concatBytes(numberToBytesBE(amount, 32), numberToBytesBE(blinding, 32));
  const ct = xchacha20poly1305(key, nonce).encrypt(plaintext);
  return bytesToHex(concatBytes(R, nonce, ct));
}

// ECIES decrypt. Returns null on ANY failure (wrong key / tampered / malformed) —
// MUST NOT throw, so scanning notes addressed to others just skips them.
export function decryptNote(
  ciphertext: `0x${string}`,
  encPriv: Uint8Array,
): { amount: bigint; blinding: bigint } | null {
  try {
    const blob = hexToBytes(ciphertext);
    if (blob.length !== NOTE_BLOB_LEN) return null;
    const R = blob.slice(0, NOTE_R_LEN);
    const nonce = blob.slice(NOTE_R_LEN, NOTE_R_LEN + NOTE_NONCE_LEN);
    const ct = blob.slice(NOTE_R_LEN + NOTE_NONCE_LEN);
    const sharedX = secp256k1.getSharedSecret(encPriv, R, true).slice(1);
    const key = hkdf(sha256, sharedX, undefined, NOTE_HKDF_INFO, 32);
    const plaintext = xchacha20poly1305(key, nonce).decrypt(ct); // throws on auth failure
    if (plaintext.length !== NOTE_PT_LEN) return null;
    return {
      amount: bytesToNumberBE(plaintext.slice(0, 32)),
      blinding: bytesToNumberBE(plaintext.slice(32, 64)),
    };
  } catch {
    return null;
  }
}

// Scan on-chain commitments and recover the notes THIS user owns: a note is mine
// iff its ciphertext decrypts under my enc key AND the plaintext reproduces the
// on-chain commitment under my spend pubkey. Zero-amount and non-decrypting notes
// are skipped.
export function recoverNotes(
  chain: ChainCommitment[],
  spendKp: PoolKeypair,
  encKp: PoolEncKeypair,
): PoolNote[] {
  const out: PoolNote[] = [];
  for (const c of chain) {
    const dec = decryptNote(c.encryptedOutput, encKp.encPriv);
    if (!dec) continue;
    if (dec.amount === 0n) continue;
    const commitment = H([dec.amount, spendKp.pubkey, dec.blinding]);
    if (commitment !== c.commitment) continue; // decrypts but isn't mine (defensive)
    out.push({ amount: dec.amount.toString(), blinding: dec.blinding.toString(), index: c.index });
  }
  return out;
}

// The nullifier for an owned note, so the app can check pool.isSpent(nullifier).
// nullifier = Poseidon(commitment, index, Poseidon(spendPriv, commitment, index)).
export function noteNullifier(spendKp: PoolKeypair, note: PoolNote): bigint {
  const kp = new Keypair(spendKp.privkey);
  const utxo = new Utxo({
    amount: BigInt(note.amount),
    keypair: kp,
    blinding: BigInt(note.blinding),
    index: note.index,
  });
  return utxo.getNullifier();
}

// ---- In-pool private transfer (extAmount = 0, no token movement) ----
// input[0] = inputNote (real, merkle path via its index in allLeaves); input[1] = zero dummy.
// output[0] = SENT note to recipient: Poseidon(amount, recipientSpendPub, blinding_new),
//   encryptedOutput1 = encryptNote(amount, blinding_new, recipientEncPub).
// output[1] = CHANGE note to self: Poseidon(inputNote.amount - amount, spendPub, blinding_change),
//   encryptedOutput2 = encryptNote(change, encKp.encPub)  (0x if no change).
// Conservation: inputNote.amount + 0 (dummy) = amount + change. publicAmount = 0.
export async function buildTransferProof(
  spendKp: PoolKeypair,
  encKp: PoolEncKeypair,
  inputNote: PoolNote,
  amount: bigint,
  recipientSpendPub: bigint,
  recipientEncPub: Uint8Array,
  allLeaves: bigint[],
  opts?: { wasmUrl?: string; zkeyUrl?: string },
): Promise<{ proof: ProofCalldata; ext: PoolExtData; sentNote: PoolNote; changeNote: PoolNote | null }> {
  const inAmount = BigInt(inputNote.amount);
  if (amount <= 0n) throw new Error("transfer amount must be positive");
  if (amount > inAmount) throw new Error("transfer amount exceeds note balance");

  const tree = new MerkleTree(LEVELS);
  for (const leaf of allLeaves) tree.insert(leaf);
  const root = tree.root();
  const { pathElements, pathIndices } = tree.path(inputNote.index);

  const spendKeypair = new Keypair(spendKp.privkey);
  const inNote = new Utxo({
    amount: inAmount,
    keypair: spendKeypair,
    blinding: BigInt(inputNote.blinding),
    index: inputNote.index,
  });
  // Sanity: reconstructed commitment must equal the leaf actually in the tree.
  if (inNote.getCommitment() !== allLeaves[inputNote.index]) {
    throw new Error("note commitment does not match the leaf at its index");
  }

  const inZero = new Utxo({ amount: 0n, index: 0 });
  const inputs = [inNote, inZero];
  const inPathElements = [pathElements, new Array(LEVELS).fill("0")];
  const inPathIndices = [pathIndices, 0];

  const change = inAmount - amount;
  const sentIndex = allLeaves.length;
  const changeIndex = allLeaves.length + 1;

  // output[0] = the SENT note, owned by the RECIPIENT's spend pubkey (we don't
  // know their privkey — output-only keypair). Fresh blinding.
  const recipientKeypair = new Keypair(0n, recipientSpendPub);
  const blindingSent = randField();
  const out0 = new Utxo({ amount, keypair: recipientKeypair, blinding: blindingSent, index: sentIndex });

  // output[1] = the CHANGE note back to the sender (or a zero note on a full transfer).
  const out1 =
    change > 0n
      ? new Utxo({ amount: change, keypair: spendKeypair, index: changeIndex })
      : new Utxo({ amount: 0n, index: changeIndex });
  const outputs = [out0, out1];

  const ext: PoolExtData = {
    recipient: "0x0000000000000000000000000000000000000000",
    extAmount: 0n,
    relayer: "0x0000000000000000000000000000000000000000",
    fee: 0n,
    encryptedOutput1: encryptNote(out0.amount, out0.blinding, recipientEncPub),
    encryptedOutput2: change > 0n ? encryptNote(out1.amount, out1.blinding, encKp.encPub) : "0x",
  };
  const extDataHash = getExtDataHash(ext);
  const publicAmount = calculatePublicAmount(0n, 0n); // == 0

  const input = buildCircuitInput(
    root,
    publicAmount,
    extDataHash,
    inputs,
    inPathElements,
    inPathIndices,
    outputs,
  );
  const proof = await prove(input, opts);

  const sentNote: PoolNote = {
    amount: out0.amount.toString(),
    blinding: out0.blinding.toString(),
    index: sentIndex,
  };
  const changeNote: PoolNote | null =
    change > 0n
      ? { amount: out1.amount.toString(), blinding: out1.blinding.toString(), index: changeIndex }
      : null;
  return { proof, ext, sentNote, changeNote };
}
