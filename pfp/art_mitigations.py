"""Essey PFP — art mitigations (NO-DESIGNER pass).

The layer art is FINAL (no designer exists). This script neutralizes the source-art defects
catalogued in ART-DEFECT LEDGER (ex DESIGNER-ART-FIXES.md) with deterministic pixel operations
on the private trait library, IN PLACE:

  fix_red_hair       male Red-hair family: the highlight/flyaway strand sub-layers are painted
                     lavender/violet (hue ~261-350 deg). Soft hue-remap of the violet window onto
                     the warm-red family, preserving S/V (the sheen stays, the purple goes).
  fix_bowler_shadow  every 'Bowler Shadow' layer is an OPAQUE cream-painted light-wash that
                     covers the left half of the crown in normal blend (the #198 'incomplete
                     red fill'). Converted into a neutral translucent shade/highlight overlay:
                     darker-than-mid pixels -> black shadow alpha, lighter-than-mid -> white
                     highlight alpha. Works over ANY crown colour -> the Bowler Red variant is
                     restored to the pool (SUPPRESS_IN entry removed in engine).
  fix_cane_fragments the 4 cane (+shadow) layers carry a small floating shard between the gold
                     head and the shaft ('hand clamped by a floating piece'). All components
                     but the head and the shaft are removed.
  fix_thirsty        the 8 'Thirsty' vampire mouths have a detached droplet speck floating
                     beside the blood drip. Specks removed; the drip itself is style, kept.
  fix_carmen         female Carmen hat (Red/Black) trails a thin stray vector wisp off the brim
                     tip, and 'Carmen Rear' contains detached slivers. Thin strokes below the
                     brim in the wisp ROI + all sub-100px orphan components removed.

Originals are backed up to {SP}/art_originals_backup/{gender}/ before the first write and a
marker file records applied fixes -> re-runs are no-ops (idempotent). The backup lives in the
PRIVATE workspace (SP), never in the repo; app/web/public/traits/ WebPs are not touched here —
they are REGENERATED from the fixed PNGs via optimize_web_art.py.

Usage:  python3 art_mitigations.py <SP>          # apply
        python3 art_mitigations.py <SP> --status # show what is applied
"""
import json, os, shutil, sys
from collections import deque

import numpy as np
from PIL import Image

SP = sys.argv[1] if len(sys.argv) > 1 else "."
BACKUP = f"{SP}/art_originals_backup"
MARKER = f"{BACKUP}/APPLIED.json"


def leaves(gender):
    return json.load(open(f"{SP}/traits/{gender}/leaves.json"))


def load_rgba(gender, f):
    return np.asarray(Image.open(f"{SP}/traits/{gender}/{f}").convert("RGBA"), np.float64) / 255.0


def save_rgba(gender, f, arr):
    path = f"{SP}/traits/{gender}/{f}"
    bdir = f"{BACKUP}/{gender}"
    os.makedirs(bdir, exist_ok=True)
    if not os.path.exists(f"{bdir}/{f}"):          # first touch -> keep the original
        shutil.copy2(path, f"{bdir}/{f}")
    Image.fromarray((np.clip(arr, 0, 1) * 255).astype("uint8")).save(path)


def components(alpha, thr=0.04):
    """4-connected component labelling on the alpha mask (no scipy dependency)."""
    m = alpha > thr
    lab = np.zeros(m.shape, np.int32)
    cur = 0
    H, W = m.shape
    for sy, sx in zip(*np.where(m)):
        if lab[sy, sx]:
            continue
        cur += 1
        q = deque([(sy, sx)])
        lab[sy, sx] = cur
        while q:
            y, x = q.popleft()
            for ny, nx in ((y-1, x), (y+1, x), (y, x-1), (y, x+1)):
                if 0 <= ny < H and 0 <= nx < W and m[ny, nx] and not lab[ny, nx]:
                    lab[ny, nx] = cur
                    q.append((ny, nx))
    sizes = np.bincount(lab.ravel())
    return lab, sizes


def prune_components(im, keep_min):
    """Zero alpha of every component smaller than keep_min px. Returns px removed."""
    lab, sizes = components(im[..., 3])
    kill = np.isin(lab, np.where(sizes < keep_min)[0]) & (lab > 0)
    im[..., 3][kill] = 0.0
    return int(kill.sum())


# ---------------------------------------------------------------- 1. red hair lavender remap
VIOLET_LO, VIOLET_HI, FEATHER = 185.0, 248.0, 6.0   # PIL hue scale 0-255 (~261-350 deg)
TARGET_HUE = 250.0                                   # warm red-pink, continuous with the maroon base


def remap_violet(im):
    rgb = (np.clip(im[..., :3], 0, 1) * 255).astype("uint8")
    hsv = np.asarray(Image.fromarray(rgb, "RGB").convert("HSV"), np.float64)
    h = hsv[..., 0]
    w = np.clip((h - (VIOLET_LO - FEATHER)) / FEATHER, 0, 1) * \
        np.clip(((VIOLET_HI + FEATHER) - h) / FEATHER, 0, 1)
    w = np.minimum(w, 1.0) * (im[..., 3] > 0.02)
    if w.max() <= 0:
        return im, 0.0
    hsv2 = hsv.copy()
    hsv2[..., 0] = h * (1 - w) + TARGET_HUE * w
    out = np.asarray(Image.fromarray(hsv2.astype("uint8"), "HSV").convert("RGB"), np.float64) / 255.0
    im2 = im.copy()
    im2[..., :3] = im[..., :3] * (1 - w[..., None]) + out * w[..., None]
    return im2, float((w > 0.5).sum())


def fix_red_hair():
    """Remap the violet-painted strands in every male Red-hair-family layer (incl. hat-hair
    copies nested under hats). Only files that actually contain violet pixels are rewritten."""
    touched = []
    for e in leaves("male"):
        p = e["path"]
        is_red_hair = p.startswith("13 Hair/Red/") or ("Hair Red" in p)
        if not is_red_hair or not e.get("file"):
            continue
        im = load_rgba("male", e["file"])
        im2, n = remap_violet(im)
        if n >= 50:                                   # real violet region, not sub-pixel noise
            save_rgba("male", e["file"], im2)
            touched.append((e["file"], int(n)))
    return touched


# ---------------------------------------------------------------- 2. bowler cream shadow
SHADE_GAIN, LIGHT_GAIN = 0.60, 0.85


def shading_overlay(im):
    """Painted-cream light-wash -> neutral translucent shade/highlight overlay."""
    a = im[..., 3]
    lum = 0.299 * im[..., 0] + 0.587 * im[..., 1] + 0.114 * im[..., 2]
    sel = a > 0.05
    if not sel.any():
        return im
    mid = float(np.median(lum[sel]))
    dark = np.clip((mid - lum) / max(mid, 1e-6), 0, 1)
    light = np.clip((lum - mid) / max(1 - mid, 1e-6), 0, 1)
    out = np.zeros_like(im)
    is_light = lum >= mid
    out[..., :3] = np.where(is_light[..., None], 1.0, 0.0)
    out[..., 3] = a * np.where(is_light, light * LIGHT_GAIN, dark * SHADE_GAIN)
    return out


def fix_bowler_shadow():
    touched = []
    for e in leaves("male"):
        if "Bowler Shadow" in e["path"] and e.get("file"):
            save_rgba("male", e["file"], shading_overlay(load_rgba("male", e["file"])))
            touched.append(e["file"])
    return touched


# ---------------------------------------------------------------- 3. cane floating shards
def fix_cane_fragments():
    touched = []
    for e in leaves("male"):
        if e["category"] == "18 Canes" and e.get("file"):
            im = load_rgba("male", e["file"])
            n = prune_components(im, keep_min=1000)   # keep the head (>15k) and shaft (~3k)
            if n:
                save_rgba("male", e["file"], im)
                touched.append((e["file"], n))
    return touched


# ---------------------------------------------------------------- 4. thirsty droplet specks
def fix_thirsty():
    touched = []
    for e in leaves("male"):
        if "/Thirsty" in e["path"] and e.get("file"):
            im = load_rgba("male", e["file"])
            n = prune_components(im, keep_min=100)    # keep mouth+drip (~4.4k), drop the specks
            if n:
                save_rgba("male", e["file"], im)
                touched.append((e["file"], n))
    return touched


# ---------------------------------------------------------------- 5. carmen brim wisp
WISP_ROI = (80, 215, 330, 329)                        # x0,y0,x1,y1 in layer coords (brim-tip area)
WISP_ROI2 = (80, 235, 230, 329)                       # tighter pass below the tip for the residual hook


def erode(m):
    e = m.copy()
    e[1:] &= m[:-1]; e[:-1] &= m[1:]; e[:, 1:] &= m[:, :-1]; e[:, :-1] &= m[:, 1:]
    return e


def dilate(m):
    d = m.copy()
    d[1:] |= m[:-1]; d[:-1] |= m[1:]; d[:, 1:] |= m[:, :-1]; d[:, :-1] |= m[:, 1:]
    return d


def erase_thin_in_roi(im, roi, r=2):
    """Morphological opening: strokes thinner than ~2r+1 px inside the ROI lose their alpha."""
    x0, y0, x1, y1 = roi
    sub = im[y0:y1, x0:x1, 3]
    m = sub > 0.04
    op = m
    for _ in range(r):
        op = erode(op)
    for _ in range(r):
        op = dilate(op)
    kill = m & ~op
    sub[kill] = 0.0
    return int(kill.sum())


def fix_carmen():
    touched = []
    for e in leaves("female"):
        if e["path"] in ("10 Hat/Carmen/Carmen Red/Carmen Red",
                         "10 Hat/Carmen/Carmen Black/Carmen Black"):
            im = load_rgba("female", e["file"])
            n = erase_thin_in_roi(im, WISP_ROI)
            n += erase_thin_in_roi(im, WISP_ROI2, r=3)
            n += prune_components(im, keep_min=100)
            save_rgba("female", e["file"], im)
            touched.append((e["file"], n))
        if e["path"] == "Carmen Rear":                # detached slivers in the rear piece
            im = load_rgba("female", e["file"])
            n = prune_components(im, keep_min=1000)   # keep only the main swoosh
            if n:
                save_rgba("female", e["file"], im)
                touched.append((e["file"], n))
    return touched


FIXES = {
    "red_hair_violet_remap": fix_red_hair,
    "bowler_shadow_overlay": fix_bowler_shadow,
    "cane_floating_shards": fix_cane_fragments,
    "thirsty_droplet_specks": fix_thirsty,
    "carmen_brim_wisp": fix_carmen,
}


def main():
    os.makedirs(BACKUP, exist_ok=True)
    applied = json.load(open(MARKER)) if os.path.exists(MARKER) else {}
    if "--status" in sys.argv:
        for k in FIXES:
            print(f"{k:26s} {'APPLIED' if k in applied else 'pending'}")
        return
    for name, fn in FIXES.items():
        if name in applied:
            print(f"{name:26s} already applied -> skip")
            continue
        result = fn()
        applied[name] = result
        json.dump(applied, open(MARKER, "w"), indent=1)
        print(f"{name:26s} applied: {result}")


if __name__ == "__main__":
    main()
