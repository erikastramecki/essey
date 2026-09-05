# Shared lessons

One entry per lesson, written once, **routed by role**. You read only what is tagged for you plus
`all`. This is deliberate: craft should cross roles, attention should not. Do not read the whole file.

    python3 tools/lessons.py --role <your-agent-name>

Append a lesson here only when it would change how a DIFFERENT role works. Anything specific to your
own job goes in `docs/agents/continuity/<your-agent-name>.md`, which nobody else pays to read.

Format is load-bearing — `tools/lessons.py` parses `**Applies to:**`, and `check-agent-wiring.mjs`
fails the build on an entry with no roles.

---

### L-001 — A probe must be shown producing a NEGATIVE result before its positive result counts
**Applies to:** all
**Origin:** 2026-09-05 · coordinator, engineer, jester
**The trap:** Three separate checks returned green on the same day, and green was the only answer any
of them could have given. A treasury page could not show a token it never queried. A style gate
globbed `*.ts` only, so every `.mjs` build gate in the repo was exempt and it passed a commit while
measuring 1 of 126 lines. A `grep` cleared a file of stranded mutants using a string the mutant did
not contain. None of them failed. None of them could have.
**Apply:** Before trusting any check, tool, gate, or test, break the exact thing it claims to catch
and watch it go red. Verify ADVERSARIALLY, not confirmatorily: mutate the case you did NOT have in
mind when you wrote it. A check you have never seen fail is a decoration.

### L-002 — Authorship is not evidence of content
**Applies to:** essey-protocol-engineer, essey-auditor, essey-harness, essey-deployment-manager
**Origin:** 2026-09-05 · engineer
**The trap:** After a concurrent process was found mutating the tree, the files were cleared as "all
deliberately mine" — authorship treated as proof of content. One of them was carrying a live
access-control mutant. Worse, that mutated file had already been hashed as the run's *pristine
baseline*, so every result would have been scored against a reference with the feature deleted.
**Apply:** A file being yours says nothing about what another writer left in it. Hash against `HEAD`
or rebuild from `git archive HEAD`; never clear a file by inspecting the lines you were thinking about.

### L-003 — Two runs on one working tree void BOTH results
**Applies to:** essey-protocol-engineer, essey-auditor, essey-harness, essey-deployment-manager
**Origin:** 2026-09-05 · coordinator
**The trap:** Two mutation-gate runs overlapped ~46 minutes on the same tree. Each run's restore
reverted the other's mutant mid-flight, producing false SURVIVED and false KILLED, and stranding a
mutant live in the source. Three runs that day produced no evidence.
**Apply:** Long jobs that mutate the tree take the lock. `python3 tools/runlock.py --list` shows what
is in flight. Never start a second run to "check" — stop the first. Prefer an isolated root built
from `git archive HEAD` so provenance is correct by construction.

### L-004 — Grade a fix by what is SERVED, not by what is committed
**Applies to:** essey-web-designer, jester, essey-deployment-manager, essey-harness
**Origin:** 2026-09-04 · jester
**The trap:** Three posts and a correction sat committed and unshipped for a full day while the live
bundle kept serving the wrong claim. The repo is where you go to talk yourself out of noticing.
**Apply:** Pull the served artifact and check the actual bytes. A fix that has not deployed is worth
nothing to the person reading the page.

### L-005 — A present-tense claim about deploy state falsifies itself on deploy
**Applies to:** jester, essey-web-designer, essey-social
**Origin:** 2026-09-05 · jester
**The trap:** A post said the live bundle "still carries the old thirteen." True when written, false
the instant it published — the post and the fix shipped in the same build, so the sentence was only
ever readable after it had become untrue.
**Apply:** Your words ship in the same build as the thing they describe. Re-read every present-tense
claim about live state as if the deploy already happened, and anchor anything that flips to a
timestamp rather than softening it.

### L-006 — Never state an inference as an observation
**Applies to:** all
**Origin:** 2026-09-05 · coordinator
**The trap:** "The suite passed with that mutant applied, so the bound may be unpinned" — two true
facts joined by an assumption that was never established, reported as a finding. It was refuted by
three tests that go red. A phantom finding costs the same review attention as a real one.
**Apply:** Label VERIFIED (and say what you ran) vs INFERRED. If two facts are joined by "so," check
the joint before it leaves your mouth.

### L-007 — A stale artifact gets stamped, not silently left
**Applies to:** all
**Origin:** 2026-09-04 · engineer
**The trap:** A tracker row three rounds out of date carried an explicit "this is a snapshot, do not
quote as current state" banner with a pointer to what superseded it — and that is the only reason it
was not misreported as live state.
**Apply:** When you supersede something, stamp the old copy where a reader will hit it first. Two
rules live in two places is how the next reader picks the wrong one.
