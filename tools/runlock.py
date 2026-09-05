"""Exclusive lock + in-flight registry for long jobs that mutate the working tree.

2026-09-05: two mutation-gate runs overlapped by ~46 minutes on the same tree. Each run's restore
reverted the other's mutant mid-flight, so mutants were silently un-applied (false SURVIVED) or
stacked (false KILLED), and one was stranded live in the tree afterwards. Three runs that day were
void. Nothing prevented it — the driver had no lock, so a second run was not discouraged, it was
ordinary. The coordinator started the duplicate, so a rule aimed at agents would not have helped.

flock is the primitive on purpose: the kernel releases it when the holder dies, so a crashed run
cannot wedge the resource and there is no stale-pidfile logic to get wrong.
"""

import datetime
import fcntl
import json
import os
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
RUNS = REPO / ".runs"


def _meta(resource, owner, detail):
    return {
        "resource": resource,
        "owner": owner,
        "detail": detail,
        "pid": os.getpid(),
        "started": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    }


class Held(Exception):
    """Raised when another run already holds the resource. Carries the holder's registry entry."""

    def __init__(self, holder):
        self.holder = holder
        super().__init__(f"resource held by pid {holder.get('pid')}")


class RunLock:
    """Exclusive, non-blocking. Refuses rather than queues: a second gate run is never what was wanted."""

    def __init__(self, resource, owner, detail=""):
        self.resource, self.owner, self.detail = resource, owner, detail
        RUNS.mkdir(exist_ok=True)
        self.path = RUNS / f"{resource}.lock"

    def __enter__(self):
        self.fh = open(self.path, "a+")
        try:
            fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.fh.seek(0)
            try:
                holder = json.loads(self.fh.read() or "{}")
            except json.JSONDecodeError:
                holder = {}
            self.fh.close()
            raise Held(holder) from None
        self.fh.seek(0)
        self.fh.truncate()
        json.dump(_meta(self.resource, self.owner, self.detail), self.fh)
        self.fh.flush()
        return self

    def __exit__(self, *exc):
        self.fh.seek(0)
        self.fh.truncate()
        self.fh.flush()
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()
        return False


def inflight():
    """Registry read. A lock file whose flock is free is a finished run, not a live one."""
    live = []
    for p in sorted(RUNS.glob("*.lock")) if RUNS.exists() else []:
        with open(p, "a+") as fh:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fh, fcntl.LOCK_UN)
            except BlockingIOError:
                fh.seek(0)
                try:
                    live.append(json.loads(fh.read() or "{}"))
                except json.JSONDecodeError:
                    live.append({"resource": p.stem, "pid": "?"})
    return live


def guard(resource, owner, detail=""):
    """Entry point for a script: acquire or exit 2 naming the holder and how to stop it."""
    try:
        return RunLock(resource, owner, detail).__enter__()
    except Held as h:
        print(
            f"BLOCKED: '{resource}' is already running.\n"
            f"  holder : pid {h.holder.get('pid')} ({h.holder.get('owner', 'unknown')})\n"
            f"  started: {h.holder.get('started', '?')}\n"
            f"  detail : {h.holder.get('detail', '')}\n"
            f"  Two runs on one tree void BOTH results. Stop the holder first:\n"
            f"    kill {h.holder.get('pid')}   # then re-run\n"
            f"  See what is in flight: python3 tools/runlock.py --list",
            file=sys.stderr,
        )
        sys.exit(2)


if __name__ == "__main__":
    runs = inflight()
    if not runs:
        print("in flight: nothing")
    for r in runs:
        print(f"in flight: {r.get('resource')}  pid {r.get('pid')}  {r.get('owner')}  since {r.get('started')}")
        if r.get("detail"):
            print(f"           {r['detail']}")
