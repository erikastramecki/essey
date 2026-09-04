#!/usr/bin/env python3
"""Adversarial mutation gate for the G-LEND round-4 fix.

Round 4's central finding was a test that PERFORMED the bypass it was named to prevent and asserted
the result, and the sweep that caught it from the other direction was mutating PRICE_CONFIRM_DELAY to
one second and finding 1,748 of 1,751 still green. So the magnitude of every constant this fix rests
on is mutated here in BOTH directions, along with every guard removed and inverted.

    python3 test/mutants/glend-r4.py     # from rh-chain/, tree must be clean of other edits

Every mutant is applied to the real tree, the targeted suites are run, and the tree is restored.
A mutant that leaves the suite GREEN is a SURVIVOR and is reported as a gap, not hidden.
"""
import subprocess, sys, pathlib

# resolve the repo from this file, never the caller's cwd (lesson of 9b6d047)
ROOT = pathlib.Path(__file__).resolve().parents[2]
MARKETS = ROOT / "src/EsseyMarkets.sol"
LIVENESS = ROOT / "src/LivenessOracle.sol"
SELECT = "DesyncStateMachine|DesyncBreaker|GLendR4|LivenessOracleTest|EsseyPoolTest|EsseyMarketsTest"

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
]


def run(mut):
    label, path, old, new = mut
    src = path.read_text()
    n = src.count(old)
    if n != 1:
        return label, "ANCHOR-MISS", f"anchor matched {n} times"
    path.write_text(src.replace(old, new))
    try:
        p = subprocess.run(
            ["forge", "test", "--match-contract", SELECT],
            cwd=ROOT, capture_output=True, text=True, timeout=2400,
        )
        out = p.stdout + p.stderr
        if "Compiler run failed" in out or "Error: Compilation failed" in out:
            return label, "NO-COMPILE", "the mutant does not build"
        fails = [l for l in out.splitlines() if l.startswith("[FAIL")]
        if fails:
            return label, "KILLED", fails[0][:150]
        return label, "SURVIVED", "the whole targeted suite stayed green"
    finally:
        path.write_text(src)


if __name__ == "__main__":
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
