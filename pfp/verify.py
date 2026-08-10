import sys, random
from collections import defaultdict
SP=sys.argv[1]; gender=sys.argv[2] if len(sys.argv)>2 else "male"; N=int(sys.argv[3]) if len(sys.argv)>3 else 400
sys.argv=["x",SP]
g={}; exec(open(SP+"/engine2.py").read().split('if __name__')[0], g)
tree,leafmeta=g["load"](gender)
def bycat(s):
    d=defaultdict(list)
    for lf in s.leaves:
        m=leafmeta.get(lf["z"])
        if m: d[m["category"]].append(m["path"])
    return d
def seg(p,i):
    a=p.split("/"); return a[i] if len(a)>i else ""
EXOTIC={"Flame","Blue","Purple"}
viol=defaultdict(int); ex=defaultdict(list)
for i in range(N):
    s=g["generate"](tree, random.Random(9000+i)); g["apply_conflicts"](s,leafmeta)
    d=bycat(s); dr=s.drivers; hid=s.hidden
    def has(cat): return len(d.get(cat,[]))>0
    def has_path(sub): return any(sub in p for ps in d.values() for p in ps)
    if gender=="male":
        # coupling
        tsets={seg(p,1) for p in d.get("11 Tattoos",[]) if not p.endswith("/None")}; tsets={t for t in tsets if t}
        if len(tsets)>1: viol["tattoo_multi"]+=1; ex["tattoo_multi"].append((i,sorted(tsets)))
        elif len(tsets)==1:
            t=list(tsets)[0]; suit=dr.get("suit","")
            if suit and suit.split()[0].lower() not in t.lower() and t.replace(" Tattoos","").lower() not in suit.lower():
                viol["tattoo_suit_mismatch"]+=1; ex["tattoo_suit_mismatch"].append((i,t,suit))
        bsets={seg(p,1) for p in d.get("12 Beard",[])}; bsets={b for b in bsets if b}
        if len(bsets)>1: viol["beard_multi"]+=1
        elif len(bsets)==1:
            b=list(bsets)[0]; hc=dr.get("hair_color","")
            if hc and hc not in EXOTIC and hc.lower() not in b.lower() and b.split()[0] not in ("Giga","POC"):
                viol["beard_hair_mismatch"]+=1; ex["beard_hair_mismatch"].append((i,b,hc))
        # conflicts
        cover=hid["cover"]
        if cover=="full":
            for c in ["16 Glasses","15 Eye Mod","10 Nose","12 Beard","14 Eyebrow"]:
                if has(c): viol[f"fullmask_shows_{c}"]+=1; ex[f"fullmask_shows_{c}"].append((i,hid["facemod"]))
            if has_path("8 Mouth"): viol["fullmask_shows_mouth"]+=1
        elif cover=="eyes":
            for c in ["16 Glasses","15 Eye Mod"]:
                if has(c): viol[f"eyemask_shows_{c}"]+=1; ex[f"eyemask_shows_{c}"].append((i,hid["facemod"]))
        elif cover=="lower":
            if has("12 Beard"): viol["lowermask_shows_beard"]+=1; ex["lowermask_shows_beard"].append((i,hid["facemod"]))
            if has_path("8 Mouth"): viol["lowermask_shows_mouth"]+=1
        if (s.picks.get("24 Laser Eye") or "None").lower()!="none":
            if has("16 Glasses") or has("15 Eye Mod"): viol["laser_shows_eyewear"]+=1
        if dr.get("hat") and has("23 Ceasar"): viol["hat_and_ceasar"]+=1
    faces={seg(p,1) for p in d.get("7 Face" if gender=="male" else "5 Face",[])}; faces={f for f in faces if f}
    if len(faces)>1: viol["face_multi"]+=1; ex["face_multi"].append((i,sorted(faces)))

print(f"=== {gender}: {N} tokens ===")
if not viol: print("  ALL INVARIANTS HOLD ✓ (coupling + conflicts)")
for k in sorted(viol): print(f"  {k}: {viol[k]}   e.g. {ex[k][:2]}")
