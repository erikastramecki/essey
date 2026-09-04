#!/usr/bin/env python3
"""Adversarial mutation gate for the G-LEND round-4 fix, extended by round 5.

Round 4's central finding was a test that PERFORMED the bypass it was named to prevent and asserted
the result, and the sweep that caught it from the other direction was mutating PRICE_CONFIRM_DELAY to
one second and finding 1,748 of 1,751 still green. So the magnitude of every constant this fix rests
on is mutated here in BOTH directions, along with every guard removed and inverted.

    python3 test/mutants/glend-r4.py     # from rh-chain/, tree must be clean of other edits

Every mutant is applied to the real tree, the targeted suites are run, and the tree is restored.
A mutant that leaves the suite GREEN is a SURVIVOR and is reported as a gap, not hidden.

Round 5 added M25-M31. M25/M26 because the test NAMED for MULTIPLIER_READ_GAS passed with the budget
cut to 5,000 — below what the deployed AAPL token needs, which would stop every borrow and every
liquidation on every market. M27-M31 for the delay line's new clock, which now ages on wall time
rather than on feed availability: never ageing, splitting the pair, outrunning the rate limit,
seeding a zero pair, and never advancing are each mutated.

Round 6 added M32-M37, and two of them were SURVIVORS found by the auditor rather than by this file.
M32 replaces the warm push's source with the last raw read — the natural simplification, which is not
equivalent because `_syncPrice` writes `seenPrice` unconditionally while `_confirmable` is
rate-limited. M33 widens MULTIPLIER_READ_GAS instead of narrowing it, which is the direction the
constant exists for; R5 mutated it downward only, and half a pin is not a pin. M34-M37 are the warm
ceiling that closes R6 MED-1, removed, inverted, at its boundary, and against a different constant.

Round 7 added M38-M41, the third and fourth instances of one rule: a call forwarding two sibling
values needs each argument mutated INDEPENDENTLY, against every source the wrong value could come
from. M32 swapped both halves of the warmed pair at once and left the one-half variants unattacked,
and the multiplier-only variant then survived 397/397 (R7 LOW-2) — because the test named for the
matched pair mocks the split AFTER the feed is dark, and a dark feed is exactly when `seenMultiplier`
cannot advance, so the two values are equal by construction there. M40 is the same gap against the
READ slot rather than the raw read, and it survived 398/398 including the test written for M38,
because every fixture in the suite left the ring's five MULTIPLIERS identical while varying prices.
"""
import signal, subprocess, sys, pathlib

# resolve the repo from this file, never the caller's cwd (lesson of 9b6d047)
ROOT = pathlib.Path(__file__).resolve().parents[2]
MARKETS = ROOT / "src/EsseyMarkets.sol"
LIVENESS = ROOT / "src/LivenessOracle.sol"
SELECT = "DesyncStateMachine|DesyncBreaker|GLendR4|GLendR5|GLendR6|GLendR7|LivenessOracleTest|EsseyPoolTest|EsseyMarketsTest"

MUTANTS = [
    # --- the magnitude of the safety constant, in BOTH directions ---
    ("M1  PRICE_CONFIRM_DELAY 6h -> 1 second", MARKETS,
     "uint256 public constant PRICE_CONFIRM_DELAY = 6 hours;",
     "uint256 public constant PRICE_CONFIRM_DELAY = 1 seconds;"),
    ("M2  PRICE_CONFIRM_DELAY 6h -> 1 hour (the old value)", MARKETS,
     "uint256 public constant PRICE_CONFIRM_DELAY = 6 hours;",
     "uint256 public constant PRICE_CONFIRM_DELAY = 1 hours;"),
    ("M3  PRICE_CONFIRM_DELAY 6h -> 24 hours (the other direction)", MARKETS,
     "uint256 public constant PRICE_CONFIRM_DELAY = 6 hours;",
     "uint256 public constant PRICE_CONFIRM_DELAY = 24 hours;"),
    # --- the age gate, removed and inverted and at the boundary ---
    ("M4  drop the age floor from corroboratedValue", MARKETS,
     "        if (age < PRICE_CONFIRM_DELAY || age > MAX_CONFIRM_AGE) return (0, false);",
     "        if (age > MAX_CONFIRM_AGE) return (0, false);"),
    ("M5  drop the age CEILING (R4 HIGH-2's fail-closed)", MARKETS,
     "        if (age < PRICE_CONFIRM_DELAY || age > MAX_CONFIRM_AGE) return (0, false);",
     "        if (age < PRICE_CONFIRM_DELAY) return (0, false);"),
    ("M6  floor comparison < -> <= (boundary)", MARKETS,
     "        if (age < PRICE_CONFIRM_DELAY || age > MAX_CONFIRM_AGE) return (0, false);",
     "        if (age <= PRICE_CONFIRM_DELAY || age > MAX_CONFIRM_AGE) return (0, false);"),
    ("M7  floor comparison inverted", MARKETS,
     "        if (age < PRICE_CONFIRM_DELAY || age > MAX_CONFIRM_AGE) return (0, false);",
     "        if (age > PRICE_CONFIRM_DELAY || age > MAX_CONFIRM_AGE) return (0, false);"),
    # --- the delay line itself ---
    ("M8  read the NEWEST slot instead of the oldest", MARKETS,
     "        return _confirmRing[token][(_confirmHead[token] + 1) % CONFIRM_SLOTS];",
     "        return _confirmRing[token][_confirmHead[token]];"),
    ("M9  drop the push rate limit (push every observation)", MARKETS,
     "        if (block.timestamp - last < CONFIRM_STEP) return;",
     "        if (false) return;"),
    ("M10 CONFIRM_SLOTS 5 -> 2 (a two-stage pipeline)", MARKETS,
     "    uint256 internal constant CONFIRM_SLOTS = 5;",
     "    uint256 internal constant CONFIRM_SLOTS = 2;"),
    ("M11 CONFIRM_SLOTS 5 -> 9 (the other direction)", MARKETS,
     "    uint256 internal constant CONFIRM_SLOTS = 5;",
     "    uint256 internal constant CONFIRM_SLOTS = 9;"),
    ("M12 push the PREVIOUS observation's stamp, not this one's", MARKETS,
     "        _confirmRing[token][head] = Observation(price, mult, block.timestamp);",
     "        _confirmRing[token][head] = Observation(price, mult, block.timestamp - CONFIRM_STEP);"),
    ("M22 push spacing < -> <= (boundary)", MARKETS,
     "        if (block.timestamp - last < CONFIRM_STEP) return;",
     "        if (block.timestamp - last <= CONFIRM_STEP) return;"),
    ("M23 skip the first-observation seed (leave holes in the ring)", MARKETS,
     "        if (last == 0) return _seedConfirmRing(token, price, mult);",
     "        if (last == 0) { _confirmRing[token][0] = Observation(price, mult, block.timestamp); return; }"),
    ("M24 seed the ring at zero time (a fresh market corroborated instantly)", MARKETS,
     "            _confirmRing[token][i] = Observation(price, mult, block.timestamp);",
     "            _confirmRing[token][i] = Observation(price, mult, block.timestamp - PRICE_CONFIRM_DELAY);"),
    # --- MED-1: the observation pair ---
    ("M13 write seenMultiplier unconditionally (the R4 MED-1 bug)", MARKETS,
     "        if (_syncPrice(token, prev, cur)) seenMultiplier[token] = cur;",
     "        _syncPrice(token, prev, cur);\n        seenMultiplier[token] = cur;"),
    # --- MED-3: the guardian's levers ---
    ("M14 give admin pauseLiquidation back", MARKETS,
     "        if (msg.sender != guardian) revert NotAdmin();\n        uint256 ceiling = block.timestamp + MAX_LIQUIDATION_PAUSE;",
     "        if (msg.sender != admin && msg.sender != guardian) revert NotAdmin();\n        uint256 ceiling = block.timestamp + MAX_LIQUIDATION_PAUSE;"),
    ("M15 give admin disableMarket back", MARKETS,
     "        if (msg.sender != guardian) revert NotAdmin();\n        _markets[token].enabled = false;",
     "        if (msg.sender != admin && msg.sender != guardian) revert NotAdmin();\n        _markets[token].enabled = false;"),
    # --- LOW-1: one budget for both reads ---
    ("M16 value collateral through an UNCAPPED read again", MARKETS,
     "        uint256 mult = _liveMultiplier(multiplierSource[token]);\n        if (mult == 0) revert BadMultiplierSource(token, multiplierSource[token]);",
     "        uint256 mult = IScaledUI(multiplierSource[token]).uiMultiplier();"),
    # --- MED-2: the recovery path ---
    ("M17 commitRotation with no timelock", LIVENESS,
     "        if (block.timestamp < at) revert RotationNotElapsed(at - block.timestamp);",
     "        if (false) revert RotationNotElapsed(at - block.timestamp);"),
    ("M18 proposeRotation open to anyone", LIVENESS,
     "        if (msg.sender != rotationAdmin) revert NotRotationAdmin();\n        if (keeper_ == address(0) || guardian_ == address(0)) revert ZeroAddress();",
     "        if (keeper_ == address(0) || guardian_ == address(0)) revert ZeroAddress();"),
    ("M19 commitRotation leaves the old guardian in place", LIVENESS,
     "        keeper = pendingKeeper;\n        guardian = pendingGuardian;",
     "        keeper = pendingKeeper;"),
    ("M20 drop the rotationAdmin distinctness rule", LIVENESS,
     "        if (rotationAdmin_ == keeper_ || rotationAdmin_ == guardian_) revert RolesMustDiffer();",
     "        if (false) revert RolesMustDiffer();"),
    ("M21 let the GUARDIAN cancel its own removal", LIVENESS,
     "    function cancelRotation() external {\n        if (msg.sender != rotationAdmin) revert NotRotationAdmin();",
     "    function cancelRotation() external {\n        if (msg.sender != rotationAdmin && msg.sender != guardian) revert NotRotationAdmin();"),
    # --- R5 LOW-1: the read budget's MAGNITUDE, which the test named for it did not pin ---
    ("M25 MULTIPLIER_READ_GAS 200,000 -> 5,000 (below what the deployed token needs)", MARKETS,
     "    uint256 public constant MULTIPLIER_READ_GAS = 200_000;",
     "    uint256 public constant MULTIPLIER_READ_GAS = 5_000;"),
    ("M26 MULTIPLIER_READ_GAS 200,000 -> 16,000 (just above the read, no headroom)", MARKETS,
     "    uint256 public constant MULTIPLIER_READ_GAS = 200_000;",
     "    uint256 public constant MULTIPLIER_READ_GAS = 16_000;"),
    # --- R5 MED-1: the delay line's clock ---
    ("M27 the line stops ageing while the feed is unreadable (the R5 MED-1 bug)", MARKETS,
     "        if (price == 0) {\n            _holdConfirmable(token);",
     "        if (price == 0) {\n            if (false) _holdConfirmable(token);"),
    ("M28 warm with the LIVE multiplier, splitting the pair (the R4 MED-1 shape)", MARKETS,
     "        _confirmable(token, head.price, head.mult);",
     "        _confirmable(token, head.price, _liveMultiplier(multiplierSource[token]));"),
    ("M29 warm past the rate limit, collapsing the line to one step", MARKETS,
     "        _confirmable(token, head.price, head.mult);",
     "        _confirmRing[token][_confirmHead[token] = (_confirmHead[token] + 1) % CONFIRM_SLOTS] =\n            Observation(head.price, head.mult, block.timestamp);"),
    # R6: this used to remove a standalone `takenAt == 0` guard, and SURVIVED once the warm ceiling
    # landed above it — the ceiling already refuses a zero head, so the guard was dead and the mutant
    # equivalent. The guard is gone; the property it named is attacked where it actually lives.
    ("M30 warm a never-observed market too, seeding a zero pair", MARKETS,
     "        if (block.timestamp - head.takenAt > MAX_CONFIRM_AGE) return;",
     "        if (head.takenAt != 0 && block.timestamp - head.takenAt > MAX_CONFIRM_AGE) return;"),
    ("M31 warm from the READ slot instead of the head, so the line never advances", MARKETS,
     "        Observation memory head = _confirmRing[token][_confirmHead[token]];",
     "        Observation memory head = _confirmRing[token][(_confirmHead[token] + 1) % CONFIRM_SLOTS];"),
    # --- R6 MED-1: the warm push may refresh the SCHEDULE, never a price's claim to be checked ---
    ("M32 warm from the last RAW read instead of the ring head (R6 LOW-2)", MARKETS,
     "        _confirmable(token, head.price, head.mult);",
     "        _confirmable(token, seenPrice[token], seenMultiplier[token]);"),
    ("M33 MULTIPLIER_READ_GAS 200,000 -> 30,000,000 (effectively uncapped)", MARKETS,
     "    uint256 public constant MULTIPLIER_READ_GAS = 200_000;",
     "    uint256 public constant MULTIPLIER_READ_GAS = 30_000_000;"),
    ("M34 drop the warm ceiling, so a gap resurrects an ancient print (the R6 MED-1 bug)", MARKETS,
     "        if (block.timestamp - head.takenAt > MAX_CONFIRM_AGE) return;",
     "        // warm ceiling removed"),
    ("M35 warm ceiling inverted", MARKETS,
     "        if (block.timestamp - head.takenAt > MAX_CONFIRM_AGE) return;",
     "        if (block.timestamp - head.takenAt < MAX_CONFIRM_AGE) return;"),
    ("M36 warm ceiling > -> >= (boundary: it must be the read's ceiling exactly)", MARKETS,
     "        if (block.timestamp - head.takenAt > MAX_CONFIRM_AGE) return;",
     "        if (block.timestamp - head.takenAt >= MAX_CONFIRM_AGE) return;"),
    ("M37 warm ceiling measured against a DIFFERENT constant", MARKETS,
     "        if (block.timestamp - head.takenAt > MAX_CONFIRM_AGE) return;",
     "        if (block.timestamp - head.takenAt > PRICE_CONFIRM_DELAY) return;"),
    # --- R7 LOW-2: the two halves of the warmed pair, mutated INDEPENDENTLY ---
    ("M38 warm the MULTIPLIER half from the raw read (R7 LOW-2)", MARKETS,
     "        _confirmable(token, head.price, head.mult);",
     "        _confirmable(token, head.price, seenMultiplier[token]);"),
    ("M39 warm the PRICE half from the raw read", MARKETS,
     "        _confirmable(token, head.price, head.mult);",
     "        _confirmable(token, seenPrice[token], head.mult);"),
    # The same independence against the OTHER slot. R5's older-slot test varies five PRICES and holds
    # one multiplier, so M40 survived 398/398 including M38's own test — the sixth false green.
    ("M40 warm the MULTIPLIER half from the READ slot, four steps behind the head", MARKETS,
     "        _confirmable(token, head.price, head.mult);",
     "        _confirmable(token, head.price, confirmedObservation(token).mult);"),
    ("M41 warm the PRICE half from the READ slot", MARKETS,
     "        _confirmable(token, head.price, head.mult);",
     "        _confirmable(token, confirmedObservation(token).price, head.mult);"),
]


# A `finally` does not run on SIGTERM, and this script holds a MUTATED contract on disk for minutes
# at a time. Killing a run therefore left the working tree carrying a live mutant that looks like an
# ordinary edit — found the hard way on 2026-09-04, with the age CEILING silently removed.
PRISTINE = {}


def restore_all(*_):
    for path, src in PRISTINE.items():
        path.write_text(src)
    sys.exit(130)


# The fork backend answers 429 under load, and its failures print as `[FAIL: ...` like any other —
# so an unlucky mutant reads as KILLED by evidence that never ran. Named, retried, and reported as
# INCONCLUSIVE rather than folded into the count.
TRANSPORT = ("Max retries exceeded HTTP error 429", "database error:", "Failed to get EIP-1559")


def is_transport(line):
    return any(t in line for t in TRANSPORT)


def suite_verdict():
    p = subprocess.run(
        ["forge", "test", "--match-contract", SELECT],
        cwd=ROOT, capture_output=True, text=True, timeout=2400,
    )
    out = p.stdout + p.stderr
    if "Compiler run failed" in out or "Error: Compilation failed" in out:
        return "NO-COMPILE", "the mutant does not build"
    fails = [l for l in out.splitlines() if l.startswith("[FAIL")]
    if not fails:
        return "SURVIVED", "the whole targeted suite stayed green"
    real = [l for l in fails if not is_transport(l)]
    if not real:
        return "RPC-FLAKE", fails[0][:150]
    return "KILLED", real[0][:150]


def run(mut):
    label, path, old, new = mut
    src = PRISTINE.setdefault(path, path.read_text())
    n = src.count(old)
    if n != 1:
        return label, "ANCHOR-MISS", f"anchor matched {n} times"
    path.write_text(src.replace(old, new))
    try:
        verdict, detail = suite_verdict()
        if verdict == "RPC-FLAKE":
            verdict, detail = suite_verdict()
        return label, verdict, detail
    finally:
        path.write_text(src)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, restore_all)
    signal.signal(signal.SIGINT, restore_all)
    results = []
    for m in MUTANTS:
        label, verdict, detail = run(m)
        print(f"{verdict:11s} {label}\n            {detail}", flush=True)
        results.append((verdict, label))
    survivors = [l for v, l in results if v != "KILLED"]
    print(f"\n{len(results) - len(survivors)}/{len(results)} killed")
    for l in survivors:
        print(f"  NOT KILLED: {l}")
    sys.exit(1 if survivors else 0)
