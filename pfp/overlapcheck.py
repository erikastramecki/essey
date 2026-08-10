"""Region-occupancy checker: flags tokens where >1 category competes for one physical slot.
This catches VISUAL crowding (two objects in a hand, hair through a hat) that count/coupling
checks miss. Run across the whole collection, both genders."""
import sys, json, random
from collections import Counter
SP = sys.argv[1]; N = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
ns = {}
exec(compile(open(f"{SP}/engine2.py").read().split("if __name__")[0], "e", "exec"), ns)
load, generate, apply_conflicts = ns["load"], ns["generate"], ns["apply_conflicts"]

# single-occupancy slots per gender: at most ONE of these categories may render
SLOTS = {
    "male": {
        "hand":    ["25 Snake", "18 Canes", "19 Hand Grip"],
        "hair":    ["13 Hair", "13.5 Hat Hair"],
        "head-top":["22 Hat", "23 Ceasar"],
    },
    "female": {
        "hand":    ["13 Hand Grip"],
        "head-acc":["11 Devilish", "16 Neko"],   # horns / fox-mask shouldn't co-occupy the head with a hat
        "head-hat":["10 Hat"],
    },
}

def run(gender, N):
    tree, lm = load(gender)
    viol = Counter(); examples = {}
    for tid in range(N):
        s = generate(tree, random.Random(1000000 + tid * 1000))  # NOTE: not the real manifest seed
        apply_conflicts(s, lm)
        present = {lm.get(lf["z"], {}).get("category", "") for lf in s.leaves}
        for slot, cats in SLOTS[gender].items():
            hit = [c for c in cats if c in present]
            if len(hit) > 1:
                viol[slot] += 1
                examples.setdefault(slot, (tid, hit))
        # cross-slot on the head: hat + horns, hat + fox-mask
        if gender == "female":
            head = [c for c in ("10 Hat", "11 Devilish", "16 Neko") if c in present]
            if len(head) > 1:
                viol["head-combo"] += 1; examples.setdefault("head-combo", (tid, head))
    print(f"=== {gender}: {N} tokens ===")
    if not viol:
        print("  NO REGION CROWDING ✓")
    for slot, n in viol.most_common():
        tid, hit = examples[slot]
        print(f"  {slot}: {n} tokens crowded   e.g. #{tid} -> {hit}")

for g in ("male", "female"):
    run(g, N)
