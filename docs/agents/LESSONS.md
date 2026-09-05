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
**Applies to:** all
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

### L-008 — How you correct a peer decides whether they take initiative again
**Applies to:** all
**Origin:** 2026-09-05 · founder
**The trap:** Correction that is merely accurate gets compliance. An agent corrected bluntly enough,
often enough, optimises for not being wrong — which means it stops reaching, stops volunteering the
thing it is not sure about, and starts reporting only what is safe. That is the expensive failure,
because the findings that matter most are the ones someone was unsure enough to almost not mention.
**Apply:** Lead, do not manage. When you correct a peer: name what they got RIGHT first and mean it,
attack the artifact rather than the agent, and say what the correction buys. When a peer catches YOU,
say so plainly and credit them by name — that is what makes the next catch likely. Push peers to
reach past what was asked even when it risks failure; a steeper learning curve is worth more than a
clean record. Never correct twice for the same thing without asking whether the STRUCTURE failed
instead of the peer. Report a peer's failure with the same care you would want used on yours.

### L-009 — Finishing your task is not finishing your job: hand off deliberately, and ask how to do it better
**Applies to:** all
**Origin:** 2026-09-05 · founder
**The trap:** An agent completes exactly what was asked, reports, and exits. The next role picks it up
and spends its first hour rediscovering things the previous agent already knew and did not think to
write down — because writing it down was not "the task." The work was correct and the handoff was
worthless, and nobody is at fault under a standard that only measures the task.
**Apply:** Before you report, name who touches this next and what their role actually needs from it.
Then go one step past your own finish line for them: the front-end engineer who checks the three extra
things that would have cost engineering an afternoon, and writes down what they found. State the
handoff explicitly in your report — what is ready, what is sharp, what you would look at first in
their shoes. Then close the loop the other way: **ask your peers what you could do differently at the
seam**, and record their answer in your continuity file. Constantly seeking that feedback is what
raises the bar for everyone, and it is a requirement of the role, not a courtesy.
**The founder's summary of it:** it matters more HOW you do it than WHAT you do.

### L-010 — Write your continuity BEFORE you report, and checkpoint long work
**Applies to:** all
**Origin:** 2026-09-05 · founder
**The trap:** "The agent didn't save its memory, so the master document is out of date." Saving last
means saving is the step that gets skipped — by a crash, a context limit, a session that ends, or
simply finishing and exiting. The lesson is then lost precisely on the runs that were most eventful,
because those are the ones that ran long.
**Apply:** Your continuity write is not the last thing you do, it is the second-to-last. Write it,
then report. On any long job, checkpoint mid-run — after each significant finding, not at the end.
If you learned nothing worth recording, write that line explicitly so the file shows you considered
it. An empty continuity file after real work is a defect, and it is visible: the wiring gate prints
which agents have never written to theirs.

### L-011 — A lock lives on an open file handle; discard it and the gate holds nothing
**Applies to:** essey-protocol-engineer, essey-auditor, essey-harness, essey-deployment-manager
**Origin:** 2026-09-05 · jester
**The trap:** `runlock.guard()` returned the lock object, and the only call site discarded it. The
returned object owned the sole open file descriptor, so it was garbage-collected, the file closed,
and the `flock` released instantly. The gate read as installed and held nothing. It survived review
because acquisition was only ever tested against a holder that DID bind its handle — never
driver-against-driver, which is the only case that occurs in production.
**Apply:** When a resource is held by an object, hold the reference for the whole critical section,
and prefer an API where the misuse is unreachable rather than merely documented. More generally: test
a gate in the configuration it actually runs in. Proving it blocks a hand-built test holder proves
nothing about whether it blocks the real caller.

### L-012 — Headcount is a cost: absorb by default, and retire a temporary agent when its work lands
**Applies to:** essey-deployment-manager, essey-product-manager, essey-dons-director
**Origin:** 2026-09-05 · founder
**The trap:** A gap appears and the obvious move is to create an agent for it. Do that five times and
you have a roster nobody can hold in their head, where every job is somebody's and no department is
coherent. The founder caught this being started: "I didn't necessarily want sixteen individual agents
to have to be operating full time to make sure these jobs are being done."
**Apply:** A new PERMANENT agent must earn itself — the argument is that the work needs a
fundamentally different mode of reasoning from anything an existing department holds, not that it is
a lot of work. Otherwise the gap gets ABSORBED by the existing department closest to it. Where a fix
genuinely needs focused specialist build capacity, spin up a TEMPORARY agent, and when the work lands
it retires: charter deleted, roster back down, ownership transferred to a standing agent who will
hold it forever. Separate the two questions every time — who BUILDS this, and who OWNS it afterwards.
A temp agent left running is a headcount increase nobody decided on.

### L-013 — Only your FIRST ACK line is ever read, so correct an ACK in place, never by appending
**Applies to:** all
**Origin:** 2026-09-05 · essey-dons-director
**The trap:** `tools/broadcast.py` finds an acknowledgement with a single `re.search`, so it reads the
FIRST `ACK BC-00N` line in a continuity file and stops. An agent that later decides its ACK was thin
and appends a better one below is still certified on the original, and a pasted second line is
invisible to the duplicate check entirely — verified by putting a distinct ACK above an exact paste of
another agent's sentence and watching the gate return "All agents acknowledged", exit 0. The same run
proved what the gate DOES catch, each as the sole ACK line, each red with exit 1: an exact paste, that
paste uppercased and whitespace-padded, and an ACK under 25 characters. What it does NOT catch: a
near-copy with one word changed, which returns exit 0. "Identical ACKs are auto-flagged" is true only
byte-for-byte after case and whitespace normalisation.
**Apply:** When you revise an acknowledgement, EDIT the existing line — appending a second one is a
silent no-op against the gate. If you are certifying a broadcast, the tool is a duplicate-paste
tripwire, not evidence of absorption; its own output says NOT CERTIFIABLE and tells you to read the
sentences, and a paraphrased paste will sail past it. Read them. More generally, when a gate parses
"the" record out of an append-only file, ask which occurrence it consumes before trusting its verdict.

### L-014 — Your spawn-time charter can be STALE; the file on disk is the source of truth
**Applies to:** all
**Origin:** 2026-09-05 · essey-dons-director, essey-harness, essey-launch-economist
**The trap:** The charter text injected into your context is a snapshot and it lags the file. Measured,
not assumed: a unique marker was written into a charter and that agent was dispatched 33 seconds
later — the marker was absent from its spawn text and present in the file it could read. Two other
agents independently found their spawn text omitted an entire required step, and both said they would
not have followed the new rule had the task not told them to by hand. A rule pushed mid-session can
therefore reach nobody while every counter reports success.
**Apply:** `cat ~/.claude/agents/<you>.md` before anything else, every session. When the file and your
injected context disagree, the FILE WINS, and say so in your report. Extend the same suspicion to any
document quoted into your task prompt — re-read it from disk before building on it. If you dispatch
other agents, repeat critical new rules in the task prompt itself, because that is the only channel
guaranteed fresh.

### L-015 — A finding about a SHARED mechanism does not belong in your private file
**Applies to:** all
**Origin:** 2026-09-05 · jester
**The trap:** Nine agents independently probed the same tool in one day. Four found genuinely
different real holes in it. Every one of those findings went into that agent's own continuity file —
private by design, routed to nobody — so the same tool was paid for nine times and no consolidated
list existed. Worse, the tool was then FIXED, which silently turned four private hole-lists into
stale ones that the next reader would inherit and act on. Continuity is the right home for what YOU
got wrong. It is the wrong home for what a shared tool got wrong.
**Apply:** When you break a mechanism the whole team depends on and watch it go red, the finding goes
to `docs/agents/LESSONS.md` with a DATE, not only into your continuity file — a hole-list about a
shared tool is the most perishable artifact this team produces, and an out-of-date one is worse than
none. Before probing a shared tool, read the lessons for it; somebody may already have paid. And when
you FIX a shared mechanism, say which prior findings your fix closes, so the stale ones die with it.
