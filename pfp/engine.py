"""Essey PFP engine v2 — coupling-aware, conflict-aware, blend-faithful.

The PSD nests traits by a DRIVING dimension (suit/body/hair/hat/eye-mod). A nested container is:
  - a STACK  (all children default-visible: colour+shadow, face base+mouth+eyes, ring combos) -> render all
  - a COUPLE (one child default-visible: keyed by a driver) -> pick the child matching the chosen driver
Drivers are picked first (Body, Suit, Hair, Eye-Mod, Hat), then coupled categories resolve against them.
"""
import json, os, re, random, sys
import numpy as np
from PIL import Image

SP = sys.argv[1] if len(sys.argv) > 1 else "."

def load(gender):
    tree = json.load(open(f"{SP}/traits/{gender}/structure.json"))["tree"]
    leafmeta = {e["z"]: e for e in json.load(open(f"{SP}/traits/{gender}/leaves.json"))}
    return tree, leafmeta

def cats_of(tree):
    return {c["name"]: c for c in tree if c["group"]}

# ---- driver dimensions: a nested container is a COUPLE if >=2 children are keyed by DIFFERENT
#      values of the SAME dimension (identity alternatives); we then pick the one matching the driver.
DIMS = {
    "faceid":     ["Magnate", "Oligarch", "Heiress"],                                   # female face identity
    "family":     ["Mogul", "Baron", "Tycoon", "Executive", "Financier", "Industrialist"],
    "build":      ["Chad", "Giga", "Chiseled", "Chet", "Zombie", "Golden"],  # +special 1/1 faces
    "suit":       ["The General", "Couture", "Designer", "Bladerunner", "Windsor", "Joker",
                   "Duke", "Pimp", "Cas", "Scholar", "Opera", "Jennifer", "Riviera", "Leadership",
                   "Hotlanta", "Ruffles", "Badass", "BossB", "Duchess", "Weeb", "Scarlet"],
    "hair_color": ["Flame", "Fire", "Blue", "Purple", "Red", "Blonde", "White", "Brown", "Black", "Pink", "Grey", "Peach", "POC"],
    "hat":        ["Fedora", "Bowler", "Santana"],
    "eyemod":     ["Cyclops", "Hardboiled", "Cyberpunk", "Spider", "Monocle", "Monocyber"],
    "hair_style": ["Rooster", "Falcon", "Electrodread", "Linecut", "Dreaded", "Updo", "Boss", "Lush",
                   "Gem", "Pantene", "Sash", "Punk", "Bob", "Medusa", "Curl", "Afro", "Rows", "Doness", "Wolf"],
}
DIM_PRIORITY = ["faceid", "suit", "family", "build", "hair_color", "hat", "eyemod", "hair_style"]
# female body family and face id are DISJOINT dimensions; couple them by matching skin tone so the
# face never mismatches the neck/body (Executive/Financier/Industrialist ~ Magnate/Oligarch/Heiress).
FAMILY_TO_FACEID = {"Executive": "Magnate", "Financier": "Oligarch", "Industrialist": "Heiress"}

def first_word(name):
    return (name or "").split()[0] if name else ""

def couple_dim(children):
    """If >=2 children are keyed by different values of one dimension, return (dim, {value: [child,...]})."""
    names = [(c, (c["name"] or "").lower()) for c in children]
    for dim in DIM_PRIORITY:
        hit = {}
        for c, nl in names:
            for v in DIMS[dim]:
                if v.lower() in nl:
                    hit.setdefault(v, []).append(c)
                    break
        if len(hit) >= 2:
            return dim, hit
    return None, None

def is_part(c):
    """A face/colour composite PART (always stacked with its siblings), not a selectable alternative."""
    nl = (c["name"] or "").lower()
    return "shadow" in nl or nl in ("mouth", "eyes", "8 mouth", "9 eyes")

# ---------------------------------------------------------------- selection
class Sel:
    def __init__(self, rng):
        self.rng = rng
        self.leaves = []          # visible leaf nodes
        self.picks = {}           # path -> chosen name (metadata)
        self.drivers = {}         # driver dimension -> value

    def emit(self, node, path):
        if node["group"]:
            self.select(node["children"], path)
        else:
            self.leaves.append(node)

    def couple_pick(self, children):
        """If children are identity-alternatives (one dimension), return the child matching the driver."""
        dim, hit = couple_dim(children)
        if not dim:
            return None
        v = (self.drivers.get(dim) or "").lower()
        if not v:
            return None
        for val, cs in hit.items():
            if val.lower() in v or v in val.lower():
                return cs[0]
        return None

    def select(self, children, path):
        # PARTS (mouth/eyes/shadow) always stack; the REST is the one selectable slot.
        parts = [c for c in children if is_part(c)]
        rest = [c for c in children if not is_part(c)]
        kept = [c for c in rest if not any(x in (c["name"] or "").lower() for x in SUPPRESS)]
        if kept:                      # drop user-suppressed variants unless they're the only option
            rest = kept
        for c in parts:
            self.emit(c, path)
        if not rest:
            return
        dim, hit = couple_dim(rest)
        # 1) DEPENDENT coupling: the driver is already chosen -> pick the matching child
        if dim and self.drivers.get(dim):
            pick = self.couple_pick(rest)
            if pick is not None:
                self.picks[path] = pick["name"]
                self.emit(pick, path + "/" + pick["name"])
                return
            nm = " ".join((c["name"] or "") for c in rest).lower()
            if "tattoo" in nm or "beard" in nm:   # OPTIONAL coupled: no matching variant -> ABSENT
                return                            # (Fire hair -> no beard; unused suit -> no tattoo)
            # else MANDATORY coupled (face/nose): fall through so a valid variant still renders
        # 2) WEIGHTED select — respects rarity, INCLUDING a "None" option (optional categories)
        weighted = [c for c in rest if c.get("rarity") is not None]
        if weighted:
            pick = self.rng.choices(weighted, weights=[c["rarity"] for c in weighted], k=1)[0]
            self.picks[path] = pick["name"]
            self.emit(pick, path + "/" + pick["name"])
            return
        # 3) identity selection that DEFINES a driver (no rarity) -> pick one real identity
        if dim:
            cands = [c for cs in hit.values() for c in cs]
            pick = self.rng.choice(cands) if cands else self.rng.choice(rest)
            self.picks[path] = pick["name"]
            self.emit(pick, path + "/" + pick["name"])
            return
        vis = [c for c in rest if c.get("vis")]
        if len(vis) == len(rest):                          # all-visible base leaves -> stack
            for c in rest:
                self.emit(c, path)
        else:
            pick = vis[0] if vis else self.rng.choice(rest)
            self.picks[path] = pick["name"]
            self.emit(pick, path + "/" + pick["name"])

    def select_category(self, cat):
        """Select a whole top-level category; return the top-level chosen name (the driver value)."""
        before = len(self.leaves)
        # a category itself is a STACK/COUPLE container over its children
        top_before = dict(self.picks)
        self.select([cat], cat["name"])
        # the driver = the first-level pick under this category
        for k, v in self.picks.items():
            if k == cat["name"]:
                return v
        # else: category stacked (no single pick) — return None
        return None


def _role(name):
    n = name.lower()
    if n.endswith("body"): return "body"
    if n.endswith("suit") or n.endswith("suits"): return "suit"
    if n.endswith("hair") and "hat" not in n and "rear" not in n: return "hair"
    if "eye mod" in n: return "eyemod"
    if n.endswith("hat") and "hair" not in n: return "hat"
    return None

_PRI = {"body": 0, "suit": 1, "hair": 2, "eyemod": 3, "hat": 4}  # drivers resolved before dependents

# Categories the PSD gives no "None"/rarity, so we make them OPTIONAL: P(present) below (absent otherwise).
OPTIONAL = {"16 Neko": 0.05}  # Neko fox mask = rare accessory
SUPPRESS = ("swollen",)       # user-flagged variants removed from every pool (bruised/red-rimmed eye)

def generate(tree, rng):
    s = Sel(rng)
    cats = cats_of(tree)
    roles = {name: _role(name) for name in cats}
    drivers = sorted([n for n, r in roles.items() if r is not None], key=lambda n: _PRI[roles[n]])
    order = drivers + [c for c in cats if roles[c] is None]
    for name in order:
        if name in OPTIONAL:
            if rng.random() >= OPTIONAL[name]:
                continue  # optional category rolled absent this token
            if s.couple_pick(cats[name]["children"]) is None:
                continue  # coupled optional (Neko) with no variant for this hairstyle -> absent
        top = s.select_category(cats[name])
        r = roles[name]
        if r == "body" and top:
            fam = first_word(top)
            s.drivers["family"] = fam
            if fam in FAMILY_TO_FACEID:            # female: force the skin-matched face id
                s.drivers["faceid"] = FAMILY_TO_FACEID[fam]
            if fam in ("Zombie", "Golden"):        # these 1/1 bodies have a matching special FACE
                s.drivers["build"] = fam           # -> couple the face to it so a head actually renders
            else:
                sub = s.picks.get(name + "/" + top, top)   # normal build at the sub-level: "Tycoon Chad"
                s.drivers["build"] = next((b for b in DIMS["build"] if b in sub.split()), None)
        elif r == "suit" and top:
            s.drivers["suit"] = top
        elif r == "hair" and top:
            # female hair is style->colour, male is colour->style: extract both order-agnostically
            cw = s.picks.get(name + "/" + top, "")
            full = (top + " " + cw).lower()
            s.drivers["hair_color"] = next((c for c in DIMS["hair_color"] if c.lower() in full), None)
            s.drivers["hair_style"] = next((st for st in DIMS["hair_style"] if st.lower() in full), first_word(top))
            if s.drivers["hair_color"] is None:   # bald/uncoloured: give beard+brows ONE shared colour
                s.drivers["hair_color"] = rng.choice(["Black", "Red", "White"])
        elif r == "eyemod":   # a redundant "15 Eye Mod" wrapper nests the real mod -> scan sub-picks
            vals = " ".join(v for k, v in s.picks.items() if k.startswith(name)).lower()
            s.drivers["eyemod"] = next((m for m in DIMS["eyemod"] if m.lower() in vals), None)
        elif r == "hat" and top and top.lower() != "none":
            s.drivers["hat"] = first_word(top)
        if name.lower().endswith("face") and top:   # face identity drives female nose/mouth/eyes
            s.drivers["faceid"] = first_word(top)
    return s

# ---------------------------------------------------------------- conflict / hide pass
# Face-mod coverage: which face region a mask hides.
FACEMOD_COVER = {"Terminator": "eyes", "Bane": "lower", "Jester": "full",
                 "Doom": "lower", "Samurai": "lower", "Cthulu": "lower"}

# held-object overlap conflicts (precomputed by compute_conflicts.py): two objects may co-render
# UNLESS their opaque areas overlap past threshold. Keep the hand item; drop a colliding cane/snake.
try:
    _HC = json.load(open(f"{SP}/traits/male/hand_conflicts.json"))
    _CG = {tuple(p) for p in _HC["cane_grip"]}
    _SG = set(_HC["snake_grip"])
    _CS = {tuple(p) for p in _HC["cane_snake"]}
except FileNotFoundError:
    _CG, _SG, _CS = set(), set(), set()

def apply_conflicts(s, leafmeta):
    picks, drivers = s.picks, s.drivers
    fm = (picks.get("17 Face Mod") or "None")
    cover = FACEMOD_COVER.get(fm.split()[0]) if fm.lower() != "none" else None
    laser = (picks.get("24 Laser Eye") or "None").lower() != "none"
    hat = bool(drivers.get("hat"))
    hide_cats, hide_paths = set(), []
    _fam = drivers.get("family")
    if _fam in ("Zombie", "Golden", "Glitch"):   # 1/1 bodies: strip normal head accessories
        hide_cats |= {"10 Nose", "11 Tattoos", "12 Beard", "13 Hair", "13.5 Hat Hair",
                      "14 Eyebrow", "15 Eye Mod", "16 Glasses", "17 Face Mod", "22 Hat", "23 Ceasar", "24 Laser Eye"}
        if _fam == "Glitch":            # Glitch body art already includes its head; Zombie/Golden need
            hide_cats |= {"7 Face"}     # the special 7 Face/<fam> face, so keep it for those two
    if cover == "full":
        hide_cats |= {"16 Glasses", "15 Eye Mod", "14 Eyebrow", "10 Nose", "12 Beard"}
        hide_paths += ["8 Mouth", "9 Eyes"]
    elif cover == "eyes":
        hide_cats |= {"16 Glasses", "15 Eye Mod"}
    elif cover == "lower":
        hide_cats |= {"12 Beard"}; hide_paths += ["8 Mouth"]
    if laser:                                   # laser eyes replace any eyewear/eye-mod
        hide_cats |= {"16 Glasses", "15 Eye Mod"}
    if hat:                                      # a hat and a laurel crown can't share the head
        hide_cats |= {"23 Ceasar"}
    if fm.split()[0] == "Doom":                  # Doom is a full helmet (hair baked in): no hat, no
        hide_cats |= {"22 Hat", "13.5 Hat Hair", "13 Hair", "23 Ceasar"}   # separate hair -> else a
        hat = False                              # broken beige dome shows between hat and helmet

    # HELD OBJECTS: keep the hand item; drop a cane/snake only if it OVERLAPS the item (else co-render).
    def _variant(cat):
        for lf in s.leaves:
            m = leafmeta.get(lf["z"], {})
            if m.get("category") == cat:
                p = m["path"].split("/")
                return p[1] if len(p) > 1 else p[0]
        return None
    grip, cane, snake = _variant("19 Hand Grip"), _variant("18 Canes"), _variant("25 Snake")
    if grip and cane and (cane, grip) in _CG:
        hide_cats |= {"18 Canes"}; cane = None
    if grip and snake and grip in _SG:
        hide_cats |= {"25 Snake"}; snake = None
    if cane and snake and (cane, snake) in _CS:
        hide_cats |= {"25 Snake"}; snake = None
    # SNAKE = one draped accessory: tail (behind, z104) + head/body (front). Strip the raw always-on
    # tail; re-add ONLY the colour-matched tail when a snake head actually survives. No orphan tails.
    add_leaves = []
    hide_cats |= {"6 Snake Tail"}
    if snake:
        col = "red" if "red" in snake.lower() else "green"
        tail = next((e for e in leafmeta.values()
                     if e.get("category") == "6 Snake Tail" and col in e["path"].lower()), None)
        if tail:
            add_leaves.append(tail)

    # HAIR vs HAT HAIR: a hat covers the crown -> show only the hat-hair; bare head -> show full hair.
    if drivers.get("family") not in ("Zombie", "Golden", "Glitch"):
        hide_cats |= {"13 Hair"} if hat else {"13.5 Hat Hair"}

    def keep(lf):
        m = leafmeta.get(lf["z"])
        if not m:
            return True
        if m["category"] in hide_cats:
            return False
        if any(hp in m["path"] for hp in hide_paths):
            return False
        return True
    s.leaves = [lf for lf in s.leaves if keep(lf)] + add_leaves
    s.hidden = {"cats": sorted(hide_cats), "paths": hide_paths, "facemod": fm, "cover": cover}
    return s

# ---------------------------------------------------------------- compositor (validated in v1)
def _over(canvas, col, sa, x0, y0):
    h, w = sa.shape
    dst = canvas[y0:y0 + h, x0:x0 + w]
    saa = sa[..., None]; ca = dst[..., 3:4]
    out_a = saa + ca * (1 - saa)
    safe = np.where(out_a > 1e-9, out_a, 1.0)
    dst[..., :3] = (col * saa + dst[..., :3] * ca * (1 - saa)) / safe
    dst[..., 3:4] = out_a

# Z overrides: render a category just beneath another, without editing the PSD.
Z_UNDER = {"15 Earing": "9 Hair"}  # earrings sit under the hair (down-hair covers them, updos reveal them)
# position overrides: female AR (17 AR) was authored off-canvas to the left -> shift it onto the
# right side of the canvas (matching the male AR placement) so it actually renders.
POS_OFFSET = {"17 AR": 1004}

def composite(leaves, leafmeta, gender):
    canvas = np.zeros((900, 900, 4), np.float64)
    tz = {}
    for cat, under in Z_UNDER.items():
        zs = [lf["z"] for lf in leaves if leafmeta.get(lf["z"], {}).get("category") == under]
        if zs:
            tz[cat] = min(zs) - 0.5
    def ez(lf):
        return tz.get(leafmeta.get(lf["z"], {}).get("category", ""), lf["z"])
    for lf in sorted(leaves, key=ez):
        m = leafmeta.get(lf["z"])
        if not m: continue
        p = f"{SP}/traits/{gender}/{m['file']}"
        if not os.path.exists(p): continue
        im = np.asarray(Image.open(p).convert("RGBA"), np.float64) / 255.0
        rgb, a = im[..., :3], im[..., 3]
        if m.get("category", "") in ("3 Chair", "1 Chairs"):   # kill the chair edge alpha-bleed speckle
            a = np.where(a < 0.9, 0.0, a)                       # (semi-transparent stray pixels -> gone)
        l, t = m["bbox"][0] + POS_OFFSET.get(m.get("category", ""), 0), m["bbox"][1]; h, w = a.shape
        x0, y0 = max(l, 0), max(t, 0); x1, y1 = min(l + w, 900), min(t + h, 900)
        if x0 >= x1 or y0 >= y1: continue
        sy, sx = y0 - t, x0 - l
        sr = rgb[sy:sy + (y1 - y0), sx:sx + (x1 - x0)]; sa = a[sy:sy + (y1 - y0), sx:sx + (x1 - x0)]
        back = canvas[y0:y1, x0:x1, :3]; mode = lf.get("blend", "normal")
        if m.get("category") == "26 AR":   # holographic HUD authored for SCREEN washes out on light
            back = back * (1 - 0.9 * sa[..., None])   # backing: near-opaque dark under the holo, then
            canvas[y0:y1, x0:x1, :3] = back           # screen -> crisp & fully visible on ANY background
            col = 1 - (1 - back) * (1 - sr)
        else:
            col = back * sr if mode == "multiply" else (1 - (1 - back) * (1 - sr)) if mode == "screen" else sr
        _over(canvas, col, sa, x0, y0)
    return Image.fromarray((np.clip(canvas, 0, 1) * 255).astype("uint8"))

if __name__ == "__main__":
    gender = sys.argv[2] if len(sys.argv) > 2 else "male"
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 7
    tree, leafmeta = load(gender)
    s = generate(tree, random.Random(seed))
    composite(s.leaves, leafmeta, gender).save(f"{SP}/eng2_{gender}_{seed}.png")
    print("drivers:", s.drivers)
    print("leaves:", len(s.leaves))
