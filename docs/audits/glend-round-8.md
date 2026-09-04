# G-LEND gate — round 8 — Solidity / contract security lens

**Date:** 2026-09-04
**Frozen SHA:** `959b70a53a885ba2ab2aae17b5a1792c5e10ee16`
**`git status --porcelain`:** **empty (0 lines)** at the start of the round and again at the end.
Every probe ran in a `git archive 959b70a` scratch root with `lib/` copied (never symlinked). Two
files were briefly written into the working tree (`rh-chain/keeper/.r8-decode-probe*.mjs`, needed to
import the keeper's own module resolution); both were removed and `git status --porcelain` re-run
empty before the round continued. The sha256 of every audited file was taken at the start and
re-taken at the end and is identical.

**Substrate:** Robinhood Chain **mainnet**, real fork.
RPC `https://rpc.mainnet.chain.robinhood.com` · `eth_chainId` → `0x1237` = **4663**
`eth_blockNumber` → `0x33fc3cc` = **54,510,540** at the start of the round
`web3_clientVersion` → `nitro/v3.11.4-rc.3-7d5ac27/linux-amd64/go1.25.14`
(round 7 recorded `linux-arm64`; the public endpoint is load-balanced across both. Recorded, not
inferred; it changes nothing.)

**Deployment state, verified rather than assumed:** the lending stack is **NOT deployed on 4663** —
`rh-chain/broadcast/DeployMarkets.s.sol/` does not exist, while 20 other deploy broadcasts do. The
substrate the fork supplies is real: AAPL `0xaF3D…93f9`, NVDA `0xd060…9EEC`, USDG `0x5fc5…d168` and
the feeds `0x6B22…2cD0` / `0x379E…9F15` all return non-empty `eth_getCode`.

---

## VERDICT

**NOT CLEAN.** 0 CRITICAL · 0 HIGH · **1 MEDIUM** · 4 LOW · 9 INFO.

Round 7 returned 0/0/0 with two LOWs, and both were closed. This round does not return clean, and
the reason is worth stating plainly: **the finding is not in the delay line.** Seven rounds have
hardened `EsseyMarkets`' corroboration machinery, and it held — the 41-mutant gate is genuinely
41/41 and I could not break it. The MEDIUM is in `EsseyPool.accrue()`, and it was found by taking
round 7's own generalised lesson — *a fixture that varies one dimension cannot pin a property over
two* — and pointing it at a different file.

---

# MED-1 · `accrue()` discards the WHOLE elapsed interval on an instantaneous borrow-asset pause

**Permissionless. Repeatable. Wrong in both directions. CONFIRMED with a runnable PoC.**

### The code path

`rh-chain/src/EsseyPool.sol:220-223`

```solidity
function accrue() public {
    (uint256 num, uint256 denom) = _growth();
    lastAccrual = block.timestamp;      // :222 — advanced BEFORE the early return
    if (num == denom) return;           // :223
```

`rh-chain/src/EsseyPool.sol:254-259`

```solidity
function _growth() internal view returns (uint256 num, uint256 denom) {
    denom = BPS * SECONDS_PER_YEAR;
    uint256 dt = block.timestamp - lastAccrual;
    if (dt == 0 || totalBorrows == 0 || _borrowAssetPaused()) return (denom, denom);
    return (denom + borrowRateBps() * dt, denom);
}
```

The pause is sampled **instantaneously**; the quantity discarded is the **entire** `dt` back to
`lastAccrual`. `lastAccrual` is written in exactly two places — `:180` (constructor) and `:222` —
so nothing else can correct it (`grep -n "lastAccrual" src/EsseyPool.sol` → `111, 180, 222, 256`).
`accrue()` is `public`, has no access control and no `nonReentrant`: **any address may call it.**

### Direction A — a fully unpaused year, erased by a stranger, for gas

`AuditR8Accrual.t.sol::test_aPauseAtTheCallInstantErasesAnEntirelyUnpausedYear`. Both worlds run from
one `vm.snapshotState()`, so the only difference is the pause at the call instant. Pool shaped like
the deploy script's kink curve (`Curve(1_000, 500, 6_000)`, `script/DeployMarkets.s.sol`
`RateModes.curve`), 700.000000 USDG of debt:

```
debt at borrow                     : 700000000
debt after the year, honest        : 770000000
debt after the year, stranger call : 700000000
borrower interest erased (USDG 6dp): 70000000
lender assets honest / erased      : 100070000000 100000000000
[FAIL: a year in which repayment was perfectly possible must still be charged: 700000000 != 770000000]
```

Repayment was possible on every one of that year's 31,536,000 seconds. `address(0xBAD)` — no
privilege, no position, no stake — called `accrue()` in the second USDG reported paused, and
**70.000000 USDG of lender interest, plus the `reserveBps` cut on it, ceased to exist**. The lender
claim goes 100,070 → 100,000 USDG. USDG may unpause the next second; the interest does not come back.

### Direction B — a year in which repayment was genuinely impossible, charged in full

`test_aPausedWindowBetweenTwoAccrualsIsChargedInFull`: pause on, warp 365d, pause off, `accrue()`.

```
debt before the paused year: 700000000
debt after it              : 770000000
[FAIL: a year in which repayment was impossible must not be charged: 770000000 != 700000000]
```

This is exactly the outcome `EsseyPool.sol:217-219` says the design prevents — "Charging interest
across that window bills them for time in which repayment was impossible — and it is the issuer's
pause, not theirs."

### Why nothing caught it — the false green, proven by mutation rather than argued

`test_accrualSuspendsOnlyWhenBorrowAssetPaused` (`test/EsseyPool.t.sol:586`, borrow-asset leg at
`:601-607`) sets `usdg.setPausedWord(1)` **before** `vm.warp`, so the pause state is CONSTANT across
the interval. The property ranges over two dimensions — pause state AND time — and the fixture varies
one. `setPausedWord` appears at exactly three sites in the whole suite (`:603`, `:607`, `:617`), so
this is the only test of the property.

I did not stop at "it looks unpinned". I applied the candidate fix and re-ran the test:

```
=== BASELINE: the existing test on the frozen tree ===
[PASS] test_accrualSuspendsOnlyWhenBorrowAssetPaused() (gas: 20712023)
FIX applied: lastAccrual no longer advances when nothing accrued
=== THE FIX: does the existing test still pass? ===
[PASS] test_accrualSuspendsOnlyWhenBorrowAssetPaused() (gas: 20711388)
```

**The test passes identically against the defect and against the fix.** It cannot fail for the
absence of the property it is named for, in either direction.

### The comment names a function that does not exist

`EsseyPool.sol:219` — "`accrueFor` skips paused intervals."
`grep -rn "accrueFor" rh-chain/src rh-chain/test rh-chain/script docs` returns **that comment and
nothing else**. A reader cannot discover the real behaviour from the code's own documentation. This
is the same shape as the `emailDisclosedRedeemers` incident in the house rules: a comment asserting a
mechanism that was never built, making an ungated path look gated.

### Precondition verified live on chain, not assumed

USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` on 4663 implements `paused()` (selector
`0x5c975abb`) and returned `0x00…00` at block 54,510,540 — not paused now, but the surface is real
and third-party-held. It is an ERC-1967 proxy (slot `0x360894…82bbc` → implementation
`0x68184c449e1a8f34fa18d289737129fd27b66f8f`, 18,645 bytes of code), so the issuer holds both the
pause and the ability to change what pausing means.

### Magnitude at the deployed parameters

Kink curve base 1,000bps / slope1 500bps / kink 80% (`EsseyPool.sol:108`), per-market `cap` 250,000
USDG (`script/DeployMarkets.s.sol:395`). At full cap and 50% utilisation the rate is 1,312bps, so
**≈ $89.86 of lender interest destroyed per day of `dt`**. `accrue()` fronts all 14 entry points
(`:318, 327, 341, 346, 351, 356, 415, 437, 505, 527, 607, 679, 709, 808`), so on a busy pool `dt` is
minutes. On a quiet pool, a single-borrower market, or a newly listed one, it is days to weeks: a
7-day stretch crossed by any USDG pause is ≈ $629, 30 days ≈ $2,696. **Nothing in the contract
bounds `dt`.**

### Severity, argued in both directions rather than asserted

**Not HIGH.** It cannot create bad debt, cannot move principal or collateral, and cannot let anyone
take value they did not have. Solvency is untouched — `totalAssets()` only ever falls, so the pool
never owes more than it holds. It also requires an exogenous USDG pause, which no attacker controls.

**Not LOW.** It is a permissionless, repeatable, unbounded transfer of value away from lenders on a
live money path; both directions are wrong and each harms a different party; the mechanism's own
comment names a symbol that does not exist; and the single test named for the property has been
proven unable to detect its absence. Seven rounds passed over it.

**MEDIUM.**

### Fix — and a warning, because the obvious one-liner is wrong

The obvious minimal fix is to move the write below the early return:

```solidity
(uint256 num, uint256 denom) = _growth();
if (num == denom) return;               // leave lastAccrual where it is
lastAccrual = block.timestamp;
```

**Do not ship that.** `_growth()` returns `(denom, denom)` for **three** reasons — `dt == 0`,
`totalBorrows == 0`, and the pause — and only the third means "suspend the clock". The other two mean
"nothing to accrue", which must still advance it. I measured the consequence
(`AuditR8FixCheck.t.sol::test_anIdlePoolStillKeepsItsAccrualClockCurrent`, an assertion on state so no
market session or feed freshness is involved):

```
=== FROZEN TREE (correct here) ===
[PASS]  now: 1758119400   lastAccrual: 1758119400   stale by (s): 0
=== UNDER THE MINIMAL FIX ===
[FAIL: an idle pool has nothing to accrue, so the clock must advance - otherwise the first borrower
       is billed for it: 1755099000 != 1758119400]
        now: 1758119400   lastAccrual: 1755099000   stale by (s): 3020400
```

Under the one-liner, an idle pool leaves the clock **35 days stale**, and the first borrower is
charged 35 days of interest on a loan one second old. (The same effect is visible in the direction-A
PoC: the "honest" figure moves from 770,000,000 to 770,950,913 under the fix, the extra 950,913 being
interest for the setUp window before the loan existed.)

The correct shape distinguishes the three reasons, and closing **direction B** additionally requires
recording *when* the pause began — it is not a one-liner:

```solidity
// sketch, NOT audited: `pausedSince` set by the first call that observes the pause,
// cleared by the first call that observes it lifted; accrue up to `pausedSince`,
// and on resumption skip `lastAccrual` forward past the paused window.
```

Whichever shape is chosen, **the test must vary the pause state WITHIN the interval, in both
orders** (unpaused→paused and paused→unpaused), or it will pass for the wrong reason again.

---

# LOW-1 · The 12-hour keeper-gap SLO has no mechanism behind it

*(This is the assessment the round was asked for, given as my own rather than the engineer's.)*

`docs/MAINNET-CONFIG.md:141-143` and `rh-chain/src/EsseyMarkets.sol:399-403` condition the stated
risk horizon on "**12h — 9h until `UNOBSERVED` goes fatal at `MAX_CONFIRM_AGE`, plus 3h to restore
observation**".

**The 9h is correct as arithmetic.** `MAX_CONFIRM_AGE = PRICE_CONFIRM_DELAY + 2 * CONFIRM_STEP` =
6h + 2×1.5h = 9h (`EsseyMarkets.sol`), and `classifyMarket` fires `UNOBSERVED` **fatally** at
`confAge > maxAge` (`keeper/keeper-health.mjs`). **But that is the time until the alarm CONDITION
becomes true, not the time until anyone is told.**

`check-liveness-keeper.mjs` — the only thing that evaluates that condition — is **not scheduled
anywhere in the repo.** The single launchd unit, `rh-chain/keeper/xyz.essey.liveness-keeper.plist`,
runs `keeper/liveness-keeper.mjs`, the keeper itself. The supervisor appears only as a manual command
in `rh-chain/RUNBOOK.md:75-77`. So the delivered detection time is 9h **plus however often a human
runs it**, and the 3h restore term assumes a round-the-clock response that nothing in the repo
provides. `KeepAlive` restarts a *crashed* keeper; it does not catch the failure this supervisor
exists for — a keeper that is up and observing nothing, which is R4 HIGH-2 exactly.

### Is 12h defensible? No as a measured commitment — and it does not need to be

Measured directly from both feeds by an independent walk (see *Evidence*), with
horizon = max feed gap + 6h delay + 1.5h step + SLO:

| SLO | AAPL horizon | AAPL abs / **down** | NVDA horizon | NVDA abs / **down** | binding headroom (abs) |
|---|---|---|---|---|---|
| 0h | 87.2h | 12.61% / **12.61%** | 83.6h | 12.90% / **9.41%** | 1.65x |
| **12h (stated)** | 99.2h | 12.61% / **12.61%** | 95.6h | 12.90% / **10.37%** | **1.65x** |
| 24h | 111.2h | 12.61% / **12.61%** | 107.6h | 13.52% / **10.37%** | 1.57x |
| 48h | 135.2h | 12.61% / **12.61%** | 131.6h | 13.52% / **10.58%** | 1.57x |
| 88h (one week total) | 175.2h | 12.61% / **12.61%** | 171.6h | 17.17% / **11.28%** | 1.24x |
| 120h | 207.2h | 12.61% / **12.61%** | 203.6h | 17.93% / **11.28%** | 1.19x |

**The 12h SLO buys nothing: the headroom is 1.65x whether the SLO is 0h or 12h.** Moving to 24h or
48h costs 0.08x. A full week of undetected keeper downtime costs 0.41x and still does not approach
1.0x on this sample. On the **risk-relevant (down) side** the binding number is AAPL's 12.61% /
**1.69x, and it is completely flat from 0h to 120h of SLO**.

**What breaks at 24h or 48h: nothing measurable.** What would break the buffer is a single-name tail
the 74-day sample cannot bound — which `EsseyMarkets.sol` already says in the same comment block
("74 days holding one stress episode cannot BOUND a 21.25% tail, only miss it"). That caveat is the
honest one and it is strictly stronger than the SLO question.

### Recommendation — two parts, both cheap

1. **Stop conditioning a contract constant's justification on an unbacked operational promise.**
   Quote the horizon at a deliberately pessimistic keeper gap — 48h — which costs 0.08x of headroom
   and removes the promise from the derivation entirely. A number that does not depend on a human
   answering a page at 03:00 on a Sunday is worth more than 0.08x.
2. **Still build the mechanism**, because the supervisor is the only thing that catches an
   observing-nothing keeper: a second launchd unit (or a systemd timer) running
   `check-liveness-keeper.mjs` on an interval, with its non-zero exit wired to something that pages.
   Then the SLO can be *stated from measurement* rather than committed to. Until then it is prose,
   and the house rule on prose applies.

---

# LOW-2 · The breaker's BASELINE product is unpinned — a survivor that leaves 499/499 green

**CONFIRMED non-equivalent, with a discriminating test that is green on the frozen tree and red on
the mutant.**

`rh-chain/src/EsseyMarkets.sol`, in `_syncPrice`:

```solidity
uint256 prevPrice = seenPrice[token];
uint256 prev = prevPrice * prevMult;      // <-- the BASELINE product
...
_breaker(token, prev, price * curMult, baselineAge);   // <-- the OBSERVED product
```

Two sibling products are built from two pairs. The gate mutates the **observed** one — my probe's
X-N (`price * prevMult`) is killed by `test_theBreakerClearsWhenTheSecondLegLands` — and **never the
baseline one.**

**Survivor X-O:** `uint256 prev = prevPrice * curMult;` — the old price against the *new* multiplier.

```
SURVIVED        X-O  breaker baseline is prevPrice x CUR multiplier
                the whole targeted suite stayed green
```

**Not equivalent.** It differs precisely when `prevMult != curMult`, i.e. exactly when a corporate
action lands. For a corporate action whose **multiplier leg lands first** (the feed has not repriced
yet), the correct code sees `P·M` against `P·2M` — a 100% dislocation — and arms. Under X-O it sees
`P·2M` against `P·2M`, a 0% deviation, and **does not arm**.

Proven, not argued (`AuditR8Baseline.t.sol::test_theBaselineIsTheLastMATCHEDPairNotAHalfUpdatedOne`):

```
--- frozen tree ---            --- X-O applied ---
baseline price          : 20000000000            20000000000
baseline multiplier     : 1000000000000000000    1000000000000000000
multiplier now          : 2000000000000000000    2000000000000000000
armed at                : 1755099000             0
reference product held  : 20000000000000000000000000000   0
[PASS]                          [FAIL: the reference is the last MATCHED pair's product …: 0 != 2e28]

Ran 18 test suites: 499 tests passed, 1 failed  (the 1 is MY new test)
```

**Why the suite cannot see it, stated exactly.** Every fixture that varies the multiplier reaches
`_breaker` in its **ARMED** state, where `prev` is dead code — `test_theBreakerClearsWhenTheSecondLegLands`
(`test/DesyncBreaker.t.sol:89-105`) drops the *feed* first (`px.set(100e8, …)`), arms, and only then
calls `tok.setMultiplier(2e18)`, which lands in the `if (ref != 0) { … return _disarm(…) }` branch
that returns before `prev` is read. Every fixture that reaches `_breaker` **unarmed** holds one
multiplier throughout, where `prevMult == curMult` makes the two spellings identical. The baseline's
multiplier half is unreachable by any assertion in the suite. There is a
`test_feedFirstSplitCannotLiquidateAHealthyPosition`; there is no multiplier-first equivalent.

**Impact of the gap.** The shipped code is correct — the frozen tree arms. Were the mutation ever
introduced, a multiplier-leg-first corporate action would fall back on `_desyncGuard` branch (b)
(`multiplierMovedAt`, `MULTIPLIER_GUARD_WINDOW` = 1h) instead of branch (b) **plus** the breaker's
`PRICE_DESYNC_HOLD` = 6h — and `test_theBreakerClearsWhenTheSecondLegLands` explicitly claims "the
two guards settle independently, and the LONGER of them is what a borrower actually gets". During the
uncovered 5h, `collateralValue` reads the live (doubled) multiplier against the not-yet-halved feed:
a ~2x over-valuation, bounded only by `borrowCap` and `maxPositionBps`.

**Severity: LOW** — a mutation-coverage gap on correct code, the same class as R7 LOW-2, and the
fourth instance of one rule: *a call forwarding two sibling values needs each argument mutated
independently, against every source the wrong value could come from.* Rounds 6 and 7 applied that
rule to `_holdConfirmable`'s pair (M32, M38-M41). It was never applied one call deeper, to
`_syncPrice`'s two products.

**Fix.** Add X-O to `test/mutants/glend-r4.py` as M42, and ship the discriminating test above
(it is written and verified in both directions; the artefact is in the receipt).

---

# LOW-3 · The mutation gate cannot tell "the suite stayed green" from "the suite never ran"

`rh-chain/test/mutants/glend-r4.py`, `suite_verdict()`:

```python
fails = [l for l in out.splitlines() if l.startswith("[FAIL")]
if not fails:
    return "SURVIVED", "the whole targeted suite stayed green"
```

A `forge test` that is killed, crashes, or aborts before any test runs produces **zero `[FAIL` lines**
and is reported `SURVIVED`. Nothing checks that the run completed — no assertion on the
`Ran N test suites` summary, no expected test count, no exit code.

**Evidence, produced accidentally and then chased down.** While gate run 1 was in flight I ran
`pkill -f "forge test"` cleaning up after an unrelated probe. It killed the gate's in-flight
subprocess. Run 1 reported:

```
SURVIVED    M32 warm from the last RAW read instead of the ring head (R6 LOW-2)
            the whole targeted suite stayed green
40/41 killed
```

Applied by hand to a clean root, **M32 dies on two separate tests**:

```
[FAIL: every warm push stands on the ring head: 26096407897 != 32217787528]
      test_theWarmPushStandsOnTheRingHeadNotOnTheLastRawRead()
[FAIL: every warm push carries the ring head's OWN multiplier: 500283040030546218 != 1000566080061092436]
      test_theWarmedMultiplierIsTheRingHeadsNotTheLastRawRead()
```

The direction here is safe — it over-reports gaps — and the cause was mine, not the tool's. It is
recorded because a gate result must be **self-validating**: without a completion check the gate
cannot distinguish "no test failed" from "no test ran", and that is one negation away from LOW-4.

**Fix.** Require the summary before believing any verdict, and pin the count from the clean baseline
(**399** at this SHA) so a mutant that *deletes* tests is caught too:

```python
m = re.search(r"Ran \d+ test suites?.*?: (\d+) tests passed, (\d+) failed", out, re.S)
if not m or int(m.group(1)) + int(m.group(2)) != EXPECTED_TESTS:
    return "RUN-INCOMPLETE", "the suite did not run to completion"
```

---

# LOW-4 · `is_transport` is an allowlist of three observed strings, so it fails OPEN on any transport failure nobody has seen yet

`rh-chain/test/mutants/glend-r4.py`:

```python
TRANSPORT = ("Max retries exceeded HTTP error 429", "database error:", "Failed to get EIP-1559")
```

Tested against the module's own `is_transport`:

```
TRANSPORT        [FAIL: backend: Max retries exceeded HTTP error 429 Too Many Requests]
TRANSPORT        [FAIL: database error: connection]
TRANSPORT        [FAIL: Failed to get EIP-1559 fees]
counted-as-REAL  [FAIL: ERC20InsufficientBalance(0x.., 0, 5)]
counted-as-REAL  [FAIL: EvmError: OutOfFunds]
counted-as-REAL  [FAIL: error sending request for url]
counted-as-REAL  [FAIL: operation timed out]
counted-as-REAL  [FAIL: connection reset by peer]
```

The three recognised strings are exactly the three that were *observed*. `error sending request`,
`operation timed out` and `connection reset by peer` are ordinary HTTP-transport failures from the
same rate-limiting backend, and each would be counted as **a real kill by evidence that never ran** —
R7's defect #2 under a different string. `ERC20InsufficientBalance` / `EvmError: OutOfFunds` are the
fixture-funding shape that bit round 5; `GLendR4Base._fund` now uses `deal()` so the fixture no longer
depends on a third party's live balance, but the classifier would not catch a recurrence.

**It did not bite this round.** I extracted all 41 kill lines from the clean run and inspected each:
every one is a named assertion string with concrete numbers, or a decoded custom-error revert
(`PriceNotCorroborated(0xF628…)`). **No kill line in either run is a transport error or an
out-of-funds error in disguise.**

**Fix.** Invert the allowlist. Recognise the shapes that ARE evidence — a Foundry assertion string, a
revert with decodable data, an `expectRevert` mismatch — and treat everything else as inconclusive.
A list of the failures you have already seen cannot cover the one you have not.

---

# INFO

**INFO-1 — `EsseyMarkets.sol:402-403` states a justification that is false for NVDA at 100h.**
"Full horizons 100h and 96h; the worst move is 12.61% (1.69x) and 12.90% (1.65x) at both, since
**neither feed's worst window grows past 84h**." The four quoted figures are right — I reproduced all
of them independently — but the justification is not: NVDA's worst absolute window is 12.90% at
84h/88h/96h and **13.52% at 100h**. Read per-feed-within-its-own-horizon the clause holds; as written
it licenses applying AAPL's 100h horizon to NVDA, where the number is 1.57x. Same text at
`docs/MAINNET-CONFIG.md:146-148`.

**INFO-2 — the economist's 7.06% point: CONFIRMED, it generalises further, and here is the ruling.**
NVDA's worst 1h move is 7.06% and it is entirely **upward**; the worst 1h **down** move is 3.76%
(ratio 1.88x, matching the economist's ~1.9x). It is not a one-row artefact: **for NVDA the worst
move is UP at every window I measured**, and at the 96h horizon the absolute 12.90% (1.65x) sits
against a down figure of 10.37% (2.05x). For AAPL the opposite holds — worst is DOWN at every window
— so AAPL's 12.61% / 1.69x is a genuine risk-side number.

> **RULING: the constant stands; the citation should be split.**
>
> `PRICE_CONFIRM_DELAY = 6 hours` spends the 21.25% threshold-to-liquidator-indifference buffer, and
> **only a DOWN move can turn collateral into bad debt**. The risk-side binding number is therefore
> AAPL's **1.69x**, which the direction question does not touch. No change to any constant is
> warranted.
>
> The citation is a different matter, for two reasons:
> - The justification overstates the risk side for NVDA by 1.88x at 1h and 1.24x at the horizon. The
>   error is in the **conservative** direction and can never under-size a market, which is why this is
>   INFO and not a finding. But `docs/MAINNET-CONFIG.md:150` instructs the founder to "read the risk
>   against 1.65x", and 1.65x is an NVDA **up**-move figure. Conservative-and-wrong is still wrong
>   when it is about to be copied into the next market's sizing, and the next name may not be one
>   that happened to trend up over the sample.
> - The absolute figure is not useless — it is filed under the wrong constant.
>   `MAX_PRICE_DEVIATION_BPS = 2_000` and `_deviates` compare the **absolute** product deviation, so
>   up and down matter equally there. I checked this is not itself a problem: `_breaker` refuses a
>   baseline older than `MAX_BASELINE_AGE = 1 hour` before calling `_deviates`, and the armed branch
>   runs at most `PRICE_DESYNC_HOLD = 6h`; the worst absolute moves at those windows are 7.06% and
>   7.88%, i.e. 2.83x and 2.54x inside the 20% bound. No spurious arming is reachable on the measured
>   sample.
>
> Recommended shape: quote **down-only** figures under `PRICE_CONFIRM_DELAY` / `MIN_RISK_GAP_BPS`,
> **absolute** figures under `MAX_PRICE_DEVIATION_BPS`, and say which is which — so the next listing
> copies the right statistic for the right constant. `measure-feed-volatility.mjs::worstMove` should
> return both directions rather than `Math.abs`.

**INFO-3 — `keeper/measure-feed-volatility.mjs` hard-codes its round counts, so it reads a staler
window every day.** `feeds = { AAPL: [addr, 555], NVDA: [addr, 981] }`, and `walk()` counts downward
from that number. Live `latestRoundData()` at block 54,510,540 gives aggregator rounds **567 (AAPL)
and 994 (NVDA)** — so the script now silently drops the newest 12 / 13 rounds, and will drop more
each week. `docs/MAINNET-CONFIG.md:151` says "Reproduce with `node keeper/measure-feed-volatility.mjs`",
and reproduction is the whole point of it. Read the phase and round from `latestRoundData()`.

**INFO-4 — `MAX_DARK_AGE = 345_600` (96h) will fire a fatal false alarm on an unscheduled multi-day
closure.** The derivation is sound for the *scheduled* calendar and I reproduced it exactly: 79.74h /
76.09h, both the 2026-07-02 → 07-06 window, 4 July 2026 falling on a Saturday and observed the
Friday, against 52.08–57.65h for ordinary weekends. A Friday or Monday holiday is the longest shape
the US equity calendar makes. Unscheduled closures are not in that set — Hurricane Sandy (NYSE closed
Mon+Tue, 2012) or a national day of mourning adjacent to a holiday would produce ~113h and trip
`FEED DARK TOO LONG`. That is a **fatal** alarm, i.e. the safe direction, and it should stay; it is
recorded so that when it happens nobody reads it as a bug. Note also that the 96h ceiling equals
NVDA's own full horizon, so at the moment the operator is paged the sizing budget is already spent —
acceptable given the LOW-1 sensitivity table, but worth knowing.

**INFO-5 — survivor X-U: the `prev != 0` conjunct on the multiplier-move stamp is unpinned.**
`if (prev != 0 && cur != prev) multiplierMovedAt[token] = block.timestamp;` → dropping `prev != 0`
survives the whole suite. Non-equivalent: on a market never yet observed (or one whose feed has been
dark since listing, so `seenMultiplier` is still 0) it stamps on every call, holding `_desyncGuard`
branch (b) true and refusing both `canBorrow` and `canLiquidate` for the dark window plus one hour.
**The harm is fail-CLOSED and bounded at `MULTIPLIER_GUARD_WINDOW` = 1h**, and a fresh market cannot
be corroborated for 6h anyway — which is why this is INFO and not LOW. Recorded because the conjunct
is currently unfalsifiable.

**INFO-6 — no balance-delta on either collateral pull (PLAUSIBLE, not confirmed).**
`EsseyPool.sol:443-445` (`borrow`) and `:648-651` (`addCollateral`) both `safeTransferFrom` and then
credit the **requested** amount; `SafeERC20` checks only the return value. A collateral token that
transfers less than requested while returning `true` would credit collateral that never arrived —
and because `_reconcile` runs *before* the pull (`:439-443`, deliberate), the shortfall is not seen
until the next reconcile, where it is socialised across the whole cohort rather than charged to the
depositor, turning a pool-wide sharing model into attacker-directed loss. **I could not confirm the
deployed AAPL/NVDA implementations under-transfer**, and the R4–R7 fork suites move real tokens
through the real `transferFrom` with exact accounting, which is evidence they do not. The residual is
that both are proxies the protocol does not control (283-byte proxies over upgradeable
implementations, `eth_getCode` = 568 hex chars). A pre/post `balanceOf` delta at both sites is two
lines and matches the file's own "impossible-by-construction" standard (`EsseyPool.sol:167`).

**INFO-7 — the constructor does not forbid `collateralToken == asset()` or `address(0)`.**
`EsseyPool.sol:144-181` validates the curve (`:157`), the sinks (`:158`), reward coherence
(`:161-163`) and asset decimals (`:168`), but not this. If the two coincide, posted collateral is
counted as cash by `totalAssets()` (`:295-296`) and by the `_withdraw` liquidity check (`:328`).
It takes a mis-deploy **and** an admin listing the borrow asset as its own collateral through the
2-day timelock (`_assertActivePool` requires a committed market with a feed), so it is a config guard
rather than an attack — but it is one line, in a file that closes this class by construction
elsewhere.

**INFO-8 — `writeOff`'s `effective == 0` branch skips `canLiquidate` and corroboration entirely.**
`EsseyPool.sol:816-819`: `if (effective != 0) floor = _writeOffFloor(...)`, and `_writeOffFloor`
(`:793-801`) is the sole carrier of `markets.canLiquidate`, the live `value >= owed` bar, and
`isInsolventCorroborated`. With `effective == 0` the resolver may settle at `recovered = 0` during a
liveness outage, a guardian `pauseLiquidation`, or a desync hold. **I found no value-extraction
path:** `effective == 0` means the collateral is genuinely gone, `_tryReturnCollateral` then transfers
nothing, and no price enters the arithmetic (the loss is `owed - recovered`, a debt quantity). The
residual is timing authority for a compromised resolver, plus a doc block (`:774-792`) that reads as
if the floor always applies. Hoisting `canLiquidate` out of `_writeOffFloor` gates both branches.

**INFO-9 — a force-liquidating threshold is reachable in ONE timelocked commit, not two.**
`commitMarket` guards the two-stage deprecation path only *below* `MIN_RISK_GAP_BPS`:
`if (p.m.liqThresholdBps < MIN_RISK_GAP_BPS) { … revert DeprecationOrderViolated … }`. A proposal of
`ltvBps = 0, liqThresholdBps = 2_500` passes `_validate` (the risk-gap check is skipped when
`ltvBps == 0`) **and** skips that guard (2,500 ≥ 2,000), so it commits directly from a live
5,000/7,500 market. Every position with debt above 25% of collateral value becomes liquidatable at
once — at the deployed 50% max LTV, that is all of them. Both routes are timelocked 2 days and emit
the full `MarketProposed` payload, so borrowers get public warning either way; the correction is that
it is **one** 2-day window rather than two. Worth stating precisely in the `admin` blast-radius note,
since the comment at `commitMarket` currently implies the two-stage path is the only route to a
force-liquidating threshold.

---

# What I verified CLEAN, with the evidence

### The mutation gate: 41/41, from zero, with real assertion strings

Two runs on a clean `git archive 959b70a` root with `lib/` copied. Run 1 returned 40/41 — the single
survivor was M32, and **I caused it** (LOW-3). Run 2 was clean and untouched:

```
41/41 killed
EXIT=0
```

All 41 kill lines inspected individually. Every one is a named assertion with concrete numbers
(`every slot stands on the LAST readable pair: 903010887255135923 != 735508011487353552`,
`and with room for the token to grow: 16000 <= 63148`, `a head AT the ceiling still warms`,
`fixture: too short to fill`, …) or a decoded custom-error revert
(`PriceNotCorroborated(0xF628…)`). **Zero transport errors, zero out-of-funds errors, zero
RPC-FLAKE, zero NO-COMPILE, zero ANCHOR-MISS.** Clean baseline: 399 tests / 17 suites / 0 failed.

*Observed, not a defect:* 11 of the 41 are killed by the same generic
`PriceNotCorroborated` revert in `test_addCollateralAfterLiquidationReverts` — those mutants break
corroboration globally and are caught by blanket breakage rather than by a test naming the property.
`suite_verdict` reports the first `[FAIL` line in output order, which is not necessarily the
discriminating one. The kills are real; the coverage behind them is more generic than the count
suggests.

### The revert decode (R7 LOW-1) — attacked, holds in every direction

Built a `Reverter` contract with eleven revert shapes, deployed it to a local anvil, and drove it
through the repo's **own** `revertName` / `priceState` / `classifyMarket` on the repo's own viem
(2.56.3), with **exactly** the error set `check-liveness-keeper.mjs` declares:

| revert shape | `errorName` | verdict, 3 days dark, keeper observing |
|---|---|---|
| `revert PriceStale(1,2,false)` | `"PriceStale"` | FEED DARK — **not fatal** |
| `revert PriceNotPositive(-1)` | `"PriceNotPositive"` | FEED BROKEN — fatal |
| `revert RoundIncomplete()` | `"RoundIncomplete"` | FEED BROKEN — fatal |
| custom error **not declared in the ABI** | `null` | FEED BROKEN — fatal |
| bare `revert()` (empty) | `null` | FEED BROKEN — fatal |
| `revert("PriceStale")` (string) | `"Error"` | FEED BROKEN — fatal |
| `1/0` → Panic 0x12 | `"Panic"` | FEED BROKEN — fatal |
| array OOB → Panic 0x32 | `"Panic"` | FEED BROKEN — fatal |
| `PriceStale` selector + **truncated** args | `null` | FEED BROKEN — fatal |
| `PriceStale` selector, **no** args | `null` | FEED BROKEN — fatal |
| 32 bytes of garbage | `null` | FEED BROKEN — fatal |

Every undecodable, empty, undeclared and malformed shape resolves to `null` and goes **fatal**. The
two forgery attempts — the declared selector with truncated args, and the selector alone — do **not**
decode as `PriceStale` and are **not** downgraded. `revert("PriceStale")` is the case a naive string
match would have got wrong; the structural decode gets it right.

Duration axis, well-formed `PriceStale` only: non-fatal `FEED DARK` at 40h / 79h / 79.74h / 95.9h /
96h; fatal `FEED DARK TOO LONG` at 96.1h / 120h / 336h. The boundary is exact at `MAX_DARK_AGE`.

The `maxDark` type guard is real, not decorative: `undefined`, `null`, the JS number `345600`, the
string `"345600"` and `NaN` all **throw** `classifyMarket: maxDark (seconds, bigint) is required` —
the silent-`false`-forever fail-open R7 LOW-1 named, closed. And `priceState` **propagates**
(`ContractFunctionExecutionError`) when the second probe also fails, so a genuinely dead node kills
the supervisor loudly rather than reading as Saturday.

### The SIGTERM restore (R7 tool defect #1) — watched, not accepted

Started the real gate on a clean root, polled `shasum` until the mutant was **actually on disk**, and
only then sent SIGTERM:

```
pristine sha256: abf4d4ac1109d7fb859d096ecacba6546bb2e95e4aceea5f01b746e316b1ae9a
MUTANT IS ON DISK after 2s: 7f13010085caec436f10b0fb895fc1f4368e48d2412108efc2d8445592279c42
406:    uint256 public constant PRICE_CONFIRM_DELAY = 1 seconds;
after SIGTERM  : abf4d4ac1109d7fb859d096ecacba6546bb2e95e4aceea5f01b746e316b1ae9a
RESTORED — the handler ran
```

The handler is real. `SIGKILL` still bypasses it — unavoidable, and worth one line in the runbook.

### The comment-only claim — verified independently, with a real tokenizer

`git diff --stat 2309cb0 959b70a -- rh-chain/src` → `EsseyMarkets.sol | 11 +++--`, and every added
and removed line begins `///`. Confirmed with a **tokenizer-grade** stripper (not `sed`), which
respects string and char literals so a `//` inside a string can never be mistaken for a comment:

```
954 source lines -> 456 after stripping   (so the stripper is doing real work, not passing through)
diff old.strip new.strip  ->  IDENTICAL
```

No behaviour, storage, gate or authority changed in `rh-chain/src` between 2309cb0 and 959b70a.

### The horizon numbers — re-derived, not re-printed

An independent walker written from the AggregatorV3 interface, reading `latestRoundData()` for the
live phase and round rather than a hard-coded count, caching raw rounds to JSON, analysed by separate
code that separates direction:

| | AAPL `0x6B22…2cD0` | NVDA `0x379E…9F15` |
|---|---|---|
| rounds walked | 567 | 994 |
| span | 2026-06-22 → 2026-09-04, 74.80d | 74.74d |
| 1e18-scaled early rounds | 17 (last 06-23T13:45Z) | 24 (last 06-23T13:48Z) |
| median gap | 2,191s | 1,711s |
| **max gap** | **79.74h** | **76.09h** |
| that gap | 2026-07-02 Thu → 07-06 Mon | 2026-07-02 Thu → 07-06 Mon |
| next four gaps | 57.65 / 56.65 / 56.28 / 54.38h | 56.60 / 55.61 / 52.53 / 52.08h |
| per-round log-return sample sd | 0.5682% (n=566) | 0.5591% (n=993) |

Every claim reproduced: max gaps **79.74h / 76.09h**, both the Independence-Day window, 4 July 2026 a
Saturday. Ordinary weekends **52.08–57.65h**, matching the stated "52–58h". Worst moves
**6.80%/7.06% at 1h, 8.47%/7.88% at 6h, 8.97%/9.22% at 12h, 10.23%/12.00% at 24h** — all four rows.
**AAPL 12.61% (1.69x) at both 88h and 100h**; **NVDA 12.90% (1.65x) at both 84h and 96h**. The 6h
row's 2.51x / 2.70x. (Round counts differ from the docs' 555/981 for the reason in INFO-3; the
derived statistics do not.)

### Other lenses

- **Custody / value flow.** No sweep, rescue or emergency-withdraw exists on `EsseyPool`; the only
  privileged non-timelocked function is the one-shot `setNoteArt`. Value destinations are immutable
  constructor addresses, `markets.resolver()`, or an owner read from `note.ownerOf(id)` at execution
  time; `liquidate` reads `holder` *before* the burn. Rate and reserve parameters are
  constructor-only — `reserveBps` has no setter and cannot be raised after deploy. **"Adminless over
  funds" holds** in the strong sense: no privileged key can route lender principal, borrower
  collateral or reserves to itself. What the keys *can* do is stop things (guardian, liveness keeper,
  depth keeper) and re-price risk behind a 2-day public timelock (admin — see INFO-9).
- **Solvency.** MED-1 moves value between lenders and borrowers; it does not break the invariant.
  Every asset outflow is bounded by a cash check or by funds received in the same call, so the pool
  can never attempt to send more than it holds.
- **Fog integrity.** Not applicable to the lending surface — there is no hidden information here, and
  correctly so. The delay line is a *delay*, not a secret: every slot is publicly readable
  (`confirmedPrice` / `confirmedMultiplier` / `confirmedObservedAt`). `syncMultiplier` is
  permissionless by design, and the R4 HIGH-1 rebuild is what makes that safe — the property no
  longer depends on who calls or when.
- **Public-repo hygiene.** No keys, no private paths, no forbidden names in the audited surface. The
  `__REPO__` placeholder in `xyz.essey.liveness-keeper.plist` is doing its job. The only 64-hex
  matches under `src/` are Merkle zero-constants in `private/pool/MerkleTreeWithHistory.sol`, out of
  scope here and previously recorded as benign.

---

## Inherited but NOT verified by me

A second reader swept `EsseyPool` / `StaleFeedGuard` / `LivenessOracle` / `MarketHealthOracle` /
`CollateralReconciler` in parallel. I re-verified and adopted its `_growth`, `writeOff`, constructor,
`accrueFor` and balance-delta observations (above), each against the source myself. The following
came from that sweep and I did **not** confirm them this round — they are listed as leads for the
engineer, not as findings, and must not be acted on as fact without checking:

- three stale `file:line` citations (`EsseyPool.sol:604`, `:641`, `EsseyMarkets.sol:491`, `:123`),
  where the substantive claim was reported true but the pointers rotted;
- `LivenessOracle.sol:56-57` understating the keeper's blast radius versus `EsseyMarkets.sol:121`;
- `removeCollateral` (`EsseyPool.sol:685`) lacking the dust cap its three siblings have;
- `LivenessOracle.setKeeper` forbidding `keeper_ == rotationAdmin` but not `keeper_ == guardian`;
- `Note.tokenURI` calling the art renderer with no gas cap.

---

## Evidence run this round

```
mutation gate     python3 test/mutants/glend-r4.py, from zero, git archive 959b70a root
                  run 1: 40/41 KILLED — the one survivor was M32 and I caused it (LOW-3)
                  run 2: 41/41 KILLED, 0 SURVIVED, EXIT 0, every kill line a real assertion
clean baseline    forge test --match-contract '<the gate's own SELECT>'
                  399 tests / 17 suites / 0 failed
survivor probe    17 fresh candidate mutants aimed at what the fixtures hold constant
                  15/17 killed; SURVIVED: X-O (LOW-2, non-equivalence proven), X-U (INFO-5)
decode probe      anvil + repo viem 2.56.3 + the repo's own keeper-health.mjs
                  11 revert shapes x 8 duration points x 5 maxDark types
volatility        independent walker: 567 + 994 real rounds off 4663, direction-separated
PoC               AuditR8Accrual.t.sol      2 tests, both RED on the frozen tree, with numbers
                  AuditR8FixCheck.t.sol     the minimal fix is wrong, measured
                  AuditR8Baseline.t.sol     GREEN on 959b70a, RED on X-O, 499/499 otherwise green
```

Nothing in the repository was modified by this audit except this file.
`git rev-parse HEAD` → `959b70a53a885ba2ab2aae17b5a1792c5e10ee16`.

---

## The gate

**This round does NOT return clean.** Under the standing rule, MED-1 must be fixed and **all three
auditors re-run fresh** before any deploy or push. LOW-2 through LOW-4 and INFO-1 through INFO-9 are
triage for the same pass; accepting any of them is legitimate, but the acceptance should be recorded
with its reasoning rather than passed over silently.

---

# ROUND 8 — FIXES APPLIED

Engineer pass on the findings above. Frozen SHA `959b70a`; nothing committed, nothing pushed.
Every claim below carries the command that produced it. **This does not close the gate** — the
three-agent audit must be re-run fresh on the fixed tree, and three consecutive clean rounds are
still required before any push.

## MED-1 — FIXED. One endpoint is not an interval.

`rh-chain/src/EsseyPool.sol`. The defect was that `_growth()` sampled the borrow-asset pause
instantaneously and let that single read stand for the whole elapsed interval, while `accrue()`
advanced `lastAccrual` regardless.

**The fix is not the one-liner, and not the auditor's `pausedSince` sketch either.** It is a
two-endpoint rule: a new `bool pauseObserved` records whether the accrual at `lastAccrual` saw the
asset paused, and an interval is forgiven **only when the pause was observed at BOTH of its
endpoints** (`EsseyPool.sol:266-275`):

```solidity
paused = _borrowAssetPaused();
if (paused && pauseObserved) return (denom, denom, paused); // suspended: both endpoints paused
uint256 dt = block.timestamp - lastAccrual;
if (dt == 0 || totalBorrows == 0) return (denom, denom, paused); // nothing to accrue, clock still runs
```

The three reasons `_growth` can report no growth are now distinct in the code, and the clock advances
in **all** of them — which is what the auditor's `AuditR8FixCheck` demanded, and why the one-liner
was wrong.

**Why not record `pausedSince` and skip the paused window.** Because the ambiguity is unclosable in
the direction that matters. Verified against the live token rather than assumed:

```
$ for sig in "paused()(bool)" "pausedAt()(uint256)" "pausedSince()(uint256)" \
             "lastPause()(uint256)" "pauseTimestamp()(uint256)"; do
    cast call 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 "$sig" --rpc-url $RPC; done
paused()(bool)             false
pausedAt()(uint256)        execution reverted, data: "0x800ab12c"
pausedSince()(uint256)     execution reverted, data: "0x800ab12c"
lastPause()(uint256)       execution reverted, data: "0x800ab12c"
pauseTimestamp()(uint256)  execution reverted, data: "0x800ab12c"
```

USDG's pause is a bare boolean with **no history**. A `pausedSince` stamped by the first call that
observes a pause is still only an observation; a window nobody called `accrue()` inside leaves no
on-chain trace at all. And forgiving on the *exit* read reopens MED-1 direction A behind one extra
call: stamp during any real one-second pause, wait a year, call again — a year erased.

So every ambiguous window resolves **toward the lender**, and witnessing one costs a single
permissionless `accrue()`.

### What this closes, and what it does not

| | before | after |
|---|---|---|
| **Direction A** — unpaused year erased by `address(0xBAD)` | 70.000000 USDG destroyed | **0** |
| **Direction B**, pause *witnessed* by ≥1 `accrue()` in-window | charged in full | **forgiven** |
| **Direction B**, pause *unwitnessed* | charged in full | charged — **not closable** |

Direction A, the permissionless money path, is closed.

**The unwitnessed case is the correct answer, not a shortfall in the fix.** It is a fact about the
token: USDG exposes a bare `paused()` and nothing else, so a window in which no one called `accrue()`
left no on-chain trace to reason from. No implementation can forgive it without forgiving on the
closing read alone — which IS Direction A. Any design that "closes" it has reopened the erasure.

It is pinned by `test_anUnwitnessedPausedWindowIsCharged` precisely so a future "fix" that forgives
it goes red. It is not attacker-triggerable, requires an exogenous multi-hour issuer pause, and any
party — borrower, lender, or keeper — converts it to the witnessed case for the price of gas.

**Direction A, measured before and after** (auditor's own PoC, unmodified):

```
--- frozen tree 959b70a ---
[FAIL: a year in which repayment was perfectly possible must still be charged: 700000000 != 770000000]
  debt after the year, honest        : 770000000
  debt after the year, stranger call : 700000000
  borrower interest erased (USDG 6dp): 70000000
  lender assets honest / erased      : 100070000000 100000000000

--- with the fix ---
[PASS] test_aPauseAtTheCallInstantErasesAnEntirelyUnpausedYear()
  debt after the year, honest        : 770000000
  debt after the year, stranger call : 770000000
  borrower interest erased (USDG 6dp): 0
  lender assets honest / erased      : 100070000000 100070000000
```

### The invented symbol

`EsseyPool.sol:219` named `accrueFor`, which exists nowhere in the tree. Removed; the comment now
names `_growth` and describes the two-endpoint rule it actually implements.

```
$ grep -rn "accrueFor" rh-chain/ --exclude-dir=lib --exclude-dir=node_modules --exclude-dir=out | wc -l
0
```

### The false green, replaced

`test_accrualSuspendsOnlyWhenBorrowAssetPaused` set the pause **before** the warp, holding pause
state constant across the interval — one dimension pinning a two-dimensional property. It is gone,
replaced by five tests in `test/EsseyPool.t.sol` that vary pause **and** time, in both orders:

- `test_aCollateralPauseDoesNotForgiveInterest` — preserves fix #5.
- `test_aPauseAtTheCallInstantCannotEraseAnUnpausedInterval` — pause lands **inside** the interval.
- `test_onlyTheWitnessedPausedWindowIsForgiven` — pause moves **both** directions inside one measured
  span, asserted against a control that varies only time, so the forgiven year must cost exactly zero
  and the two unpaused days exactly what they would have cost unpaused. No magic numbers.
- `test_anUnwitnessedPausedWindowIsCharged` — pins the accepted residual.
- `test_anIdlePoolKeepsItsAccrualClockCurrent` — no borrower, so it asserts on the clock and nothing
  else; this is the one that rules out the one-liner.

### Verified red — adversarially, in every direction

Not "mutate the thing I had in mind and stop". Every value the fix touches, mutated every way, via
`~/.claude/gate-receipts/audit-glend-r8-poc/mutate-med1-fix.py`:

```
classifier self-test: 4/4 ok (PASS lines ignored, ']' in revert data survived)
KILLED  D   THE R8 DEFECT: suspend on the live read alone
KILLED  M-a guard && -> ||          KILLED  M-h stamp removed
KILLED  M-b guard -> pauseObserved alone (the exit-forgives design)
KILLED  M-c guard -> true           KILLED  M-i stamp inverted
KILLED  M-d guard -> false          KILLED  M-j live read hardcoded false
KILLED  M-e guard removed           KILLED  M-k live read hardcoded true
KILLED  M-f stamp hardcoded false   KILLED  M-l THE NAIVE ONE-LINER (clock below the early return)
KILLED  M-g stamp hardcoded true    KILLED  M-m nothing-to-accrue also suspends the clock

14/14 killed
```

**The classifier is self-tested, because the first two versions of it were wrong** — and both
failures are the shapes LOW-3 and LOW-4 describe. Version one used `\[FAIL[^\]]*\]` and silently
missed every kill whose revert data contains `]` (`Undercollateralised(700000000 [7e8], …)`),
under-reporting killers. Version two matched `\] (test_\w+)\(`, which also matches `[PASS]` lines,
and reported all 14 mutants killed by all 5 tests — **a gate failing open, reported as a triumph**.
Only the third version separates the two cases, and it now proves it does before it is trusted.


## LOW-1 — the 12h SLO is gone, and the pager is built

Both halves of the auditor's recommendation, because quoting a safer number without building the
mechanism would have been the same prose problem in a different font.

**The horizon is requoted at 48h** in `rh-chain/src/EsseyMarkets.sol:406-420` and
`docs/MAINNET-CONFIG.md`. The 12h was never a code fact — its arithmetic was right (9h to
`MAX_CONFIRM_AGE`, plus 3h to restore) but 9h is when the alarm CONDITION becomes true, not when
anyone is told. At 48h the horizons are 135.2h AAPL / 131.6h NVDA, the worst absolute moves 12.61%
(1.69x) and 13.52% (1.57x). It costs 0.08x of headroom and removes a promise about a human from a
contract constant's derivation.

The EsseyMarkets change is **comment-only, proven rather than asserted** — and the proof is itself
verified red:

```
$ git show 959b70a:rh-chain/src/EsseyMarkets.sol | comment-strip.py > before
$ comment-strip.py < rh-chain/src/EsseyMarkets.sol   > after
stripped lines: before=456 after=456
COMMENT-ONLY VERIFIED: stripped sources are byte-identical

$ sed 's/PRICE_CONFIRM_DELAY = 6 hours/PRICE_CONFIRM_DELAY = 7 hours/' … | comment-strip.py
STRIP PROOF VERIFIED RED against a 6h->7h code change:
192c192
<     uint256 public constant PRICE_CONFIRM_DELAY = 6 hours;
>     uint256 public constant PRICE_CONFIRM_DELAY = 7 hours;
```

`PRICE_CONFIRM_DELAY = 6 hours` is unchanged.

**The pager exists now.** `keeper/xyz.essey.liveness-pager.plist` runs
`keeper/page-liveness-keeper.sh` every 900s, which runs `check-liveness-keeper.mjs` — the thing
nothing scheduled — and pages on **any** non-zero exit, including exit 2 (bad config), because a
supervisor that cannot run is not a quieter supervisor.

```
$ plutil -lint xyz.essey.liveness-pager.plist          -> OK
"Label" => "xyz.essey.liveness-pager"      "StartInterval" => 900     (no KeepAlive)

$ ./page-liveness-keeper.sh
2026-09-04T21:48:04Z
LIVENESS_ORACLE and ESSEY_MARKETS are required
NO PAGE SENT  PAGER_WEBHOOK_URL is unset or the POST failed …
              This unit is NOT paging anyone. Configure it or stop trusting it.
exit=2
```

It fails **loud**. Secret hygiene checked, because this unit is the first thing in the repo to hold a
webhook URL:

```
$ git check-ignore -v .env.liveness-pager                  .gitignore:10:.env.*
$ git check-ignore -v rh-chain/.keeper-state/…alert        .gitignore:42:rh-chain/.keeper-state/
```

**UNVERIFIED, stated plainly:** real launchd scheduling. Nothing was installed — the plist ships as a
`__REPO__` template with the `sed` install line in `RUNBOOK.md:128-131`, matching the existing
keeper unit's convention. What would settle it is `launchctl load` on the founder's machine and one
observed page. **Residual with no mechanism:** if the wrapper itself cannot start, nothing pages —
there is no dead-man's switch.

`docs/MAINNET-ACTIVATION.md` claimed of R4 HIGH-2 that "a supervisor unit and an on-chain symptom
check ship with it". The unit supervised the keeper *process*; nothing ran the *check*. That row now
says what actually shipped, and when.

## LOW-2 — M42 added and killing; the survivor is dead

`test/mutants/glend-r4.py:195-198` adds M42 (`prevPrice * prevMult` → `prevPrice * curMult`), and
`test/DesyncBreaker.t.sol:109-136` adds the multiplier-leg-first fixture the suite never had. Verified
in both directions, with the file's sha256 identical before and after the probe:

```
--- X-O APPLIED ---
[FAIL: the reference is the last MATCHED pair, not the old price against the new multiplier:
       0 != 20000000000000000000000000000] test_theBaselineIsTheLastMATCHEDPairNotAHalfUpdatedOne()
--- frozen tree, restored ---
[PASS] test_theBaselineIsTheLastMATCHEDPairNotAHalfUpdatedOne()
--- through the gate's own run() ---
KILLED  M42 breaker baseline is the old price against the NEW multiplier (R8 LOW-2)
```

**The new test pins the MULTIPLIER half only, and that was measured rather than assumed.** Mutating
the other half independently:

```
X-O  prevPrice * curMult   (M42, multiplier half) -> [FAIL: ...: 0 != 2e28]
X-P  price * prevMult      (the PRICE half)       -> [PASS]   <-- SURVIVES
```

X-P is a no-op in this fixture because the feed leg has not moved, which the test itself asserts.
Closing it needs a fixture where the feed HAS advanced but the pair is still matched. Carried below
as an open gap rather than quietly counted as covered.

## LOW-3 / LOW-4 — the gate is self-validating and fails closed

**LOW-3.** `suite_verdict()` now believes a verdict only from a run that reached its completion
summary with the expected count. Driving the real function over synthetic forge output:

```
ok  RUN-INCOMPLETE   subprocess killed before any test ran (the R8 LOW-3 incident)
ok  RUN-INCOMPLETE   mutant DELETES a test; nothing fails      -> 399 ran, expected 400
ok  RUN-INCOMPLETE   partial output, summary never printed
ok  SURVIVED         clean full run, nothing failed
ok  KILLED           real assertion failure with the full count
ok  RPC-FLAKE        transport failure only
ok  NO-COMPILE       compile failure
misclassified: 0

PRE-FIX gate @959b70a -> SURVIVED   subprocess killed before any test ran   <-- the old behaviour
```

`EXPECTED_TESTS` is measured, not recalled — and **it moved again when the MED-1 tests landed**, which
is the maintenance cost of this mechanism showing up immediately:

```
frozen tree              399
+ LOW-2 test             400
+ MED-1's net 4 tests    412   <- shipped value
```

The jump is 12, not 4, because `EsseyPoolTest` is a base: three contracts in the gate's selection
carry it. Tree-wide the same 4 tests land across eight contracts, which is exactly why the full suite
moved 1808 → 1840. Both reconcile to the test function count; neither was inferred.

**LOW-4.** `is_transport` is gone, replaced by `is_evidence` — a positive test for the shapes that ARE
evidence (a rendered comparison of two concrete operands, one of forge's/the EVM's own verdicts, or a
revert decoding to an error **this repo declares**). Everything else is INCONCLUSIVE and retried.

```
===== the 8 strings from the report  (3 were already caught, 5 were REAL KILLS) =====
INCONCLUSIVE  Max retries exceeded HTTP error 429 / database error: / Failed to get EIP-1559
INCONCLUSIVE  error sending request for url / operation timed out / connection reset by peer
INCONCLUSIVE  ERC20InsufficientBalance(...) / EvmError: OutOfFunds
===== the live 429 this session actually produced =====
INCONCLUSIVE  vm.createSelectFork: could not instantiate forked environment …
===== all 53 unique [FAIL lines in both R8 gate logs =====
53 of 53 -> EVIDENCE            misclassified: 0
```

Zero of the 53 real kills are downgraded. `ERC20InsufficientBalance` decodes cleanly but is declared
in `lib/openzeppelin`, not by this repo — so requiring a repo-declared error catches the R5
fixture-funding shape too, one notch tighter than the report prescribed.


## Evidence — the runs, not a summary of them

**Full suite, merged tree** (`-j 3`; the RH mainnet fork backend rate-limits at default parallelism):

```
Ran 94 test suites in 261.03s (691.82s CPU time): 1841 tests passed, 0 failed, 0 skipped (1841 total)
```

Reconciled against the 1808 frozen-tree baseline, because a jump of 33 wants explaining rather than
accepting: MED-1's net +4 tests land in `EsseyPoolTest`, which is the base of **eight** contracts
tree-wide → +32; LOW-2's test lands once in `DesyncBreakerTest` → +1. 1808 + 32 + 1 = **1841**.

An intermediate run with the MED-1 fix alone measured **1840/1840**, which is the same arithmetic one
test short. Both were verified by counting the contracts, not by assuming the delta.

**Keeper suite:**

```
ℹ tests 124   ℹ pass 124   ℹ fail 0   ℹ cancelled 0   ℹ skipped 0
```

**Builds — under the right profile, which is the part that needed establishing.** Plain
`forge build` fails on the frozen tree and on this one, identically: `foundry.toml:34-36` documents
that `Deploy.s.sol` exceeds the legacy pipeline and needs `via_ir`. It is **pre-existing**, and I
confirmed that by stashing the entire changeset and reproducing the identical error before
attributing it — an early bisection had wrongly pinned it on adding a state variable.

```
                                        pristine 959b70a   merged tree
forge build --skip script                     OK           exit 0, 0 errors
FOUNDRY_PROFILE=script forge build            OK           exit 0, 0 errors  (345.33s)
FOUNDRY_PROFILE=v4     forge build            OK           exit 0, 0 errors  (16.86s)
forge build (default, incl. script)      Stack too deep     n/a — pre-existing, not a regression
```

Both columns are measured. (An intermediate reading of `exit 2` on the first row was a quoting bug
in my own loop, not a build failure; run directly it is exit 0.)

## The mutation gate — 42/42, with every line resolved to a real assertion

```
37/42 killed
  NOT KILLED: M13, M16, M18, M20, M25      <- all five RPC-FLAKE, not SURVIVED
```

**Those five were never survivors.** The RPC degraded from 429 to HTTP 403 mid-run — largely under
this session's own load — and the new classifier refused to score any of them, which is the whole
point of LOW-4. Re-run individually with backoff, all five resolve to real assertions:

```
KILLED  M13  [FAIL: MED-1: the multiplier half did NOT move alone: 500283040030546218 != 1000566080061092436]
KILLED  M16  [FAIL: call reverted as expected, but without data]
KILLED  M18  [FAIL: next call did not revert as expected]
KILLED  M20  [FAIL: next call did not revert as expected]
KILLED  M25  [FAIL: armed: 0 <= 0]

re-run result: 5 KILLED, 0 UNRESOLVED
```

**Final: 42/42 killed, 0 survivors, 0 unresolved.** M42 kills on its own assertion:

```
KILLED  M42 breaker baseline is the old price against the NEW multiplier (R8 LOW-2)
        [FAIL: the reference is the last MATCHED pair, not the old price against the new
               multiplier: 0 != 20000000000000000000000000000]
```

**Every kill line inspected for a transport or out-of-funds disguise**, using the gate's own
`is_evidence` over all 47 `[FAIL` lines produced:

```
kill lines inspected: 47   classified EVIDENCE: 42   NOT evidence: 5
transport / out-of-funds disguises among the 42 scored kills: 0
```

The five non-evidence lines are exactly the five the gate declined to score. Nothing infrastructural
was counted as evidence — the failure mode LOW-4 exists to prevent, observed working on live data
rather than on the report's sample.

The tree is restored: `git diff --numstat src/EsseyMarkets.sol src/LivenessOracle.sol` shows only the
19/4 comment change, no mutant stranded.

**A note on the transport failures seen during this session, since LOW-4 is precisely about not
scoring them as evidence.** Full-suite runs at default parallelism produced 33, 31, 28, 20 and 16
failures on successive attempts — a count that moves run to run is not a deterministic failure. Every
one was `vm.createSelectFork … Max retries exceeded HTTP error 429`; zero were assertions. Under
`-j 3` the same tree is 1841/0. The new `is_evidence` classifies all of them INCONCLUSIVE, which is
the fix working on live data rather than on the report's sample.

## A standing rule this round earned five times over

Every tooling defect in this engagement is one shape: **a check that could not produce a negative
result, reported as a pass.** The gate's SIGTERM hole and its missing completion check (LOW-3), its
denylist classifier (LOW-4), my mutation classifier matching `[PASS]` lines and announcing "14/14
killed by all 5 tests" — and, during this very round, my own completion *waiters*.

The waiters were written as `until pgrep -f "forge test -j 3"; do sleep; done`. The waiting shell's
own command line **contains that string**, so `pgrep` matched itself and the loop could never exit.
One such waiter would have blocked forever; a `Monitor` armed the same way could never have fired.
It is the identical defect as the `[PASS]`-matching regex: a probe whose positive branch is
unreachable-negative, silently. Caught by asking why a 42-mutant gate appeared to be five minutes
old after half an hour of waiting.

**The rule, stated so it survives this round: any tool that produces evidence must first be shown to
produce a NEGATIVE result.** A classifier proves it rejects; a waiter proves it terminates; a gate
proves it can report the failure it exists to catch. Until then it is a claim, not an instrument —
and the four gate findings above are all cases where the instrument was trusted without that proof.

## Still open — carried forward, not closed

Listed because a fix pass that reports only what it fixed is how round 8 happened.

1. **X-P — THE EIGHTH INSTANCE, and the one to scope first.** `_syncPrice`'s baseline PRICE half is
   unpinned: mutating `uint256 prev = prevPrice * prevMult;` to `price * prevMult` **survives the
   test written for LOW-2**, measured directly:

   ```
   X-O  prevPrice * curMult   (the MULTIPLIER half) -> [FAIL: ...: 0 != 2e28]   killed by M42
   X-P  price      * prevMult (the PRICE half)      -> [PASS]                   SURVIVES
   ```

   It is a no-op in that fixture because the feed leg has not moved — which the test itself asserts
   (`DesyncBreaker.t.sol:126`, "the feed leg has not moved"). Closing it needs a fixture where the
   feed HAS advanced but the pair is still matched.

   **The shape matters more than the mutant.** This is the third consecutive round in which a test
   pinned ONE HALF of a pair, and the fix for the seventh false green does not cover its own sibling.
   Deliberately NOT absorbed into this changeset; scoped as its own pass alongside item 2.
2. **`EsseyMarkets.sol:525` `_confirmable(token, price, curMult)` — NEITHER half mutated.** The direct
   sibling of `:556`, which carries seven mutants. Highest-value remaining gap; it feeds every
   corroborated liquidation price.
3. **`_valueAt`'s `(collDec, feedDec)` pair at `:204` and `:313` — a swap COMPILES** and silently
   rescales collateral value by 10^n with no revert. Money path, no mutant.
4. **`_setFeed`'s `(heartbeat, maxStaleness)` at `:800` — both `uint32`, a swap compiles.** The file's
   own comment calls it "the freshness pair".
5. **`LivenessOracle.sol:135-138`** — two same-type sibling pairs swappable in the constructor.
6. **The report's claim that X-N is killed by `test_theBreakerClearsWhenTheSecondLegLands` is
   INHERITED, not re-verified**, and the observed product's price half is unprobed by anyone.
7. **`worstMove` is direction-blind** (`keeper/measure-feed-volatility.mjs:90`, `Math.abs`), so the
   repo's own tool cannot reproduce the NVDA **down** figures the config doc now leans on. AAPL's
   1.69x reproduces; NVDA's does not.
8. **`EXPECTED_TESTS` is a standing maintenance obligation** — it already moved twice in this pass.
9. **The pager has no dead-man's switch**, and its launchd scheduling is UNVERIFIED (nothing installed).

## NOT PINNED BY ANY TEST

- That `accrue()` and the 4626 `max*` views can never disagree **under a pause**. The property holds
  by construction — `_growth()` is still the single computation and both callers read the same two
  inputs — but no test exercises `maxWithdraw`/`maxRedeem` across a witnessed pause boundary.
- Items 1–6 above.

## The gate — still NOT clean, and this pass does not close it

This is the engineer's fix pass. **The three-agent `essey-auditor` gate must be re-run fresh on this
tree, and three consecutive clean rounds are required before any push** — a finding resets the count
to zero. Nothing here is self-approved, nothing is committed, nothing is pushed, and no launchd unit
was installed.
