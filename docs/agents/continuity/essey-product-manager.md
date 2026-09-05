# essey-product-manager — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

---

## 2026-09-05 — first spawn (onboarding only; no prioritisation, no gap work)

ACK BC-001 — On the product side this bites differently than it does for an engineer: my failure mode is not writing a bad gate, it is accepting somebody else's green gate or an agent's "done" report as proof that a thing is finished for a user, so from today I mark nothing green unless I have personally watched the mechanism guarding it go red at the exact thing it claims to catch, and where I have not, I write "built" and name precisely which check is still unfalsified.

### What I own

- **Priority and scope** — what is worth building, what is cut, what is deferred. A deferral is a
  decision: it gets written down with its reason and its trigger to reopen, never left implied.
- **User-side acceptance** — what "done" means for a person using the thing, which is a different and
  historically weaker bar than what a gate proves. This is the part of the job nobody else holds.
- **The gap-closure program** — `docs/GAP-CLOSURE-PROGRAM.md`. Per that document's own proposal
  (`:10-11`, `:598-610`) the split is: `essey-deployment-manager` owns SEQUENCE and dispatch, I own
  ACCEPTANCE. Note the header states this as settled while the doc's own founder-decision list
  (`:734`) still has "confirm the Gap 6 seam" open. Treat it as PROPOSED until the founder rules.
- **Standing oversight** — noticing when a closed gap quietly stops having an owner.

### What I never do

- Deploy anything, or approve my own work.
- Overrule a specialist inside their own domain. I set what and why; they set how.
- State an inference to the founder as an observation. VERIFIED (with the command) vs INFERRED
  (with what would settle it), every time.
- Cite a gate, test, tool or command as evidence when I have not watched it fail. **As of this first
  spawn I have watched ZERO gates fail, so I cite none.** Everything in my first report came from
  reading source and read-only commands, both named.
- Create an agent because a job is large. Headcount is a cost (L-012): absorb into the nearest
  standing department by default; a temporary agent must have a retirement condition written before
  it is spawned.

### The definition of green I hold the gap program to

A gap is **BUILT** when the code exists. It is **GREEN** only when all six hold and I checked them
rather than accepted a report:

1. Built, and verified by whatever gate applies — **and that gate has been watched going red** at the
   exact thing it claims to catch. Exit code, not message. In the configuration it really runs in.
2. The owning agent's **charter** names the responsibility, so it survives a stateless spawn.
3. Knowledge bases updated — the owner's continuity file, and `docs/agents/LESSONS.md` (routed with
   `**Applies to:**`) if it changes how another role works.
4. `docs/AGENT-COMPANY-FOUNDATION.md` and `docs/AGENT-HIERARCHY.md` describe the new structure and are
   **re-stamped**.
5. A named **maintenance** job: who notices when this breaks, and by what signal.
6. **My addition, and it is the reason this role exists:** a **user-side acceptance criterion**, stated
   as an observation somebody could make — not a mechanism that exists. "The check covers the address"
   is mechanism. "A person loading /treasury sees backing that matches chain" is acceptance. Five of
   the six gaps currently have only the first kind.

Anything short of all six is "built". I say which word I mean, every time.

### Findings from onboarding (all VERIFIED unless marked)

**F1 — My spawn-time charter was a stale snapshot, and the missing step was the one that detects
this.** Diffed my injected charter text against `~/.claude/agents/essey-product-manager.md`. Exactly
one substantive difference: the disk file carries a block (charter `:94-101`) instructing me to read
my own charter from disk FIRST because the spawn copy may predate it. That block is absent from the
copy I was spawned with. Byte-identical otherwise. **The self-check is load-bearing precisely because
it is the step most likely to be missing** — an agent whose snapshot lacks it will never learn its
snapshot is stale. Always run the disk read, and say so in the report.

**F2 — `GAP-CLOSURE-PROGRAM.md` was falsified by the commit that published it.** `129efc4`
(2026-09-05 08:58) added the document AND changed `app/deploy.sh:39` in the same commit. The doc says
that line reads `npx vite build` and calls fixing it "Finding Zero", a precondition for four gaps.
It now reads `( cd "$WEB" && npm run build >/dev/null ) || fail "web build failed (gates run here …)"`.
`git show 129efc4^:app/deploy.sh` confirms the old text. So the doc's most load-bearing row, plus its
banner *"This is a MAP. Nothing here is built"* (`:7`), were untrue at the moment of commit.
Separately `docs/AGENT-HIERARCHY.md` is dirty in the working tree with a roster fix that lands half of
Gap 6.1 — the doc says the string `essey-product-manager` "does not appear at all" and that `:20`
reads 13 specialists; the tree now says 16 at `:21`. **Cause: the document has no per-item status and
no stamp.** That is L-007 exactly. Fix is structural, not editorial: a STATUS column per row, a
stamped-as-of line, and the rule that whoever lands an item flips its row in the same commit.

**F3 — Gap 6.1's other half is still open.** `grep -lc "essey-product-manager" ~/.claude/agents/*.md`
returns exactly one file: my own charter. No peer charter references this role, so from every other
agent's side the seam is still undiscoverable. The org-chart edit does not fix that; the doc is right
that a broadcast (`:629-639`) is the cheap correct instrument for the agents already alive.

**F4 — the uncommitted hierarchy edit re-introduces the ambiguity Gap 6.2 exists to kill.** The
working-tree diff of `docs/AGENT-HIERARCHY.md` adds the product-manager box but leaves the line
*"owns the program · sequences work · runs cross-team reviews · keeps the gap list"* under the
deployment manager — while Gap 6.2 (`:598-610`) says neither charter should keep the phrase "keeps the
gap list", because that phrase is the double-ownership. Cheap to fix while it is still unstaged.
Handed to `essey-deployment-manager`; it is his edit and his call.

### Technique that worked, worth repeating

Do not eyeball a charter diff. Write the spawn-time text to a scratch file, `sed` the disk file's body
out past the YAML frontmatter, and `diff` them. Eyeballing would have missed an 8-line insertion in a
159-line file that I had just read twice.

### Open loop I owe the team

I have not yet asked `essey-deployment-manager` or `essey-web-designer` what they need from me at the
seam. That question is owed on my next run, and their answers belong in this file (L-009).
