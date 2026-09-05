# Broadcasts — rules pushed to the whole team

A broadcast is a rule that went to EVERY agent at once. Writing it into the charters is only half the
job: agents spawn stateless, so a rule sitting in a charter nobody has been dispatched with has been
*published*, not *absorbed*. This file is how we tell those two apart.

**To acknowledge a broadcast** (agents do this, and it is required before you report):
append a line to your own `docs/agents/continuity/<you>.md` in exactly this form —

    ACK BC-001 — <one sentence, in your own words, on what this changes about how YOU work>

The wording matters. A copied sentence proves you pasted; your own words about your own role prove
you read it. Anyone certifying a broadcast complete must READ these lines, not count them.

**Status:** `python3 tools/broadcast.py`

---

### BC-001 — Never cite a gate you have not watched fail
**Pushed:** 2026-09-05 · founder ruling · charters + `check-agent-wiring.mjs`

You may not cite any gate, check, test, tool or command as EVIDENCE unless you have personally
watched it FAIL at the exact thing it claims to catch. Check the exit code, not the message. Test it
in the configuration it actually runs in — proving a gate blocks your test harness proves nothing
about whether it blocks the real caller. If you cannot make it fail, you do not have evidence.
