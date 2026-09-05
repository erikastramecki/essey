"""Role-filtered view of docs/agents/LESSONS.md.

The founder's constraint, 2026-09-05: share craft across roles, but never at the cost of an agent
losing track of its own job. So a lesson is written ONCE and routed — the engineer inherits "verify
your probe can fail" because it makes it better at its own work, and never inherits the Jester's
voice rules. Filtering at read time is what keeps a shared surface from becoming a context tax.
"""

import argparse
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
LESSONS = REPO / "docs" / "agents" / "LESSONS.md"


def parse():
    if not LESSONS.exists():
        return []
    out = []
    for block in LESSONS.read_text().split("\n### ")[1:]:
        m = re.search(r"^\*\*Applies to:\*\*\s*(.+)$", block, re.M)
        roles = {r.strip() for r in m.group(1).split(",")} if m else set()
        out.append({"title": block.split("\n", 1)[0].strip(), "roles": roles, "body": "### " + block.rstrip()})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--role", required=True)
    ap.add_argument("--titles", action="store_true", help="one line each, for a cheap startup read")
    a = ap.parse_args()

    hits = [l for l in parse() if a.role in l["roles"] or "all" in l["roles"]]
    if not hits:
        print(f"No shared lessons tagged for '{a.role}'.")
        return 0
    print(f"{len(hits)} shared lesson(s) for {a.role} — these are yours to apply, not to chase:\n")
    for l in hits:
        print(l["title"] if a.titles else l["body"] + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
