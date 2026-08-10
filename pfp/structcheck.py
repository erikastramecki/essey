import sys, random
from collections import defaultdict, Counter
SP=sys.argv[1]; gender=sys.argv[2] if len(sys.argv)>2 else "female"; N=int(sys.argv[3]) if len(sys.argv)>3 else 300
sys.argv=["x",SP]
g={}; exec(open(SP+"/engine2.py").read().split('if __name__')[0], g)
tree,leafmeta=g["load"](gender)
FACE="5 Face" if gender=="female" else "7 Face"
def paths(s):
    return [leafmeta.get(lf["z"],{}).get("path","") for lf in s.leaves]
def cats(s):
    return [leafmeta.get(lf["z"],{}).get("category","") for lf in s.leaves]
bad=defaultdict(int); ex=defaultdict(list)
for i in range(N):
    s=g["generate"](tree, random.Random(3000+i)); g["apply_conflicts"](s,leafmeta)
    if s.drivers.get("family") in ("Zombie","Golden","Glitch"): continue
    P=paths(s); C=cats(s); hid=s.hidden
    # count content leaves (exclude shadows) per region
    def cnt(pred): return sum(1 for p in P if pred(p) and "shadow" not in p.lower())
    faceids={p.split("/")[1] for p in P if p.startswith(FACE) and len(p.split("/"))>1}
    eyes=cnt(lambda p: "/9 Eyes/" in p or "/Eyes/" in p or "/Eyes " in p)
    mouth=cnt(lambda p: "/8 Mouth/" in p or "/Mouth/" in p or "/Mouth " in p)
    nose=cnt(lambda p: p.startswith("6 Nose") or p.startswith("10 Nose"))
    grip=cnt(lambda p: p.startswith("13 Hand Grip") or p.startswith("19 Hand Grip"))
    cover=hid.get("cover")
    # invariants (unless hidden by a full mask)
    if cover!="full":
        if eyes==0: bad["eyes_MISSING"]+=1; ex["eyes_MISSING"].append((i,sorted(faceids)))
        if eyes>1: bad["eyes_DUP"]+=1; ex["eyes_DUP"].append((i,eyes))
        if mouth==0 and cover not in ("full","lower"): bad["mouth_MISSING"]+=1
        if mouth>1: bad["mouth_DUP"]+=1
        if nose==0: bad["nose_MISSING"]+=1
        if nose>1: bad["nose_DUP"]+=1; ex["nose_DUP"].append((i,nose))
    if grip>1: bad["grip_DUP"]+=1; ex["grip_DUP"].append((i,grip,[p for p in P if "Grip" in p and "shadow" not in p.lower()]))
    if len(faceids)>1: bad["face_DUP"]+=1
print(f"=== {gender}: {N} tokens ===")
if not bad: print("  STRUCTURE CLEAN ✓")
for k in sorted(bad): print(f"  {k}: {bad[k]}   e.g. {ex[k][:2]}")
