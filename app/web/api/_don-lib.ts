// Essey Dons — shared plumbing for the Don metadata layer (underscore-prefixed: the platform does not
// expose this file as an endpoint; it is imported by the /api/don* functions).
//
// THE DESIGN PROBLEM this layer solves: the chain stores only the keccak COMBO HASH of a Don's traits
// (Don.traits / DonDistributor.comboOf) — the preimage (the builder inputs that resolve to the actual
// layer selection) exists client-side at build/mint time. So metadata serving needs a hash -> selection
// registry. Three primitives, shared by every endpoint:
//
//   1. PERMANENT preimage registry in the KV store (`don:pre:<comboHash>`, no TTL — a revealed Don stays
//      revealed forever). Written on every /api/reserve resolution and by the permissionless
//      /api/don-reveal. First record wins (NX): records are server-recomputed, so a duplicate can only
//      ever say the same thing.
//   2. Authoritative server-side re-resolution: the key is recomputed from {gender, forced, seed} via the
//      SAME resolver the client uses — a caller can never spoof a key their inputs don't resolve to.
//   3. Chain reads against the Don stack (addresses from don-config, env-overridable) for verification.
import { Redis } from "@upstash/redis";
import { createPublicClient, http, keccak256, toHex, parseAbi } from "viem";
import { DON_NET, donChain } from "../src/don-config.js";
import { resolveSelection, type BuilderData, type Resolved } from "../src/pfp-resolve.js";

export const DON_ADDR = (process.env.DON_ADDR || DON_NET.don) as `0x${string}`;
export const DISTRIBUTOR_ADDR = (process.env.DISTRIBUTOR_ADDR || DON_NET.distributor) as `0x${string}`;

export const donReadAbi = parseAbi([
  "function comboOf(uint256) view returns (bytes32)",
  "function usedCombo(bytes32) view returns (bool)",
  "function locked(uint256) view returns (bool)",
  "function liened(uint256) view returns (bool)",
]);

export function chainClient() {
  return createPublicClient({ chain: donChain, transport: http(process.env.RPC_URL || DON_NET.rpc) });
}

// The KV integration provisions KV_REST_API_*; a direct install provisions UPSTASH_REDIS_REST_*.
// Accept either (same posture as reserve.ts). null = store unclaimed: endpoints degrade gracefully.
export function store(): Redis | null {
  const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;
  return url && token ? new Redis({ url, token }) : null;
}

/// keccak of the resolver key — the exact bytes32 the on-chain combo ledger is keyed by.
export function comboHash(key: string): `0x${string}` {
  return keccak256(toHex(key));
}

// ---------------------------------------------------------------------------- preimage registry

/// The permanent hash -> selection record. `id` is attached when a reveal verifies it against
/// comboOf(id); it is informational — lookups are always by combo hash.
export type Preimage = {
  v: 1;
  gender: string;
  forced: Record<string, string>;
  seed: number;
  key: string;
  id?: number;
  ts: number;
};

export const preKey = (combo: string) => `don:pre:${combo.toLowerCase()}`;

/// NX write, no TTL. Returns true when this call created the record (false = already revealed).
export async function persistPreimage(redis: Redis, combo: string, pre: Omit<Preimage, "v" | "ts">): Promise<boolean> {
  const rec: Preimage = { v: 1, ts: Date.now(), ...pre };
  const set = await redis.set(preKey(combo), rec, { nx: true });
  return set !== null;
}

/// Re-resolve a stored preimage into the full selection. Callers MUST verify comboHash(resolved.key)
/// still equals the on-chain combo before trusting it (resolver-drift belt-and-suspenders).
export async function resolvePreimage(pre: Preimage): Promise<Resolved> {
  const data = await builderData(pre.gender);
  return resolveSelection(data, pre.forced || {}, pre.seed >>> 0);
}

// ---------------------------------------------------------------------------- static assets + origins

/// Builder data and trait layers ship as static assets of THIS deployment (kept out of the public repo,
/// uploaded at deploy time). Fetched from the deployment's own origin and cached per instance — the
/// compute pool reuses instances, so this is warm.
export function assetOrigin(): string {
  if (process.env.ASSET_ORIGIN) return process.env.ASSET_ORIGIN;
  return process.env.VERCEL_URL ? `https://${process.env.VERCEL_URL}` : "http://localhost:5173";
}

const dataCache = new Map<string, BuilderData>();
export async function builderData(gender: string): Promise<BuilderData> {
  const g = gender === "female" ? "female" : "male";
  const hit = dataCache.get(g);
  if (hit) return hit;
  const resp = await fetch(`${assetOrigin()}/builder/data_${g}.json`);
  if (!resp.ok) throw new Error(`builder data ${g}: ${resp.status}`);
  const data = (await resp.json()) as BuilderData;
  dataCache.set(g, data);
  return data;
}

/// The public origin serving THIS request — used for self-referential URLs inside metadata (the image
/// endpoint), so metadata served through any domain points back at that same domain.
export function requestOrigin(req: Request): string {
  const host = req.headers.get("x-forwarded-host") || req.headers.get("host");
  if (host) {
    const proto = req.headers.get("x-forwarded-proto") || (host.startsWith("localhost") ? "http" : "https");
    return `${proto}://${host}`;
  }
  return assetOrigin();
}

// ---------------------------------------------------------------------------- misc

export const ZERO32 = "0x0000000000000000000000000000000000000000000000000000000000000000";

export function json(code: number, obj: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(obj), {
    status: code,
    headers: { "content-type": "application/json", ...headers },
  });
}
