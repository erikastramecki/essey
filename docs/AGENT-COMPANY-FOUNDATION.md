# Building a team of AI agents that actually gets better

**A portable blueprint.** Everything here was built at Essey between 2026-08 and 2026-09-05 and is
running in production. It is written to be handed to someone starting from zero, so it explains the
failures that produced each piece rather than just the final shape. Copy it, ignore the parts that
do not fit your work, and skip the month we spent learning it.

Nothing below is theoretical. Every mechanism exists because something broke first.

---

## The one premise everything follows from

**Sub-agents spawn stateless.** Every time you dispatch one, it starts from its definition file with
no memory of anything that has ever happened. It does not remember yesterday's incident, the
correction you gave it last week, or the trap it personally fell into twice.

That single fact has a consequence most teams miss for a long time:

> **A lesson that is not written into a file the agent reads at startup was not learned. It was
> experienced and discarded.**

You will feel like the team is learning, because *you* are learning. You are the only continuous
thread in the system, so your improving judgment reads as the team improving. It is not.

**The diagnostic that proved it for us:** we had 15 agents. Exactly one — the writer — had a charter
line saying *"You spawn stateless, so this file IS your continuity"* and naming a file to write back
to. That agent's file had grown to 20 sections, and it added two of them without being asked. The
other 14 had nothing. Guess which agent visibly got better over a month.

**Try this on your own setup right now:** grep your agent definitions for any reference to a file the
agent is told to *write* to. If the answer is none, your agents are not learning, however good they
seem. Ours were not.

---

## The four failures, and what each one forced us to build

This is the who/what/when/where/why. Each mechanism below is the scar tissue from a specific day.

### Failure 1 — Every lesson died at exit

**What happened:** Over one 24-hour period we found twelve separate instances of the same bug shape —
a check whose failure branch was unreachable. A test whose name claimed one thing and whose assertion
tested another. A gate that printed `BLOCKED` and exited `0`. A mock returning a data shape the real
chain never returns. Each one got diagnosed, discussed, and fixed. **None of it was written anywhere
an agent would read.** The lessons lived in the coordinator's memory directory, which sub-agents
cannot read, and in commit messages nobody opens at dispatch time.

**Why it matters:** the same class of bug kept reappearing from different agents, and every
recurrence cost a fresh diagnosis at full price.

→ Built: **per-agent continuity files** and a **shared lessons file**.

### Failure 2 — Sharing everything is as bad as sharing nothing

**What we nearly did:** dump every lesson into one file every agent reads. This is the obvious fix
and it is wrong. An agent reading 40 lessons, 35 of which belong to other roles, pays attention for
all 40 and starts drifting toward work that is not its own. The founder's framing was the correct
one:

> *"Shared lessons that matter, skill sets adopted from each other that makes sense to each other's
> role, just like normal hierarchy within the workplace. Part of the skill that you like from your
> peers that fit your role so you can do your role better. I don't want bleed over."*

You adopt a technique from a peer because it makes you better at **your** job. You do not go do their
job. The security auditor should inherit "prove your probe can fail." It should never inherit the
writer's rules about tone.

→ Built: **role-routed lessons**. Written once, tagged with the roles it applies to, filtered at
read time.

### Failure 3 — Two runs on one tree, and nothing stopped it

**What happened:** two verification runs executed against the same working directory, overlapping by
about 46 minutes. Each run mutated source files and restored them; each run's restore reverted the
other's mutation mid-flight. Results were silently false in both directions — mutations un-applied
and scored as survived, mutations stacked and scored as killed. One was left applied in the source
afterward. **Three runs that day produced no evidence at all.**

Then it got worse. One agent rebuilt an isolated copy to redo the work, but copied the tree *while a
mutation was applied* — so the hash it recorded as its "clean baseline" was byte-identical to the
corrupted file. Every subsequent result would have been measured against a reference with the safety
feature already deleted.

**The part that determines the fix:** the duplicate run was started by **the coordinator**, not by an
agent. A rule in the agent charters would have done nothing. The constraint has to live at the
resource, where it binds whoever touches it.

→ Built: **a lock and an in-flight registry**.

### Failure 4 — Every one of those rules was still just prose

Continuity files, routed lessons, a lock — all of it is text in a file until something fails when it
is missing. We have a standing rule about this, learned the hard way:

> **A rule without a mechanism is not a rule. It is a note, and it will be skipped.**

→ Built: **a build gate** that fails when the wiring has drifted.

---

## The structure

### The org

The shape matters less than that it exists and that seams are explicit. Ours:

```
      PROGRAM MANAGER  ·  PRODUCT MANAGER          (peers: WHEN it ships · WHAT ships and why)
   ┌────────────────┬──────────────────┬────────────────────┬──────────────┐
   BUILD & QUALITY   PRODUCT            ECONOMY & DESIGN      COMMUNICATION
   engineer          brand designer     economist             writer
   auditor   (gate)  web designer       game designer         social
   zk auditor(gate)  researcher         launch economist
   harness   (E2E)   legal advisor
                            GAME DIRECTOR  (peer of the PM, not under it)
```

Three properties worth copying:

1. **The gate roles are separate agents from the build roles.** The engineer never approves its own
   work. The auditor does not write the fix. This is not distrust — an agent reviewing its own output
   is measuring the same blind spot twice.
2. **A program manager owns sequence, not correctness.** It decides what runs when and what is
   blocked on whom. It does not overrule the specialist inside the specialist's domain.
3. **Two program owners as peers** (protocol and game) rather than one over the other, because they
   have genuinely different clocks.
4. **Program and product are split.** One owns *when* a thing ships and which gate it is behind; the
   other owns *what* is worth building and what "done" means for a person rather than for a gate.
   Collapsing them is the default and it hides the second question entirely — the founder holds it
   personally until somebody is named, which works exactly as long as the founder scales.

### Growing the org: absorb by default, and let temporary agents retire

The tempting move when a gap appears is to create an agent for it. Do that five times and you have a
roster nobody can hold in their head, where every job is somebody's and no department is coherent.

Treat permanent headcount as a cost that has to be earned. The argument for a new standing agent is
that the work needs a **fundamentally different mode of reasoning** from anything an existing
department holds — not that it is a lot of work. Otherwise the gap is absorbed by whichever
department already owns the nearest thing.

Where a fix genuinely needs focused specialist capacity, the pattern that works is a **temporary
agent that retires**:

1. Spin it up to scope and build the fix.
2. When the work lands, ownership transfers to a **standing** agent — normally an existing one — who
   will hold it forever.
3. The temporary charter is deleted and the roster shrinks back.

So every gap answers two separate questions, and they often have different answers: **who builds
this**, and **who owns it afterwards**. A temporary agent left running is a headcount increase nobody
decided on.

### The two knowledge surfaces, and why they are separate

| | **Continuity** (private) | **Lessons** (shared) |
|---|---|---|
| Path | `docs/agents/continuity/<agent>.md` | `docs/agents/LESSONS.md` |
| Who reads it | only that agent | any agent the entry is tagged for |
| What goes in | what *you* got wrong, what worked for *your* job | anything that would change how a **different** role works |
| Cost to others | none | one filtered read |

The split is the whole design. Without the private file, every small lesson gets pushed into the
shared one and it becomes unreadable. Without the shared file, craft never crosses roles.

**Routing format** — the tag line is machine-parsed, so it is enforceable:

```markdown
### L-001 — A probe must be shown producing a NEGATIVE result before its positive counts
**Applies to:** all
**Origin:** 2026-09-05 · engineer
**The trap:** three checks returned green the same day, and green was the only answer any of
them could have given. A page could not show a token it never queried. A style gate globbed
*.ts only, so every .mjs gate in the repo was exempt. A grep cleared a file using a string the
bug did not contain.
**Apply:** before trusting any check, break the exact thing it claims to catch and watch it go
red. A check you have never seen fail is a decoration.
```

`**Applies to:** all` is the universal tag. Everything else routes.

An agent reads its slice with one command:

```bash
python3 tools/lessons.py --role <agent-name>
```

**Verify the routing by difference, not by whether it runs.** Our check: the engineer's slice
contains the tree-corruption lessons and the writer's does not; the writer's slice contains the
publishing lessons and the engineer's does not; both contain the universals. If every agent sees the
same list, you have built a mailing list, not a router.

---

## The mechanisms

### 1. Continuity file per agent

One file per agent, and the charter must say what it is in words that make it non-optional:

> `docs/agents/continuity/<name>.md` is your living file. **You spawn stateless, so this file IS your
> continuity.** Read it before you start. Append to it when you finish.

That exact sentence is the one that worked. Wire the read into the charter's opening instructions and
the write into its closing ones.

### 2. Role-routed lessons

Covered above. The only subtlety: an entry needs both a **trap** (what went wrong, concretely) and an
**apply** (what to do differently). An entry with only a trap is a war story, and people skim it.

### 3. A lock on anything that mutates a shared tree

Use `flock`. Not a pidfile, not a "check if running" helper — the kernel releases a `flock` when the
holder dies, so a crashed job cannot wedge the resource and there is no stale-lock logic to get wrong.

Non-negotiable behaviours:

- **Refuse, do not queue.** A second verification run is never what anyone wanted.
- **Name the holder** — pid, who, when, and the command to stop it. "Resource busy" makes people
  work around the lock; naming the holder makes them stop it.
- **Bind everyone, including the orchestrator.** Ours broke because the coordinator started the
  duplicate.

```bash
python3 tools/runlock.py --list     # what is in flight, right now
```

**Verify it by watching it block**, and check the *exit code* rather than the message. We had already
shipped a gate that printed `BLOCKED` and exited `0`, because it ran inside a pipeline and the
subshell swallowed the failure flag. A gate is not a gate until you have watched it stop something.

### 4. Broadcasts — proving a team-wide rule was absorbed, not merely published

Writing a rule into every charter feels like done. It is not: agents spawn stateless, so a rule in a
charter nobody has been dispatched with has reached nobody. We measured this — at the moment a rule
was declared pushed to sixteen charters, **zero agents had read it.**

So a team-wide rule gets an id in `docs/agents/BROADCASTS.md`, and each agent acknowledges it in its
own continuity file **in its own words about its own role**. `tools/broadcast.py` prints the
sentences rather than counting them and exits non-zero while anyone is pending.

Three things that make it more than a checkbox, each of which we got wrong first:

- **Parse every acknowledgement line, not the first.** Reading only the first made a corrected ACK a
  silent no-op and let a pasted second line hide from duplicate detection entirely.
- **Derive the roster from the CHARTERS, not from who has a continuity file.** Otherwise a new agent
  is *absent* rather than *pending*, and the tool reports complete while agents have never seen it.
- **Flag identical and near-empty ACKs.** One sentence pasted into every file otherwise scores 100%.

And its honest limit, which belongs in the tool's own output: it is a duplicate-paste tripwire, not
evidence of comprehension. A paraphrased paste sails through. **Certification is a human reading the
sentences**, which is why the tool prints them.

**The sharpest one, now measured rather than suspected.** Agents reported that the charter text
injected at spawn predated the file on disk. We tested it directly: planted a unique marker in a
charter at a known time, dispatched that agent 33 seconds later, and asked whether the marker was in
its spawn text. **It was not** — while `grep` found it in the file the agent could read. Edits made
earlier in the same session *had* propagated, so the spawn copy is a snapshot with lag, not simply
frozen. The same agent then watched its charter change on disk again mid-session.

**The consequence is structural: a rule pushed mid-session may reach nobody, and every mechanism
above would still report success.** You cannot fix this from inside the charter, because a stale
charter cannot carry the instruction that would fix it.

Two mitigations, and you need both:
- Every charter instructs the agent to `cat` its own charter file from disk *first*, and to treat the
  FILE as authoritative when the two disagree. This helps on the next dispatch, not this one.
- **The dispatching orchestrator repeats that instruction in the task prompt itself.** The task is
  the only channel guaranteed fresh, so it is where a new rule actually lands today.

If you build this, run the marker probe on your own platform before trusting any broadcast count.

### 5. A wiring gate in the build

Fails the build on: a lesson with no `Applies to:` line, a charter missing the knowledge-base block, a
charter that does not read its own slice, or a missing continuity file.

**Be honest about its limit.** It checks the *wiring*, which is falsifiable. It cannot check that an
agent read or understood anything. Do not let a passing gate feel like a working culture.

---

## The culture layer, which is not decoration

Structure gets you consistency. It does not get you an agent that volunteers the finding it is only
70% sure about — and those are the findings that matter most, because they are the ones somebody
almost did not mention.

Three requirements, wired into **every** charter rather than living in a document:

### Correct in a way that inspires loyalty, not compliance

> *"Management and leadership are two different things. When you lead people, you can get really
> great results by pushing them to explore themselves and take initiative and go above and beyond,
> even if it risks maybe a little bit more failure to get there, because your progression knowledge
> curve is gonna be really high."*

An agent corrected bluntly enough, often enough, optimises for not being wrong. It stops reaching. It
reports only what is safe. That is a far more expensive failure than the occasional overreach.

In practice: name what they got right first and mean it. Go at the artifact, never the agent. Say
what the correction buys. When a peer catches **you**, say so plainly and credit them — that is what
makes the next catch likely. And if you are correcting the same peer twice for the same thing, ask
whether the **structure** failed rather than the peer.

### Hand off deliberately — finishing your task is not finishing your job

> *"If you're a UI/UX front-end engineer and you could go above and beyond and check a few more extra
> things that would make it so engineering has an easier path, and share that knowledge base, then
> engineering can be more efficient."*

Before reporting, name who touches this next and what their role actually needs. Go one step past
your own finish line for them. Every report states: **what is ready, what is sharp or half-finished,
and what you would look at first in their shoes.**

### Seek feedback at the seam, continuously

Ask the peers you hand work to what you could do differently at the interface, and record what they
say in your continuity file. This is a requirement of the role, not a courtesy. It is the only
mechanism that improves the *seams*, and seams are where multi-agent systems actually fail.

> **It matters more how you do it than what you do.**

---

## Build it yourself, from zero

1. **Audit what you have.** Grep your agent definitions for any file they are told to write to. If
   nothing, none of them are learning. Start there.
2. **Create `docs/agents/continuity/<name>.md` per agent.** One line of seed content is enough.
3. **Create the shared lessons file.** Seed it from your last month of incidents — you already have
   them, in postmortems and commit messages. Tag each with the roles it applies to.
4. **Write the reader** (~40 lines): parse the entries, filter by `--role`, print the matches.
5. **Wire every charter**: read your continuity file and your lessons slice at start; append to one or
   both at finish; check the in-flight registry before starting anything long.
6. **Add the lock** to any job that mutates a shared working tree.
7. **Add the wiring gate to your build**, and then **break each of its branches on purpose** and watch
   it fail before you trust it.
8. **Add the culture requirements to every charter**, not to a document. A charter is read at every
   dispatch. A document is read once.

Steps 1–7 took an afternoon. Step 8 is the one that decides whether the rest compounds.

---

## What this does not solve

Stated plainly, because a structure oversold is worse than no structure:

- **The wiring is enforced; the reading is not.** Nothing verifies an agent actually read its slice.
- **A lesson can be tagged to the wrong roles** and every check still passes.
- **If charters live outside your repo**, the gate can pass locally while the charters differ
  elsewhere.
- **It is new.** As of this writing the structure is one day old. It has not yet been proven to stop a
  repeat of anything.

The correct posture is that this makes the failures *visible and expensive to repeat*, not
impossible. That is worth a great deal, and it is less than it sounds like.

---

*Built at Essey. The failures are real, the quotes are the founder's, and the mechanisms are running.
If you build this and find where it breaks, that is the next lesson — write it down where the next
person reads it.*



---

## Keeping this document true

A blueprint that drifts from the thing it describes is worse than none, because people trust it. So
this file is **gated, not maintained by discipline.**

`check-agent-wiring.mjs` computes a fingerprint over the live structure — the agent roster, every
lesson ID with its routing tags, and the mechanism files that must exist — and compares it to the
stamp at the bottom of this file. **Any organisational, leadership, or lesson change fails the build
until this document is reconciled.**

```bash
node app/web/check-agent-wiring.mjs           # fails if this doc is stale, naming the drift
node app/web/check-agent-wiring.mjs --stamp   # re-stamp AFTER you have updated the prose
```

Two deliberate choices:

- **It never auto-updates.** Silently regenerating the stamp is the obvious convenience and it
  defeats the purpose: the hash would track reality while the prose rotted, and the gate would stay
  green over a lie. Drift must cost a human read.
- **It fails the build, not a linter.** Nothing ships while the blueprint describes a structure that
  no longer exists.

**On agents saving their memory.** The failure to design against is *"the agent didn't save, so the
master doc is out of date."* Three things make that unavailable as an excuse:

1. **Charters require the continuity write BEFORE the report**, not after — saving last is saving
   skipped, and it is skipped hardest on the longest, most eventful runs.
2. **Long jobs checkpoint mid-run**, after each significant finding.
3. **The gate prints every agent that has never written to its continuity file.** An empty file after
   real work is visible rather than assumed.

The honest limit remains: the write is enforced by instruction, not by a lock. The *visibility* of a
missing write is what is mechanised. Whoever orchestrates the team should treat "agent completed but
its continuity file did not change" as unfinished work and send it back.

<!-- STRUCTURE-FINGERPRINT: f5d0600ab689eb3d -->
