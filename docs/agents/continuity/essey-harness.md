# essey-harness — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

## 2026-09-05 — onboarding to the new charter (no harness run, no wallet, no tx)

ACK BC-001 — My whole output is evidence, so a harness I have never seen go red is not proof a flow works — it is a green light with no bulb in it; from now on every check I cite (negative revert case, ledger reconciliation, UI assertion, timing bound) gets deliberately broken first — wrong revert reason, one wei off, the button disabled, the clock short — and I watch it fail on the exact thing it claims to catch, checking the exit code and not the printed message, before its PASS is allowed into a report.

### What I own
- The two mandated verification layers (charter `~/.claude/agents/essey-harness.md:9-11`): (1) the contract harness driven by throwaway wallets against live testnet 46630, every tx hash recorded, NEGATIVE checks included; (2) the full UI click-through in a real browser, every tab/button/state cross-checked against chain state. No UI change ships without layer 2 passing.
- Wei-exact ledger reconciliation and timing of every gated flow against the contract's own constants — never "looks right" (charter:22-23).
- Producing the evidence other agents and the founder act on: tx hashes, chain reads, screenshots, timings, and an explicit list of what was found but NOT fixed (charter:21,27).
- Adversarial mutation of my own harness: proving each assertion can fail before I report that it passed (BROADCASTS.md BC-001, LESSONS L-001).

### What I must never do
- Never deploy or mint to MAINNET 4663. Hard founder gate, explicit per-action approval only (charter:14).
- Never force a green result. Surfacing a real gap is a SUCCESS; a manufactured pass is the worst thing I can ship (charter:24).
- Never report a claim without its source inline and a VERIFIED / INFERRED / UNVERIFIED label; never inherit another agent's output as truth (charter GROUNDING GATE, charter:35; L-006).
- Never run `game-keeper.sh` concurrently with a harness sharing the deployer key — nonces race (charter:15).
- Never start a second tree-mutating run while `python3 tools/runlock.py --list` shows one in flight; two runs void BOTH results (L-003, charter:102-109).
- Never background a wait and stop; poll in the foreground, and if the budget blows, verify the pre-state landed and report the remainder as pending with the exact due time (charter:25-26).
- Never judge an animation from a screenshot — hidden tabs throttle rAF to zero; drive with setTimeout and poll the DOM (charter:17).

### Lessons from my slice that change how I will work
- L-004 (grade a fix by what is SERVED, not what is committed): my UI layer must fetch the live bundle and assert on the bytes actually being served. A click-through of a local dev build proves nothing about production. This pairs with the Vercel note (charter:18) — `vercel deploy` runs from the REPO ROOT because the project root is configured as `app/web`.
- L-011 + BC-001 corollary (test the gate in the configuration it actually runs in): proving my harness catches a fault I injected into my harness proves nothing. The injection has to go into the real contract/UI path the real caller takes. My throwaway-wallet layer is the right shape for this precisely because it uses the production entrypoints.
- L-002 (authorship is not evidence of content): before a run I hash the tree against `HEAD` or build an isolated root from `git archive HEAD`. "Those files are mine" is not a clearance — a live mutant hashed as the pristine baseline scores every result against a reference with the feature deleted.
- L-010: continuity is written BEFORE the report, and checkpointed after each significant finding on a long run — my runs are exactly the long ones that get truncated.
- Open question for my next real run, flagged now so it is not lost: I have NOT yet watched `tools/runlock.py` block my own real caller, and per BC-001 I therefore may not cite it as protecting a run. Settling it = start a genuine long job, attempt a second, confirm exit code and that the lock actually holds (L-011's failure was exactly this, undetected).

### Two findings from the onboarding read itself (checkpointed before reporting)

**F-1 — The mainnet prohibition has NO mechanism, so by BC-001 I must call it a decoration.**
VERIFIED: `grep -rIn '4663' ~/.claude/bin ~/.claude/settings.json` returns nothing; `ls tools/` is
broadcast.py, lessons.py, runlock.py only; there is no `.claude/settings.json` in the repo. The
closest guard, `~/.claude/bin/guard-deploy.py:116-121`, blocks a *Vercel production deploy from a
dirty tree* — not a chain write. So "NEVER deploy or mint to mainnet 4663" (charter:14) is prose,
and prose is what gets skipped. I cannot watch it fail without attempting the forbidden action,
which is the worst possible test. What would settle it safely: a PreToolUse guard that rejects any
`cast`/`forge` invocation whose `--rpc-url` or `--chain-id` resolves to 4663, which I can then prove
by pointing a harmless READ at 4663 and confirming exit code 2. Until that exists I report my own
mainnet safety as UNVERIFIED, not as a control.

**F-2 — The charter I was DISPATCHED with omits the BROADCASTS step that the charter FILE contains.**
VERIFIED by direct comparison: the file `~/.claude/agents/essey-harness.md:79-90` says "BEFORE you
start work, **all** of these" and leads with `cat docs/agents/BROADCASTS.md` plus the ACK protocol.
The charter injected into my runtime prompt this session says "BEFORE you start work, **both** of
these" and lists only continuity + lessons — no BROADCASTS, no ACK. I would never have read BC-001
had the founder not told me to by hand. Cause UNVERIFIED (cached dispatch copy vs. an edit landing
after dispatch — I cannot see the dispatch layer). This is the exact failure BROADCASTS.md was
written to prevent: a rule that is published but not absorbed. Anyone certifying a broadcast should
treat `tools/broadcast.py` output as necessary but not sufficient, because the file it reads is
written by agents whose own charter may not have told them to read the broadcast.

**Minor:** the charter calls this continuity file "Private to you; nobody else pays to read it"
(charter:131). `tools/broadcast.py:29` reads every agent's continuity file and prints the ACK line
verbatim for the founder. It is team-audited, not private. I will write it accordingly.
