// Essey Dons — image endpoint: GET /api/don-img/[id] (or /api/don-img/x?combo=0x… for combo-addressed
// renders). Server-side composite of the SAME layer files the client builder draws, in the SAME z-order
// with the SAME blend modes (pfp-compositor.ts is the reference implementation) — so the served art is
// pixel-faithful to what the holder built and the chain committed.
//
// The composite is done in raw RGBA (decode via sharp, per-pixel source-over/multiply/screen + the AR
// darken-backing-then-screen special case, encode via sharp) rather than sharp's own composite pipeline:
// layers overhang the 900x900 canvas and carry canvas-space crops, and exact parity with the browser
// canvas is the whole point.
//
// Cache posture: a combo's render never changes (the hash IS the art), so combo-addressed requests and
// LOCKED Dons cache immutable-long; an unlocked Don's id -> combo mapping can reroll, so id-addressed
// requests cache short. ETag = combo hash either way. Unrevealed/unknown falls to a branded placeholder
// (inline SVG, no external assets) — never a broken image.
import sharp from "sharp";
import { assetOrigin, builderData, chainClient, comboHash, donReadAbi, DISTRIBUTOR_ADDR, DON_ADDR, header, json, preKey, store, ZERO32, type NodeReq, type NodeRes, type Preimage } from "../_don-lib.js";
import { posOffset, posYOffset, resolveSelection, type BuilderData, type Resolved } from "../../src/pfp-resolve.js";

const CANVAS = 900;
const CACHE_LONG = "public, max-age=3600, s-maxage=31536000, immutable";
const CACHE_SHORT = "public, max-age=0, s-maxage=60, stale-while-revalidate=600";

type Raw = { data: Buffer; width: number; height: number };

async function fetchLayer(gender: string, file: string): Promise<Raw | null> {
  try {
    const resp = await fetch(`${assetOrigin()}/traits/${gender}/${encodeURIComponent(file)}`);
    if (!resp.ok) return null;
    const { data, info } = await sharp(Buffer.from(await resp.arrayBuffer()))
      .ensureAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });
    return { data, width: info.width, height: info.height };
  } catch {
    return null; // one missing layer must not kill the render (the client compositor skips too)
  }
}

/// Per-pixel draw with the canvas blend model (non-premultiplied W3C compositing):
/// Cm = (1-ab)·Cs + ab·B(Cb,Cs); Co = (Cm·as + Cb·ab·(1-as)) / ao; ao = as + ab·(1-as).
/// `top`/`bot` are canvas-space row clamps (the cropTop/cropBottom lines).
function draw(canvas: Uint8ClampedArray, img: Raw, x: number, y: number, mode: string, top: number, bot: number) {
  const { data: s, width: w } = img;
  const y0 = Math.max(top, 0), y1 = Math.min(bot, CANVAS);
  const x0 = Math.max(x, 0), x1 = Math.min(x + w, CANVAS);
  for (let dy = y0; dy < y1; dy++) {
    const sRow = (dy - y) * w, dRow = dy * CANVAS;
    for (let dx = x0; dx < x1; dx++) {
      const si = (sRow + dx - x) * 4, di = (dRow + dx) * 4;
      const as = s[si + 3] / 255;
      if (as === 0) continue;
      const ab = canvas[di + 3] / 255;
      const ao = as + ab * (1 - as);
      for (let k = 0; k < 3; k++) {
        const Cs = s[si + k], Cb = canvas[di + k];
        let B = Cs;
        if (mode === "multiply") B = (Cb * Cs) / 255;
        else if (mode === "screen") B = 255 - ((255 - Cb) * (255 - Cs)) / 255;
        const Cm = (1 - ab) * Cs + ab * B;
        canvas[di + k] = (Cm * as + Cb * ab * (1 - as)) / ao;
      }
      canvas[di + 3] = ao * 255;
    }
  }
}

/// AR layers: luminance-weighted dark backing under the bright holo pixels (source-over), then screen
/// the layer itself — the pfp-compositor drawAR algorithm, verbatim. No crops on the AR path.
function drawAR(canvas: Uint8ClampedArray, img: Raw, x: number, y: number) {
  const { data: s, width: w, height: h } = img;
  const backing = Buffer.alloc(s.length); // zeroed RGB = black
  for (let i = 0; i < s.length; i += 4) {
    const lum = (0.299 * s[i] + 0.587 * s[i + 1] + 0.114 * s[i + 2]) / 255;
    backing[i + 3] = Math.round(0.85 * lum * (s[i + 3] / 255) * 255);
  }
  draw(canvas, { data: backing, width: w, height: h }, x, y, "normal", y, y + h);
  draw(canvas, img, x, y, "screen", y, y + h);
}

/// Render a resolved selection to a webp buffer. Exported for smoke-testing the compositor directly.
export async function renderResolved(data: BuilderData, r: Resolved): Promise<Buffer> {
  const layers = await Promise.all(r.render.map((l) => fetchLayer(data.gender, l.file)));
  const canvas = new Uint8ClampedArray(CANVAS * CANVAS * 4);
  for (let i = 0; i < r.render.length; i++) {
    const img = layers[i];
    if (!img) continue;
    const l = r.render[i];
    const x = l.bbox[0] + posOffset(data, l.category), y = l.bbox[1] + posYOffset(l.category, l.file);
    if (l.category === "26 AR" || l.category === "17 AR") {
      drawAR(canvas, img, x, y);
      continue;
    }
    const top = l.cropTop != null ? Math.max(y, l.cropTop) : y;
    const bot = l.cropBottom != null ? Math.min(y + img.height, l.cropBottom) : y + img.height;
    if (bot > top) draw(canvas, img, x, y, l.blend, top, bot);
  }
  return sharp(Buffer.from(canvas.buffer, canvas.byteOffset, canvas.byteLength), {
    raw: { width: CANVAS, height: CANVAS, channels: 4 },
  })
    .webp({ quality: 92 })
    .toBuffer();
}

/// Branded placeholder for unrevealed Dons — dark/gold, generated inline, zero external assets.
function placeholderSvg(label: string): string {
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">` +
    `<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">` +
    `<stop offset="0" stop-color="#E7C57A"/><stop offset="1" stop-color="#B8923E"/></linearGradient>` +
    `<radialGradient id="bg" cx="0.5" cy="0.32" r="0.9">` +
    `<stop offset="0" stop-color="#161A24"/><stop offset="1" stop-color="#0A0C11"/></radialGradient></defs>` +
    `<rect width="400" height="400" fill="url(#bg)"/>` +
    `<text x="200" y="64" text-anchor="middle" font-family="Georgia,serif" font-size="19" letter-spacing="10" fill="#98A0B0">ESSEY</text>` +
    `<g transform="translate(110,100) scale(1.8)">` +
    `<path d="M50 7.81 L89.06 28.13 L89.06 71.88 L50 92.19 L10.94 71.88 L10.94 28.13 Z" fill="rgba(212,169,78,0.07)" stroke="url(#g)" stroke-width="3.4" stroke-linejoin="round"/>` +
    `<text x="50" y="51.5" text-anchor="middle" dominant-baseline="central" font-family="Didot,Georgia,serif" font-size="50" fill="url(#g)">E</text>` +
    `</g>` +
    `<text x="200" y="322" text-anchor="middle" font-family="Menlo,monospace" font-size="21" letter-spacing="3" fill="#E9EBF1">${label}</text>` +
    `<text x="200" y="376" text-anchor="middle" font-family="Menlo,monospace" font-size="11" letter-spacing="2" fill="#616A7B">UNREVEALED</text>` +
    `</svg>`
  );
}

function sendSvg(res: NodeRes, label: string): void {
  res.setHeader("content-type", "image/svg+xml");
  res.setHeader("cache-control", CACHE_SHORT);
  res.status(200).send(placeholderSvg(label));
}

// Vercel Node serverless handler (Node req + Express-like res; see _don-lib NodeReq/NodeRes).
export default async function handler(req: NodeReq, res: NodeRes) {
  if (req.method !== "GET") return json(res, 405, { error: "method" });

  const url = new URL(req.url || "/", "http://x");
  const idStr = url.pathname.split("/").filter(Boolean).pop() || "";
  const id = Number(idStr);
  const comboParam = (url.searchParams.get("combo") || "").toLowerCase();
  const comboMode = /^0x[0-9a-f]{64}$/.test(comboParam);

  let combo: string, locked = false, label: string;
  if (comboMode) {
    combo = comboParam;
    locked = true; // combo-addressed content is immutable by construction
    label = "DON";
  } else {
    if (!Number.isInteger(id) || id < 1 || id > 1_000_000) return json(res, 400, { error: "bad id" });
    label = `DON #${id}`;
    try {
      const client = chainClient();
      [combo, locked] = await Promise.all([
        client.readContract({ address: DISTRIBUTOR_ADDR, abi: donReadAbi, functionName: "comboOf", args: [BigInt(id)] }),
        client.readContract({ address: DON_ADDR, abi: donReadAbi, functionName: "locked", args: [BigInt(id)] }),
      ]);
    } catch {
      return json(res, 503, { error: "chain read failed — retry" }, { "cache-control": "no-store" });
    }
    if (combo === ZERO32) return json(res, 404, { error: "not minted" }, { "cache-control": CACHE_SHORT });
  }

  // 304 fast-path: the combo hash IS the content identity.
  if (header(req, "if-none-match") === `"${combo.toLowerCase()}"`) {
    return res.status(304).end();
  }

  const redis = store();
  const pre = redis ? await redis.get<Preimage>(preKey(combo)).catch(() => null) : null;
  if (!pre) return sendSvg(res, label); // unrevealed (or store unclaimed): branded placeholder

  try {
    const data = await builderData(pre.gender);
    const r = resolveSelection(data, pre.forced || {}, pre.seed >>> 0);
    if (comboHash(r.key).toLowerCase() !== combo.toLowerCase()) return sendSvg(res, label);
    const webp = await renderResolved(data, r);
    res.setHeader("content-type", "image/webp");
    res.setHeader("etag", `"${combo.toLowerCase()}"`);
    res.setHeader("cache-control", locked ? CACHE_LONG : CACHE_SHORT);
    return res.status(200).send(webp);
  } catch {
    return sendSvg(res, label); // a render failure must degrade to the placeholder, never a 500 image
  }
}
