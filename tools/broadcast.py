"""Who has actually absorbed a team-wide rule, and who has only had it published at them.

Founder, 2026-09-05: after pushing a rule to every agent, verify their continuity files updated and
READ them before certifying it done. Agents spawn stateless, so a rule in an undispatched charter has
reached nobody. Counting acknowledgements is not certifying — this prints the actual sentences so
they have to be read.
"""

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
CONT = REPO / "docs" / "agents" / "continuity"
BC = REPO / "docs" / "agents" / "BROADCASTS.md"

ids = re.findall(r"^### (BC-\d+)", BC.read_text(), re.M) if BC.exists() else []
AGENTS = pathlib.Path.home() / ".claude" / "agents"
_owned = lambda f: f.startswith(("essey-", "don-")) or f == "jester.md"
agents = sorted(p.stem for p in AGENTS.glob("*.md") if _owned(p.name)) if AGENTS.exists() else []

if not ids:
    print("no broadcasts on file")
    sys.exit(0)

incomplete = False
for bc in ids:
    acked = {}
    for a in agents:
        cf = CONT / f"{a}.md"
        if not cf.exists():
            continue
        found = re.findall(
            rf"^ACK {bc}\s*[—-]\s*(.+?)(?=\n\s*\n|\n\s*ACK BC-|\Z)",
            cf.read_text(),
            re.M | re.S,
        )
        if found:
            acked[a] = [" ".join(f.split()) for f in found]
    print(f"\n{bc}: {len(acked)}/{len(agents)} acknowledged")
    for a in agents:
        if a in acked:
            print(f"  ACK  {a}\n         " + "\n         ".join(acked[a]))
    # An ACK is meant to prove the agent read the rule. A blank one, or the same sentence pasted into
    # several files, proves the opposite and would otherwise count toward a clean 16/16.
    seen = {}
    for a, sents in acked.items():
        for sent in sents:
            key = " ".join(sent.lower().split())
            if len(key) < 25:
                incomplete = True
                print(f"  SUSPECT {a}: an ACK line is empty or too short to be its own words")
            seen.setdefault(key, []).append(a)
        if len(sents) > 1:
            print(f"  note: {a} has {len(sents)} ACK lines for {bc}; all are checked")
    for key, who in seen.items():
        if len(who) > 1:
            incomplete = True
            print(f"  SUSPECT identical ACK pasted by {len(who)}: {', '.join(who)}")

    missing = [a for a in agents if a not in acked]
    if missing:
        incomplete = True
        print(f"  PENDING ({len(missing)}): {', '.join(missing)}")

print(
    "\nNOT CERTIFIABLE — every agent must acknowledge in its own words, and you must READ them."
    if incomplete
    else "\nAll agents acknowledged. Read the sentences above before certifying; identical wording means pasted, not absorbed."
)
sys.exit(1 if incomplete else 0)
