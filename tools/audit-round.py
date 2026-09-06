"""Freeze the subject of an audit round, and prove it did not move.

All three auditors independently found the same defect on 2026-09-05: the round had no frozen
subject. The surface went from 43 commits to 45 mid-round, and one auditor caught the drift only
because a guard happened to print two different receipt shas at it — its own words: "that was luck,
not method." A round against moving bytes certifies nothing.

    python3 tools/audit-round.py open   # pin HEAD + tree hash, refuse if the tree is dirty
    python3 tools/audit-round.py check  # has anything moved since? exit 1 if so
    python3 tools/audit-round.py close  # release

The tree hash covers tracked content, so an uncommitted edit during a round is caught too — that is
how a stranded mutant survived a run once already.
"""

import hashlib
import json
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
PIN = REPO / ".runs" / "audit-round.json"


def git(*a):
    return subprocess.run(["git", "-C", str(REPO), *a], capture_output=True, text=True).stdout.strip()


def subject():
    head = git("rev-parse", "HEAD")
    dirty = git("status", "--porcelain")
    tree = hashlib.sha256(git("ls-files", "-s").encode()).hexdigest()[:16]
    work = hashlib.sha256((git("diff") + git("diff", "--cached")).encode()).hexdigest()[:16]
    return {"head": head, "tree": tree, "work": work, "dirty": dirty}


cmd = sys.argv[1] if len(sys.argv) > 1 else "check"

if cmd == "open":
    s = subject()
    PIN.parent.mkdir(exist_ok=True)
    if s["dirty"]:
        print("note: uncommitted files are frozen INTO this round and must not move:")
        for line in s["dirty"].splitlines():
            print(f"  {line}")
    PIN.write_text(json.dumps(s))
    print(f"round OPEN on {s['head'][:12]} (tree {s['tree']}). Every auditor must be given this sha.")
    sys.exit(0)

if cmd == "close":
    PIN.unlink(missing_ok=True)
    print("round CLOSED")
    sys.exit(0)

if not PIN.exists():
    print("no round is open — nothing is frozen, so no verdict from this window counts.", file=sys.stderr)
    sys.exit(1)

pinned = json.loads(PIN.read_text())
now = subject()
moved = [k for k in ("head", "tree", "work") if pinned.get(k) != now[k]]
if moved:
    print(f"ROUND VOID: the audited surface moved ({', '.join(moved)}).", file=sys.stderr)
    print(f"  pinned head {pinned['head'][:12]} tree {pinned['tree']} work {pinned.get('work')}", file=sys.stderr)
    print(f"  now    head {now['head'][:12]} tree {now['tree']} work {now['work']}", file=sys.stderr)
    print("  Discard every verdict from this window and re-open on the new sha.", file=sys.stderr)
    sys.exit(1)
print(f"round INTACT on {pinned['head'][:12]} (tree {pinned['tree']})")
