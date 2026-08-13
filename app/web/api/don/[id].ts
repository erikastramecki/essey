// Essey Dons — ERC-721 metadata endpoint: GET /api/don/[id] (what DonArt's baseURI points at).
//
// Chain first, registry second: the Don's combo hash + locked/liened flags are read from the chain every
// time (the chain is the authority on WHICH art a Don committed), then the permanent preimage registry
// decodes hash -> selection for the human-readable attributes. A Don whose preimage was never recorded
// (minted around the API, store down) gets dignified "unrevealed" metadata — never a 500, never blank.
//
// Cache posture: a LOCKED Don's traits are frozen on-chain forever -> long immutable CDN cache. An
// unlocked Don can reroll -> short cache. Unrevealed metadata is always short-cached so a reveal
// propagates quickly.
import { builderData, chainClient, comboHash, donReadAbi, DISTRIBUTOR_ADDR, DON_ADDR, json, preKey, requestOrigin, store, ZERO32, type NodeReq, type NodeRes, type Preimage } from "../_don-lib.js";
import { resolveSelection, type Resolved } from "../../src/pfp-resolve.js";

const CACHE_LONG = "public, max-age=3600, s-maxage=31536000, immutable";
const CACHE_SHORT = "public, max-age=0, s-maxage=60, stale-while-revalidate=600";

/// Marketplace attributes from the resolved selection: top-level category picks that actually render
/// (conflict-hidden picks are dropped — the attributes must describe the visible art, not the raw
/// selection), with the ordering prefix stripped ("13 Hair" -> "Hair").
function attributesFrom(r: Resolved, gender: string, locked: boolean, liened: boolean) {
  const visible = new Set(r.render.map((l) => l.category));
  const attrs: { trait_type: string; value: string }[] = [
    { trait_type: "Gender", value: gender === "female" ? "Female" : "Male" },
  ];
  for (const [cat, pick] of Object.entries(r.picks)) {
    if (cat.includes("/")) continue; // nested variant picks fold into their top-level category
    if (!pick || pick.toLowerCase() === "none") continue;
    if (!visible.has(cat)) continue;
    attrs.push({ trait_type: cat.replace(/^[\d.]+\s+/, ""), value: pick });
  }
  attrs.push({ trait_type: "Locked", value: locked ? "Yes" : "No" });
  if (liened) attrs.push({ trait_type: "Liened", value: "Yes" });
  return attrs;
}

// Vercel Node serverless handler (Node req + Express-like res; see _don-lib NodeReq/NodeRes).
export default async function handler(req: NodeReq, res: NodeRes) {
  if (req.method !== "GET") return json(res, 405, { error: "method" });

  const idStr = new URL(req.url || "/", "http://x").pathname.split("/").filter(Boolean).pop() || "";
  const id = Number(idStr);
  if (!Number.isInteger(id) || id < 1 || id > 1_000_000) return json(res, 400, { error: "bad id" });

  // Chain truth: which combo this Don committed, and whether it is frozen / pledged.
  let combo: `0x${string}`, locked: boolean, liened: boolean;
  try {
    const client = chainClient();
    [combo, locked, liened] = await Promise.all([
      client.readContract({ address: DISTRIBUTOR_ADDR, abi: donReadAbi, functionName: "comboOf", args: [BigInt(id)] }),
      client.readContract({ address: DON_ADDR, abi: donReadAbi, functionName: "locked", args: [BigInt(id)] }),
      client.readContract({ address: DON_ADDR, abi: donReadAbi, functionName: "liened", args: [BigInt(id)] }),
    ]);
  } catch {
    return json(res, 503, { error: "chain read failed — retry" }, { "cache-control": "no-store" });
  }
  if (combo === ZERO32) return json(res, 404, { error: "not minted" }, { "cache-control": CACHE_SHORT });

  // Registry: hash -> selection. Store down or record missing both degrade to "unrevealed".
  const redis = store();
  const pre = redis ? await redis.get<Preimage>(preKey(combo)).catch(() => null) : null;

  const origin = requestOrigin(req);
  const image = `${origin}/api/don-img/${id}`;

  if (pre) {
    try {
      const data = await builderData(pre.gender);
      const r = resolveSelection(data, pre.forced || {}, pre.seed >>> 0);
      if (comboHash(r.key).toLowerCase() !== combo.toLowerCase()) throw new Error("registry/chain mismatch");
      return json(
        res,
        200,
        {
          name: `Don #${id}`,
          description:
            `A Don of the Essey Dons — the seat at the table. Its trait combo is committed on-chain as ${combo}; ` +
            (locked
              ? "the Don is staked, so this art is locked forever."
              : "traits stay mutable (reroll) until the Don is staked — staking locks the art forever."),
          image,
          combo,
          attributes: attributesFrom(r, pre.gender, locked, liened),
        },
        { "cache-control": CACHE_SHORT /* lien state is mutable even when art is locked - audit R5 LOW */ },
      );
    } catch {
      // fall through to unrevealed — a bad decode must never take the endpoint down
    }
  }

  return json(
    res,
    200,
    {
      name: `Don #${id}`,
      description:
        `A Don of the Essey Dons — the seat at the table. Its trait combo is committed on-chain as ${combo}, ` +
        `but the combo's preimage has not been revealed to the metadata service yet. The holder can reveal it by ` +
        `reopening the builder at ${origin}/builder or POSTing the builder inputs to ${origin}/api/don-reveal.`,
      image,
      combo,
      attributes: [
        { trait_type: "Revealed", value: "No" },
        { trait_type: "Locked", value: locked ? "Yes" : "No" },
        ...(liened ? [{ trait_type: "Liened", value: "Yes" }] : []),
      ],
    },
    { "cache-control": CACHE_SHORT },
  );
}
