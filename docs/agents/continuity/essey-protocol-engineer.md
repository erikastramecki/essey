# essey-protocol-engineer — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

---

## 2026-09-05 — onboarding session (no build; charter + broadcast read)

ACK BC-001 — I stop treating a green `forge test` as proof of anything: before I cite a Foundry test as pinning a money-path invariant I break the exact line it guards, watch that test go RED, and put the source back — and I say plainly which parts of the suite are only a regression baseline rather than pretending the whole run is evidence.

### What I own (VERIFIED — `~/.claude/agents/essey-protocol-engineer.md`, charter body)
- The Foundry project at `rh-chain`: `src/`, `test/`, `script/`, `keeper/`.
- Turning scopes into building, passing Solidity + deploy scripts. Not the economy (don-economist),
  not the mechanics (don-designer), not the front-end (essey-web-designer).

### What I must NEVER do
- Deploy to mainnet. I prepare deploy-ready code plus the exact command; the founder fires it.
- Self-approve security. Every contract change goes to the essey-auditor gate before any push.
- Report `forge test` / `forge build` green as *done* without pasting the real output.
- Name a Solidity symbol I have not confirmed exists in the source.

### Lessons from peers that change MY slice (from `python3 tools/lessons.py --role essey-protocol-engineer`)
- **L-002** — being the author of a file says nothing about its current contents. Before any run I
  treat as evidence, rebuild the baseline from `git archive HEAD` or hash against `HEAD`; a live
  access-control mutant once got hashed as somebody's "pristine" baseline.
- **L-003 / L-011** — take `tools/runlock.py` before any tree-mutating run, and remember the lock
  itself was once a decoration because its caller discarded the handle. Two overlapping mutation runs
  void BOTH results.
- **L-001 + CLAUDE.md "mutation-verify ADVERSARIALLY"** — mutate every direction, not the one I had in
  mind writing the test: guards removed AND inverted, comparisons boundary-shifted, constants swapped
  for a *different* constant, enums to the dangerous member. Then rank by which survivor moves money.

### Defect found while onboarding (grounded, worth someone acting on)
My charter's rule 2 says the 3-agent gate resets to zero on **"a finding."** That wording is
**superseded**: the founder ruled 2026-09-04 that the gate is *three consecutive rounds with no
CRITICAL, HIGH, or MEDIUM; LOWs get logged, triaged, and fixed on their own schedule rather than
blocking* — `docs/MAINNET-ACTIVATION.md:1405-1412` (also `docs/PRODUCT-TRACKER.md:28`). The register
explicitly notes the old bar was unreachable: G-LEND ran nine rounds under it and never closed
(`docs/MAINNET-ACTIVATION.md:1410-1412`). Charters at `~/.claude/agents/*.md` are outside the repo, so
a stale rule there is invisible to the L-007 "stamp the superseded copy" habit. VERIFIED by reading
both files; I did not edit the charter (not my file to change unasked).

### Open question for my peers at the seam (ask next dispatch)
For essey-auditor and essey-harness: when I hand off, what do you most often have to re-derive that I
could have written down — the mutation log per invariant, the exact `forge` invocation + profile, or
the frozen SHA the suite was run against? Record the answer here.
