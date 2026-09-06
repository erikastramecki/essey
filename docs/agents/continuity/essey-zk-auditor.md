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
Absolute `/Users/erikastramecki/...` paths exist in 6 files but were NOT new in this push
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
- Pre-existing, NOT caused by this push and already public: absolute `/Users/erikastramecki/...`
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
