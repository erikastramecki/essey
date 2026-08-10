import warnings; warnings.filterwarnings("ignore")
import os, re, json, sys
from psd_tools import PSDImage
RARITY=re.compile(r'#(\.?\d+(?:\.\d+)?)')
def clean(n): return RARITY.sub("", n or "").strip()
def slug(s):
    return re.sub(r'[^A-Za-z0-9]+','_', s).strip('_')[:60] or "x"

def extract(path, gender, outdir):
    psd=PSDImage.open(path)
    meta=[]; z=[0]
    def walk(node, path_parts, cat, catord):
        for l in node:
            nm=l.name or ""
            c,co=cat,catord
            if node is psd:
                m=re.match(r'\s*(\d+(?:\.\d+)?)\s+', clean(nm))
                if m: c=clean(nm); co=float(m.group(1))
            z[0]+=1; myz=z[0]
            pp=path_parts+[clean(nm)]
            if l.is_group():
                walk(l, pp, c, co)
            else:
                try:
                    img=l.topil()  # RGBA of this leaf at its bbox
                except Exception as e:
                    continue
                if img is None: continue
                img=img.convert("RGBA")
                bbox=list(l.bbox)  # (l,t,r,b)
                try: bm=str(l.blend_mode).split('.')[-1].lower()
                except Exception: bm="normal"
                fid=f"{myz:04d}_{slug('/'.join(pp[-2:]))}"
                fn=os.path.join(outdir, fid+".png")
                img.save(fn)
                meta.append({"id":fid,"gender":gender,"category":c,"cat_order":co,
                    "path":"/".join(pp),"name":clean(nm),"z":myz,
                    "blend":"multiply" if "multiply" in bm else "normal",
                    "bbox":bbox,"file":os.path.basename(fn)})
    walk(psd, [], "", 0)
    json.dump(meta, open(os.path.join(outdir,"leaves.json"),"w"), indent=1)
    print(f"{gender}: extracted {len(meta)} leaves -> {outdir}")

SP=sys.argv[1]
extract("/Users/erikastramecki/Downloads/The MALE PFP.psd","male",SP+"/traits/male")
extract("/Users/erikastramecki/Downloads/The FEMALE PFP.psd","female",SP+"/traits/female")
print("DONE")
