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
