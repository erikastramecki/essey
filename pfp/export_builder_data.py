"""Export per-gender builder data (leaves catalog + selection tree + rules) for the browser
client resolver + canvas compositor. Writes to app/web/public/builder/. Art PNGs are copied
separately (gitignored). Nothing rarity/collection here — just the trait taxonomy + rules the
live builder needs."""
import sys, json, os
SP = sys.argv[1]
WEB = sys.argv[2]   # app/web/public/builder
os.makedirs(WEB, exist_ok=True)
ns = {}
exec(compile(open(f"{SP}/engine2.py").read().split("if __name__")[0], "e", "exec"), ns)
RULES = {k: ns[k] for k in ("DIMS", "DIM_PRIORITY", "FAMILY_TO_FACEID", "FACEMOD_COVER",
                            "SUPPRESS", "OPTIONAL", "POS_OFFSET", "Z_UNDER")}
RULES["SUPPRESS"] = list(RULES["SUPPRESS"])
RULES["SUPPRESS_IN"] = {k: list(v) for k, v in ns["SUPPRESS_IN"].items()}
RULES["HIDE_LEAF"] = list(ns["HIDE_LEAF"])
RULES["CROP_TOP"] = ns["CROP_TOP"]
RULES["CROP_BOTTOM"] = ns["CROP_BOTTOM"]
# NO-DESIGNER female hair-vs-hat rules (see engine2.py / ART-DEFECT LEDGER). The TS resolver
# does not enforce these yet — exported so the client can wire them without a data migration.
RULES["FEMALE_HAT_BLOCK"] = sorted(ns["FEMALE_HAT_BLOCK"])
RULES["FEMALE_HAT_HAIR_CROP"] = ns["FEMALE_HAT_HAIR_CROP"]
RULES["FEMALE_HAT_HAIR_CROP_STYLES"] = sorted(ns["FEMALE_HAT_HAIR_CROP_STYLES"])

def role(name):
    return ns["_role"](name)

for gender in ("male", "female"):
    leaves = json.load(open(f"{SP}/traits/{gender}/leaves.json"))
    tree = json.load(open(f"{SP}/traits/{gender}/structure.json"))["tree"]
    # web-optimized asset map: orig_png -> [webp_name, [cropped_left, cropped_top]] (see optimize_web_art.py)
    wmap_path = f"{WEB}/web_bbox_map_{gender}.json"
    wmap = json.load(open(wmap_path)) if os.path.exists(wmap_path) else {}
    def webify(e):
        m = wmap.get(e["file"])
        if not m: return e["file"], e["bbox"]           # fall back to raw png/bbox if not optimized
        return m[0], [m[1][0], m[1][1]] + e["bbox"][2:]  # webp name + cropped top-left (browser uses [0],[1])
    # slim leaves for the client (drop nothing needed: z, category, path, file, bbox, blend)
    slim = []
    for e in leaves:
        f, bb = webify(e)
        slim.append({"z": e["z"], "category": e["category"], "path": e["path"],
                     "file": f, "bbox": bb, "blend": e.get("blend", "normal")})
    hand = {}
    if gender == "male":
        hand = json.load(open(f"{SP}/traits/male/hand_conflicts.json"))
    # category roles (which the user selects vs which are driver-derived)
    cats = {c["name"]: {"group": c["group"], "role": role(c["name"])} for c in tree if c["group"]}
    data = {"gender": gender, "leaves": slim, "tree": tree, "cats": cats,
            "rules": RULES, "hand_conflicts": hand}
    p = f"{WEB}/data_{gender}.json"
    json.dump(data, open(p, "w"))
    print(f"{gender}: {len(slim)} leaves, {len(cats)} categories -> {p} ({os.path.getsize(p)//1024} KB)")
