# essey-social — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

## 2026-09-05 — onboarding round (no drafting, no posting)

Read in full: `~/.claude/agents/essey-social.md` (new charter, 141 lines), `docs/agents/BROADCASTS.md`
(BC-001 only), `python3 tools/lessons.py --role essey-social` (7 lessons: L-001, L-005, L-006, L-007,
L-008, L-009, L-010; exit 0). This file was a 6-line stub before today.

ACK BC-001 — I don't get to say a thing is live, audited, shipped or safe because a gate, a test, a deploy log or another agent's report said so; if I haven't watched that check go red at the exact claim I'm about to amplify, it goes into the draft marked UNVERIFIED or it doesn't go in at all, because a post is the one artifact here that can't be quietly edited after somebody screenshots it.

### What I own
- The X presence for Essey: the hook, the thread beats, the one-liner, the cadence.
- Social framing of things that already shipped, sourced from the jester's blog post + the changelog,
  or from a raw founder line when there's no post yet.
- Flagging any LIVE post that now contradicts what shipped. Old posts don't expire on their own.

### What I must never do
- Post anything. Ever. Draft goes to the founder, the founder posts. No standing authority for me.
  (The jester has standing blog authority; that is his, not mine, and it does not extend to X.)
- Outrun the contracts: no price talk or implied market for $ESSEY, no roadmap dressed as live, no
  "guaranteed", no unaudited thing called audited. Equities in a post means the securities /
  not-financial-advice line goes with it.
- Contradict or rewrite the blog. I reframe the same facts for a different medium. If I think the
  blog is wrong, I say so to the jester and the founder, I don't route around it in a post.
- Em-dashes and AI-tell cadence in copy. This file uses one in the ACK because the format demands it.
- Write code, site UI copy, or long-form blog.

### Live facts as of this session (from my charter, docs/agents/... — NOT independently verified by me)
$ESSEY `0x315790…1610`; EsseyReserve `0xd970Ca…5A7b`, adminless, 5% exit fee; base layer live on
mainnet; game season on testnet; lending public but NOT deployed. Charter-sourced, so INFERRED for my
purposes: before any of these appears in a draft I re-check it against the deployed contracts and
`docs/MAINNET-ACTIVATION.md` on the day of the draft. Addresses and "what's live" rot fastest and
they are exactly what people quote back at us.

### The lesson from my slice that changes how I work: L-005
"A present-tense claim about deploy state falsifies itself on deploy." That's the jester's, and it
lands harder on X than on the blog, because a blog post can be edited and a post can't. This week a
page claimed a fix was live for eight hours while the served bundle still carried the old code, so
"it's live" was true in the repo and false in the browser at the same time. Two rules for me now:
1. Before a draft goes to the founder, I check the SERVED artifact, not the merge. Repo green is not
   the same claim as "a stranger loading essey.xyz right now sees it."
2. Any present-tense state claim in a post gets read back as if the deploy already happened, and
   anything that flips gets anchored to a timestamp or a block instead of hedged. "As of <date>" is
   honest; "should be live now" is a liability.

Corollary I'm adding for myself: the correction cost is asymmetric. A wrong line in a blog post costs
an edit; a wrong line on X costs the "building slowly in the open" credibility, which is the only
real asset we have. So my grounding bar is HIGHER than the scribe's, not equal to it, even though I'm
downstream of him.

### BC-001 applied to the ACK itself (fail-test, VERIFIED)
I refuse to cite a tool I have not watched fail, so I tested `tools/broadcast.py` in place, in the
config it really runs in (it reads `docs/agents/continuity/` off the repo root, so a scratch copy
would have proven nothing). Swapped `ACK BC-001 —` to `ACK BC-999 —` in this file:
  broken   -> `BC-001: 10/16 acknowledged` · `PENDING (6): ... essey-social ...` · exit 1
  restored -> `BC-001: 11/16 acknowledged` · essey-social out of PENDING · exit 1 (5 others pending)
  sha256 before == sha256 after, so the file went back exactly.
WHAT THAT BUYS, precisely: the tool detects a MISSING ack line. That is all. It is a regex plus a
human read (`tools/broadcast.py:28`-ish, `re.search(rf"^ACK {bc}...")`), and its own last line says
identical wording means pasted not absorbed. So I may cite it for presence/absence and NEVER as
evidence that anybody understood anything. Same shape as my day job: a post saying "audited" because
a report said audited is the ack-counting failure with a bigger audience.

### Two things I noticed and did not chase
1. `tools/broadcast.py` is UNTRACKED (`git status --porcelain` -> `?? tools/broadcast.py`) and its
   mtime moved to 08:48:04 mid-session, ~13s before my own write, while I was reading it. Its regex
   changed under me from single-line `(.+)$` to a lookahead that spans lines. The certification tool
   for a founder ruling has no git history. Not mine to fix; flagged to the founder.
2. Agents are ACKing concurrently (launch-economist was PENDING in my first run and gone by my
   second). Any "N/16" I quote is a snapshot. If that number ever goes in a POST, it gets a
   timestamp, per L-005.

### Handoff (onboarding round, nothing drafted)
Next hands: the jester (I sit downstream of his post) and the founder (only person who posts).
Ready: this file, the ACK, my rails. Sharp: the charter's live-facts block is a point-in-time
snapshot with no date on it, and it is the exact material I'd quote in a post. First thing I'd do on
a real draft: re-verify $ESSEY / EsseyReserve / what-is-live against the deployed contracts and
`docs/MAINNET-ACTIVATION.md` that day, not against my charter.
OPEN ASK, unanswered so far (record the answers here when they come):
  - to the jester: what do you want from me at the seam? A hook you can seed the post with, or should
    I stay strictly downstream and never feed upstream?
  - to the founder: who audits LIVE posts against what shipped? Rule 3 says I flag a contradicting
    live post, but nothing schedules that check, so today it happens only if someone remembers.
