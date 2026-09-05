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

Round 8 added M42, the fifth instance of that same rule and the first one applied a call DEEPER than
`_holdConfirmable`. `_syncPrice` builds two sibling products and forwards both; the baseline half was
never attacked, and `prevPrice * curMult` survived the whole targeted suite. Round 8 also made the
gate self-validating: a verdict is now believed only from a run that reached its completion summary
with the expected test count, and a failure counts as a kill only when the failure text is EVIDENCE
the repo itself can account for — the old three-string transport denylist failed OPEN on every
transport shape nobody had seen yet.
"""
import re, signal, subprocess, sys, pathlib

# resolve the repo from this file, never the caller's cwd (lesson of 9b6d047)
ROOT = pathlib.Path(__file__).resolve().parents[2]
MARKETS = ROOT / "src/EsseyMarkets.sol"
LIVENESS = ROOT / "src/LivenessOracle.sol"
POOL = ROOT / "src/EsseyPool.sol"
SELECT = "DesyncStateMachine|DesyncBreaker|GLendR4|GLendR5|GLendR6|GLendR7|LivenessOracleTest|EsseyPoolTest|EsseyMarketsTest"
# Measured on the clean tree with the exact invocation in suite_verdict. Re-measure and update it
# whenever a test is added to the selected suites, or every mutant reports RUN-INCOMPLETE. It moves
# by more than the tests you wrote: EsseyPoolTest is a base, so a test added there lands once per
# subclass. THREE contracts in SELECT carry it (EsseyPoolTest, DesyncBreakerTest,
# DesyncStateMachineTest); R8's net +4 accrual tests therefore moved this 400 -> 412, while the
# whole tree moved 1808 -> 1840 across eight. GLendR4Base descends from Test, not from the pool.
EXPECTED_TESTS = 418

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
    # --- R8 LOW-2: the same independence rule one call deeper, on _syncPrice's BASELINE product ---
    ("M42 breaker baseline is the old price against the NEW multiplier (R8 LOW-2)", MARKETS,
     "        uint256 prev = prevPrice * prevMult; // 0 when either half has no baseline yet",
     "        uint256 prev = prevPrice * curMult; // 0 when either half has no baseline yet"),
    # --- R9 LOW-1: the bound on how much interval one witnessed pause buys. The MED-1 fix's own
    # script mutated the guard's SHAPE and the stamp's SHAPE and got 14/14, because every mutant
    # asked "does the code implement the chosen rule?" and none asked "is the rule's evidence enough
    # for what it forgives?". These are folded in here rather than kept beside it, so they inherit
    # is_evidence and the completion check instead of the classifier that failed open (R9 INFO-8).
    ("M43 the bound removed entirely — the R9 LOW-1 defect restored", POOL,
     """        if (paused && pauseObserved) {
            if (dt <= MAX_FORGIVEN_GAP) return (denom, denom, paused); // suspended: both endpoints paused
            dt -= MAX_FORGIVEN_GAP; // the endpoints vouch for a bounded window; the rest is charged
        }""",
     "        if (paused && pauseObserved) return (denom, denom, paused);"),
    ("M44 past the bound, forgive the whole gap anyway (the subtraction neutered)", POOL,
     "            dt -= MAX_FORGIVEN_GAP; // the endpoints vouch for a bounded window; the rest is charged",
     "            dt = 0;"),
    ("M45 the subtraction reversed — charge for time nobody was billed for", POOL,
     "            dt -= MAX_FORGIVEN_GAP; // the endpoints vouch for a bounded window; the rest is charged",
     "            dt += MAX_FORGIVEN_GAP;"),
    ("M46 the subtraction against a DIFFERENT constant, not merely deleted", POOL,
     "            dt -= MAX_FORGIVEN_GAP; // the endpoints vouch for a bounded window; the rest is charged",
     "            dt -= dt < SECONDS_PER_YEAR ? dt : SECONDS_PER_YEAR;"),
    # `<= -> <` is NOT here, and deliberately: it is provably EQUIVALENT. At dt == MAX_FORGIVEN_GAP
    # the `<` variant falls through to `dt -= MAX_FORGIVEN_GAP`, which makes dt zero, and the very
    # next line returns the identical (denom, denom, paused) on `dt == 0`. Both spellings forgive the
    # same set. Shifting the boundary by a second is the mutation that actually moves behaviour.
    ("M47 the bound one second wider (boundary genuinely shifted)", POOL,
     "            if (dt <= MAX_FORGIVEN_GAP) return (denom, denom, paused); // suspended: both endpoints paused",
     "            if (dt <= MAX_FORGIVEN_GAP + 1) return (denom, denom, paused); // suspended: both endpoints paused"),
    ("M48 bound comparison inverted", POOL,
     "            if (dt <= MAX_FORGIVEN_GAP) return (denom, denom, paused); // suspended: both endpoints paused",
     "            if (dt >= MAX_FORGIVEN_GAP) return (denom, denom, paused); // suspended: both endpoints paused"),
    # The magnitude in BOTH directions, and to a value long enough to close nothing — the shape R4
    # found by cutting PRICE_CONFIRM_DELAY to a second and finding 1,748 of 1,751 still green.
    ("M49 MAX_FORGIVEN_GAP 1h -> 0 (forgives nothing; a witnessed pause is billed)", POOL,
     "    uint256 public constant MAX_FORGIVEN_GAP = 1 hours;",
     "    uint256 public constant MAX_FORGIVEN_GAP = 0;"),
    ("M50 MAX_FORGIVEN_GAP 1h -> 1 second", POOL,
     "    uint256 public constant MAX_FORGIVEN_GAP = 1 hours;",
     "    uint256 public constant MAX_FORGIVEN_GAP = 1 seconds;"),
    ("M51 MAX_FORGIVEN_GAP 1h -> 24 hours (the other direction)", POOL,
     "    uint256 public constant MAX_FORGIVEN_GAP = 1 hours;",
     "    uint256 public constant MAX_FORGIVEN_GAP = 24 hours;"),
    ("M52 MAX_FORGIVEN_GAP 1h -> 365 days (a bound that closes nothing — the R9 LOW-1 defect, dressed)", POOL,
     "    uint256 public constant MAX_FORGIVEN_GAP = 1 hours;",
     "    uint256 public constant MAX_FORGIVEN_GAP = 365 days;"),
    # --- the R8 MED-1 guard itself, re-mutated HERE so the pair is scored by one classifier ---
    ("M53 forgive on the closing read alone (R8 MED-1 direction A restored)", POOL,
     "        if (paused && pauseObserved) {",
     "        if (paused) {"),
    ("M54 forgive on the OPENING read alone", POOL,
     "        if (paused && pauseObserved) {",
     "        if (pauseObserved) {"),
    ("M55 the guard widened to OR", POOL,
     "        if (paused && pauseObserved) {",
     "        if (paused || pauseObserved) {"),
    ("M56 the guard hardcoded TRUE", POOL,
     "        if (paused && pauseObserved) {",
     "        if (true) {"),
    ("M57 the guard hardcoded FALSE (forgiveness deleted)", POOL,
     "        if (paused && pauseObserved) {",
     "        if (false) {"),
    ("M58 the opening endpoint never recorded", POOL,
     "        pauseObserved = paused;",
     "        pauseObserved = pauseObserved;"),
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
# so an unlucky mutant reads as KILLED by evidence that never ran. R8 LOW-4: this used to be three
# observed transport strings, so `error sending request`, `operation timed out` and `connection reset
# by peer` were REAL kills. A denylist of the failures you have already seen cannot cover the one you
# have not, so the test is inverted and anything unrecognised is INCONCLUSIVE.
COMPLETION = re.compile(r"Ran \d+ test suites?.*?: (\d+) tests passed, (\d+) failed", re.S)
REASON = re.compile(r"\[FAIL: (.*?)(?:\] \S+\(.*)?$")
# Two concrete operands compared — how forge renders assertEq/assertLt and friends.
COMPARISON = re.compile(r"(?:0x[0-9a-fA-F]+|\d+) ?(?:!=|==|<=|>=|<|>) ?(?:0x[0-9a-fA-F]+|\d+)")
DECODED_REVERT = re.compile(r"^([A-Za-z_]\w*)\(")
# Forge's and the EVM's own verdicts, which are a CLOSED set produced locally — unlike the open set
# of things a rate-limited backend can say. OutOfFunds and OutOfGas stay out: those are the R5
# fixture-funding shape, indistinguishable from a mutant that never got to run.
HARNESS_VERDICT = (
    "did not revert as expected", "reverted as expected, but without data",
    "Error != expected error", "log != expected log", "assertion failed",
    "panic:", "EvmError: Revert",
)
_OWN_TEXT = []


def own_text():
    if not _OWN_TEXT:
        _OWN_TEXT.append("".join(
            p.read_text(errors="ignore") for d in ("src", "test") for p in sorted((ROOT / d).rglob("*.sol"))
        ))
    return _OWN_TEXT[0]


def is_evidence(line):
    """Whether a [FAIL line is something the repo can account for, rather than an unread run."""
    m = REASON.match(line)
    if not m:
        return False
    reason = m.group(1)
    if COMPARISON.search(reason) or any(s in reason for s in HARNESS_VERDICT):
        return True
    err = DECODED_REVERT.match(reason)
    # A decoded revert counts only when THIS repo declares the error. An ERC20InsufficientBalance or
    # an OutOfFunds decodes just as cleanly and means the fixture never funded — the R5 shape.
    if err:
        return f"error {err.group(1)}(" in own_text()
    # An assertTrue message renders with no operands, so the last recogniser is the message as a
    # string LITERAL. A bare substring would recognise any English word the repo happens to contain.
    return f'"{reason.removeprefix("revert: ")}"' in own_text()


def suite_verdict():
    p = subprocess.run(
        ["forge", "test", "--match-contract", SELECT],
        cwd=ROOT, capture_output=True, text=True, timeout=2400,
    )
    out = p.stdout + p.stderr
    if "Compiler run failed" in out or "Error: Compilation failed" in out:
        return "NO-COMPILE", "the mutant does not build"
    fails = [l for l in out.splitlines() if l.startswith("[FAIL")]
    real = [l for l in fails if is_evidence(l)]
    if real:
        return "KILLED", real[0][:150]
    if fails:
        return "RPC-FLAKE", fails[0][:150]
    # R8 LOW-3: zero [FAIL lines used to be enough to call a mutant SURVIVED, so the run a stray
    # pkill took down mid-flight on 2026-09-04 reported as a clean green suite. Pinning the count
    # also catches the mutant that DELETES tests rather than failing them.
    m = COMPLETION.search(out)
    ran = int(m.group(1)) + int(m.group(2)) if m else None
    if ran != EXPECTED_TESTS:
        return "RUN-INCOMPLETE", f"{ran if ran is not None else 'no'} tests ran, expected {EXPECTED_TESTS}"
    return "SURVIVED", "the whole targeted suite stayed green"


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
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "tools"))
    import runlock

    # Two runs on one tree void BOTH results and can strand a mutant live in the source (2026-09-05).
    runlock.guard("glend-mutation-gate", "glend-r4.py", f"{len(MUTANTS)} mutants against {ROOT}")
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
