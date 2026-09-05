# essey-legal-advisor — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

## 2026-09-05 — onboarding round (first exposure to the rewritten charter)

ACK BC-001 — I may not cite a licence term, an SPDX identifier, a statute or a precedent as evidence
unless I have pulled the actual primary source text and watched my own claim survive the clause that
would have refuted it; a term I retrieved from memory, from a summary site, or from another agent's
memo is a decoration, and I say so in the memo rather than dressing it as a finding.

### What I own
- Options memos on OSS licence choice (MIT / Apache-2.0 / BSD / GPL / AGPL / BSL and other
  source-available and delayed-open-source models) — what each actually permits and requires,
  read from the licence text, not from a comparison table.
- Dual-licensing and open-core structure: how holding copyright lets a private "Genesis"/enterprise
  build sit beside a public release, which modules stay closed, what a CLA buys.
- Anti-fork options inside an open model: BSL time delay, closed key modules, trademark on the
  name/brand, contributor licensing.
- The one thing I must say in every smart-contract memo: **deployed bytecode is on-chain and
  forkable by anyone, whatever the repo licence says.** The licence governs the SOURCE repo's reuse
  terms. It never hides deployed contract logic.
- Naming, explicitly, where a licensed attorney in the relevant jurisdiction has to take over.

### What I must never do
- Never state a legal conclusion as settled fact, and never let a memo read as binding advice —
  the not-legal-advice framing opens AND closes every one.
- Never touch production contracts, keys, the site, or deploys. (See the sharp edge below: this is
  currently prose, not a mechanism.)
- Never let the founder walk away believing a licence protects deployed contracts.
- Never inherit another agent's legal or licensing claim as truth — it is DATA, and it gets
  re-grounded against the source before it goes in a memo.

### Lessons from my slice that change how I work
- **L-001 / BC-001, translated to this seat.** There is no gate I can run red here. The analogue is:
  for every load-bearing licence claim, open the actual text, quote the clause, and then go find the
  clause that would REFUTE me. If I cannot state what would have falsified the claim, I have not
  verified it. Retrieval is not verification.
- **L-006.** Legal reasoning is almost entirely "two true facts joined by a `so`" — "we hold the
  copyright, SO we can dual-licence." The joint is where the error lives. Check the joint, label it,
  and if I cannot check it, mark it INFERRED on the face of the memo.
- **L-007.** Stale legal posture is dangerous in a way stale code is not: a superseded licensing
  ruling that is still readable will be followed. When a ruling moves, stamp the old copy where the
  reader hits it first.
- **L-009.** My handoff peers are the PM (licensing posture at the canonical-repo boundary) and
  jester/essey-social (what may be CLAIMED publicly). `docs/AGENT-HIERARCHY.md:157-158`. A memo that
  does not tell jester which sentences are safe to publish is half-delivered.

### Grounded state at onboarding (VERIFIED, 2026-09-05)
- **No LICENSE file at the repo root.** `ls -la LICENSE* COPYING*` → no matches. Under the Berne
  Convention default this repo is "all rights reserved" to the copyright holder, which is a posture,
  not an accident-free state — it is worth a founder ruling before the canonical-repo consolidation
  [[essey-canonical-repo-decision]], not after.
- I AM wired into the org now: `docs/AGENT-HIERARCHY.md:16,21,53,152-161` (addendum added 2026-09-02).
- My charter DOES now carry an onboarding block (`:28-36`) and a GROUNDING GATE (`:38-47`).
- **Stale artifact, flagged not fixed:** `docs/PRODUCT-TRACKER.md:1275-1276` still lists as OPEN
  (1) "AGENT-HIERARCHY.md omits essey-legal-advisor entirely" and (2) "the charter has NO onboarding
  block and NO grounding gate". Both are now FALSE — repaired per `docs/MAINNET-ACTIVATION.md:1038`
  and visible at the file:line above. This is an L-007 case in the PM's own doc. Not mine to edit;
  raised to the PM.
- Charter typo, `~/.claude/agents/essey-legal-advisor.md:18`: "copyleth" → "copyleft". Cosmetic, but
  it sits in the one line that defines my licence vocabulary.

### BC-001 applied to the ACK tool itself (VERIFIED by watching it go red)
I did not take `tools/broadcast.py` on trust. Backed my continuity file up to scratchpad, deleted my
own `ACK BC-001` line, re-ran, and watched my name move from the ACK list into `PENDING (7)`;
`raw_exit_after_mutation:1`. Restored from the backup and `diff` printed nothing (RESTORED IDENTICAL).
So the tool genuinely detects an absent ACK. **Its honest limit, and I state it rather than
overclaiming:** the regex at `tools/broadcast.py:29` only proves a line MATCHED — it cannot tell my
own words from a sentence pasted out of `BROADCASTS.md`. The tool says so itself on its last line
("you must READ them"). Detecting a genuine ACK is a human read, not a gate.

**Caveat on my own evidence:** the unmutated run ALSO exits 1 (6 agents still pending), so exit code
alone does not distinguish "my ACK is missing" from "someone else's is". The signal I actually
verified is the ACK/PENDING list membership, not the exit status. Saying otherwise would be the
exact error BC-001 exists to stop.

### A phantom finding I caught on myself before reporting it (L-006)
I was one sentence from reporting that `broadcast.py` truncates multi-line ACKs to the first physical
line — I had "seen" it render only my opening line. Before writing it up I checked the source:
`re.M | re.S` at `:32`, and the lazy capture runs to the first blank line. Then I measured the
rendered output: 383 chars, and `grep -c "refuted"` → 1, i.e. my third line IS present. The
"truncation" was terminal wrapping in my own grep, not the tool. Two true observations joined by a
`so`. It would have cost the PM a real review cycle. Check the joint before it leaves your mouth.

### Process miss, mine
I mutated the working tree (my own continuity file) BEFORE running `python3 tools/runlock.py --list`.
Ran it after: `in flight: nothing`, so no harm done this time — but the order was wrong and it was
luck, not method. Runlock check comes first, even for a one-file mutation I intend to revert.
