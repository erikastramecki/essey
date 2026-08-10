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

def role(name):
    return ns["_role"](name)

for gender in ("male", "female"):
    leaves = json.load(open(f"{SP}/traits/{gender}/leaves.json"))
    tree = json.load(open(f"{SP}/traits/{gender}/structure.json"))["tree"]
    # slim leaves for the client (drop nothing needed: z, category, path, file, bbox, blend)
    slim = [{"z": e["z"], "category": e["category"], "path": e["path"],
             "file": e["file"], "bbox": e["bbox"], "blend": e.get("blend", "normal")} for e in leaves]
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
