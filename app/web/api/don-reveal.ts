// Essey Dons — PERMISSIONLESS preimage reveal (serverless function).
//
// POST { gender, forced, seed, id? } — the builder inputs of a MINTED Don. The server re-resolves the
// selection (authoritative: the same resolver the client used, so the key/hash cannot be spoofed),
// verifies the resulting combo hash actually exists on-chain, and persists hash -> selection in the
// PERMANENT registry. Any Don minted around the API (direct contract call, another frontend) can thus
// always be revealed after the fact by anyone who knows its combo — and the owner always does: their
// client built it.
//
// Trust shape: nothing here is trusted. The selection is recomputed server-side; the hash is checked
// against the chain (comboOf(id) when an id is offered, the usedCombo ledger otherwise); the registry
// is NX (first record wins; any valid record for a hash decodes to the same rendered art, because the
// hash IS the resolver key's keccak). Worst case for an attacker: they reveal someone's art earlier
// than the owner would have — reveal is disclosure, not authority.
import { builderData, chainClient, comboHash, donReadAbi, DISTRIBUTOR_ADDR, json, persistPreimage, preKey, store, type Preimage } from "./_don-lib.js";
import { resolveSelection } from "../src/pfp-resolve.js";

export default async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method" });

  const redis = store();
  if (!redis) return json(503, { error: "preimage store not provisioned — the reveal cannot be recorded yet; retry once the store is claimed" });

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "bad json" });
  }
  const { gender, forced, seed, id } = body || {};

  let key: string;
  let combo: `0x${string}`;
  try {
    const data = await builderData(String(gender));
    const r = resolveSelection(data, forced || {}, (Number(seed) >>> 0) || 0); // authoritative
    key = r.key;
    combo = comboHash(key);
  } catch (e) {
    return json(500, { error: `resolve failed: ${(e as Error)?.message ?? e}` });
  }

  // On-chain verification: only combos the chain has actually committed get a permanent record.
  let verifiedId: number | undefined;
  try {
    const client = chainClient();
    let minted = false;
    if (id != null && Number.isInteger(Number(id)) && Number(id) > 0) {
      const onChain = await client.readContract({ address: DISTRIBUTOR_ADDR, abi: donReadAbi, functionName: "comboOf", args: [BigInt(Number(id))] });
      if (onChain.toLowerCase() === combo.toLowerCase()) {
        minted = true;
        verifiedId = Number(id);
      }
    }
    if (!minted) {
      minted = await client.readContract({ address: DISTRIBUTOR_ADDR, abi: donReadAbi, functionName: "usedCombo", args: [combo] });
    }
    if (!minted) return json(404, { ok: false, error: "combo not found on-chain (not minted)", combo });
  } catch {
    return json(502, { error: "chain verification unavailable — retry" });
  }

  try {
    const pre = { gender: String(gender) === "female" ? "female" : "male", forced: forced || {}, seed: (Number(seed) >>> 0) || 0, key, ...(verifiedId != null ? { id: verifiedId } : {}) };
    const created = await persistPreimage(redis, combo, pre);
    if (!created && verifiedId != null) {
      // Enrich an existing record with the freshly verified id (never touch its selection fields).
      const existing = await redis.get<Preimage>(preKey(combo));
      if (existing && existing.id == null) await redis.set(preKey(combo), { ...existing, id: verifiedId });
    }
    return json(200, { ok: true, revealed: true, already: !created, combo, id: verifiedId ?? null });
  } catch {
    return json(503, { error: "preimage store write failed — retry" });
  }
}
