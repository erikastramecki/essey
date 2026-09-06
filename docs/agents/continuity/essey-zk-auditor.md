# essey-zk-auditor — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

## 2026-09-05 — onboarding round (no audit performed)

Read: `~/.claude/agents/essey-zk-auditor.md` (full, new charter), `docs/agents/BROADCASTS.md`,
`python3 tools/lessons.py --role essey-zk-auditor` (6 lessons: L-001, L-006, L-007, L-008, L-009,
L-010). This file was empty before this entry.

ACK BC-001 — I do not get to call a circuit "sound" because an adversarial witness was rejected; I have to have watched that specific constraint go red for the specific forgery it claims to stop, confirmed the red came from the constraint system rather than a witness-generation assert, and watched the honest witness still verify after I put the circuit back — because an under-constrained circuit and a green test suite look identical from the outside, and a passing end-to-end proof is the loudest decoration in this codebase.

### The zk-specific trap inside BC-001 (my own refinement, apply every run)
A malicious-witness test going red is NOT automatically evidence the CONSTRAINT SYSTEM rejected it.
In circom/snarkjs the red can come from three different places, and only one of them is a real gate:
  1. witness generation aborting on an `assert()` / template-level JS check — outside the R1CS, so a
     real prover simply does not run it. This is a FAKE gate and it is the default thing you see.
  2. the constraint system failing (`snarkjs wtns check <r1cs> <wtns>`) — real.
  3. prove -> verify returning false, and best of all the DEPLOYED verifier contract reverting — real,
     and the only one in "the configuration it actually runs in" (BC-001 corollary two).
So the standard I hold myself to: a negative test cites which of these produced the red. If it is (1)
only, I have proven nothing about a malicious prover and must say so rather than count it.
Corollary: the honest witness must still verify after I revert the mutation, or I broke the circuit
rather than proved the constraint.
STATUS: UNVERIFIED — I have not yet run this against our circuits; it is a method, not a finding.

### What I own
- The circuits: shielded-pool join-split (charter names `rh-chain/circuits-nova/transaction*.circom`,
  a Tornado-Nova / Privacy-Pools fork) and the solvency/IVC circuit (`SolvencyVerifier`).
- The Groth16 verifiers (charter names `PoolVerifier2.sol`) and the three-way consistency:
  circuit <-> deployed zkey <-> deployed verifier contract. A circuit fix that was never re-ceremonied
  and re-deployed is not shipped, no matter how green the local test is.
- Trusted-setup ceremonies end to end (compile -> r1cs -> phase-1 -> phase-2 -> multi-party
  contributions -> public beacon -> regenerate verifier). Charter names `~/Developer/essey-ceremony/`.
- The standing toolchain, and GROWING it: circomspect (triage EVERY warning, real or benign, with the
  reason), adversarial witness tests, diff-against-audited-upstream (only our fork deltas), and
  constraint-completeness review (every public signal constrained, value conservation, nullifier
  deterministic + unique, Merkle root bound).
NOTE: the file paths above are quoted from the charter and are UNVERIFIED by me — I did not stat them
this session (onboarding was scoped to reads only). First real task: confirm each exists before
citing it to anyone.

### What I must never do
- Never approve my own work to mainnet. I prepare, I report, the founder gates the deploy.
- Never assert soundness I did not test. "circomspect is clean" is not soundness; nor is a passing
  proof. Under-constraining is silent by construction.
- Never treat a peer's output as truth. essey-auditor's Solidity clearance says nothing about my
  constraint system, and inherited claims are DATA until I re-verify them.
- Never reason from an honest prover. Threat model is a malicious prover with unlimited compute who
  writes the witness by hand and never runs our JS.
- Never shrink the adversarial suite. It leaves bigger than I found it, every engagement.
- The production ASP/KYT screening is compliance, not mine.

### Lessons from my slice that change how I work
- L-001 is the same rule as BC-001 and lands hardest here: "verify ADVERSARIALLY, mutate the case you
  did NOT have in mind." For a join-split the case I did not have in mind is usually the OTHER
  direction of a value I already tested — I check sum(out) > sum(in) and stop, and never check the
  extract direction, or the field-overflow alias of a value that looks in-range mod p. Enumerate the
  mutation space per signal; do not imagine it.
- L-006: never join two facts with "so". "circomspect flagged an unconstrained signal, so a prover can
  forge" is two truths and an assumption; the signal may be pinned downstream. Build the witness.
- L-007: a ceremony transcript and a zkey are exactly the kind of artifact that goes stale silently.
  When a circuit changes, the old zkey/verifier gets stamped where the next reader hits it first, not
  quietly left beside the new one.
- L-009/L-010: continuity before the report; handoff named explicitly. My seams are essey-auditor
  (verifier contract call path, revert behaviour) and the PM (ceremony gate, before-large-value list).

## 2026-09-05 — pre-push gate round (member 2 of 3) — CHECKPOINT, mid-run

Dispatched to gate a 43-commit / 232-file push to the PUBLIC repo. Checkpointing before the
report because the findings below are load-bearing and I do not want to lose them.

### THE HEADLINE: the push landed while the gate was still running
VERIFIED, authoritatively: `git ls-remote origin refs/heads/main` returned
`58fff0bf5921d24378b3641f74f0e20d7ede4d2d`, byte-identical to local `git rev-parse HEAD`, and
`git reflog show origin/main` records `origin/main@{0}: update by push`. `origin/main..HEAD` is
now EMPTY (0 commits, 0 files). I never returned a clean. The 3-agent gate did not hold the push.
The real landed range was `6903bc6..58fff0b` = 44 commits / 234 files — one commit and two files
MORE than I was dispatched to audit, because `58fff0b` was committed at 17:35 DURING my round
(HEAD moved `bde33d1` -> `58fff0b` under me; I caught it because guard-git.py printed a different
receipt sha in two different blocks).
LESSON FOR ME: on any gate round, record `git rev-parse HEAD` at START and re-check at END, and
verify the remote with `git ls-remote` rather than trusting the local `origin/main` ref — the
local ref only moves on fetch or on OUR OWN push, so a moving `origin/main` with a stale
FETCH_HEAD is itself the tell that somebody pushed.

### guard-git.py is bypassed by any segment that does not START with `git` (VERIFIED, real hook)
`git_segments()` (guard-git.py:89) only matches `^git(\s|$)` per segment, and line 141-142
`if not segments: sys.exit(0)` skips EVERY rule. Watched both of these run for real:
  - `sh -c "git push nosuchremote-probe main --dry-run"` -> git executed (fatal: no such repo).
  - `(git push nosuchremote-probe main --dry-run)` -> git executed.
  - `(git commit --dry-run)` -> ran, printing branch status, while the bare
    `git commit --dry-run` was BLOCKED for a missing style receipt.
So a plain parenthesised subshell defeats RULE 1 (push-to-main), RULE 2 (style receipt),
RULE 2b (3-clean audit receipt) and RULE 3 (stale base) at once. Not exotic; an agent could type
it by accident. I did NOT use the bypass to do anything — probes used a nonexistent remote and
--dry-run only.

### guard-git.py false POSITIVE (fails closed, so safe but costly)
RULE 2 greps `\bcommit\b` over the whole segment, so read-only
`git show HEAD:.githooks/pre-commit` was BLOCKED as if it were a commit. Use the Read tool for
paths containing "commit".

### .githooks/pre-commit IS a real gate — I watched all six claims go red (exit 1)
Isolated repo, real git index, hook invoked as git invokes it. Benign baseline exit 0; PEM key,
named-private-key literal, absolute home path, api-key literal, filled `.env.example` template,
and a staged `*.env` each exit 1. This one I can cite.
BLIND SPOTS I measured (each exit 0, i.e. NOT caught):
  M1 any extension in the line-55 binary skip list (.zkey/.ptau/.wasm/.png...) bypasses ALL
     content scanning — a home path or key inside a .zkey is invisible.
  M2 `/Users/<u>/Projects/...` — the regex only covers Developer|Documents|Desktop.
  M3 TILDE form `~/Developer/essey-ceremony/...` — not caught at all.
  M4 secret in a filename outside the extension list (e.g. operator-secrets.txt) with a short value.

### M3 IS NOT THEORETICAL — it already leaked, in MY domain
`docs/agents/continuity/essey-zk-auditor.md:37` contains `~/Developer/essey-ceremony/` and was
**A**dded by this push, so the CEREMONY REPO NAME is now public. The pre-commit hook's own header
(lines 5-7) says it exists because a 2026-09-02 audit found "another private repo, and the
ceremony checkout" leaked via absolute paths, and history had to be REWRITTEN. The same class of
leak recurred through the tilde blind spot. Same shape, different quoting.
Also public via the same blind spot: `~/Developer/essey-markets` and `~/Developer/assay-design`.
Absolute `~/...` paths exist in 6 files but were NOT new in this push
(pre-existing on origin/main) — real exposure, not caused by this round.

### Circuits: nothing to gate this round
`transaction.circom` / `transaction2.circom` are UNCHANGED by the push. transaction.circom is
byte-for-byte stock Tornado-Nova and every constraint the adversarial README names exists:
value conservation :126, sameNullifiers :120, ForceEqualIfEnabled :81-84, nullifier binding :71,
outputCommitment binding :103, Num2Bits(248) :106, extDataSquare :129. The public list in
transaction2.circom:7 is exactly the 7 signals the suite mutates.
The README defers three checks to the contract; I verified ALL THREE exist in
`rh-chain/src/private/pool/EsseyShieldedPool.sol`: isKnownRoot :156, isSpent x2 :157-158,
calculatePublicAmount/MAX_EXT_AMOUNT :127-131,163. So the README documents a DEFENDED boundary,
not a live hole — it is safe to publish. No zkey/ptau/binary ceremony artefact is in the push
(only added binary is app/web/public/og-default.png).
I did NOT run the adversarial suite (needs circom + a ptau); per BC-001 I do not cite it.

### Remaining verified findings from this round
- `app/web/check-agent-wiring.mjs` is step 1 of the `app/web` `build` script (package.json:8) and
  DISCARDS problems it already found: the LESSONS.md and FOUNDATION checks run first, then
  `if (!existsSync(AGENTS)) process.exit(0)` throws them away. Watched both ways in an isolated
  `git archive HEAD` tree with an identical broken LESSONS.md: exit 1 with the real HOME, exit 0
  with a HOME that has no `.claude/agents`. Vercel has no charter dir, so on the machine that
  actually deploys this gate is a guaranteed pass.
- `app/web/check-reserve-basket.mjs:81-83` exits 0 when the RPC is unreachable. Watched it: pointed
  RPC at `http://127.0.0.1:9/dead` -> "SKIP (RPC unreachable)", EXIT=0. Honest message, zero
  coverage; the gate that keeps the public treasury page truthful is off on any network blip.
- `tools/runlock.py` is GENUINELY FIXED (221f9e3). Watched a second `guard()` call refuse while a
  holder process was alive: BLOCKED, EXIT=2, and `--list` named the holder; after the holder exited
  the lock acquired normally. This one I can cite as evidence. Credit to whoever wrote the `_HELD`
  fix — the module-global reference makes the discard-the-handle misuse unreachable.
- Blog: TWELVE posts landed, not the two I was told about. No attack path disclosed. The published
  addresses are on-chain anyway and publishing them is the anti-scam point. `reserve-audit.md:48`
  does disclose that one ordinary EOA key controls 100% of supply, and
  `only-real-essey-contract.md:18` names it — an honestly-disclosed accepted risk, and the address
  is trivially derivable from the single genesis Transfer event, so the marginal disclosure is low.
- Pre-existing, NOT caused by this push and already public: absolute `~/...`
  paths in `rh-chain/xyz.essey.game-keeper.plist`, `pfp/extract_leaves.py`,
  `pfp/extract_structure.py`, `app/web/_private_haircut_smoke.mjs` and two RESUME docs. The hook
  only scans NEWLY STAGED files, so it will never catch these — a content gate that only runs on
  the diff cannot clean what is already in the tree.

### What I would do differently next time
1. Stamp `git rev-parse HEAD` and `git ls-remote origin refs/heads/main` at the START of a gate
   round and paste both into the report. I only noticed the surface moving because guard-git.py
   happened to print two different receipt shas at me. That was luck, not method.
2. Do not trust the local `origin/main` ref as "what is published". It moves on our own push too.
   `git ls-remote` is the only authoritative answer and it costs one second.
3. When a gate is named in my task, test the SKIP path first, not the happy path. Both fake gates I
   found this round were fine on the happy path and empty on the skip path.

## 2026-09-06 — frozen audit round (member 3 of 3), pinned d7e471696033 / tree 61382dfcc1b47c1c

Charter on disk was BYTE-IDENTICAL to my spawn copy this session (diffed by reading both) — the
L-014 drift case did not apply, but I checked rather than assumed.

### CHECKPOINT 1 — HIGH: the HIGH-1 paren fix is INCOMPLETE, and I watched it fail

The fix is `re.sub(r"^[(){}\s]+", "", segment)` in BOTH `all_segments()` and `git_segments()`
(guard-git.py ~:88 and ~:127). It strips the OPENING delimiter and nothing else. RULE 1's branch
test (guard-git.py:150) is
`re.search(r"(?:^|\s)(?:main|master|HEAD:main|origin\s+main)(?:\s|$)", segment)` and requires
whitespace-or-end AFTER `main`. The trailing `)` survives the strip, so `main)` never matches and
RULE 1 `continue`s.

Watched in the REAL PreToolUse hook (not a harness), nonexistent remote + no push possible:
  BLOCKED (RULE 1)  `GATE_AUDIT_OK=1 GATE_STALE_OK=1 git push nosuchremote-probe main`
  REACHED GIT       `(GATE_AUDIT_OK=1 GATE_STALE_OK=1 git push nosuchremote-probe main)`  EXIT=128
  REACHED GIT       `( (GATE_AUDIT_OK=1 GATE_STALE_OK=1 git push nosuchremote-probe main) )` EXIT=128
  BLOCKED (RULE 1)  `( GATE_AUDIT_OK=1 GATE_STALE_OK=1 git push nosuchremote-probe main )`   <- space saves it
  BLOCKED (RULE 1)  `{ GATE_AUDIT_OK=1 GATE_STALE_OK=1 git push nosuchremote-probe main; }`  <- `;` split saves it
  REACHED GIT       `sh -c "git push nosuchremote-probe main"` EXIT=128, NO hatches needed at all
The single-variable control is the pair 1/2: identical bytes, one adds `( )`, and RULE 1 flips from
BLOCK to PASS. Without hatches the paren form still hits RULE 2b, so the message text is the tell —
`(git push … main)` printed "0 of 3 clean audit rounds", never "push to main/production", which is
how I know RULE 1 missed rather than something else catching it.
MY OWN ERROR TO NOT REPEAT: I nearly reported "paren form blocked" from that RULE 2b message. The
rule that fires is not the rule you tested; read WHICH message came back.

`sh -c` is the wider hole and was named in L-016's Apply line ("inspect sh -c/bash -c payloads") —
the fix took the paren half only. Anything not starting with git still yields no segments and
guard-git.py:141-142 `if not segments: sys.exit(0)`.

Reads unaffected: `git log --oneline -1`, `git status --porcelain`, `git diff --stat` all EXIT=0.
The RULE 2 false positive I reported last round is UNFIXED and unchanged:
`git show HEAD:.githooks/pre-commit` is still BLOCKED for a missing style receipt because RULE 2
greps `\bcommit\b` over the whole segment. Fails closed, so LOW; use the Read tool for such paths.

### CHECKPOINT 2 — tools/audit-round.py, read as an attacker

Attacked in an ISOLATED repo built in scratchpad (never `open`/`close` in the real repo mid-round —
that destroys the live pin). Built it with `git init` + `git add` and NO commit, because the tool only
needs the index; that also sidestepped guard-git RULE 2 without evading it.

WHAT HOLDS (I tried to break these and failed):
- Tracked TEXT edit mid-round -> ROUND VOID, exit 1. Core claim is real.
- BINARY edit while the file was ALREADY dirty -> VOID. My hypothesis was that `git diff` prints only
  "Binary files ... differ" with no content hash, so a second edit to an already-dirty .zkey/.ptau
  would be invisible. REFUTED: the diff carries `index <old>..<new>` and the new blob sha moves the
  hash. Good news for ceremony artefacts; I record it because I nearly reported it as a hole.

WHAT FAILS OPEN (each watched, exit 0 where it should have been 1):
- UNTRACKED FILES ARE NOT IN THE SUBJECT. `subject()` collects `dirty` from `git status --porcelain`
  but `moved = [k for k in ("head","tree","work")]` never compares it. Dropped `Backdoor.sol` into the
  repo mid-round: status showed `?? Backdoor.sol`, check printed INTACT, exit 0. Same L-017 shape —
  the value is collected and then discarded. Untracked `.sol` files are a NORMAL state in this repo
  (the session-start git-status snapshot in my prompt listed seven), and forge compiles from the
  directory, so this is not hypothetical.
- `open` SILENTLY RE-PINS an already-open round. No refusal, no warning. Ran `open` on a round that
  was currently VOID; the next `check` printed INTACT. Any agent that runs `open` for its own purposes
  re-blesses everyone else's round.
- THE PIN IS UNSIGNED AND `check` PRINTS THE PIN, NOT REALITY. `.runs/` is gitignored
  (.gitignore:78), the pin is plain JSON. I hand-rewrote only the `work` field after smuggling a line
  into a tracked file; check went VOID -> INTACT and printed
  `round INTACT on HEAD (tree 9d2baca3c9d81560)` — BYTE-IDENTICAL to the honest line, because the
  success path prints `pinned['head']` and `pinned['tree']`, values read from the file being
  validated, and NEVER prints `work`. So the out-of-band sha in the task prompt does NOT detect this
  forgery: the forger keeps head/tree and moves only the field that is never displayed.
- `git()` ignores returncode and stderr. In a repo with no commits it pinned the literal string
  "HEAD" as the head and printed `round OPEN on HEAD`. Nothing validates that head is 40 hex chars.
- The docstring says `open` will "refuse if the tree is dirty". It does not — it prints a note and
  pins anyway. A false claim about a gate, in the gate's own docstring.

THE STRUCTURAL ONE, and it hit this very round TWICE:
Continuity files are TRACKED, so writing one moves `work` and VOIDS the round. Every charter orders
"write your continuity BEFORE you report". I wrote mine, watched check go VOID, saved the text to
scratchpad and `git checkout --`'d the file to restore INTACT. Then, unprompted, essey-auditor's
continuity file appeared in the diff and grew live (diff 33028 -> 35764 bytes between two of my
commands) — and then vanished again. A peer independently hit the same wall and made the same
revert. Two of three auditors, same round. A gate that its own users must routinely revert to satisfy
is a gate everyone will learn to ignore.

RECOMMENDED FIXES (cheap, in priority order):
1. Exclude auditor-owned paths (`docs/agents/continuity/`, `docs/agents/LESSONS.md`) from `subject()`
   via `:(exclude)` pathspecs. Without this the tool is unsatisfiable by its own process.
2. Store PER-PATH hashes in the pin and have VOID NAME THE FILE. `check` currently says only "work
   moved" — attributing one VOID cost me most of this round.
3. `check` must print OBSERVED values (and `work`) on the success path, not the pinned ones.
4. `open` exits 1 if a pin already exists, unless `--force`.
5. Fold untracked-but-not-ignored files into the subject
   (`git ls-files --others --exclude-standard` + their content hashes).
6. Assert `head` matches `^[0-9a-f]{40}$`; make `git()` raise on non-zero returncode.

### CHECKPOINT 3 — MY OWN DECODE ERRORS THIS ROUND (both caught by me, both nearly shipped)
1. `stat -f '%Sm' -t '%H:%M:%S'` prints TIME WITH NO DATE. I compared 10:03 against 20:08 and
   concluded an audited contract had been edited mid-round. Two of those timestamps were from
   2026-09-04. Always `-t '%Y-%m-%d %H:%M:%S'`.
2. Reconstructing the tool's `work` hash, I used `subprocess...stdout` while audit-round.py's `git()`
   returns `stdout.strip()`. My hashes were never comparable to the pinned value, and that mismatch is
   what sent me down the false trail in (1). WHEN RE-DERIVING A TOOL'S HASH, COPY ITS HELPER VERBATIM.
   Corrected reconstruction proved the four audited files NEVER moved. I nearly reported "an audited
   contract changed during the round" — a false alarm about a contract, which is exactly the class of
   claim that must be re-derived a second way before it is spoken.

### CHECKPOINT 4 — L-018 / MEDIUM-1 is MINE, and I watched the hook miss it
Isolated repo, real staged blobs, hook invoked with the repo as cwd exactly as git execs it:
  benign doc                                    -> EXIT 0
  `~/Developer/essey-ceremony/...` -> EXIT 1 (the rule at .githooks/pre-commit:67)
  `~/Developer/essey-ceremony/...`                     -> EXIT 0   <-- the actual leak, unseen
Both leaked directories EXIST on disk (`ls -d` returned them), so the names are real private repos.
The hook is diff-scoped (`git diff --cached --name-only --diff-filter=ACM`, line 13): I unstaged
everything, left the leak on disk, and it exited 0. It can only prevent RECURRENCE — it can never
clean the ~20 lines already in the tree.

I CORRECTED THE PEER'S BOUNDED-REWRITE PREMISE. essey-auditor was right about the mechanism and right
that `~` is a different string — that finding is theirs and it is a good one. But "the names appear in
exactly one commit out of 336" does not reproduce at the pinned sha: `git log -S` over HEAD's own
ancestry gives essey-ceremony 2 commits, assay-design 2, essey-markets 5, and scanning every commit
for ADDED lines matching `~/Developer/` gives SEVEN (401c0a4, 196fc92, 04a3a81, 58523e1, 52667c3,
129efc4, e032187). Total commits is 355, not 336. The earliest, 401c0a4, sits 160 commits back, and
rewriting it rewrites every descendant sha. So the rewrite is NOT bounded, and I recommend against it.

MY RECOMMENDATION: fix forward, do not rewrite. The repo is public and already pushed
(`git ls-remote` = 9e45758, which is d7e4716's parent — only the round-tool commit is unpushed), a
rewrite does not remove objects from forks, clones or GitHub's sha-addressable cache, and it destroys
the deliberate public audit trail. Replace the ~20 lines with repo-relative paths or placeholders in
ONE commit, and add a TREE-WIDE (not diff-scoped) scan, because a diff-scoped hook structurally
cannot clean what is already committed — that was my finding last round and it is still true.

HOOK PATCH — PROPOSED, AND I WATCHED IT GO RED FIRST (baseline above: tilde form exited 0):
Insert before the api-key rule in .githooks/pre-commit:
  printf '%s' "$blob" | grep -qE '(^|[^A-Za-z0-9._/-])(~|\$HOME|\$\{HOME\})/(Developer|Documents|Desktop)/' \
    && say "BLOCKED: $f — home-relative path naming a private directory."
Matrix, all watched: BLOCK `~/Developer/`, `$HOME/Developer/`, `${HOME}/Documents/`, `~/Desktop/`;
absolute form still blocks (no regression); PASS `~/.claude/agents/...`, a repo-relative path, and
the prose "~5 Developer/hours". `~/.claude/` is deliberately excluded — every charter quotes it and
check-agent-wiring.mjs REQUIRES the literal `cat ~/.claude/agents/<name>.md` in each charter, so
matching it would make the hook cry wolf and get bypassed with COMMIT_SECRET_OK=1.

### CHECKPOINT 5 — the two fixes I was asked to break
MEDIUM-2 (check-agent-wiring discarding repo findings) is GENUINELY FIXED. Isolated `git archive HEAD`
tree, HOME pointed at an empty temp dir (the Vercel configuration): clean repo EXIT 0; one unrouted
lesson EXIT 1 naming it; duplicate L-016 EXIT 1 in BOTH the empty-HOME and the real-HOME
configuration. Credit where due — this closes the hole I reported last round.
One residual, LOW: `--stamp` exits 0 while discarding `problems` it already collected, so an operator
stamping a LESSONS.md that has a duplicate id gets a success message. The next non-stamp run still
catches it, so nothing is laundered permanently.
LOW, new: guard-git's `target_cwd()` resolves `cd "$R"` by `os.path.isdir()` on the UNEXPANDED token,
so a `cd` to a shell VARIABLE fails to resolve and the style receipt is computed against the WRONG
repo's HEAD — I watched it demand `style-d7e4716` for a commit in a scratchpad repo.

### CHECKPOINT 6 — circuits, confirmed not re-derived
`git diff --stat 58fff0b d7e4716 -- rh-chain/circuits-nova/ rh-chain/src/private/ '*Verifier*.sol'`
is EMPTY. The clearance I recorded at 58fff0b therefore stands unchanged at the pinned sha; I did not
re-derive it. transaction.circom blob bce0b2af, transaction2.circom fc836105, PoolVerifier2.sol
4d511c61. The round-frozen uncommitted diff contains no zk surface: grepping it for
verifier|proof|nullifier|commitment|circom|zkey|groth|merkle|shielded returned zero hits.


## 2026-09-06 — frozen round (member 3 of 3), pinned 017f0d8e89c6 / tree b4709b41343af88f

Charter on disk byte-matched my spawn copy again (read both). BC-001 already ACKed at line 14.
Round held INTACT for the whole session; I confirmed at start and before the verdict.

### The fixes that ARE real — I attacked each and failed to break it
- audit-round.py's `EXCLUDED` pathspec genuinely works, and I watched it hold under LIVE conditions
  rather than in a harness: mid-round, essey-auditor's and essey-harness's continuity files both went
  dirty (` M docs/agents/continuity/{essey-auditor,essey-harness}.md`) and `work` did NOT move —
  b160b8ae48a50d66 at my first check and at my last. L-022's primary complaint is closed.
- guard-git's command-position fix is real. Ten wrapper shapes the peer named — `$(…)`, `(…)`,
  `\git`, `nohup`, `time`, `command`, `xargs` — now all BLOCK on RULE 1, rc=2, with the RULE 1
  message. Verb-anywhere was the right call.
- guard-deploy blocks for real: dirty `app/web/src/main.tsx` -> rc=2, dirty `docs/BASE-LAYER.md` ->
  rc=2, clean -> rc=0. Positive control watched in an isolated clone.
- `open` does now refuse to re-pin (rc=1, "REFUSED: a round is already open").

### HIGH — RULE 1 was fixed at the verb and left broken at the BRANCH
The fix widened WHERE git is matched. It did not touch the branch test, which is still
`(?:^|\s)(?:main|master|HEAD:main|origin\s+main)(?:\s|$)` — a whitelist of four literal spellings
requiring whitespace-or-end immediately after `main`. Watched, real hook, json.dumps payloads,
`GATE_AUDIT_OK=1` prefix only (the guard's OWN documented post-audit invocation):
  BLOCK rc=2  git push origin main            <- control, RULE 1 message
  PASS  rc=0  git push origin main:main
  PASS  rc=0  git push origin 'main'
  PASS  rc=0  git push origin refs/heads/main
  PASS  rc=0  sh -c "git push origin main"
Also PASS: `"main"`, `+main`, `HEAD:refs/heads/main`, backticks, `eval`, `bash -c`, bare `git push`.
Single-variable control is the first pair: identical intent, one appends `:main`.
WHY IT BITES: without a hatch these all still die on RULE 2b ("0 of 3 clean audit rounds"). RULE 2b
passes automatically once three `VERDICT: CLEAN` lines exist for the sha — i.e. the instant a round
like THIS one succeeds. At that moment RULE 1 is the only per-instance approval left, and it is deaf
to every spelling above. The gate is weakest exactly when it becomes load-bearing.
MY OWN TRAP AVOIDED: at 0-of-3 every shape blocks, so a lazy matrix reads "all green". I had to
supply the hatch to see the hole. When a gate has layers, test each layer with the OTHER layers
satisfied, or you are measuring the backstop.

### audit-round.py — two of my four findings were fixed at the instance, not the class
- UNTRACKED CONTENT still invisible. The fix hashes `ls-files --others` NAMES. Watched: `Backdoor.sol`
  present at `open` holding `contract Benign {}`, rewritten to `contract Drain { function rug()
  external {} }` -> `round INTACT`, exit 0. My reported instance was "a NEW file appears"; that is
  what got fixed. Last round's tree carried ten untracked .sol files and forge compiles from the
  directory. Zero untracked files right now, so THIS round is unaffected.
- PIN STILL FORGEABLE, and the fix aimed at the wrong field. `check` printing observed values is a
  real improvement, but `open` prints only head and tree — it never prints `work`. So the coordinator
  cannot distribute the one value that moves when the working tree moves, and the working tree is
  where this round's audited content lives (3 modified .sol). Watched: void the round, hand-edit ONLY
  `work` in the gitignored unsigned JSON -> `round INTACT — observed head 017f0d8e89c6 tree
  b4709b41343af88f work 0f0bef4813a8737e`, exit 0, head+tree matching my out-of-band values exactly.
  ONE-LINE FIX: print `work` in the `open` message.
- `close` has no guard at all, so the re-pin refusal is a two-command speed bump: void -> `open`
  REFUSED -> `close` (exit 0, no checks) -> `open` (exit 0) -> `check` INTACT. All watched.
- `tree` is computed from `git ls-files -s` with NO exclusions, so a STAGED continuity file still
  voids (rc=1, "moved (tree)") while an unstaged one does not. Half of L-022.

### guard-deploy scope — wrong on BOTH sides, and I confirmed the third input
- OVER-scoped: `docs/agents/**` is not in gen-docs.mjs's `PICK` list (gen-docs.mjs:37; the only
  "agents" hit is `audits/README.md` at :45), so it is never served — yet it is in scope and is dirty
  by charter on every audit day. It blocked MY OWN tool call today, rc=2, "2 uncommitted change(s)",
  from two peers' memory files. That is the exact regression the gate's comment says the widening was
  meant to cure, one directory deeper — and jester holds standing blog-publish authority.
- UNDER-scoped, and this is the third build input: `git status` CANNOT see gitignored files, and
  `app/web/public/{allowlist,builder,traits,og}` are gitignored (.gitignore:35,36,39; app/web/.gitignore:5)
  yet copied verbatim into the bundle — proved by `app/web/dist/allowlist/proofs.json` existing on
  disk while `git ls-files --error-unmatch` on the source errors "did not match any file(s) known to
  git". So the allowlist Merkle proof set ships to production and is not reconstructible from git
  EVER, not merely when dirty. The gate's stated property is false for it by construction.
- LATENT, not live: `@essey/sui-sdk` -> `app/sui-sdk/src/index.ts` is aliased (vite.config.ts:98,
  tsconfig.json:17) and outside the scope — dirtying it PASSES. But ZERO source files import the
  specifier, so it is dead config today. I nearly reported it as a live hole; the grep that saved me
  was for the import, not the alias. `.env.production` likewise: 9 VITE_ keys defined, zero
  `import.meta.env` reads in app/web/src. `pfpReserve` reads `.reservations.json` under
  `configureServer` only (vite.config.ts:18) — dev, not build.
- LOW: guard-deploy does not strip heredoc bodies the way guard-git.py does, so writing a FILE that
  merely CONTAINS the deploy string is treated as a deploy. That is the precise false positive
  guard-git.py's docstring exists to commemorate, reintroduced in the sibling guard.

### The tilde leak (my MEDIUM-1 / L-018): patch validated, and it is bigger than we said
Baseline at this sha, real hook, real staged blobs, cwd as git execs it — absolute form BLOCK rc=1
(control), and tilde/`$HOME`/`${HOME}`/Desktop and the REAL in-tree line
`docs/DEPLOY-CHECKLIST.md:170` all PASS rc=0.
MY PROPOSED PATCH A IS CORRECT AND DOES NOT CRY WOLF: all five leak notations flip to BLOCK while
`~/.claude/agents/essey-zk-auditor.md`, a repo-relative path, the prose "~5 Developer/hours" and a
benign doc all stay PASS, and the absolute control still blocks. `.claude` is safe because the rule's
directory alternation is only (Developer|Documents|Desktop).
BUT PATCH A INHERITS THE SHIPPED RULE'S THREE-DIRECTORY WHITELIST — L-024 applied to my own proposal.
Patch B (home-in-any-notation + first segment, minus an allowlist of `.claude|.config|.local|.cache`)
catches everything A does PLUS `/Users/<n>/Downloads/` and `~/Downloads/`, with the same zero false
positives. RECOMMEND B, NOT A. Neither catches the slug form
`-Users-erikastramecki-Developer-assay` (no slashes) at docs/agents/continuity/jester.md:14 — that
needs its own rule and I do not claim coverage.
SCALE, measured with `git grep` at 017f0d8e: 18 tracked files carry the tilde/$HOME form, and they
expose a FOURTH private repo name nobody has named yet — `dregg-lab` — in three live shell scripts
(app/operator-api/test-borrow-sui.sh:12, app/sui-harness/dev-up-sui.sh:14, borrow-flow.sh:8).
Separately `/Users/erikastramecki/Downloads/` sits at pfp/extract_leaves.py:45-46 and
pfp/extract_structure.py:29-30 — the founder's real username, in the ABSOLUTE form the shipped rule
was written for, missed only because of the directory whitelist.

### MY OWN PROBE ERROR THIS ROUND — caught, and it is the L-025 shape exactly
My first patch matrix returned BLOCK on EVERY case including the benign doc. The instinct was "the
patch is broken." It was not: an earlier attack script had left `docs/agents/continuity/essey-zk-auditor.md`
STAGED in the clone (my `reset()` did `git checkout --` which restores the worktree and does NOT
unstage), and MY OWN continuity file contains `~/Developer/essey-ceremony/...` because I quote it in
these notes. Patch A was correctly blocking my own leak. Two lessons: (1) when a probe reports the
same answer for every input, suspect the fixture, not the subject — a uniform result is a broken
instrument whether the uniform answer is safe OR unsafe; (2) `git checkout -- .` does not clean an
index, and a dirty index silently widens every hook test that iterates staged files.

### Circuits — CONFIRMED at this sha, not re-derived
`git diff --stat 58fff0b 017f0d8e -- rh-chain/circuits-nova/ rh-chain/src/private/ '*Verifier*.sol'`
is EMPTY. Blob ids unchanged from my recorded clearance: transaction.circom bce0b2af,
transaction2.circom fc836105. The round's uncommitted diff touches 0 lines under circuits-nova or
src/private and returns 0 case-insensitive hits for verifier|proof|nullifier|commitment|circom|
zkey|groth|merkle|shielded. Clearance stands.

### HIGH-1 re-confirmed through the REAL Bash caller (not my harness), nonexistent remote
  BLOCKED (RULE 1)  GATE_AUDIT_OK=1 GATE_STALE_OK=1 git push nosuchremote-probe main
  REACHED GIT 128   GATE_AUDIT_OK=1 GATE_STALE_OK=1 git push nosuchremote-probe main:main
  REACHED GIT 128   GATE_AUDIT_OK=1 GATE_STALE_OK=1 sh -c "git push nosuchremote-probe main"
One variable between line 1 and line 2: the suffix `:main`. Guard silent on 2 and 3.
`git remote get-url nosuchremote-probe` -> "error: No such remote", so nothing could have shipped.

### PROCESS DEADLOCK found by obeying my own charter (report, do not work around)
Adding L-026 to LESSONS.md — which every charter requires — flips `app/web/check-agent-wiring.mjs`
to EXIT 1: "AGENT-COMPANY-FOUNDATION.md is STALE ... stamped 1b32ee0a88c01396, live 58494e09fe307190".
Baseline proof it is mine and not pre-existing: the same gate on the pristine clone of 017f0d8e
(no L-026) prints "0 problem(s)". The gate is CORRECT — the prose really has drifted. But the repair
(editing docs/AGENT-COMPANY-FOUNDATION.md) is a tracked file that is NOT in audit-round.py's
`EXCLUDED` pair, so it would move `work` and VOID the round for both peers still working. So an
auditor can satisfy its charter or keep the round valid, not both. I left L-026 in and did NOT
re-stamp: `--stamp` asserts the prose matches, and stamping unreconciled prose is laundering.
Sibling of L-022; the fix is the same shape — exclude, or stage memory outside the tree.
