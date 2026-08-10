"""Objective metadata<->render validator: assert every declared trait paints VISIBLE (in-canvas,
non-transparent) pixels. Catches off-canvas / hidden / dropped traits that agents can miss.
This is the build-time gate for the builder + mint (no token ships a trait that didn't render)."""
import sys, json, random
import numpy as np
from PIL import Image
SP = sys.argv[1]; N = int(sys.argv[2]) if len(sys.argv) > 2 else 10000
THRESH = 40   # a trait must paint >= this many in-canvas opaque px to count as "rendered" (catches
#             # truly off-canvas/absent 0px cases; small-but-present traits like knuckle tattoos pass)
ns = {}
exec(compile(open(f"{SP}/engine2.py").read().split("if __name__")[0], "e", "exec"), ns)
load, generate, apply_conflicts = ns["load"], ns["generate"], ns["apply_conflicts"]
POS_OFFSET = ns["POS_OFFSET"]
man = json.load(open(f"{SP}/out/manifest.json"))

# trait_type (metadata label) -> possible leaf categories. Base traits (always part of body/face/hair)
# are exempt from the "must render" check; we validate the accessory/optional traits that can vanish.
TRAIT_CAT = {
    "AR": ["26 AR", "17 AR"], "Hat": ["22 Hat", "10 Hat"], "Eye Mod": ["15 Eye Mod"],
    "Glasses": ["16 Glasses"], "Face Mod": ["17 Face Mod"], "Hand Grip": ["19 Hand Grip", "13 Hand Grip"],
    "Canes": ["18 Canes"], "Snake": ["25 Snake"], "Necklace": ["8 Necklace"], "Earring": ["15 Earing"],
    "Devilish": ["11 Devilish"], "Neko": ["16 Neko"], "Ceasar": ["23 Ceasar"], "Laser Eye": ["24 Laser Eye"],
    "Wrist": ["21 Wrist", "12 Wrist dec"], "Ring": ["20 Rings", "14 Ring"], "Tattoos": ["11 Tattoos"],
    "Beard": ["12 Beard"], "phoenix eyes": ["18 phoenix eyes"], "The hawk": ["2 The hawk"],
}

def leaf_coverage(gender):
    """z -> in-canvas non-transparent px for every leaf (accounts for bbox + POS_OFFSET)."""
    cov = {}
    for e in json.load(open(f"{SP}/traits/{gender}/leaves.json")):
        p = f"{SP}/traits/{gender}/{e['file']}"
        try:
            a = np.asarray(Image.open(p).convert("RGBA"))[..., 3] > 30
        except Exception:
            cov[e["z"]] = 0; continue
        h, w = a.shape
        l = e["bbox"][0] + POS_OFFSET.get(e["category"], 0); t = e["bbox"][1]
        x0, y0 = max(l, 0), max(t, 0); x1, y1 = min(l + w, 900), min(t + h, 900)
        if x0 >= x1 or y0 >= y1:
            cov[e["z"]] = 0; continue
        cov[e["z"]] = int(a[y0 - t:y1 - t, x0 - l:x1 - l].sum())
    return cov

engines = {g: load(g) for g in ("male", "female")}
covers = {g: leaf_coverage(g) for g in ("male", "female")}
flags = []
for tid in range(N):
    gender = man[str(tid)]["gender"]; tree, lm = engines[gender]; cov = covers[gender]
    s = generate(tree, random.Random(man[str(tid)]["seed"])); apply_conflicts(s, lm)
    # in-canvas px per category for this token's visible leaves
    catpx = {}
    for lf in s.leaves:
        c = lm.get(lf["z"], {}).get("category", "")
        catpx[c] = catpx.get(c, 0) + cov.get(lf["z"], 0)
    meta = json.load(open(f"{SP}/out/metadata/{tid}.json"))
    for a in meta["attributes"]:
        tt = a["trait_type"]
        if tt not in TRAIT_CAT:
            continue
        px = max((catpx.get(c, 0) for c in TRAIT_CAT[tt]), default=0)
        if px < THRESH:
            flags.append({"id": tid, "gender": gender, "trait": tt, "value": a["value"], "px": px})

from collections import Counter
print(f"validated {N} tokens (threshold {THRESH}px)")
print(f"FLAGS (declared trait renders <{THRESH}px): {len(flags)}")
by = Counter(f"{f['trait']}" for f in flags)
for t, n in by.most_common():
    ex = [f["id"] for f in flags if f["trait"] == t][:6]
    print(f"  {t}: {n}  e.g. {ex}")
json.dump(flags, open(f"{SP}/render_flags.json", "w"))
