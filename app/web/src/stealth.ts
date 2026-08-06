// Essey Private — Phase 0 client crypto (ERC-5564 secp256k1, schemeId 1).
//
// This is the ONLY money-critical crypto in the private layer's frontend: it derives the recipient's
// spend/view keypair, computes the one-time STEALTH address a sender pays to, and lets the recipient
// detect + spend those funds. A bug here sends money to an address nobody can spend from — permanently
// lost. So it is deliberately small, dependency-light (only the audited @noble primitives, which every
// stealth SDK is built on), and implements the scheme EXACTLY as the on-chain announcer/registry expect.
//
// Scheme (ERC-5564, schemeId 1 = SECP256K1), matching the canonical ScopeLift reference so off-the-shelf
// SDKs interoperate with the same registry:
//   meta-address      = spendPub(33, compressed) || viewPub(33, compressed)          [66 bytes on-chain]
//   sender:  R = r·G ;  S = r·viewPub ;  s = keccak256(S_compressed) ;  tag = s[0]
//            P_stealth = spendPub + s·G ;  stealthAddr = keccak(P_stealth_uncompressed[1:])[-20:]
//            announce(stealthAddr, ephemeralPub = R, metadata = [tag])
//   scan:    S = viewPriv·R ;  s = keccak256(S_compressed) ;  skip unless s[0] == metadata[0]
//            recompute P_stealth ; owned iff derived address == announced stealthAddr
//   spend:   p_stealth = (spendPriv + s) mod n     (the private key controlling stealthAddr)
//
// secp256k1 is a prime-order group, so P_stealth = spendPub + s·G has private key spendPriv + s (mod n);
// the recipient learns `s` from the view key alone, but needs the spend key to actually move funds.

import { secp256k1 } from "@noble/curves/secp256k1";
import { bytesToNumberBE, numberToBytesBE } from "@noble/curves/abstract/utils";
import { keccak_256 } from "@noble/hashes/sha3";
import type { Hex, Address } from "viem";

const Point = secp256k1.ProjectivePoint;
const N = secp256k1.CURVE.n;

// A user proves control of their wallet by signing this exact string; the signature deterministically
// seeds their stealth keys. Re-signing on any device reproduces the same keys (recovery). The message is
// versioned + domain-scoped so a signature farmed elsewhere can't reproduce Essey keys, and vice-versa.
export const STEALTH_DERIVE_MESSAGE =
  "Essey Private — derive my stealth keys.\n\n" +
  "Signing this proves wallet control and generates the private keys for your shielded balance. " +
  "It costs no gas and grants no approvals. Only sign this on essey.xyz.\n\nVersion: 1";

// ---------- small hex/byte helpers (no viem dependency in the crypto core) ----------

function hexToBytes(hex: string): Uint8Array {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (h.length % 2 !== 0) throw new Error("odd-length hex");
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return out;
}
function bytesToHex(b: Uint8Array): Hex {
  let s = "0x";
  for (let i = 0; i < b.length; i++) s += b[i].toString(16).padStart(2, "0");
  return s as Hex;
}
function concat(...arrs: Uint8Array[]): Uint8Array {
  const len = arrs.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(len);
  let o = 0;
  for (const a of arrs) { out.set(a, o); o += a.length; }
  return out;
}

// Reduce 32 hash bytes to a valid nonzero secp256k1 scalar. The tiny modular bias (n is within 2^-128 of
// 2^256) is standard and irrelevant here; a zero result is astronomically unlikely and rejected outright.
function hashToScalar(b: Uint8Array): bigint {
  const s = bytesToNumberBE(b) % N;
  if (s === 0n) throw new Error("degenerate scalar"); // never happens in practice
  return s;
}

// EIP-55-agnostic: keccak(uncompressed pubkey without the 0x04 prefix), take the low 20 bytes. Returns a
// lowercase 0x address; viem's getAddress() checksums it at the call sites where display matters.
function pointToAddress(p: InstanceType<typeof Point>): Address {
  const uncompressed = p.toRawBytes(false); // 65 bytes: 0x04 || X(32) || Y(32)
  const hash = keccak_256(uncompressed.slice(1));
  return bytesToHex(hash.slice(12)) as Address;
}

// ---------- key derivation (recipient) ----------

export interface StealthKeys {
  spendPriv: bigint;
  viewPriv: bigint;
  spendPub: Uint8Array; // 33-byte compressed
  viewPub: Uint8Array;  // 33-byte compressed
  metaAddress: Hex;     // 66-byte spendPub||viewPub, as stored in the ERC-6538 registry
}

// Deterministically derive the spend + view keypair from a wallet signature over STEALTH_DERIVE_MESSAGE.
// spend and view use distinct domain-separated labels so the two keys are independent.
export function deriveStealthKeys(signature: Hex): StealthKeys {
  const sig = hexToBytes(signature);
  if (sig.length < 64) throw new Error("signature too short to derive keys");
  const seed = keccak_256(sig);
  const spendPriv = hashToScalar(keccak_256(concat(seed, new Uint8Array([0x00]))));
  const viewPriv = hashToScalar(keccak_256(concat(seed, new Uint8Array([0x01]))));
  const spendPub = Point.BASE.multiply(spendPriv).toRawBytes(true);
  const viewPub = Point.BASE.multiply(viewPriv).toRawBytes(true);
  return { spendPriv, viewPriv, spendPub, viewPub, metaAddress: bytesToHex(concat(spendPub, viewPub)) };
}

export function parseMetaAddress(metaAddress: Hex): { spendPub: Uint8Array; viewPub: Uint8Array } {
  const b = hexToBytes(metaAddress);
  if (b.length !== 66) throw new Error("meta-address must be 66 bytes (spendPub||viewPub)");
  return { spendPub: b.slice(0, 33), viewPub: b.slice(33, 66) };
}

// ---------- sender: compute a one-time stealth address for a recipient ----------

export interface StealthPayment {
  stealthAddress: Address;   // where funds go (EsseyStealthPay.pay recipient)
  ephemeralPubKey: Hex;      // R = r·G, 33-byte compressed (announcement field)
  metadata: Hex;            // 1 byte: the view tag (announcement field)
  viewTag: number;
}

// Generate a fresh stealth address for `metaAddress`. `randomScalar` is injectable ONLY for deterministic
// tests; production callers must omit it so a cryptographically secure ephemeral key is used.
export function generateStealthAddress(metaAddress: Hex, randomScalar?: bigint): StealthPayment {
  const { spendPub, viewPub } = parseMetaAddress(metaAddress);
  const spendPoint = Point.fromHex(spendPub);
  const viewPoint = Point.fromHex(viewPub);

  const r = randomScalar ?? bytesToNumberBE(secp256k1.utils.randomPrivateKey());
  if (r <= 0n || r >= N) throw new Error("bad ephemeral scalar");
  const R = Point.BASE.multiply(r);              // ephemeral pub
  const shared = viewPoint.multiply(r);          // S = r·viewPub
  const s = keccak_256(shared.toRawBytes(true));  // hash of compressed shared secret
  const viewTag = s[0];
  const sScalar = hashToScalar(s);

  const stealthPoint = spendPoint.add(Point.BASE.multiply(sScalar)); // P_spend + s·G
  return {
    stealthAddress: pointToAddress(stealthPoint),
    ephemeralPubKey: bytesToHex(R.toRawBytes(true)),
    metadata: bytesToHex(new Uint8Array([viewTag])),
    viewTag,
  };
}

// ---------- recipient: detect + spend ----------

export interface Announcement {
  stealthAddress: Address;
  ephemeralPubKey: Hex; // 33-byte compressed R
  metadata: Hex;        // view tag in byte 0
}

// Does this announcement pay ME? Uses the view key only (which is safe to keep hot for scanning). Returns
// the shared scalar `s` on a hit so the spend key can be computed with the (cold) spend key separately.
export function checkAnnouncement(
  a: Announcement,
  viewPriv: bigint,
  spendPub: Uint8Array,
): { owned: boolean; sScalar?: bigint } {
  let R: InstanceType<typeof Point>;
  try {
    R = Point.fromHex(hexToBytes(a.ephemeralPubKey));
  } catch {
    return { owned: false }; // malformed ephemeral key — not ours
  }
  const shared = R.multiply(viewPriv);           // S = viewPriv·R  == r·viewPub
  const s = keccak_256(shared.toRawBytes(true));
  const meta = hexToBytes(a.metadata);
  if (meta.length === 0 || meta[0] !== s[0]) return { owned: false }; // view-tag fast reject
  const sScalar = hashToScalar(s);
  const derived = pointToAddress(Point.fromHex(spendPub).add(Point.BASE.multiply(sScalar)));
  const owned = derived.toLowerCase() === a.stealthAddress.toLowerCase();
  return owned ? { owned, sScalar } : { owned: false };
}

// The private key that controls a matched stealth address: p_stealth = (spendPriv + s) mod n. Import this
// into a viem local account to sweep the funds. Guard against the (impossible) zero key.
export function computeStealthPrivKey(spendPriv: bigint, sScalar: bigint): Hex {
  const k = (spendPriv + sScalar) % N;
  if (k === 0n) throw new Error("degenerate stealth key");
  return bytesToHex(numberToBytesBE(k, 32));
}
