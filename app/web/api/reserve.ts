// Essey Dons — mint-combo RESERVATION service (Vercel serverless function).
//
// The on-chain DonDistributor `usedCombo` ledger is the source of truth for uniqueness — this service
// only provides SOFT HOLDS so two builders don't spend minutes perfecting the same 1-of-1 and race the
// same combo at the wallet. A hold lasts HOLD_TTL_S and then lapses; a mint that lands on-chain is
// permanent regardless of any hold (the contract reverts ComboTaken for everyone else).
//
// Trust shape mirrors the dev middleware in vite.config.ts: the uniqueness key is re-resolved
// SERVER-SIDE from the posted selection via the same resolver the client uses, so a client cannot
// spoof someone else's key. Store: Upstash Redis (Vercel Marketplace, KV_* / UPSTASH_* env), holds are
// SET NX EX — atomic check-and-lock with expiry.
//
// Optional on-chain check: set DISTRIBUTOR_ADDR (and optionally RPC_URL) once the Don stack is
// deployed, and POST/GET also report combos already minted on-chain (`minted: true`).
import { Redis } from "@upstash/redis";
import { createPublicClient, http, defineChain, parseAbi, keccak256, toHex } from "viem";
import { resolveSelection } from "../src/pfp-resolve.js";
import { persistPreimage } from "./_don-lib.js";

const HOLD_TTL_S = 30 * 60; // a builder session's soft hold

const RPC = process.env.RPC_URL || "https://rpc.testnet.chain.robinhood.com";
const CHAIN = defineChain({ id: Number(process.env.CHAIN_ID || 46630), name: "Robinhood Chain", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const DISTRIBUTOR = (process.env.DISTRIBUTOR_ADDR || "") as `0x${string}`;
const distributorAbi = parseAbi(["function usedCombo(bytes32) view returns (bool)"]);

// The Vercel Upstash KV integration provisions KV_REST_API_*; a direct Upstash install provisions
// UPSTASH_REDIS_REST_*. Accept either so the store survives a re-provision under the other name.
function store(): Redis | null {
  const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;
  return url && token ? new Redis({ url, token }) : null;
}

// Builder data ships as a static asset of THIS deployment (gitignored in the public repo, uploaded via
// .vercelignore). Fetch once per instance and cache — Fluid Compute reuses instances, so this is warm.
const dataCache = new Map<string, any>();
async function builderData(gender: string): Promise<any> {
  const g = gender === "female" ? "female" : "male";
  if (dataCache.has(g)) return dataCache.get(g);
  const origin = process.env.VERCEL_URL ? `https://${process.env.VERCEL_URL}` : "http://localhost:5173";
  const resp = await fetch(`${origin}/builder/data_${g}.json`);
  if (!resp.ok) throw new Error(`builder data ${g}: ${resp.status}`);
  const data = await resp.json();
  dataCache.set(g, data);
  return data;
}

/// keccak of the resolver key — the exact bytes32 the contract's usedCombo ledger is keyed by, so the
/// client can pass it straight to mintCustom/reroll.
function comboHash(key: string): `0x${string}` {
  return keccak256(toHex(key));
}

async function mintedOnChain(combo: `0x${string}`): Promise<boolean | null> {
  if (!DISTRIBUTOR) return null; // stack not deployed yet
  try {
    const client = createPublicClient({ chain: CHAIN, transport: http(RPC) });
    return await client.readContract({ address: DISTRIBUTOR, abi: distributorAbi, functionName: "usedCombo", args: [combo] });
  } catch {
    return null; // RPC hiccup: report unknown rather than lie either way
  }
}

export default async function handler(req: Request): Promise<Response> {
  const json = (code: number, obj: unknown) =>
    new Response(JSON.stringify(obj), { status: code, headers: { "content-type": "application/json" } });

  const redis = store();
  if (!redis) return json(503, { error: "reservation store not provisioned" });

  if (req.method === "GET") {
    const key = new URL(req.url).searchParams.get("key") || "";
    if (!key) return json(400, { error: "key required" });
    const held = (await redis.get<{ wallet: string }>(`hold:${key}`)) ?? null;
    const minted = await mintedOnChain(comboHash(key));
    return json(200, { key, reserved: !!held || !!minted, by: held?.wallet ?? null, minted });
  }

  if (req.method === "POST") {
    let body: any;
    try {
      body = await req.json();
    } catch {
      return json(400, { error: "bad json" });
    }
    const { gender, forced, seed, wallet } = body || {};
    const data = await builderData(String(gender));
    const r = resolveSelection(data, forced || {}, (Number(seed) >>> 0) || 0); // authoritative key
    const combo = comboHash(r.key);

    // PERMANENT preimage registry (no TTL, NX — first record wins): hash -> the builder inputs that
    // resolve to it. This is what lets /api/don/[id] decode a minted Don's on-chain combo hash back
    // into traits forever. Best-effort: a registry hiccup must not block the reservation.
    await persistPreimage(redis, combo, { gender: data.gender, forced: forced || {}, seed: (Number(seed) >>> 0) || 0, key: r.key }).catch(() => {});

    const minted = await mintedOnChain(combo);
    if (minted) return json(200, { ok: false, taken: true, minted: true, key: r.key, combo });

    // Atomic soft hold: first writer wins, expires on its own. Renewals by the SAME wallet extend.
    const holder = { wallet: String(wallet || "anon"), ts: Date.now() };
    const set = await redis.set(`hold:${r.key}`, holder, { nx: true, ex: HOLD_TTL_S });
    if (set === null) {
      const existing = (await redis.get<{ wallet: string }>(`hold:${r.key}`)) ?? null;
      if (existing && existing.wallet === holder.wallet && holder.wallet !== "anon") {
        await redis.set(`hold:${r.key}`, holder, { ex: HOLD_TTL_S }); // renew own hold
        return json(200, { ok: true, reserved: true, renewed: true, key: r.key, combo, ttl: HOLD_TTL_S });
      }
      return json(200, { ok: false, taken: true, key: r.key, by: existing?.wallet ?? null, combo });
    }
    return json(200, { ok: true, reserved: true, key: r.key, combo, ttl: HOLD_TTL_S });
  }

  return json(405, { error: "method" });
}
