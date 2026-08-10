"""Precompute which held-object pairs overlap too much to co-render.
Output: traits/male/hand_conflicts.json  {threshold, cane_grip:[[cane,grip]...], snake_grip:[[grip]...]}
A pair is a conflict if the smaller object's opaque area is >= threshold covered by the other."""
import sys, json
from collections import defaultdict
import numpy as np
from PIL import Image
SP = sys.argv[1]
THRESH = float(sys.argv[2]) if len(sys.argv) > 2 else 0.30

lm = json.load(open(f"{SP}/traits/male/leaves.json"))
groups = defaultdict(list)
for e in lm:
    if e["category"] in ("18 Canes", "19 Hand Grip", "25 Snake"):
        groups[(e["category"], e["path"].split("/")[1])].append(e)

def mask(entries):
    m = np.zeros((300, 300), bool)
    for e in entries:
        if "Shadow" in e["path"]:
            continue
        im = np.asarray(Image.open(f"{SP}/traits/male/{e['file']}").convert("RGBA"))
        a = im[..., 3] > 30
        b = e["bbox"]; h, w = a.shape
        full = np.zeros((900, 900), bool)
        x0, y0 = max(b[0], 0), max(b[1], 0); x1, y1 = min(b[0]+w, 900), min(b[1]+h, 900)
        if x0 >= x1 or y0 >= y1:
            continue
        full[y0:y1, x0:x1] = a[y0-b[1]:y1-b[1], x0-b[0]:x1-b[0]]
        m |= np.asarray(Image.fromarray(full).resize((300, 300)))
    return m

masks = {k: mask(v) for k, v in groups.items()}
area = {k: int(m.sum()) for k, m in masks.items()}
def ov(a, b):
    if area[a] < 50 or area[b] < 50:
        return 0.0
    return int((masks[a] & masks[b]).sum()) / min(area[a], area[b])

canes = [k for k in masks if k[0] == "18 Canes"]
grips = [k for k in masks if k[0] == "19 Hand Grip"]
snakes = [k for k in masks if k[0] == "25 Snake"]

cane_grip = [[c[1], g[1]] for c in canes for g in grips if ov(c, g) >= THRESH]
# snake shape is colour-independent; a grip conflicts with snake if it conflicts with ANY snake variant
snake_grip = sorted({g[1] for s in snakes for g in grips if ov(s, g) >= THRESH})
cane_snake = [[c[1], s[1]] for c in canes for s in snakes if ov(c, s) >= THRESH]

out = {"threshold": THRESH, "cane_grip": cane_grip, "snake_grip": snake_grip, "cane_snake": cane_snake}
json.dump(out, open(f"{SP}/traits/male/hand_conflicts.json", "w"), indent=1)
print(f"threshold {THRESH}")
print(f"cane+grip conflicts: {len(cane_grip)} / {len(canes)*len(grips)} pairs")
print(f"  grips that conflict with EVERY cane:",
      sorted({g[1] for g in grips if all([c[1], g[1]] in cane_grip for c in canes)}))
print(f"  grips that conflict with NO cane:",
      sorted({g[1] for g in grips if not any([c[1], g[1]] in cane_grip for c in canes) and area[g] >= 50}))
print(f"snake conflicts with grips: {snake_grip}")
