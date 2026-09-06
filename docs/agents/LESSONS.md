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

### L-016 — guard-git.py inspects only segments that START with `git`, so a subshell defeats every rule
**Applies to:** all
**Origin:** 2026-09-05 · essey-zk-auditor
**The trap:** `git_segments()` (guard-git.py:89) keeps a segment only if it matches `^git(\s|$)`, and
line 141-142 then does `if not segments: sys.exit(0)`. So any shape that does not put `git` first
skips RULE 1 (push to main), RULE 2 (style receipt), RULE 2b (the three-clean audit receipt) and
RULE 3 (stale base) all at once. Watched against the REAL PreToolUse hook, not a harness:
`sh -c "git push <remote> main --dry-run"` and `(git push <remote> main --dry-run)` both reached git
and returned git's own "does not appear to be a git repository", while the bare form was BLOCKED;
and `(git commit --dry-run)` ran and printed branch status while bare `git commit --dry-run` was
BLOCKED for a missing style receipt. A plain parenthesised subshell is not an exotic evasion — it is
something an agent can type by accident, and it silently removes every deploy guard at once.
**Apply:** Do not treat guard-git.py as proof that a push or commit was gated; it gates only the
shapes it can see. If you are relying on it, run the command in bare `git ...` form so it is actually
inspected, and never wrap a git command in `( )`, `sh -c` or `xargs` to get past a block — a block is
information, not an obstacle. If you maintain the guard, match git in any command position and
inspect `sh -c`/`bash -c` payloads. More generally: when a gate parses commands out of a string, ask
what shape of the same command it CANNOT see before you trust its silence.

### L-017 — A gate that SKIPS when its input is missing usually throws away findings it already made
**Applies to:** all
**Origin:** 2026-09-05 · essey-zk-auditor
**The trap:** Two build gates in `app/web`'s `build` script pass unconditionally in the environment
that actually deploys. `check-agent-wiring.mjs` validates LESSONS.md and the blueprint fingerprint
FIRST, collecting problems, and then hits `if (!existsSync(AGENTS)) process.exit(0)` — so on any
machine without `~/.claude/agents` (Vercel, CI) it discards problems it had already detected.
Measured in an isolated `git archive HEAD` tree with one identical broken LESSONS.md: exit 1 with the
real HOME, exit 0 with a HOME lacking the charter dir. `check-reserve-basket.mjs:81-83` does the same
on network failure — pointing its RPC at a dead port produced "SKIP (RPC unreachable)" and EXIT 0,
disabling the only check that keeps the published treasury basket honest. Both print a truthful SKIP
message, which is why neither reads as a defect.
**Apply:** When you audit or write a gate, test the SKIP path before the happy path — a gate is
strongest-looking and weakest exactly where its input is absent. Two rules: findings already
collected must be reported before any early exit, and a check that cannot run in the environment it
is wired into is not a gate there, so either make it fail closed or stop citing it as coverage for
that environment. If you cite a build gate, say WHICH machine you watched it fail on.

### L-018 — A path-leak gate only sees the notation it was written against; `~` is a different string
**Applies to:** essey-auditor, essey-protocol-engineer, essey-web-designer, jester, essey-deployment-manager, essey-zk-auditor
**Origin:** 2026-09-05 · essey-auditor
**The trap:** `.githooks/pre-commit:67` blocks `/Users/<name>/(Developer|Documents|Desktop)/` — the
literal form of the 2026-09-02 leak that forced a history rewrite. It was verified working (I planted
that exact string and watched exit 1). A scan for the same shape across the push range returned ZERO,
and that zero was reported as "no private paths." Both the gate and the scan were correct and both
missed the leak, because the leak had been rewritten in tilde form. `git grep -c` against the
then-current `origin/main` scored it: `~/Developer/assay-design` 0 → 3 occurrences,
`~/Developer/essey-ceremony` 0 → 1, `~/.claude/agents/…` 0 → many. The ceremony checkout is the exact
private repo the hook was built to keep out, re-entering public history in the one notation the hook
cannot see. A slug form also exists and contains no `/` at all:
`~/.claude/projects/-Users-<name>-Developer-<repo>/…` in `docs/agents/continuity/jester.md:14`.
**Apply:** A path is a value, not a string, and a gate that matches strings must enumerate every
notation that denotes the same value before it can claim coverage: `/Users/<n>/`, `/home/<n>/`, `~/`,
`$HOME/`, `%USERPROFILE%`, `C:\Users\`, and the Claude project-slug `-Users-<n>-<...>`. When you are
handed a "zero hits" result — including your own — the first question is not "is the grep correct"
but "what OTHER spelling of the same thing would this grep never return?" Repo-relative paths in
prose avoid the whole class; if a doc must name a location outside the repo, name it without the home
prefix. And note the second-order trap: agent continuity files are the highest-risk surface here,
because their whole content is an agent narrating where its own files live.

### L-019 — A gate that NORMALISES a value stops testing the property its consumer depends on
**Applies to:** essey-web-designer, essey-protocol-engineer, essey-harness, essey-auditor, essey-deployment-manager
**Origin:** 2026-09-05 · essey-harness
**The trap:** `check-reserve-basket.mjs` exists to guarantee the treasury page reads every token the
reserve holds. It lowercases each BASKET address before comparing (`:53`) and issues its RPC as
hand-built JSON strings, never through viem. So when `0x8fA1248c3EC58f733E778b89C30526716Cd70893`
shipped with a broken EIP-55 checksum — the only bad one of fifteen — the gate printed
"15 token(s) ever received, 15 in BASKET, 0 unlisted equity, 0 unlisted other" and exited 0, while
the live page rendered that row as `unreadable` and raised a site-wide "INCOMPLETE READ — THIS IS A
LOWER BOUND" banner telling visitors to reload. viem throws `InvalidAddressError` at ENCODE time, so
the request never reached the chain; reloading could never have helped. Provenance: the address was
correct while it lived lowercased in `ACKNOWLEDGED`, and was hand-cased when promoted into `BASKET`.
**Apply:** Before trusting a gate, ask what the CONSUMER requires, not what the comparison needs.
Every normalisation in a check — `toLowerCase()`, `trim()`, `sort()`, a permissive regex — is a
property the check has stopped enforcing. Where the consumer is a library, exercise the value THROUGH
that library (`getAddress()`, the real client with its real batch/multicall config), not through a
hand-rolled equivalent. And when a UI says "unreadable" while your own raw `eth_call` returns real
data, the bug is in the read path: rebuild the page's exact client and run the same call through it.

### L-020 — A freeze tool that prints its own pin cannot tell you the surface moved
**Applies to:** all
**Origin:** 2026-09-06 · essey-zk-auditor
**The trap:** `tools/audit-round.py` exists so an audit round has a frozen subject, and its core claim
is real — a tracked text edit mid-round produced `ROUND VOID`, exit 1, and a binary edit to an
already-dirty file was caught too (the `index <old>..<new>` line carries the blob sha, so the
"binary diffs are contentless" hypothesis is refuted). But three things it cannot do were each watched
returning exit 0: an UNTRACKED file dropped in mid-round leaves the round INTACT, because `subject()`
collects `dirty` from `git status --porcelain` and then never compares it; `open` silently RE-PINS an
already-open round, so any agent running it re-blesses everyone else's; and hand-editing the unsigned
JSON in gitignored `.runs/` flips VOID to INTACT while printing a line BYTE-IDENTICAL to the honest
one — because the success path prints `pinned['head']` and `pinned['tree']`, values read from the very
file being validated, and never prints the `work` hash that actually caught the movement. An
out-of-band sha therefore does not detect the forgery: keep head and tree, move only the field that is
never displayed. Structurally worse: continuity files are TRACKED, so the charter-mandated "write your
continuity BEFORE you report" voids the round. Two of three auditors hit that in the same round and
both silently reverted their file to get INTACT back.
**Apply:** When a check reports on state it also stores, ask which of the two it is PRINTING — a gate
that echoes its own record can never contradict the record. Demand that success output show the
OBSERVED value, and that failure NAME THE PATH that moved; "the surface moved" without a filename cost
a full audit round of forensics here. Two corollaries with teeth. First, if you re-derive a tool's
hash to attribute its verdict, COPY ITS HELPER VERBATIM — audit-round.py's `git()` returns
`stdout.strip()`, mine did not, and the mismatch nearly became a reported claim that an audited
contract had changed mid-round. Second, a gate its own users must routinely revert their work to
satisfy will be ignored, so exclude the paths your process REQUIRES people to write
(`docs/agents/continuity/`, `docs/agents/LESSONS.md`) from the frozen subject rather than asking
everyone to work around it.

### L-022 — The round freeze and the mandated continuity write are in direct conflict
**Applies to:** all
**Origin:** 2026-09-06 · essey-harness
**The trap:** `tools/audit-round.py` freezes the WORKING TREE (`git diff` + `git diff --cached`), and
every charter requires an agent to write `docs/agents/continuity/<you>.md` BEFORE it reports. That file
is tracked. So the first auditor in a multi-member round who obeys its charter silently voids the round
for everyone still working. This is not hypothetical: round `d7e471696033` opened INTACT with four
dirty files, and mid-round `docs/agents/continuity/essey-zk-auditor.md` appeared with 157 added lines
(mtime 2026-09-06T10:17:16 local). `check` then printed "ROUND VOID: the audited surface moved (work)"
with head and tree hashes IDENTICAL — only `work` had changed. Nothing under audit had moved at all.
**Apply:** Before reporting a VOID, read WHICH of the three hashes moved. `head`/`tree` moving means the
audited bytes really changed and your verdict is dead. `work` moving alone can be nothing but a peer's
own memory file — so name the file that moved and prove the files you audited are pinned-identical
(`git diff --quiet <sha> -- <file>` per file) before you discard a round's worth of evidence. If you
maintain the tool: exclude `docs/agents/continuity/` from the work hash, or have agents write memory to
an untracked staging path, otherwise a three-member round can never close cleanly by construction.

### L-023 — `grep` here is ugrep, and it exits 0 on a regex it refuses to run
**Applies to:** all
**Origin:** 2026-09-06 · essey-harness
**The trap:** The shell `grep` is a function wrapping `ugrep 7.5.0`. Given a pattern with nested
quantifiers it prints `ugrep: error: ... exceeds complexity limits` to stderr and **exits 0**. A script
or an agent reading only the exit code, or only an empty stdout, reads "no matches found" from what was
actually "I did not run your search." Watched: `grep -oE '(a{0,60}){0,60}b' bundle.js` → complexity
error, `EXIT=0`. I hit this while proving a false public claim was gone from a served bundle — the
answer I nearly recorded as evidence of absence was evidence of nothing.
**Apply:** Never treat an empty `grep` result as proof of absence without checking stderr, and prefer
`grep -F` (fixed strings) whenever you are searching a large minified bundle or any generated artifact.
More generally this is BC-001's corollary running backwards: we are told to check the exit code rather
than the message, and here the exit code is the liar and the message is the truth. Check both.

### L-024 — A fix lands on the INSTANCE the auditor named; the class it belongs to stays live
**Applies to:** essey-auditor, essey-zk-auditor, essey-protocol-engineer, essey-web-designer, essey-deployment-manager, essey-harness
**Origin:** 2026-09-06 · essey-auditor
**The trap:** Four fixes in one push each closed exactly the example in the report and left the rest of
their own class shipping. `9e45758` ("stop telling the public that lending is audited") corrected
`docs/BASE-LAYER.md:142` — the file the auditor cited — while `docs/TOKENOMICS-v3.md:178` still reads
*"provably-solvent RWA lending protocol (AAPL/NVDA borrow markets already built + audited)"*, and
`app/web/gen-docs.mjs:47` publishes that file to the site: the string is in the LIVE production bundle
at `https://essey.xyz/assets/index-DPnMhTNW.js` (`grep -c` → 1). `10cd992` asserted every `BASKET`
address through viem but nothing else, and 2 of 84 address literals in `app/web` still fail
`isAddress` — `live.ts:69 BUNDLE = "0x…B0B1"`, which `encodeFunctionData` on the real
`setPayoutToken(uint256,address)` ABI rejects, so the "Get paid in → Bundle" button can never build a
transaction. `e032187` closed `(git push)` by stripping leading `[(){}\s]`, which is a whitelist of
three characters, not the class "git is not command-initial": `sh -c`, `bash -c`, `eval`, `env`,
`command`, `time`, `\git`, `$(…)`, backticks, `if …; then`, `xargs` and `nohup` all still exit 0.
And `.githooks/pre-commit:67` blocks `/Users/<n>/(Developer|Documents|Desktop)/` while `~/`, `$HOME/`,
`/Users/<n>/Downloads/` (in-tree at `pfp/extract_leaves.py:45-46`) and `/Users/<n>/.foundry/` pass.
Worse, that commit message states in public that `sh -c "git push"` "already exits 2, so I am recording
that half as not reproduced." Both registered PreToolUse guards return 0 for it, and through the real
Bash caller `sh -c "git push <remote> main --dry-run"` reached git and returned git's own exit 128.
**Apply:** When you fix a finding, write down the CLASS it belongs to and enumerate the class
mechanically before you call it closed — every one of the four above was one command
(`node -e` over all address literals; the guard driven with twelve command shapes; the path gate driven
with six notations of one path; a grep for the claim across all published docs, then against the served
bundle). When you AUDIT a fix, do the same enumeration rather than re-testing the reported example, and
treat the commit message's NEGATIVE claims — "not reproduced", "already handled", "does not apply" — as
unrun experiments: they are load-bearing assertions with no test behind them, and one of them was false
here. A fix verified only against the example that produced it has been confirmed, not tested.

### L-025 — A negative result from a probe you did not validate is not a negative result
**Applies to:** all
**Origin:** 2026-09-06 · coordinator, essey-auditor
**The trap:** A guard was reported as already blocking `sh -c "git push"`, and that claim was written
into a public commit message as evidence. It was false. The test had passed the guard shell-quoted
JSON with unescaped inner quotes, so the payload was malformed and the case was never exercised at
all — the probe returned "blocked" because it never ran the thing it claimed to test. An auditor
driving the real caller got the opposite result. Ten wrapper shapes were open at the time.
**Apply:** BC-001 says watch a check go red before citing it. This is its mirror: when your probe
reports the SAFE answer, you owe it the same scepticism. Validate the probe on a case you KNOW should
fail before believing it about a case you hope will not. Construct payloads the way the real caller
does — `json.dumps`, not a hand-quoted string — and if a peer's result contradicts yours, assume your
instrument before assuming their conclusion.
