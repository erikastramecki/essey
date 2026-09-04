# G-LEND gate — round 9 — Solidity / contract security lens

**Date:** 2026-09-04
**Frozen SHA:** `1bc9ec73fe681afebdb1623b3fbf31b9097ede18`
**`git status --porcelain`:** **empty (0 lines)** at the start of the round.

```
$ git rev-parse HEAD
1bc9ec73fe681afebdb1623b3fbf31b9097ede18
$ git status --porcelain
$                                   # 0 lines
```

Every probe ran in a `git archive 1bc9ec7` scratch root with `lib/` copied (never symlinked), under
`scratchpad/{r9root,gateroot,xpv}`. The sha256 of every audited file was taken at the start and
re-taken at the end; the table is in the receipt `~/.claude/gate-receipts/audit-glend-r9`.

**One integrity incident, disclosed rather than buried.** A `cd` into a scratch root failed and the
compound command carried on in the previous working directory, so a probe edit landed on the REAL
`rh-chain/src/EsseyMarkets.sol`. It was caught on the next command, reverted with
`git checkout --`, and the file's sha256 re-verified as
`bae72864fbcfb34e40e38cff7b270a3ec1bdfde1574251127a0bcae702aaf8f3`, identical to `1bc9ec7`; `git
status --porcelain` empty and `HEAD` unchanged. **The scripted edit asserted its anchor but not its
LOCATION** — the house rule covers anchors and this was one hop past it. Every subsequent scripted
edit in this round asserts `cwd` before writing, and the assertion text is in the pasted output.

**Substrate:** Robinhood Chain **mainnet**, real fork.

```
RPC  https://rpc.mainnet.chain.robinhood.com
eth_chainId       -> "0x1237"   = 4663
eth_blockNumber   -> "0x3418839" = 54,562,361   (round start)
web3_clientVersion-> nitro/v3.11.4-rc.3-7d5ac27/linux-arm64/go1.25.14
USDG 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168  paused()(bool) -> false
     pausedAt() / pausedSince() -> revert 0x800ab12c
```

The `paused()`-is-a-bare-boolean grounding the MED-1 fix rests on was **re-verified by me against the
live proxy**, not inherited from the fix receipt.

**Deployment state, verified rather than assumed:** the lending stack is still **NOT deployed on
4663** — `rh-chain/broadcast/DeployMarkets.s.sol/` does not exist while 36 other deploy broadcasts
do (`ls broadcast/ | wc -l` -> 36). Nothing in this report is live value at risk today.

---

## VERDICT

**NOT CLEAN.** 0 CRITICAL · 0 HIGH · 0 MEDIUM · **2 LOW** · 8 INFO.

Both LOWs are reported as LOWs. Neither was promoted to justify the round, and I considered and
rejected MEDIUM for LOW-1 explicitly (the reasoning is in its severity section). The two items
carried forward from round 8 — X-P and `EsseyMarkets.sol:525` — **both resolve to no finding**, and
in the X-P case the carried-forward claim is refuted outright.

The mutation gate re-ran from zero: see *The tooling* below for the run and for the negative-control
evidence on every instrument, mine included.

---

# RULING 1 — the "NOT CLOSABLE" reasoning for direction B

This was the load-bearing claim of the whole fix, so it gets ruled on first.

**The claim** (`EsseyPool.sol:261-266`, and the fix receipt): *any design that closes the unwitnessed
direction-B window has reopened the erasure, because forgiving on the closing read alone IS
direction A.*

**RULING: the claim is TRUE, and it is correctly reasoned — but it settles a narrower question than
the one it is being used to settle, and the gap is where LOW-1 lives.**

Taking it in parts, each verified rather than accepted:

1. **The chain holds no record of an unwitnessed pause window. VERIFIED.** `paused()` returns a bare
   boolean and the live USDG proxy exposes no timestamp variant — I re-ran the probe myself at block
   54,562,361: `paused()` answers `false`, and `pausedAt()`, `pausedSince()` both revert
   `0x800ab12c`. Any rule in `_growth` is therefore a function of only
   `(pauseObserved, paused, dt, lastAccrual)`. The ground truth — *did the pause hold across the
   interval?* — is **not determined** by those four. So no endpoint-only rule can forgive an
   unwitnessed window correctly. The residual is genuinely not closable in the contract.
2. **Forgiving on the closing read alone is direction A. VERIFIED.** Round 8 proved it with a PoC and
   the shipped `test_aPauseAtTheCallInstantCannotEraseAnUnpausedInterval`
   (`test/EsseyPool.t.sol:599-620`) now pins it; it passes on the frozen tree.
3. **But the dichotomy is incomplete, and the omission is not cosmetic.** The argument offers two
   options — forgive on the closing read (direction A), or accept the residual — and takes the
   second. There is a third: **forgive a BOUNDED interval.** It matters because the very
   indeterminacy that makes an unwitnessed window unforgivable *also* makes the shipped rule's
   forgiveness unsound in the opposite direction. Two endpoint reads are evidence about **two
   instants**. `_growth` treats them as evidence about **the whole interval between them**, and
   nothing bounds that interval — the `paused && pauseObserved` return at `EsseyPool.sol:270` fires
   **before `dt` is even computed** (`:271`). That is the identical error as direction A, applied to
   a pair of reads instead of one.

**So: the residual is correctly declared not closable, and the pin
(`test_anUnwitnessedPausedWindowIsCharged`, `test/EsseyPool.t.sol:648-655`) is right to exist. What
does not follow — and was not established — is that the two-endpoint rule is therefore sound.** The
honest statement of what two instantaneous reads can support is: *forgive a bounded window around
them.* LOW-1 is what falls out of the difference.

---

# RULING 2 — X-P, the eighth "one-half-of-a-pair" instance

**RULING: REFUTED. X-P is not a survivor and not an unpinned half. It is the most heavily-killed
mutant measured in this engagement. Strike it from the handoff.**

The round-8 handoff records: *"X-P (`price * prevMult`, the PRICE half of the same baseline) SURVIVES
the new M42 test — measured, not assumed… EIGHTH instance of the one-half-of-a-pair shape; THIRD
round running."*

The narrow measurement is true and the conclusion drawn from it is not. **"Survives" in this gate is
defined over the whole `SELECT` suite** (`test/mutants/glend-r4.py`, `suite_verdict()`), not over one
test. X-P was run against the M42 test alone.

Applied to a scratch root and run against the gate's own targeted suite:

```
--- clean baseline (negative control, same command, same instrument) ---
Ran 17 test suites in 49.91s (361.17s CPU time): 412 tests passed, 0 failed, 0 skipped (412 total tests)

--- X-P applied (anchor asserted 1/1, cwd asserted) ---
Ran 17 test suites in 38.06s (230.76s CPU time): 373 tests passed, 27 failed, 0 skipped (400 total tests)

[FAIL: observed market: the breaker arms: 0 <= 0] test_theObservedMarketStillArms()
[FAIL: Error != expected error: PriceNotCorroborated(0xF628…) != LiquidationNotAllowed(0xF628…)] test_feedFirstSplitCannotLiquidateAHealthyPosition()
[FAIL: one unit past the bound arms: 0 <= 0] test_theDeviationBoundaryIsExact()
[FAIL: next call did not revert as expected] test_theBreakerFiresInTheUpDirectionToo()
[FAIL: a fresh baseline still sees the gap: 0 <= 0] test_aFreshBaselineStillArmsOnTheSameGap()
[FAIL: armed: 0 != 1755099000] test_aStandaloneSyncCommitsTheArmAndTheHoldExpires()
[FAIL: the -30% gap armed it] test_theArmedPairIsWrittenAndClearedAsOneValue()
   … 18 distinct assertion kills in total
```

**The mechanism, checked by algebra against the source rather than inferred from the failure count.**
`_deviates` (`src/EsseyMarkets.sol:640-643`) is
`diff * 10_000 > ref * MAX_PRICE_DEVIATION_BPS` — homogeneous of degree 1, so for any `k > 0`,
`_deviates(k·a, k·b) ⟺ _deviates(a, b)`. Under X-P the baseline becomes `price * prevMult` while the
observed argument at `:542` is `price * curMult`: **both carry the common factor `price`**, which
cancels, and the comparison reduces to `_deviates(prevMult, curMult)`. The breaker becomes blind to
price entirely and can only see multiplier changes — deleting case (c) at `src/EsseyMarkets.sol:494`
("the FEED moved without the multiplier"), the primary reason the breaker exists. It is not a
half-pinned pair; it is a catastrophic non-equivalence that 18 tests catch.

**Where the false gap came from.** The engineer's stated reason is correct as far as it goes: in the
M42 fixture the feed leg has not moved, which `test/DesyncBreaker.t.sol:127` asserts verbatim
(`assertEq(mk.seenPrice(t), priceBefore, "the feed leg has not moved");` — note **:127**, not the
`:126` the handoff cites, which is `mk.syncMultiplier(t);`). With `price == prevPrice`, X-P is a
literal no-op *in that fixture*. Running one mutant against one test and reporting "SURVIVES" carries
a claim the measurement cannot support.

**This is the sixth instance of the standing tooling shape — inverted.** The five before it produced
false GREENs; this one produced a **false GAP**, and it propagated into the handoff as a standing
third-round coverage debt that does not exist. An instrument that over-reports gaps is safer than one
that under-reports them, but it still spends a round's attention on nothing.

**Disposition:** no security finding; shipped code correct and thoroughly pinned. Adding X-P to
`glend-r4.py` as M43 is harmless and would report KILLED, but it closes nothing.

---

# RULING 3 — `EsseyMarkets.sol:525`, the un-mutated `_confirmable` pair

**RULING: not a coverage gap. INFO only, two items — and the handoff's line numbers are stale.**

At `1bc9ec7`, `:525` and `:556` are **comment lines**:

```
$ sed -n '525p;556p' rh-chain/src/EsseyMarkets.sol
    /// coming apart — `seenMultiplier` was written unconditionally while this returned without
    /// fail-closed held only for a PERMANENTLY dead keeper: one observation gap outlasting
```

The real call sites are 15 lines lower:

```
$ grep -n "_confirmable(" rh-chain/src/EsseyMarkets.sol
540:        _confirmable(token, price, curMult);          # the RAW push, in _syncPrice
571:        _confirmable(token, head.price, head.mult);   # the WARM push, in _holdConfirmable
584:    function _confirmable(address token, uint256 price, uint256 mult) internal {
```

**The asymmetry is real** — the warm push carries 7 mutants and the raw push 0:

```
$ grep -c '_confirmable(token, head.price, head.mult);' rh-chain/test/mutants/glend-r4.py
7
$ grep -c '_confirmable(token, price, curMult)' rh-chain/test/mutants/glend-r4.py
0
```

Seven independent mutants were built against `:540` — each argument against every wrong source it
could come from (`prevMult`, `seenMultiplier[token]`, the READ slot, the HEAD slot, `prevPrice`) —
and **all seven were KILLED**, on readable assertions checked against repo-declared evidence.
One candidate is equivalent by construction and correctly so: `seenPrice[token]` is written at
`src/EsseyMarkets.sol:538`, one line above the call, so `price === seenPrice[token]` at `:540`.

- **INFO-3** — the handoff's `:525`/`:556` citations are stale; the calls are `:540`/`:571`.
- **INFO-4** — coverage at `:540` is **incidental rather than targeted**. Every kill came from a test
  named for the warm path or for corroboration generally; no test is named for the raw push's pair.
  It holds because the warm push copies the head the raw push wrote, so corruption propagates. That
  is real coverage, but it is load-bearing by accident: a refactor decoupling warm from raw would
  drop it silently. Adding one price-half and one multiplier-half mutant would pin it deliberately at
  no cost.

---

# LOW-1 · The two-endpoint rule is straddle-able: two pause instants forgive everything between them

**Permissionless. Repeatable. Unbounded in magnitude. CONFIRMED with a runnable PoC, and the existing
suite actively pins the defective behaviour.**

### The code path

`rh-chain/src/EsseyPool.sol:267-275`

```solidity
function _growth() internal view returns (uint256 num, uint256 denom, bool paused) {
    denom = BPS * SECONDS_PER_YEAR;
    paused = _borrowAssetPaused();
    if (paused && pauseObserved) return (denom, denom, paused); // :270 — before dt is computed
    uint256 dt = block.timestamp - lastAccrual;                 // :271
    if (dt == 0 || totalBorrows == 0) return (denom, denom, paused);
    return (denom + borrowRateBps() * dt, denom, paused);
}
```

`pauseObserved` (`:114`) records the pause read at `lastAccrual`; `accrue()` (`:226-229`) sets it and
advances the clock unconditionally. **Nothing requires the pause to have HELD between the two
endpoints, and nothing bounds the interval** — the forgiving return at `:270` fires before `dt`
exists. `accrue()` is `public`, unauthenticated, and callable by any address (`:225`).

### The exploit

Two *unrelated* USDG pause episodes, with a fully unpaused stretch between them, forgive the whole
stretch. Measured, with a control that varies only time:

```
[FAIL: a year in which repayment was possible on every second must still be charged: 700191780 != 770210958]
  honest debt (USDG 6dp)      : 770210958
  straddled debt              : 700191780
  borrower interest erased    :  70019178      <- 70.019178 USDG
  lender assets, honest       : 100070210958
  lender assets, straddled    : 100000191780
  lender assets destroyed     :  70019178
```

`address(0xBAD)` — no position, no stake, no privilege — called `accrue()` in one instant of pause
episode 1, and again in one instant of pause episode 2, 365 unpaused days later. Every second of that
year was a second in which repayment was possible.

With **realistic one-hour episodes** rather than instants, against a control that witnesses at every
boundary so only the two genuinely-paused hours are forgiven:

```
[FAIL: only the hours that were actually paused may be forgiven: 700015981 != 770008789]
  debt when only the paused hours are forgiven: 770008789
  debt under the straddle                     : 700015981
  over-forgiven                               :  69992808      <- 69.99 USDG for 2h of real pause
```

**Negative control, run first and green**, so the probe measures the pause rather than the warps:

```
[PASS] test_r9_negativeControl_noPauseAnywhereMeansNoDifference()
  no-pause world A: 770210958
  no-pause world B: 770210958
```

PoC: `~/.claude/gate-receipts/audit-glend-r9-poc/AuditR9Straddle.t.sol`.

### Why one pause episode is NOT enough — the bound of the finding, stated honestly

For `paused && pauseObserved` to hold, two `accrue()` calls must each read paused. With a single
episode `E`, both calls lie inside `E`, so the forgiven interval is a subset of `E` and forgiveness
is **correct**. Over-forgiveness strictly requires the pause to lift and resume between two
observations. `_borrowAssetPaused()` (`:295-298`) reads a fixed immutable `asset()`, so an attacker
cannot manufacture the reading; I also checked the gas-cap direction and it cannot be forced. Under
EIP-150 the staticcall receives `min(50_000, 63G/64)`: to starve it you need `63G/64 <` the cost of
`paused()` (~5k), i.e. `G < ~5,080`, which leaves `G/64 ≈ 79` gas — nowhere near the ~30k of SSTOREs
`accrue()` still has to perform, so the transaction cannot complete. And that direction yields
*not-paused*, not paused. **Two exogenous pause episodes are genuinely required.**

### Why it is not merely theoretical

During a borrow-asset pause every USDG-moving entry point reverts — `deposit`, `withdraw`, `borrow`,
`repay`, and **`liquidate`**, which pulls USDG from the liquidator at `EsseyPool.sol:743`
(`IERC20(asset()).safeTransferFrom(msg.sender, address(this), owed)`). So in normal operation
**nobody calls `accrue()` during a pause at all** — which means the forgiveness path is reached
essentially only when someone *deliberately* witnesses. The only party with an incentive to witness
is the borrower, and witnessing hands them not the paused window but the entire gap since the last
accrual. `removeCollateral` (`EsseyPool.sol:686-711`) is not blocked — it moves only the collateral
token — so a borrower can also strip collateral against the under-stated debt in a window where
liquidation is impossible.

Magnitude at the deployed parameters, using round 8's own figures (`kinkBps = 8_000` at `EsseyPool.sol:119`; per-market cap 250,000 USDG at
`script/DeployMarkets.s.sol:395`; 1,312bps at 50% utilisation): **≈ $89.86 of lender interest per day
of erased gap**, and the gap is bounded by nothing in the contract.

### Why nothing caught it — and worse, why the suite pins it

The borrow-asset pause word is set at exactly five sites across four tests:

```
$ grep -n "setPausedWord" rh-chain/test/EsseyPool.t.sol
610: test_aPauseAtTheCallInstantCannotEraseAnUnpausedInterval   (1)
632: test_onlyTheWitnessedPausedWindowIsForgiven                (1)
636: test_onlyTheWitnessedPausedWindowIsForgiven                (0)
650: test_anUnwitnessedPausedWindowIsCharged                    (1)
652: test_anUnwitnessedPausedWindowIsCharged                    (0)
688: test_nonBooleanPausedWordDoesNotFreezeThePool              (2)
```

Round 8 prescribed varying the pause *within* the interval "in both orders (unpaused→paused and
paused→unpaused)". Both of those shapes are now covered. **The straddle is a third shape —
paused→unpaused→paused across a single forgiven interval — and no fixture produces it.**

The MED-1 fix's own mutation script (`~/.claude/gate-receipts/audit-glend-r8-poc/mutate-med1-fix.py`,
14 mutants) mutates the guard's *shape* and the stamp's *shape* — `&& -> ||`, `pauseObserved` alone,
hardcoded true/false, stamp removed/inverted, the naive one-liner — and **nothing bounds the forgiven
interval.** Every mutant asks "does the code implement the chosen rule?" None asks "is the rule's
evidence sufficient for what it forgives?" That is the standing shape one level up.

**And the suite does not merely miss it — it enforces it.** Applying the bounded fix below:

```
[FAIL: the witnessed paused year cost the borrower nothing: 770413980 != 700383614]
        test_onlyTheWitnessedPausedWindowIsForgiven()   (test/EsseyPool.t.sol:622)
```

A correct fix goes **red** on the shipped suite. Round 8's lesson was that the test named for the
property could not detect its absence; here the test named for the property asserts the defect.
**This is not an artefact of the bound I chose:** that test forgives a 365-day window from two
`accrue()` calls, so it goes red for *any* bound short enough to be useful. Only a bound ≥ 365 days
leaves it green, and such a bound closes nothing.

### The fix

Bound the forgiven interval to what two instantaneous reads can vouch for:

```solidity
uint256 public constant MAX_FORGIVEN_GAP = 1 hours;   // pick the cadence deliberately
...
paused = _borrowAssetPaused();
uint256 dt = block.timestamp - lastAccrual;
if (paused && pauseObserved) {
    if (dt <= MAX_FORGIVEN_GAP) return (denom, denom, paused);
    dt -= MAX_FORGIVEN_GAP;   // two instants vouch for a bounded window, not for the whole gap
}
if (dt == 0 || totalBorrows == 0) return (denom, denom, paused);
return (denom + borrowRateBps() * dt, denom, paused);
```

Measured against the same PoC (proposed only, applied in a scratch root, **not** shipped):

```
straddle erasure, frozen tree : 70019178   (70.019178 USDG)
straddle erasure, bounded fix :     7993   ( 0.007993 USDG)   -> reduced ~8,760x, to the bound
```

70,019,178 / 7,993 = 8,760.4, and 365 days / 1 hour = 8,760. The residual is exactly the bound and
nothing else, which is the arithmetic check that the fix does what it says rather than merely
changing the number.

It does not reopen direction A: a single read still forgives nothing. **State the trade-off in place
rather than leaving it implicit** — a genuinely long, genuinely witnessed pause now needs a witness
every `MAX_FORGIVEN_GAP` or the borrower is charged for the excess. That is the design's own stated
principle ("witnessing one costs a single permissionless `accrue()`", `EsseyPool.sol:265-266`)
applied consistently, and it is a deliberate choice that should be made rather than inherited.
`test_onlyTheWitnessedPausedWindowIsForgiven` must be rewritten to witness periodically; a test that
asserts an unbounded forgiveness cannot coexist with a bound.

Whatever shape is chosen, **the fixture must produce paused→unpaused→paused inside one forgiven
interval**, or it will pass for the wrong reason a third time.

### Severity, argued in both directions

**Not MEDIUM.** Round 8's MED-1 fired on **one** pause instant, by **any** address, **accidentally**
— a stranger's routine call sufficed. This requires **two** exogenous pause episodes that the
attacker cannot cause, bracketing an inter-accrual gap that stays quiet, plus deliberate timing. If
pauses are Poisson, the probability is roughly squared. USDG reads `paused() -> false` today and has
no pause history surface at all. Promoting a strictly-harder variant of a MEDIUM to MEDIUM would be
grade inflation.

**Not INFO.** It is a confirmed, non-equivalent, permissionless value transfer away from lenders on a
live money path, with an unbounded magnitude and a runnable PoC; it is a fresh hole in the fix for a
MEDIUM, in the same function, in the same direction the fix's own comment claims closed; the comment
at `EsseyPool.sol:264-265` states "**Ambiguous windows therefore resolve toward the lender**", which
is **false** for this window — it resolves toward the borrower; and the shipped suite goes red on the
correct fix.

**LOW** — but a LOW that becomes MEDIUM-equivalent the moment USDG pauses twice in the life of a
loan, and one that should be fixed rather than accepted, because accepting it silently leaves a test
in the tree that will resist the fix.

### Solvency is untouched

Forgiveness only ever reduces `totalBorrows` growth and the matching `totalReserves` cut. The pool
never owes more than it holds; `totalAssets()` in the PoC moves 100,070.21 → 100,000.19 USDG, and
share pricing stays consistent with it. This is a value **leak**, not a solvency break — which is the
main reason it is not HIGH.

---

# LOW-2 · The activation register states in the present tense that the liveness pager RUNS. Nothing is installed.

**CONFIRMED on this machine.**

`docs/MAINNET-ACTIVATION.md`, the R4 HIGH-2 remediation row, was changed in `1bc9ec7` to read:

> **the on-chain symptom check now actually RUNS** … a second unit runs it every 900s and pages on
> any non-zero exit

Measured:

```
$ launchctl list | grep -i essey
53837  0    xyz.essey.game-keeper
25432  -15  xyz.essey.markets-keeper
-      1    xyz.essey.markets-rehearsal-ad1
25435  -15  xyz.essey.markets-keeper-ad1
-      0    xyz.essey.markets-rehearsal
-      1    xyz.essey.markets-rehearsal-v2
22669  0    xyz.essey.markets-keeper-v2

$ ls ~/Library/LaunchAgents/ | grep -c liveness
0
```

**Neither `xyz.essey.liveness-pager` nor `xyz.essey.liveness-keeper` is installed or loaded.**
Moreover the shipped plist is a **template**, not a loadable unit — it carries `__REPO__`
placeholders that `RUNBOOK.md` tells the operator to `sed` before installing:

```
$ plutil -lint rh-chain/keeper/xyz.essey.liveness-pager.plist
… : OK
$ grep '__REPO__' rh-chain/keeper/xyz.essey.liveness-pager.plist | head -1
  <string>__REPO__/rh-chain</string>
```

**The mechanism is real and correctly built** — `page-liveness-keeper.sh` pages on any non-zero exit
including 2, uses `curl --fail` so a revoked webhook counts as undelivered, and prints `NO PAGE SENT`
when unconfigured; `RUNBOOK.md:119-151` documents the install honestly as a step to perform. The
engineer's own receipt says plainly: *"UNVERIFIED — real launchd scheduling — nothing installed."*
**The receipt was more honest than the register.**

This matters because `MAINNET-ACTIVATION.md` is the live register the deploy gate reads. R4 HIGH-2
was HIGH precisely because the breaker is load-bearing on an unsupervised keeper; the register now
says that supervision gap is closed when on this machine it is not. It is the same failure the row
was being corrected for — an overstated remediation — displaced one level down.

**Severity LOW,** not higher: the stack is not deployed (`broadcast/DeployMarkets.s.sol/` absent), so
nothing is unsupervised today, and the code and runbook are correct.

**Fix.** State the row in the tense that is true: the unit is **built and documented, not installed**.
Move it to installed only after `launchctl list | grep liveness-pager` returns a line and
`.keeper-state/liveness-pager.log` shows one run that is not `NO PAGE SENT`. That is a one-command
check and it is falsifiable, which is the whole point of the register.

---

# INFO

**INFO-1 · `accrueFor` is genuinely gone from the code.** Round 8 found the comment at
`EsseyPool.sol:219` naming a function that never existed. A tree-wide grep now returns four hits and
**all four are inside `docs/audits/glend-round-8.md`** documenting the finding; `src/`, `test/` and
`script/` are clean. Verified, not inherited.

**INFO-2 · A witnessed pause still charges its head and its tail.** The first `accrue()` inside a
pause charges from `lastAccrual` to that instant, including the already-paused part; the first
`accrue()` after it lifts charges through the still-paused part. Bounded by observation cadence and
in the conservative direction (toward the lender), consistent with the stated principle. Recorded so
it is a known cost rather than a surprise. **Accepted.**

**INFO-3 · Stale line citations in the round-8 handoff** — `:525`/`:556` are comments; the calls are
`:540`/`:571`. Also `DesyncBreaker.t.sol:126` should be `:127`. Anyone grepping the cited lines finds
prose and concludes the item is phantom.

**INFO-4 · Coverage of the raw `_confirmable` push at `:540` is incidental, not targeted.** See
Ruling 3. Two named mutants would pin it deliberately.

**INFO-5 · The gate scores KILLED before it checks run completeness.** In `suite_verdict()`
(`test/mutants/glend-r4.py`), the `EXPECTED_TESTS` completion gate is only consulted on the path to
`SURVIVED`. A run that produces genuine evidence but did not complete is banked as KILLED without the
count being checked — I hit exactly this shape in my own X-P run (`373 passed, 27 failed`, 400 of
412). Every kill there was genuine, so the direction is benign and I am **not** calling it a defect;
but the theoretical fail-open is a backend degradation that surfaces as an assertion-shaped message
rather than a transport one, which `is_evidence` cannot distinguish. **Accepted**, with the mitigation
recorded: run the gate without concurrent RPC load. I did not, at first, and caused the 429s myself.

**INFO-6 · The `osascript` interpolation in `page-liveness-keeper.sh:50-51` is not injectable.**
`$summary` is interpolated into a double-quoted AppleScript string inside a double-quoted shell
string, which would matter if any chain-controlled free text reached it. It does not:
`classifyMarket` (`keeper/keeper-health.mjs:61-66`) builds every line as `${token}` — a hex address —
plus fixed literals, and the only other dynamic value is `errorName` (`keeper-health.mjs:40`), which
comes from ABI decoding and is drawn from the repo's own bounded identifier set. **Checked and
cleared** rather than silently passed.

---

**INFO-7 · A shipped source comment cites a line number that holds something else.**
`script/DeployMarkets.s.sol:21-22` reads "flat at the policy rate up to the pool's kink (80% util,
`EsseyPool.sol:108`)". `EsseyPool.sol:108` is `uint256 public totalBorrows;`. The 80% kink is
`kinkBps = 8_000` at **`:119`**. The citation was already stale before this commit and the MED-1
fix's three added lines (`:112-114`) moved it three further; round 8's own report inherited it. Same
class as the `accrueFor` finding — a comment a reader cannot verify — but far milder. Worth a
general note: **line-number citations inside source comments go stale on every insertion above
them**, so prefer naming the symbol (`kinkBps`) over the line.

---

**INFO-8 · The "14/14 killed, adversarial in every direction" evidence behind the MED-1 fix rests
on a classifier that fails OPEN on transport failures.** `mutate-med1-fix.py`
(`~/.claude/gate-receipts/audit-glend-r8-poc/`) does have a real self-test — `_self_test()` runs
first in `main()`, uses `assert`, and includes two negative cases; I re-ran it and it reports
`4/4 ok`. But its `killed_by()` has **no evidence test at all**: any `[FAIL` line containing a
`test_x(` token counts as a kill. Driven over the three shapes the main gate's LOW-4 fix exists to
reject:

```
killed_by(429 transport           ) -> ['test_onlyTheWitnessedPausedWindowIsForgiven']
killed_by(OutOfFunds              ) -> ['test_anIdlePoolKeepsItsAccrualClockCurrent']
killed_by(ERC20InsufficientBalance) -> ['test_aPauseAtTheCallInstantCannotEraseAnUnpausedInterval']

is_evidence(429 transport           ) -> False      # the main gate, same three lines
is_evidence(OutOfFunds              ) -> False
is_evidence(ERC20InsufficientBalance) -> False
```

The fix receipt says the script's corrections were "Same shapes as LOW-3 and LOW-4." They are the
**LOW-3** shapes (a `[PASS]` line counted as a kill; `]` inside revert data breaking the name regex).
The **LOW-4** shape — an open set of transport failures scored as evidence — was never addressed
there. It also has no completion check, and no `if __name__ == "__main__"` guard, so importing the
module runs it. This does not show the 14/14 is wrong; it shows that figure is **unverified in the
transport dimension**, and LOW-1 shows the mutant set was not adversarial in every direction either.
**Seventh instance of the standing shape**, in the one script the receipt cites as already fixed
twice. If that script is kept, give it the main gate's `is_evidence` and a completion check; better,
fold its mutants into `glend-r4.py` where both already exist.

---

# The tooling — re-run from zero, every instrument controlled

Four tooling defects have produced false evidence in this engagement, including in my own rounds, and
a fifth appeared in the engineer's waiters. **A sixth appeared in mine, this round.** The standing
rule is applied to every instrument below: *shown to produce a negative result before any positive
result was trusted.*

## The mutation gate, run from zero

Fresh `git archive 1bc9ec7` root, `lib/` copied. **Clean baseline measured, not recalled:**

```
Ran 17 test suites in 49.91s (361.17s CPU time): 412 tests passed, 0 failed, 0 skipped (412 total tests)
```

`EXPECTED_TESTS = 412` in `test/mutants/glend-r4.py` is therefore correct at this SHA.

**Result: 42/42 KILLED. 0 survivors, 0 `RPC-FLAKE`, 0 `RUN-INCOMPLETE`, 0 `ANCHOR-MISS`,
0 `NO-COMPILE`.**

```
$ grep -oE '^(KILLED|SURVIVED|RPC-FLAKE|NO-COMPILE|RUN-INCOMPLETE|ANCHOR-MISS)' gate-r9.log | sort | uniq -c
  42 KILLED
$ tail -1 gate-r9.log
42/42 killed
```

**Every kill line was read and re-classified**, not counted. All 42 detail lines were fed back
through the repo's own `is_evidence`:

```
rows parsed: 42   scored on non-evidence: 0
transport / out-of-funds disguises among the scored kills: 0
```

Eight of the 42 are decoded reverts rather than assertion messages, so the decode was checked at the
source: `error PriceNotCorroborated(address token);` is declared at **`src/EsseyPool.sol:66`**, and
the control holds — `grep -rn "error ERC20InsufficientBalance(" src/` returns **0**, which is exactly
why `is_evidence` rejects that shape. The remaining 34 are assertion text or forge's own closed-set
harness verdicts (`next call did not revert as expected`, `call reverted as expected, but without
data`).

**This run produced zero RPC flakes, and that is informative.** Round 8's five `RPC-FLAKE` results
came from the backend degrading 429 → 403 under that session's own load. I reproduced the same
degradation earlier in this round by running a probe alongside the gate, then stopped doing it; run
alone, the gate saw no transport failure at all. The five flakes were self-inflicted load, not an
unreliable endpoint — worth knowing before anyone treats flake counts as a signal about the RPC.

`~/.claude/gate-receipts/audit-glend-r9-poc/mutation-gate-r9.log` holds the full run.

## `is_evidence` — negatives first, then positives, on real data

The LOW-4 fix replaced a three-string transport denylist with a positive test. Driven over the
module's own `is_evidence`, imported from the repo:

```
=== NEGATIVES: is_evidence MUST return False ===
ok  DECLINED   transport 429                     ok  DECLINED   transport 403
ok  DECLINED   transport send                    ok  DECLINED   transport timeout
ok  DECLINED   transport reset                   ok  DECLINED   transport db
ok  DECLINED   transport 1559                    ok  DECLINED   OutOfFunds
ok  DECLINED   EvmError: OutOfFund               ok  DECLINED   ERC20InsufficientBalance
ok  DECLINED   ERC20InsufficientAllowance        ok  DECLINED   the [PASS] disguise (LOW-3 shape)
ok  DECLINED   transport 403 url
negatives misclassified: 0/13
```

And against the **live 429 this session produced**, verbatim rather than synthesised:

```
[FAIL: EVM error; database error: failed to get account for 0x6B22A786…2cD0: Max retries exceeded
 HTTP error 429 with body: {"jsonrpc":"2.0","error":{"code":429,"message":"Too Many Requests"}}
  is_evidence -> False   (must be False)
```

Then positives — **ten real kill lines produced by my own runs this session**, not from a fixture:

```
positives missed: 0/10
```

`ERC20InsufficientBalance` and `OutOfFunds` — the two shapes round 8 found being banked as kills —
are both declined, and `[PASS]` is declined. The classifier is verified in both directions.

## The completion check

```
ok  COMPLETE   (ran=412)   REAL clean baseline I ran this session
ok  INCOMPLETE (ran=400)   REAL degraded X-P run I ran this session (429 ate a suite)
ok  INCOMPLETE (ran=None)  killed subprocess: no summary at all (the R8 LOW-3 shape)
ok  INCOMPLETE (ran=400)   a mutant that DELETES tests
ok  INCOMPLETE (ran=None)  truncated mid-summary
ok  INCOMPLETE (ran=1)     single-suite run mistaken for the full set
ok  COMPLETE   (ran=412)   complete but with failures summing to 412
misclassified: 0/7
```

The collection step was checked too: forge prints its `[FAIL` lines at column 0 (my X-P run's lines
matched `grep -E '^\[FAIL'`), so `startswith("[FAIL")` sees them; the indented copies under
`Failing tests:` are duplicates, not the only occurrence.

## Is the declining behaviour real, or merely reported? — REAL, two independent witnesses

1. **Mine.** My X-P run degraded to HTTP 429 under my own concurrent load. Driving the repo's own
   `is_evidence` over the verbatim line returns `False` — the gate would have returned `RPC-FLAKE`,
   not a kill.
2. **Independent.** A second probe against the `:540` call site hit a live 429 mid-mutant; the gate
   returned `RPC-FLAKE` and **refused to score it**, resolving to a verdict only after backoff. The
   same probe witnessed all four verdict classes — `ANCHOR-MISS` on a non-existent anchor,
   `SURVIVED` on a provably equivalent mutant, `RPC-FLAKE` on the live 429, `KILLED` on M42 — so the
   classifier is demonstrably not a constant in any direction.

## The sixth instance of the standing shape — in MY instrument

Two waiter shells were spinning at 48 minutes on
`until [ "$(pgrep -f 'glend-r4.py' | wc -l)" = "0" ]`. `pgrep -f` matches against full command
lines **including the waiting shell's own**, so the count can never reach 0 and the negative branch
is unreachable — identical to the `[PASS]` regex and to the fifth instance already recorded. **My
first process check had the same defect** and reported two shells as gate processes:

```
=== MY instrument, as I first wrote it (DEFECTIVE) ===
pgrep -f 'glend-r4.py' ->
  pid 30009 : …/Python … test/mutants/glend-r4.py     <- the real gate
  pid 99321 : /bin/zsh -c … until [ "$(pgrep -f 'glend-r4.py' …                <- a waiter
  pid 99583 : /bin/zsh -c … until [ "$(pgrep -f 'glend-r4.py' …                <- a waiter
```

**The bracket trick does not fix this one** — the literal pattern is in the *other* shells' argv, not
only the matcher's. The correct instrument matches the interpreter, not the string, and was shown to
return a negative before use:

```
=== CORRECT instrument ===              ps -Ao pid=,command= | awk '$2 ~ /[Pp]ython/ && /glend-r4\.py/'
gate pids -> 30009
=== NEGATIVE CONTROL ===                same instrument, pattern that matches nothing
  empty -> the instrument CAN return a negative (not a constant-true)
```

## The PoC harness

`AuditR9Straddle.t.sol` ships its own negative control,
`test_r9_negativeControl_noPauseAnywhereMeansNoDifference`, which runs the identical warps and calls
with no pause anywhere and asserts the two worlds are identical. It **passes** (`770210958 ==
770210958`), so the two failing tests are measuring the pause and not the fixture. Written and run
before the positives were believed.

---

# What this round did NOT cover — stated so it is not mistaken for coverage

- **The full-tree suite.** I measured the gate's targeted suite (412/412), which is the denominator
  the gate's verdict is defined over. The engineer's `1841 passed / 94 suites` tree-wide figure I did
  **not** re-run — running it concurrently would have polluted the gate's RPC. **UNVERIFIED by me.**
  Settled by one clean `forge test --skip script` run with the gate idle.
- **The keeper's own test suite** (`124/124` claimed). Not re-run. **UNVERIFIED by me.**
- **Real launchd scheduling.** LOW-2 establishes that nothing is installed; whether the unit works
  once installed is settled by `launchctl load -w` plus one observed page, which is a machine action
  and not mine to take.
- **The feed-volatility measurement** behind the 48h requote. I verified the arithmetic reconciles
  against `measure-feed-volatility.mjs:139` (`headroom = 0.2125 / worst`, giving 21.25/12.61 = 1.69x
  AAPL down-side and 21.25/13.52 = 1.57x NVDA absolute) and that the doc and the contract comment
  agree. I did **not** re-walk the feeds; that was round 8's independent measurement.
- **`EsseyMarkets` beyond the two carried-forward call sites.** Seven rounds have hardened it and the
  42-mutant gate re-ran over it; I did not re-derive the delay line from scratch.

---

# Round-8 items, closed or carried

| Round-8 item | Status at `1bc9ec7` |
|---|---|
| MED-1 direction A (one instant erases a year) | **CLOSED.** `test_aPauseAtTheCallInstantCannotEraseAnUnpausedInterval` passes; I re-ran it. |
| MED-1 direction B, witnessed | **CLOSED** for intervals bracketed by two paused observations. Head/tail still charged — INFO-2. |
| MED-1 direction B, unwitnessed | **CORRECTLY DECLARED NOT CLOSABLE.** Ruling 1. Reasoning holds; the dichotomy it sits in is incomplete, which is LOW-1. |
| MED-1, new residual | **LOW-1** — the straddle. |
| `accrueFor` invented symbol | **CLOSED.** INFO-1. |
| LOW-1 12h SLO → 48h, pager built | **CODE AND DOCS CLOSED.** Not installed — **LOW-2.** |
| LOW-2 M42 / X-O | **CLOSED.** M42 present at `glend-r4.py:200`, killing; test at `DesyncBreaker.t.sol:115-137`. |
| LOW-3 completion check | **CLOSED.** 7/7 on my own synthetic and real outputs. Residual INFO-5. |
| LOW-4 `is_transport` → `is_evidence` | **CLOSED.** 13/13 negatives, 10/10 positives, live 429 declined. |
| INFO-1 1.65x → 1.69x, statistic relocated | **CLOSED.** Absolute statistic under `MAX_PRICE_DEVIATION_BPS:359-364`; down-only figures under `PRICE_CONFIRM_DELAY:417-420`. |
| Carried: X-P | **REFUTED.** Ruling 2. Strike it. |
| Carried: `EsseyMarkets.sol:525` | **NO GAP.** Ruling 3. INFO-3, INFO-4. |

---

# Gate status

**NOT CLEAN — 0 CRIT / 0 HIGH / 0 MED / 2 LOW / 8 INFO.** The G-LEND three-consecutive-clean counter
does **not** advance this round.

Neither LOW blocks on its own merits — the stack is not deployed and neither is live value at risk —
but the standing rule is that a round with findings resets the counter, and LOW-1 in particular
should be fixed rather than accepted, because leaving it means leaving a test in the tree that goes
red on the correct fix.
