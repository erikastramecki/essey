// Client-side canvas compositor — draws resolved trait PNGs with faithful blend modes.
// Mirrors pfp/engine.py composite(): normal/multiply/screen + AR darken-backing-then-screen.
// Chair alpha-speckle is baked out at art-export time, so no per-pixel cleanup needed here.
import type { BuilderData, RenderLeaf } from "./pfp-resolve";
import { posOffset } from "./pfp-resolve";

const CANVAS = 900;
const imgCache = new Map<string, Promise<HTMLImageElement>>();

function loadImg(url: string): Promise<HTMLImageElement> {
  let p = imgCache.get(url);
  if (!p) {
    p = new Promise((res, rej) => { const im = new Image(); im.onload = () => res(im); im.onerror = rej; im.src = url; });
    imgCache.set(url, p);
  }
  return p;
}
const blendMap: Record<string, GlobalCompositeOperation> = { normal: "source-over", multiply: "multiply", screen: "screen" };

function drawAR(ctx: CanvasRenderingContext2D, img: HTMLImageElement, x: number, y: number) {
  const w = img.width, h = img.height;
  // luminance-weighted dark backing: darken the bg ONLY under BRIGHT holo pixels (so dark structural
  // pixels stay translucent — no opaque black blobs), then screen the AR -> visible on ANY background.
  const tmp = document.createElement("canvas"); tmp.width = w; tmp.height = h;
  const tctx = tmp.getContext("2d")!; tctx.drawImage(img, 0, 0);
  const id = tctx.getImageData(0, 0, w, h); const d = id.data;
  for (let i = 0; i < d.length; i += 4) {
    const lum = (0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]) / 255, a = d[i + 3] / 255;
    d[i] = 0; d[i + 1] = 0; d[i + 2] = 0; d[i + 3] = Math.round(0.85 * lum * a * 255);
  }
  tctx.putImageData(id, 0, 0);
  ctx.globalCompositeOperation = "source-over"; ctx.globalAlpha = 1; ctx.drawImage(tmp, x, y);
  ctx.globalCompositeOperation = "screen"; ctx.drawImage(img, x, y);
}

export async function composite(canvas: HTMLCanvasElement, data: BuilderData, render: RenderLeaf[], stillCurrent?: () => boolean) {
  const ctx = canvas.getContext("2d")!;
  // preload in parallel FIRST (no canvas mutation yet), then draw atomically in z order
  const imgs = await Promise.all(render.map((r) => loadImg(`/traits/${data.gender}/${r.file}`).catch(() => null)));
  if (stillCurrent && !stillCurrent()) return; // a newer render superseded this one — don't clobber
  canvas.width = CANVAS; canvas.height = CANVAS; // (resizing also clears)
  ctx.clearRect(0, 0, CANVAS, CANVAS);
  for (let i = 0; i < render.length; i++) {
    const img = imgs[i]; if (!img) continue;
    const r = render[i]; const x = r.bbox[0] + posOffset(data, r.category); const y = r.bbox[1];
    if (r.category === "26 AR" || r.category === "17 AR") { drawAR(ctx, img, x, y); continue; }
    ctx.globalCompositeOperation = blendMap[r.blend] || "source-over"; ctx.globalAlpha = 1;
    // clip runaway rows: cropTop drops rows above the line (smoke plume), cropBottom drops rows
    // below it (disconnected lower element, e.g. Devilish floating tail). Both are canvas-space y.
    const top = r.cropTop != null ? Math.max(y, r.cropTop) : y;
    const bot = r.cropBottom != null ? Math.min(y + img.height, r.cropBottom) : y + img.height;
    if (top !== y || bot !== y + img.height) {
      const sy = top - y, sh = bot - top;
      if (sh > 0) ctx.drawImage(img, 0, sy, img.width, sh, x, top, img.width, sh);
    } else ctx.drawImage(img, x, y);
  }
  ctx.globalCompositeOperation = "source-over"; ctx.globalAlpha = 1;
}
