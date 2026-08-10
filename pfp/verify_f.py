import sys, random
from collections import defaultdict
SP=sys.argv[1]; N=int(sys.argv[2]) if len(sys.argv)>2 else 400
sys.argv=["x",SP]
g={}; exec(open(SP+"/engine2.py").read().split('if __name__')[0], g)
tree,leafmeta=g["load"]("female")
def bycat(s):
    d=defaultdict(list)
    for lf in s.leaves:
        m=leafmeta.get(lf["z"])
        if m: d[m["category"]].append(m["path"])
    return d
def seg(p,i):
    a=p.split("/"); return a[i] if len(a)>i else ""
viol=defaultdict(int); ex=defaultdict(list); neko=0
for i in range(N):
    s=g["generate"](tree, random.Random(7000+i)); g["apply_conflicts"](s,leafmeta)
    d=bycat(s); dr=s.drivers
    faces={seg(p,1) for p in d.get("5 Face",[])}; faces={f for f in faces if f}
    if len(faces)>1: viol["face_multi"]+=1; ex["face_multi"].append((i,sorted(faces)))
    bodies={seg(p,1) for p in d.get("3 Body",[])}; bodies={b for b in bodies if b}
    if len(bodies)>1: viol["body_multi"]+=1
    suits={seg(p,1) for p in d.get("4 Suits",[])}; suits={x for x in suits if x}
    if len(suits)>1: viol["suit_multi"]+=1; ex["suit_multi"].append((i,sorted(suits)))
    noses={seg(p,1) for p in d.get("6 Nose",[])}; noses={n for n in noses if n}
    if len(noses)>1: viol["nose_multi"]+=1
    # Neko: if present, must match hairstyle
    nk=[p for p in d.get("16 Neko",[])]
    if nk:
        neko+=1; variant=seg(nk[0],1); hs=dr.get("hair_style","")
        if hs and hs.lower() not in variant.lower(): viol["neko_hair_mismatch"]+=1; ex["neko_hair_mismatch"].append((i,variant,hs))
print(f"=== female: {N} tokens ===   Neko present: {neko} ({100*neko/N:.1f}%)")
if not viol: print("  ALL INVARIANTS HOLD ✓")
for k in sorted(viol): print(f"  {k}: {viol[k]}   e.g. {ex[k][:2]}")
