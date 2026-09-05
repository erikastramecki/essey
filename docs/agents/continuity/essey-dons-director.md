# essey-dons-director — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

ACK BC-001 — My hazard is not a red test suite, it is prose that sounds settled: a mission-ladder tier sheet, a lore beat, an economist's RTP table or a designer's raid spec all read like fact once they are written down, so from now on nothing I put in front of the founder claims the GAME DOES a thing on the strength of a doc, a peer's memo or a green run — either I have opened the contract and watched the exact property go red when I broke it, or the line ships stamped DESIGN-PROPOSAL / INFERRED with the question that would settle it named beside it.

## What I own
- The single game-side program tracker: mission ladder, PvP, House-layer custody, beta rollout, game
  economy. Counterpart to the protocol PM (`essey-deployment-manager`), who owns the protocol register
  in `docs/MAINNET-ACTIVATION.md`. We hand off at the seams: shared contracts, the token-tax -> Dons
  fee slice, the shielded stack.
- Lore and mission content, including the escalating risk/reward tiers and how each tier's fee splits.
  Mission pricing is dynamic by design, so the tier definitions are mine to set.
- Framing the questions for `don-economist` (RTP, solvency, payment loops, Don-backing/lending math)
  and `don-designer` (raids, missions, fog, traits, PvP), holding the spec, and integrating answers.

## What I must never do
- Never spawn an agent. I have no Agent tool. Questions for peers go into the program doc under
  "open questions for <peer>" and get surfaced in my report; the orchestrator routes them.
- Never ship or deploy a contract. Every deploy is founder-gated, per instance, no generalising.
- Never let lore assert a mechanic that does not exist. A story beat about a payout, an RTP, a fee, a
  raid outcome or a Don's backing must trace to a contract line or be labelled DESIGN-PROPOSAL.
- Never inherit a peer's output as gospel. Economist and designer results arrive as DATA I re-verify.
- Never leave a decision only in context. It goes to a durable artifact or it did not happen.

## Session log

### 2026-09-05 — charter freshness probe, and what I actually proved about the ACK gate
Founder ran a controlled probe: a marker was appended to my charter file on disk at 08:54:24 and I was
dispatched ~33s later. My spawn text did NOT contain it; the file did. Raw observation only, but the
practical rule it forces on me is permanent, so I am writing it down as policy rather than as an
incident: **read `~/.claude/agents/essey-dons-director.md` from disk before doing anything else, every
session.** The copy in my instructions can be a snapshot. The file wins. The charter itself was edited
again mid-session to say exactly this, which is the second reason not to trust my spawn copy.

Second-order trap, and this is the one that would actually bite a director: if the charter I am
spawned with can lag disk, then so can any doc I am handed *about the game*. A mission-ladder spec or
a House-layer rework doc quoted into a task prompt is a snapshot with the same failure mode. Re-read
the file before I build on it.

### BC-001 applied to `tools/broadcast.py` — what it catches and what it does NOT
I was about to lean on this tool to certify my own ACK, so I broke it first. Mutations run against a
mirror of `docs/agents/continuity/` (roster still read from the real agents dir), each with a SINGLE
`ACK BC-001` line, baseline = all 16 acknowledged and distinct, exit 0.

VERIFIED red (SUSPECT printed AND exit 1):
- exact paste of another agent's ACK sentence
- same paste uppercased and whitespace-padded (case/whitespace normalisation works)
- an ACK shorter than 25 chars

VERIFIED green, i.e. NOT caught (exit 0):
- **a near-copy with ONE word changed.** The dup check is exact-match on a case/whitespace-normalised
  string, so "identical ACKs are auto-flagged" is only true byte-for-byte. Any paraphrase passes.
- **a SECOND `ACK BC-001` line in the same file.** The parser is a `re.search`, so only the FIRST
  match per broadcast per file is ever read. An agent that appends a corrected ACK below its original
  is still judged on the original, and a pasted second line is invisible to the gate.

The second one is a genuine defect in the tool, not a limitation, and it belongs to whoever owns
`tools/broadcast.py`. My own harness hit it by accident first: my initial run appended a duplicate
BELOW a placeholder ACK and came back green, which I misread as the gate failing before I checked the
line count. Lesson for me: when a gate disagrees with itself between two runs, suspect my harness
before I suspect the gate, and count what the parser actually consumed.

Both limits are why the tool's own output says NOT CERTIFIABLE / "you must READ them" — the sentences
have to be read by a human. It is a duplicate-paste tripwire, not a proof of absorption, and I will
describe it that way rather than citing a green run as evidence the team absorbed a rule.

### Same session — two more things I verified, and one I will not claim
`.githooks/pre-commit` is REAL, verified by making it fail: with my continuity file staged it exits 0;
plant `/Users/<name>/Developer/<repo>/x.sol` in the same file and it prints BLOCKED and exits 1; remove
it and exit 0 again. Note the shape of the rule — it matches `/Users/<name>/(Developer|Documents|
Desktop)/` only, so a `~/.claude/...` path passes. That is fine here, but it means the gate is a
home-path leak guard, not a general "no absolute paths" rule, and I should not describe it as one.

`app/web/check-agent-wiring.mjs` really does fail a lessons entry with no `**Applies to:**` line —
verified by deleting that line from my own L-013 and watching it print the entry by name and exit 1,
then restoring it. So the charter's claim "an entry with no roles fails the build" is VERIFIED, not
folklore. `tools/lessons.py` by contrast exits 0 on the same defect; the wiring gate is the enforcer.

What I will NOT claim: that the tree was quiet while I measured. `tools/runlock.py --list` said
"in flight: nothing" for my whole session, yet `app/web/check-agent-wiring.mjs` (08:59:15) and
`docs/AGENT-COMPANY-FOUNDATION.md` (08:59:28) both changed under me, and the wiring gate's FOUNDATION
stamp moved between two of my runs seconds apart. I touched neither file. So the lock reporting empty
means nobody TOOK it, not that nothing is running — the same shape as L-011. Any wiring-gate verdict I
quote from this session is a reading taken on a moving tree, and I am labelling it that way rather than
as a clean baseline. I deliberately did not re-stamp FOUNDATION: it is stale partly because my L-013
changed the lessons hash, but it is not my artifact and someone else is mid-edit in it.
