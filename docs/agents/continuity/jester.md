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

## 2026-09-07 — the cadence gate reported "current" while five days went unlogged

**THE FINDING, and it is mine and it is about my own instrument.** `app/web/check-blog-cadence.mjs`
compares the newest date in `docs/JESTER-BUILD-LOG.md` against the newest `date:` in
`app/web/src/blog/posts/`. It has no notion of shipped work. So when the LOG stops, `gapDays <= 0` and
it prints `current` and exits 0 forever. Measured in an isolated fake root (copy of the gate + one
post + a fixture log), all three states:
  A. log frozen 2026-08-01, post 2026-09-05 -> `blog-cadence: current`, **exit 0**  <- the hole
  B. log 2026-09-20, post 2026-09-05        -> BACKLOG + `FAIL — the gap is 15 days`, exit 1
  C. log absent                              -> `FAIL — ... is missing`, exit 1
Case C is the one `88a2469` built (it also TRACKED the log — `git check-ignore` now exits 1, closing
essey-harness's L-030). Case A is what it did to me today: real run against the real tree printed
`current (newest post 2026-09-05 "fourteen-could-not-remember", log 2026-09-05)` while 09-05-evening
through 09-06 shipped ~20 commits and nothing was logged.
**The gate's single input is the thing a stalled process stops producing.** It watches the right
property (log-ahead-of-blog is the literal definition of a backlog, and that reasoning is still
correct) from the wrong place. Same family as everything in the two audit rounds: trigger, not
inspection. §37 needs an addendum and I wrote it as §42.

**BC-001 discipline this session — seven probes, five reds I watched myself.** All PreToolUse guards
driven with `json.dumps` payloads (L-025), never shell-quoted:
- `guard-deploy.py` current: dirty app/web -> exit 2 for BOTH `bash app/deploy.sh --web` and
  `vercel --prod`; clean tree -> exit 0 for both; `echo hello` -> 0.
- `guard-deploy.py` PRE-FIX (reconstructed in scratch by reverting only the DEPLOY_SCRIPTS clause):
  same dirty tree, `bash app/deploy.sh --web` -> **exit 0**, `vercel --prod` -> exit 2. That is the
  TRIGGER defect, measured, not relayed.
- `guard-git.py` backup `.bak-20260906` (the pre-fix branch whitelist at its `:150`): all six
  push-to-main shapes exit 2, but FIVE carry "0 of 3 clean audit rounds", not the production message.
  Re-run with `GATE_AUDIT_OK=1 GATE_STALE_OK=1` prefixed (the only configuration where RULE 1 is
  observable): `main:main`, `refs/heads/main`, `+main`, bare `git push`, `--all` all -> **exit 0**.
  Current guard, same mask lifted: 9 of 9 shapes exit 2 with "BLOCKED: push to main/production."
  **A matrix that only reads exit codes returns all-green and teaches you nothing.** The message is
  what tells you WHICH rule fired. Read it.
- `check-agent-wiring.mjs` on an isolated copy (needs tools/*.py + AGENT-HIERARCHY.md copied too, or
  the `mech` filter changes the fingerprint and the baseline fails for the wrong reason): clean copy
  exit 0; append one properly-tagged lesson -> exit 1, blueprint STALE. The mandated write breaks it.
- `check-reserve-basket.mjs` on an isolated copy with a node_modules symlink: baseline
  "15 token(s) ever received, 15 in BASKET", exit 0; replant the exact miscased Supercycle address
  that shipped in `5c42f14` -> exit 1, naming the address and the correction. The checksum arm sits
  BEFORE the network call, so it binds offline too (L-017 done right, worth noting as a good example
  rather than a trap).
- Served-bundle probe with BOTH controls: positive "treasury" -> 42 hits exit 0, negative
  "zzz_jester_negative_control_zzz" -> 0 hits **exit 1**. Only then did I believe "Reliable floor"
  (1 hit) and "no equity holding has a live mark" (1 hit) mean the treasury fix is live.

**COULD NOT REPRODUCE, and I am not publishing it: L-023's ugrep exit-0.** essey-harness recorded
`grep -oE '(a{0,60}){0,60}b' bundle.js` -> complexity error, EXIT=0. In my hands that exact pattern
does not error at all, and the pattern that DOES error
(`((a{0,60}){0,60}){0,60}b`) exits **2**, not 0. The only exit 0 I could produce was through a pipe
(`... | head -1` -> 0), which is the already-known zsh pipe trap, a different defect. Their core
advice (prefer `grep -F`, check stderr) is right and I followed it all session. The exit-code half
does not reproduce here. Told them; not filed as a correction to the lesson because the difference may
be the haystack, and I would rather they re-measure than have me overwrite their record from one shell.

**SEAM I HIT AND SHOULD RAISE, not swallow.** `guard-deploy.py`'s served scope is
`["app/web", "docs", ":(exclude)docs/agents"]`. `docs/JESTER-BUILD-LOG.md` is now TRACKED and is NOT
under `docs/agents`, and `gen-docs.mjs`'s PICK list (`:37-56`) does not include it, so it is never
published. So writing my own mandated log dirties the deploy scope and blocks the blog-only deploy
§33 grants me, for a file no reader can ever see. Exact same shape as the `docs/agents` exclusion
`6522889` already added. One-token fix; not mine to make.

**Link discipline (§19).** Verified the repo is PUBLIC (github.com/erikastramecki/essey resolves) and
opened all five commit URLs I embed, checking the subject line matches what I claim. Do this every
time; the previous post cut a link because blockscout sat behind a challenge and a bogus hash returned
the same 200.

**A thing I nearly did not check, and it is the one that would hurt most.**
`docs/JESTER-PERSONA-BIBLE.md` is GITIGNORED (`.gitignore:57`; `git ls-files --error-unmatch` errors
on it). My character file, the file that IS my continuity across every session, exists on exactly one
disk with no version history. That is L-030's shape one level up: `88a2469` tracked the build log for
precisely this reason and left the bible behind. Forty-two sections of accumulated voice, rulings and
lore, one `rm` from gone. Raised to Erik; his call, because it contains internal day-records (§26
COMMS-HOLD material) and going public with it is a disclosure decision, not a hygiene one. A private
mirror outside the repo would solve it without that question.

**A judgement call I made and want on the record.** My cadence finding generalises across roles, so
L-015 says it belongs in `docs/agents/LESSONS.md`, not only here. I did NOT write it there. Appending
one lesson breaks the build until `docs/AGENT-COMPANY-FOUNDATION.md` is reconciled by hand and
re-stamped, which I proved again this session (clean copy exit 0, one lesson appended exit 1), and the
founder asked for a clean tree while he works elsewhere. Handing someone a red build to make a point
about gates costing their users is the exact failure the lesson describes. So I wrote the entry text
into my report for whoever owns the blueprint. Second session running that I have declined this for
the same structural reason: **that is the signal that the STRUCTURE is wrong, not my judgement.** The
lessons file needs to be appendable without a second manual reconciliation, or lessons will keep not
being written by the agents most likely to have one.

**HANDOFF.** Next hands: Erik (word to publish), then essey-web-designer / essey-deployment-manager
for the blog-only deploy, then essey-social for the X block.
- READY: `app/web/src/blog/drafts/gates-watching-from-the-wrong-place.md` + `.x.md`. Front-matter
  parsed with the build's own regex; title/summary present, date `2026-09-07T12:40:00` parses and
  sorts newest. Ten tweets, all under 280, zero em-dashes outside fenced tool output.
- ONE `mv` FROM LIVE: `drafts/` is gitignored and not globbed, so promotion is
  `mv app/web/src/blog/drafts/gates-watching-from-the-wrong-place.md app/web/src/blog/posts/`.
- SHARP: the date stamp is 12:40 UTC on 09-07. If it publishes later, restamp it to the real publish
  moment (§32) or the "this morning" in the cadence section drifts.
- SHARP: `docs/JESTER-BUILD-LOG.md` is dirty and it is under `docs/`, so `guard-deploy` blocks the
  deploy until it is committed. Watched: the REAL hook returned
  "BLOCKED: production deploy with 1 uncommitted change(s) under app/web or docs" on my own probe
  call. Commit the log first, then deploy. Do not reach for GATE_DIRTY_OK=1; it switches off the
  app/web arm too.
- WHAT I WOULD LOOK AT FIRST in their shoes: whether the OG card renders, since the title is long
  (60 chars) and I could not verify `/og/gates-watching-from-the-wrong-place.png` without a build.
- ASKED AT THE SEAM (record answers next session): for the designer, whether a 2,350-word post with
  five fenced code blocks reads on a phone or wants a pull-quote treatment; for the deployment
  manager, whether the build-log-blocks-deploy seam is worth one token in `guard-deploy`'s exclude
  list or whether they would rather I always commit the log first.

## 2026-09-10 — the whole supply burned, and five live posts went false the same minute

CHECKPOINT written mid-session (L-010), before the log and the draft.

**What I verified myself, all against `https://rpc.mainnet.chain.robinhood.com`, chain 4663, at head
block 59379932 (ts 1789040987 = 2026-09-10 11:49:47 UTC):**
- `$ESSEY.totalSupply()` = **0**. `balanceOf(ops 0x93e6…4B9E)` = 0. `balanceOf(0xdEaD)` = **0**, which
  means `_remove()` took the real `burn()` branch (`EsseyReserve.sol:114-120`), not the strand-at-dead
  fallback. Supply reduction is genuine, not a transfer to a hole.
- `receiptCount()` = 1. `receipts(0)` = (`0x93e6e42CcC676614FB3635b0983d60F35dDE4B9E`,
  8888888888000000000000000000) — the receipt is for the ENTIRE `claimBase`, which reads
  8888888888000000000000000000. `circulatingSupply()` = 0. `EXIT_FEE_BPS()` = 500.
- `claimed(0, token)` = **true for all 15** basket tokens in `app/web/src/reserve.ts:44-60`.
- **The token's entire history is THREE Transfer events.** `eth_getLogs` from block 0:
  49634440 mint `0x0`→ops; 58931401 ops→reserve; 58931401 reserve→`0x0`. All three for the full
  8,888,888,888. That three-line ledger is the spine of the post and it needs no prose to carry it.
- redeem tx `0x4df5445e…f4e4`, block 58931401, ts 1788995699 = 2026-09-09 23:14:59 UTC, status 1,
  gasUsed 115,297. claim tx `0xdca0a6d2…e2cb`, block 58931577, ts 1788995717 = 23:15:17 UTC,
  status 1, gasUsed 1,513,567, **all 15 legs paid in one `claimMany`**, 41 logs.
- `0xfb8f41b2` = `cast sig 'ERC20InsufficientAllowance(address,uint256,uint256)'`. Confirmed, not taken
  from the commit message.

**THE BRIEF WAS WRONG IN TWO PLACES AND BOTH MATTER. Neither is the briefer's fault — the chain moved.**
1. **"the reserve retains 5.00% of AMZN, SPY and FLR."** AMZN and FLR read **5.000000%** right now
   (post ÷ (post+paid), to six decimals). **SPY reads 20.142733%**, because SPY is the ONE basket token
   that received a further deposit AFTER the claim: 6,247,648,429,307,173 at block 59152096 from
   `0xe2f08818…20cc3` (291 bytes of code, referenced nowhere in the repo). Back that deposit out and SPY
   was exactly 5.000000% at the claim too. I ran the same `eth_getLogs` (topics `[Transfer, null, reserve]`,
   fromBlock 0x3833979) over all 15 tokens: SPY is the only one with any inbound since. `549e177`'s own
   commit message carries the SPY figure, so it was true when written and is stale now.
   **So all 15 retained exactly 5%, and one of the three the brief named no longer reads that way.**
2. **"the stocks are in his wallet."** Not now. Ops holds 0 AMZN and 0 NVDA. The full claimed AMZN
   (16,065,456,126,994,822, byte-for-byte the `Claimed` amount) left ops at block 58937739 for
   `0x36dc95f1…02bc2`, a 6,752-byte contract with no `owner()`, `symbol()` or `essey()` and no mention
   anywhere in the repo. I stopped tracing there on purpose: that is the unannounced-relaunch direction
   and it is not mine to map. **The post says the receipt's legs were pulled and paid to the redeemer,
   which is what the 15 `Claimed` events prove, and says nothing about where anything sits now.**

**THE FINDING I NEARLY DID NOT GO LOOKING FOR, and it is the most urgent thing here.**
The burn falsified FIVE sentences that are LIVE on essey.xyz this minute. Verified SERVED (L-004), not
committed — bundle `/assets/index-BnhyDNnu.js`, 4,559,908 bytes, with both controls run first:
positive `treasury` 42 hits exit 0, negative `zzz_jester_negative_control_zzz` 0 hits **exit 1**, so the
probe can go red. Then: `8,888,888,888` **11 hits**; `You can read that balance yourself` 1;
`still sit in the treasury wallet` 1; `Exactly one transfer event exists` 1.
- `only-real-essey-contract.md:18` — "all 8,888,888,888 of them, currently sits in one treasury wallet
  … You can read that balance yourself." A reader who obeys that sentence reads **0** and concludes we
  were robbed or lying. This is the anti-scam post. It is the worst possible one to be wrong.
- `only-real-essey-contract.md:77` — "All 8,888,888,888 tokens still sit in the treasury wallet."
- `reserve-audit.md:48` — "Exactly one transfer event exists on the token in its entire history."
  There are three, and I have all three.
- `front-door-two-sided.md:28` — "The fixed supply, 8,888,888,888 tokens, minted once."
- `base-layer-live.md:14` — present-tense "is minted to the treasury wallet."
Plus `app/web/src/docs.generated.ts` carries the same fixed-supply framing into /docs.
**And the bind, which is why I did not touch any of them:** every correction discloses the burn, and the
burn is under a disclosure hold. So the fix is gated on the same decision as the post. I did not silently
leave it either — it is the first thing in my report. §38's rule, one level up: a correction I cannot
publish is worth zero to the reader, and a correction I am not ALLOWED to publish is a founder decision,
not a backlog item.

**BC-001, and I watched this one go red the useful way.** §19 makes me open every link. The check I have
been using for explorer links is worthless: `curl -o /dev/null -w %{http_code}` on the real redeem tx
returned `http=200 size=89908`, and on `0xdeadbeef…deadbeef` returned `http=200 size=89908` — the same
status and the SAME BYTE COUNT. Blockscout is an SPA, so the shell is identical for a tx that does not
exist. My own session-1 note said a bogus hash returns 200; I now have the size equality too, which kills
the last version of that check that looked usable. Any explorer link I ship is grounded on my own
`cast receipt` / `eth_getLogs`, never on the fetch.
