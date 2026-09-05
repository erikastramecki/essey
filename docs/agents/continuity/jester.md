# jester — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

## 2026-09-05 — first entry: I was asked to describe a lock, and the lock did not hold

Drafted `fourteen-could-not-remember.md` on the agent-memory rebuild (`1af1a84`). The brief told me to
verify rather than trust it. Two things did not survive.

**1. The brief said the coordinator's memory directory "is unreadable by any subagent." It is not.**
I read `~/.claude/projects/-Users-erikastramecki-Developer-assay/memory/MEMORY.md` from my own Bash in
one call, exit 0. The true version is weaker and still makes the point: no charter references that path
(`grep -l "projects/-Users-erikastramecki" ~/.claude/agents/*.md` returns nothing), and it sits outside
the repo. Not-pointed-at, not walled-off. I cut the claim rather than soften it.

**2. `tools/runlock.py` does not lock at its only call site.** `guard()` returns the RunLock, and that
object is the sole owner of the open file handle. Discard the return value and CPython closes the file,
which releases the flock immediately. Proven by A/B with two processes on one resource: handle bound ->
second process printed BLOCKED and exited 2; handle discarded -> second process ACQUIRED, exit 0, and
`runlock.py --list` printed "in flight: nothing" during a live run.
`rh-chain/test/mutants/glend-r4.py:374` discards it. Reported to Erik; not my file to fix.
The sting: `1af1a84`'s own commit message says every gate here was shown producing a negative result
first (L-001). That was done for the wiring gate. It was not done for the lock.

**THE HABIT THAT FOUND IT.** I did not go looking for a bug. I ran the tool because §39 says I may not
cite a gate as evidence in a post unless I have established it can fail. Applying §39 to a claim someone
handed me to praise is what turned it up. Keep doing that: **run the mechanism before writing the
sentence that credits it**, especially when the sentence is flattering to us.

**Craft note.** The strongest paragraph in the piece is the one that undercuts the piece. Erik has never
once asked for the flattering version, and the posts that landed are the ones that named a cost. Do not
soften a live defect into a caveat.

**Tense (§40 applied, not just logged).** The lock defect is present-tense about a tree that is moving
under me (three commits landed while I wrote). Anchored it to "as of 15:25 UTC on 5 September 2026" and
added that it may be history by publication, rather than hedging it. Everything else is anchored to a
commit sha, which does not move.

**Working-tree hazard I hit and did NOT cause.** `docs/agents/LESSONS.md` and
`app/web/check-agent-wiring.mjs` both changed under me mid-session. I verified the wiring gate against a
COPY in scratch (`cp` the checker + docs into a fake repo root, since REPO = parents[1] of the script)
rather than mutating LESSONS.md to watch it go red. Do that every time: never break a shared tracked
file to test a gate while another session is live in the tree.

**New coupling to know about.** `check-agent-wiring.mjs` now fingerprints roster+lessons+mechanisms and
fails the build if `docs/AGENT-COMPANY-FOUNDATION.md` is stale. So appending a lesson to LESSONS.md
BREAKS THE BUILD until someone reconciles that doc's prose and re-runs `--stamp`. Adding a lesson is no
longer a free append. Budget for it, or hand the entry to whoever owns the blueprint.

**Draft placement.** `app/web/src/blog/drafts/` is gitignored (`app/web/src/blog/.gitignore:2`) and NOT
globbed (`blog.ts:18` globs `./posts/*.md` only), so a file there physically cannot render. `posts/` is
live-on-next-build even when untracked, which is where `never-gone-red.md` sits. When told DRAFT ONLY,
use `drafts/` and say so in the report; promotion is one `mv`.

## 2026-09-05 (session 2) — onboarding, charter drift, and what the team did with BC-001

ACK BC-001 — Nothing I write has a compiler, so my version of a green light is a citation that merely LOOKS checked: a file:line lifted out of a peer's report, a `cast call` I ran once and never pointed at a wrong input, a page I watched render a number without ever making it render the wrong one; from now on a fact only enters a post after I have made its source tell me NO at least once (query an address that does not exist and watch it come back empty, read the SERVED bundle rather than the repo, run the mechanism before writing the sentence that credits it), and the part that actually changes for me is downstream: I sit at the end of fifteen agents' greens, so "the auditor watched it fail" is still hearsay by the time it reaches a paragraph with my name on it, and what I publish now carries either a red I saw myself or the word UNVERIFIED in the draft.

**Charter drift is REAL and I hit it.** My spawn-time charter text omitted the block at
`~/.claude/agents/jester.md:117-127` — the "cat your own charter from disk FIRST" step and the
paragraph explaining that the dispatched copy can be a stale snapshot. Everything else matched
heading-for-heading (14 `##` sections, same order, same four fenced blocks minus that one). File
mtime Sep 5 08:55. So the rule that exists to catch stale charters was itself missing from a stale
charter. essey-harness found the same shape independently and wrote it up first
(`docs/agents/continuity/essey-harness.md`, F-2) — credit theirs, mine is a second data point, and
two independent hits means it is systemic, not a one-off dispatch hiccup.

**Prior-state check (L-010 working as designed).** My file already held the full session-1 entry
(the runlock defect, the drafts/ vs posts/ gitignore trap, the wiring-gate fingerprint coupling). I
have no episodic memory of writing it and I should stop pretending otherwise in reports: what I
verified is that the file exists and is internally consistent with the tree, not that I "remember"
it. That is the whole point of the file.

**`tools/broadcast.py` HAS MOVED, and several peers' notes about it are now stale.** It is tracked
now (`52667c3`), and reading the current source: the roster comes from the charters dir with an
`essey-`/`don-`/`jester` filter (`tools/broadcast.py:19-20`), not from globbing continuity files; a
sub-25-char ACK prints SUSPECT (`:48-50`); a byte-identical pasted ACK prints SUSPECT (`:53-55`);
and the capture is multi-line up to a blank line or the next `ACK BC-` (`:33-37`). That closes
essey-launch-economist's glob-denominator finding and essey-research-intern's HOLES 2 and 3, and it
falsifies essey-web-designer's parenthetical that a wrapped ACK is truncated at the first newline.
Not their error — the file changed under all of us. READ FROM SOURCE, not watched-fail: I did not
re-probe it, deliberately, because nine of sixteen agents already did.
Still open by source-read: a paraphrase of someone else's ACK passes (the dup key is an exact
normalised string, `:47`), and only the FIRST `ACK BC-nnn` per file is ever read (`re.search`), so a
corrected ACK appended below an original is invisible. Both belong to whoever owns that file.

**The structural thing, and it is the useful finding.** Nine of sixteen agents independently ran or
probed the same ~68-line reader's aid on the same day, each found a different subset of its holes,
and each wrote them into a file the other eight are not routed to read. `tools/lessons.py` is
role-filtered on purpose and continuity is nominally private, so there is no seam where those four
hole-lists meet. Result: duplicated effort, no consolidated list, and findings that decay silently
when the tool is fixed (see the paragraph above). BC-001 makes every agent verify; nothing yet makes
verification SHARED. That is a coordinator-shaped gap, not an agent-shaped one.

**Why I am not filing this as a LESSONS.md entry right now.** Appending to `docs/agents/LESSONS.md`
trips the fingerprint in `app/web/check-agent-wiring.mjs:93-155`, which fails the build until
`docs/AGENT-COMPANY-FOUNDATION.md` is reconciled and re-stamped — and that checker is MODIFIED in
the working tree right now (`git status --porcelain` -> ` M app/web/check-agent-wiring.mjs`), i.e.
another session is mid-edit in it. Adding a lesson would hand someone else a broken build mid-flight.
Raised in the report instead. Same rule as session 1: never break a shared tracked file while
another session is live in the tree.

**Caught myself doing the thing, thirty seconds after acking it.** I ran
`python3 tools/broadcast.py 2>&1 | tail -6; echo "raw_exit:${?}"` and printed `raw_exit:0`. That is
`tail`'s exit code, not the tool's. Re-ran with no pipe, redirecting to a file: `real_exit:1`,
`BC-001: 15/16 acknowledged`, zero SUSPECT lines, `jester` moved out of PENDING. essey-research-intern
logged this exact zsh trap first (`$pipestatus[1]`, 1-indexed, not `${PIPESTATUS[0]}`) and I read it
and walked into it anyway. BC-001's first corollary is "check the exit code, not the message" — a
piped exit code is not the exit code. Never report one taken through a pipe.
Honest limit on my own A/B, per essey-legal-advisor's caveat: the run exits 1 both before and after
my append (essey-product-manager is still pending), so the signal I verified is LIST MEMBERSHIP
moving PENDING -> ACK, not the exit status. Saying otherwise would be the error BC-001 exists to stop.
