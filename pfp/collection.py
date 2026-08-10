"""Essey PFP collection builder — dedup, OpenSea metadata, rarity report.

Usage:
  python3 collection.py <SP> plan   <N_male> <N_female> <base_seed>      # metadata + rarity only (fast)
  python3 collection.py <SP> render <lo> <hi>                            # render images for id range [lo,hi)
The plan step writes:  out/metadata/<id>.json, out/collection.json, out/rarity.json, out/manifest.json
The render step reads manifest.json (id -> gender+seed) and writes out/images/<id>.png
"""
import sys, json, os, hashlib, random, re
from collections import Counter, defaultdict

SP = sys.argv[1]
MODE = sys.argv[2]
OUT = f"{SP}/out"

# load engine2 (its top reads SP from sys.argv[1], already set)
_ns = {}
exec(compile(open(f"{SP}/engine2.py").read().split("if __name__")[0], "engine2", "exec"), _ns)
load, generate, apply_conflicts, composite, cats_of = (
    _ns["load"], _ns["generate"], _ns["apply_conflicts"], _ns["composite"], _ns["cats_of"])

# male/female name the same slot differently -> one canonical trait_type
TRAIT_NORMALIZE = {"Chairs": "Chair", "Rings": "Ring", "eye brow": "Eyebrow",
                   "Earing": "Earring", "Suits": "Suit", "Wrist dec": "Wrist"}

def clean_type(cat):
    t = re.sub(r"^[\d.]+\s*", "", cat or "").strip()
    return TRAIT_NORMALIZE.get(t, t)

def clean_val(v):
    v = re.sub(r"#\d+", "", v or "")
    return re.sub(r"^[\d.]+\s*", "", v).strip()

# categories covered by semantic drivers (don't also emit their raw top-level pick)
SKIP = {"body", "suits", "suit", "hair", "hat", "eye mod", "face", "rear hair",
        "hat hair", "hair rear", "eyes", "mouth", "shade for hats only"}

def attrs_of(s, gender, visible_cats, cats):
    a = {"Gender": gender.capitalize()}
    d = s.drivers
    if d.get("family"):     a["Bloodline"] = d["family"]
    if d.get("build"):      a["Build"] = d["build"]
    if d.get("suit"):       a["Suit"] = clean_val(d["suit"])
    if d.get("hair_color"): a["Hair Color"] = d["hair_color"]
    if d.get("hair_style") and ("13 Hair" in visible_cats or "9 Hair" in visible_cats):
        a["Hair Style"] = d["hair_style"]
    # only list Hat / Eye Mod if they actually SURVIVED conflict-resolution (Doom hides hats;
    # laser hides eye-mods) — metadata must match the render for the builder + uniqueness key.
    if d.get("eyemod") and "15 Eye Mod" in visible_cats: a["Eye Mod"] = d["eyemod"]
    if d.get("hat") and ("22 Hat" in visible_cats or "10 Hat" in visible_cats): a["Hat"] = d["hat"]
    for k, v in s.picks.items():
        if "/" in k or k not in cats or k not in visible_cats:
            continue
        t, val = clean_type(k), clean_val(v)
        if t.lower() in SKIP or val.lower() in ("none", ""):
            continue
        a.setdefault(t, val)
    return a

def signature(s, gender, leafmeta):
    # key on the RENDERED result (visible leaves after conflict resolution), so two tokens that
    # differ only in a dropped cane/snake/hidden layer are NOT counted as distinct.
    body = sorted(leafmeta.get(lf["z"], {}).get("path", str(lf["z"])) for lf in s.leaves)
    return hashlib.md5((gender + json.dumps(body)).encode()).hexdigest()

def plan(n_male, n_female, base):
    os.makedirs(f"{OUT}/metadata", exist_ok=True)
    engines = {g: load(g) for g in ("male", "female")}
    catmap = {g: cats_of(engines[g][0]) for g in engines}
    seen, manifest, rows = set(), {}, []
    rarity = defaultdict(Counter)          # trait_type -> Counter(value)
    tid = 0
    for gender, want in (("male", n_male), ("female", n_female)):
        tree, leafmeta = engines[gender]
        cats = catmap[gender]
        made, salt = 0, 0
        while made < want:
            seed = base + tid * 1000 + salt
            s = generate(tree, random.Random(seed))
            apply_conflicts(s, leafmeta)
            sig = signature(s, gender, leafmeta)
            if sig in seen:                # collision -> reroll same slot with a fresh salt
                salt += 1
                continue
            seen.add(sig)
            vis = {leafmeta.get(lf["z"], {}).get("category", "") for lf in s.leaves}
            attrs = attrs_of(s, gender, vis, cats)
            meta = {
                "name": f"Essey #{tid}",
                "description": "Essey — provably-solvent RWA lending club on Robinhood Chain.",
                "image": f"images/{tid}.png",
                "attributes": [{"trait_type": t, "value": v} for t, v in attrs.items()],
            }
            json.dump(meta, open(f"{OUT}/metadata/{tid}.json", "w"), indent=2)
            manifest[str(tid)] = {"gender": gender, "seed": seed}
            for t, v in attrs.items():
                rarity[t][v] += 1
            made += 1
            tid += 1
            salt = 0
    total = tid
    json.dump(manifest, open(f"{OUT}/manifest.json", "w"))
    # rarity report: per trait_type, value -> {count, pct}; plus "(none)" for tokens lacking the trait
    report = {}
    for t, ctr in sorted(rarity.items()):
        have = sum(ctr.values())
        vals = {v: {"count": c, "pct": round(100 * c / total, 2)} for v, c in ctr.most_common()}
        if have < total:
            vals["(none)"] = {"count": total - have, "pct": round(100 * (total - have) / total, 2)}
        report[t] = vals
    json.dump(report, open(f"{OUT}/rarity.json", "w"), indent=2)
    json.dump({"total": total, "male": n_male, "female": n_female, "base_seed": base,
               "unique": len(seen)}, open(f"{OUT}/collection.json", "w"), indent=2)
    print(f"planned {total} unique tokens ({n_male}M/{n_female}F) -> {OUT}")
    print(f"trait types: {len(report)}")
    for t, vals in report.items():
        top = list(vals.items())[:3]
        print(f"  {t:12} {len(vals)} values  e.g. " +
              ", ".join(f"{k} {d['pct']}%" for k, d in top))

def render(lo, hi):
    os.makedirs(f"{OUT}/images", exist_ok=True)
    manifest = json.load(open(f"{OUT}/manifest.json"))
    engines = {g: load(g) for g in ("male", "female")}
    for tid in range(lo, hi):
        e = manifest.get(str(tid))
        if not e:
            continue
        tree, leafmeta = engines[e["gender"]]
        s = generate(tree, random.Random(e["seed"]))
        apply_conflicts(s, leafmeta)
        composite(s.leaves, leafmeta, e["gender"]).save(f"{OUT}/images/{tid}.png")
    print(f"rendered ids [{lo},{hi})")

if MODE == "plan":
    plan(int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]))
elif MODE == "render":
    render(int(sys.argv[3]), int(sys.argv[4]))
