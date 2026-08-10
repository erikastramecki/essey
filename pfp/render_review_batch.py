"""Render a QA review batch: baseline even-spread + oversampled RISKY interactions
(where layering bugs hide), tagged so reviewers know what to scrutinize. 600px for detail."""
import sys, os, json, random
from collections import defaultdict
from PIL import Image
SP = sys.argv[1]
PER = int(sys.argv[2]) if len(sys.argv) > 2 else 150   # per gender
ns = {}
exec(compile(open(f"{SP}/engine2.py").read().split("if __name__")[0], "e", "exec"), ns)
load, generate, apply_conflicts, composite = ns["load"], ns["generate"], ns["apply_conflicts"], ns["composite"]
man = json.load(open(f"{SP}/out/manifest.json"))
OUT = f"{SP}/review_imgs"; os.makedirs(OUT, exist_ok=True)

def tags_of(s, lm, gender):
    picks, dr = s.picks, s.drivers
    cats = [lm.get(lf["z"], {}).get("category", "") for lf in s.leaves]
    t = []
    fm = (picks.get("17 Face Mod") or "None")
    if fm != "None": t.append("mask:" + fm.split()[0])
    if dr.get("family") in ("Zombie", "Golden", "Glitch"): t.append("special-body")
    hand = [c for c in ("18 Canes", "19 Hand Grip", "25 Snake") if c in cats]
    if len(hand) > 1: t.append("multi-hand-object")
    if "25 Snake" in cats: t.append("snake")
    if (picks.get("24 Laser Eye") or "None") != "None": t.append("laser")
    if "23 Ceasar" in cats: t.append("ceasar")
    if "2 The hawk" in cats: t.append("hawk")
    if dr.get("build") == "Giga": t.append("giga")
    if dr.get("hat") and fm != "None": t.append("hat+mask")
    if "26 AR" in cats: t.append("AR")
    if "16 Neko" in cats: t.append("neko")
    if "11 Devilish" in cats: t.append("devilish")
    if "18 Phoenix eyes" in cats or "phoenix" in " ".join(cats).lower(): t.append("phoenix")
    hg = next((lm[lf["z"]]["path"] for lf in s.leaves if lm.get(lf["z"], {}).get("category", "").endswith("Hand Grip")), "")
    if any(w in hg for w in ("Havannah", "Cigar")): t.append("cigar")
    if (dr.get("hair_style") or "") in ("Medusa",): t.append("medusa")
    return t

def pick_ids(gender, lo, hi, per):
    tree, lm = load(gender)
    by_tag = defaultdict(list); all_ids = []
    for tid in range(lo, hi):
        s = generate(tree, random.Random(man[str(tid)]["seed"])); apply_conflicts(s, lm)
        tg = tags_of(s, lm, gender)
        all_ids.append((tid, tg))
        for x in tg: by_tag[x].append(tid)
    chosen = {}
    # oversample: up to 10 per risky tag
    for tag, ids in sorted(by_tag.items()):
        for tid in ids[:10]:
            chosen[tid] = next(tg for i, tg in all_ids if i == tid)
    # fill to `per` with an even baseline spread
    step = max(1, (hi - lo) // per)
    for tid in range(lo, hi, step):
        if len(chosen) >= per: break
        chosen.setdefault(tid, next(tg for i, tg in all_ids if i == tid))
    return tree, lm, chosen

manifest = []
for gender, lo, hi in (("male", 0, 5000), ("female", 5000, 10000)):
    tree, lm, chosen = pick_ids(gender, lo, hi, PER)
    for tid, tg in sorted(chosen.items()):
        s = generate(tree, random.Random(man[str(tid)]["seed"])); apply_conflicts(s, lm)
        im = composite(s.leaves, lm, gender).resize((600, 600), Image.LANCZOS)
        p = f"{OUT}/{tid}.png"; im.save(p)
        meta = json.load(open(f"{SP}/out/metadata/{tid}.json"))
        manifest.append({"id": tid, "gender": gender, "path": p,
                         "traits": {a["trait_type"]: a["value"] for a in meta["attributes"]},
                         "tags": tg})
json.dump(manifest, open(f"{SP}/review_manifest.json", "w"))
print(f"rendered {len(manifest)} review images -> {OUT}")
from collections import Counter
tagc = Counter(x for m in manifest for x in m["tags"])
print("tag coverage:", dict(tagc.most_common()))
