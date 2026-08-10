import warnings; warnings.filterwarnings("ignore")
import re, json, sys
from psd_tools import PSDImage
RARITY=re.compile(r'#(\.?\d+(?:\.\d+)?)')
def wt(n):
    m=RARITY.search(n or ""); return float("0"+m.group(1)) if m else None
def clean(n): return RARITY.sub("", n or "").strip()

def build(path, gender):
    psd=PSDImage.open(path); z=[0]
    def node(l, isroot=False):
        nm=l.name or ""
        z[0]+=1; myz=z[0]
        try: bm=str(l.blend_mode).split('.')[-1].lower()
        except Exception: bm="normal"
        d={"name":clean(nm),"raw":nm,"rarity":wt(nm),"z":myz,
           "blend": ("multiply" if "multiply" in bm else ("screen" if "screen" in bm else "normal")),
           "group":l.is_group(), "vis": bool(l.visible)}
        if l.is_group():
            d["children"]=[node(c) for c in l]
        else:
            d["file"]=f"{myz:04d}"  # matches extract_leaves fid prefix
        return d
    tree=[node(l, True) for l in psd]
    json.dump({"gender":gender,"tree":tree}, open(sys.argv[1]+f"/traits/{gender}/structure.json","w"))
    print(f"{gender}: structure written ({z[0]} nodes)")

SP=sys.argv[1]
build("/Users/erikastramecki/Downloads/The MALE PFP.psd","male")
build("/Users/erikastramecki/Downloads/The FEMALE PFP.psd","female")
print("DONE")
