# Runbook — the ex-date liquidation pause

**Owner:** essey-deployment-manager (procedure) · founder (the guardian key, every call)
**Status:** PRE-POSITIONED. `EsseyMarkets` is **not deployed on 4663** — no broadcast exists
(`PRODUCT-TRACKER.md` row D1). Every address below is a placeholder until the founder's deploy.
**Companion:** [`MAINNET-LENDING-SCOPE.md`](MAINNET-LENDING-SCOPE.md) ·
[`MAINNET-ACTIVATION.md`](MAINNET-ACTIVATION.md)

Every claim in this file carries a `file:line` into `rh-chain/`. Where the answer is "nothing is
built", it says so rather than describing an intention. Line numbers are against the working tree at
the time of writing; re-check them after any edit to `EsseyMarkets.sol`.

---

## 0. What this runbook is, and what it deliberately is not

A corporate action rescales two things in opposite directions. A 2:1 split halves the Chainlink feed
and doubles the token's `uiMultiplier()`. The protocol prices collateral on the **product** of the
two (`EsseyMarkets.sol:209-218`, `_valueAt`), so a *completed* action costs nothing — but **between the legs the
product is dislocated**, and a healthy position reads underwater at roughly half its real value. A
liquidator takes near-full collateral against half the debt.

**This runbook covers ANNOUNCED actions only.** Ex-dates are public weeks ahead; a human can see them
coming and spend a lever. It does **not** cover:

- an **oracle misprint** — no announcement exists to watch for;
- an **issuer acting off-schedule**, early, or with an unannounced ratio;
- a **leg ordering nobody predicted** (multiplier first instead of feed first).

Those are the automatic breaker's job — the desync guard (`EsseyMarkets.sol:459-477`) and the
corroboration delay (`:401`). **We keep both because each one is exactly blind where the other sees.**
This runbook is the announced half. Nothing in it justifies weakening the automatic half.

---

## 1. The levers that already exist

Nothing needs building on-chain. Two functions, both guardian-only, both immediate:

| Lever | Where | Caller | Effect | Bound |
|---|---|---|---|---|
| `pauseLiquidation(address token, uint256 until)` | `EsseyMarkets.sol:859` | **guardian only** (`:860`) | `canLiquidate(token)` returns false while `block.timestamp < liquidationPausedUntil[token]` (`:702`) | `until` ≤ `now + 24h` (`:861-862`, `MAX_LIQUIDATION_PAUSE` `:373`), and a **cooldown as long as the pause it follows** (`:865-866`) |
| `disableMarket(address token)` | `EsseyMarkets.sol:836` | **guardian only** (`:837`) | stops **NEW borrows only** | immediate, no timelock; re-enabling pays the full 2-day `PARAM_TIMELOCK` (`:105-111`) |

### 1.1 The trap: `pauseLiquidation` alone is not safe

`canBorrow` (`:324-346`) checks `enabled`, `ltvBps`, chain liveness, the depth cap, the desync guard
and the price — **it never reads `liquidationPausedUntil`**. Grep confirms the pause mapping is read
in exactly one place, `canLiquidate` at `:702`.

So a bare `pauseLiquidation` leaves **borrowing open with the liquidation backstop switched off**.
That is only harmless in the leg ordering where collateral reads *low*. In the other ordering — the
multiplier leg lands first, the feed leg has not — collateral reads roughly **2x**, and the automatic
cover for that ordering is `MULTIPLIER_GUARD_WINDOW = 1 hour` (`:348`, branch (b) at `:471-473`).
Past that hour, someone opens an over-collateralised-on-paper position that cannot be liquidated.

> **RULE: `disableMarket` FIRST, `pauseLiquidation` SECOND. Never the pause on its own.**

The cost is real and must be accepted before the ex-date, not discovered during it: **re-enabling the
market costs a 2-day timelock** (`:830`, `PARAM_TIMELOCK` `:111`). The market is closed to new borrows
for the action plus two days.

### 1.2 What `disableMarket` deliberately does NOT do

It does **not** stop liquidation. `canLiquidate` has no `enabled` conjunct, on purpose — a disabled
market's existing positions must stay liquidatable and write-off-able, or disabling would freeze risk
exactly when it is being managed (`:695-698`). Do not reach for `disableMarket` expecting it to
protect a borrower. It protects the *pool* from new bad borrows. Only `pauseLiquidation` protects the
borrower.

---

## 2. Where ex-date announcements come from, and who watches

**VERIFIED GAP: nothing is built.** `rh-chain/keeper/` contains `liveness-keeper.mjs`,
`keeper-health.mjs`, `check-liveness-keeper.mjs`, `market-list.mjs`, `measure-feed-volatility.mjs`
and `holder-airdrop/`. A grep for `ex-date` / `exDate` / `corporate` across the keepers returns
nothing. **There is no corporate-action watcher, no calendar feed, and no alerting.**

Until one exists, this is a **human duty on a calendar**, and it belongs to a named person:

1. **Source.** The issuer of the collateral token is authoritative for the *multiplier* leg; the
   listing venue's corporate-action calendar is authoritative for the *ex-date*. For the two markets
   that ship — AAPL (`RobinhoodFeeds.sol:10`) and NVDA (`:12`) — that is the Nasdaq corporate-action
   calendar plus each company's investor-relations announcement. **UNVERIFIED:** whether Robinhood
   publishes a machine-readable schedule for Stock Token `uiMultiplier` changes. *What would settle
   it:* the founder or the research intern reading Robinhood's Stock Token issuer documentation and
   confirming (a) whether a schedule endpoint exists and (b) how far ahead it publishes.
2. **Cadence.** A weekly check, and a re-check 5 business days out. Splits are announced ~2–6 weeks
   ahead; that is the whole reason this runbook can exist.
3. **Watcher.** Founder, until a keeper exists. **Do not treat this as covered by the liveness
   keeper** — it observes markets on a 300s beat (`liveness-keeper.mjs:149-167`) but has no concept of
   a calendar.
4. **The build that closes this.** A watcher that (a) polls a corporate-action calendar for every
   listed collateral token, (b) alerts at T−5d, T−1d and T−1h, and (c) reads `uiMultiplier()` and the
   feed each minute across the window and pages when the product dislocates. **Not scoped, not
   queued.** Recommend queueing it to `essey-protocol-engineer` after G-LEND clears — it is the
   difference between this runbook running and this runbook being read after the fact.

---

## 3. How far ahead to pause, and for how long

### 3.1 First, the thing that saves half the budget: **do not pause into the dark window**

The feeds are 24/5 with an 86,400s heartbeat and a 90,000s (25h) staleness bound
(`RobinhoodFeeds.sol:21-22`, installed at `DeployMarkets.s.sol:399`). Past `maxStaleness`, `priceOf`
reverts, `_liquidationPriceGate` catches it (`EsseyMarkets.sol:715-721`), and **`canLiquidate` is
already false**. The weekend dark window needs no pause — it is closed by the staleness guard.

Measured, not assumed (`EsseyMarkets.sol:397-399`, over 2026-06-22 → 2026-09-04, 74.3 days):

| | Friday-close → Monday gap | minus 25h staleness = **dark** |
|---|---|---|
| typical weekend | ~71h | ~46h |
| **measured worst** | **79.74h AAPL / 76.09h NVDA** | **~54.7h / ~51.1h** |

> ⚠️ **Correction to a number in circulation.** The dark window is commonly quoted as "~40h". The
> figure to plan against is **~55h** (`EsseyMarkets.sol:508` states it directly: *"The AAPL feed is
> unreadable ~55h EVERY weekend"*). ~40h is roughly the *typical* case. Size against the measured
> worst.
>
> The two comments at `:365-366` (~65h weekend) and `:508` (~55h unreadable) describe different
> quantities — nominal gap vs gap-minus-staleness — and are not in conflict, but they read as if they
> are. **Queued, not fixed here** (one problem, one fix): reconcile the two comments to state which
> quantity each is.

**Consequence:** a Monday ex-date needs **no pause over the preceding weekend**. Spend the budget from
the first readable Monday round forward. This is not a nicety — the budget is 50% duty cycle (§3.3),
so wasting 24h of it on a window that is already closed halves your real coverage.

### 3.2 The automatic cover you are supplementing — and when it is ZERO

| Branch | Constant | Covers | Caveat |
|---|---|---|---|
| (a) scheduled action | `MULTIPLIER_GUARD_WINDOW` 1h (`:348`) | pre-flip, from `newUIMultiplier()` | **INERT for every source that ships.** The deployed Stock Token answers with one word so `_scheduledEffectiveAt` returns 0 forever; `ConstantMultiplier` answers (0,0) (`:462-466`). **Count on nothing from branch (a).** |
| (b) multiplier moved | `MULTIPLIER_GUARD_WINDOW` 1h (`:348`, `:471-473`) | the multiplier leg | 1 hour only |
| (c) feed moved, multiplier did not | `PRICE_DESYNC_HOLD` **6h** (`:368`, `:474-476`) | the feed leg — the dangerous one | **arms only if the product deviates by MORE than 20%** (`MAX_PRICE_DEVIATION_BPS` `:358`, `_deviates` `:620-623`) **and** the baseline is under 1h old (`MAX_BASELINE_AGE` `:363`, `:598`) |
| corroboration delay | `PRICE_CONFIRM_DELAY` **6h** (`:401`) | always on; seizure needs underwater at the live price **and** at an observation ≥6h old | a two-point test, not a duration test (`:404-412`); it does not stop a *persistent* dislocation past 6h |

**The ratio determines whether you get the 6h automatic hold at all.** `_deviates` requires the move
to be **strictly greater** than 20%:

| Action | Product dislocation | Branch (c) arms? |
|---|---|---|
| 4:1, 3:1, 2:1 split | 75% / 66.7% / 50% | ✅ yes — 6h automatic |
| 3:2 split | 33.3% | ✅ yes |
| 4:3 split | 25% | ✅ yes |
| **5:4 split** | **exactly 20.0%** | ❌ **NO** — `diff*10000 > ref*2000` is strict |
| stock dividend < 25% | < 20% | ❌ **NO** |
| cash dividend | typically ≪ 20% | ❌ **NO** |

> **RULE: for any action whose dislocation is ≤20%, the automatic hold contributes ZERO. The pause
> must carry the whole event from the first dislocated round.** For >20% actions you may start the
> pause 6h later and keep 6h of budget.

And note the hold is **stamped once and does not extend** (`:600-601`); after 6h `_disarm(..., false)`
re-baselines to the dislocated level (`:589-592`) and treats it as the new truth. The automatic feed-leg
cover is **exactly 6 hours, once**, not a renewing shield.

### 3.3 The 24h cap and the cooldown — the sequencing, exactly

`pauseLiquidation` sets `pauseCooldownUntil[token] = until + (until - block.timestamp)` (`:866`) and a
new pause reverts `PauseOnCooldown` while `block.timestamp < pauseCooldownUntil[token]` (`:865`). The
cooldown ends **one pause-length after the pause ends**.

**Therefore the duty cycle is exactly 50%, and it is 50% whatever length you choose.** A 24h pause
buys a 24h hole; a 6h pause buys a 6h hole. You cannot beat 50%; you can only choose *where* the
covered half sits.

Standing a pause **down** is never rate-limited (`:863-864`) — `until` in the past reopens liquidation
immediately and does not touch the cooldown. Use this the moment both legs land (§5); it does not buy
back budget already spent, but it stops charging borrowers a closed market they no longer need.

**Sequence for a >20% action.** Let **T0** = the first readable feed round after the ex-date.

| Window | State | Call |
|---|---|---|
| before T0 (incl. the weekend) | dark → `canLiquidate` already false | **none.** Do not spend budget. |
| T0 − 1h | — | `disableMarket(token)` — §1.1 |
| T0 → T0+6h | automatic branch (c) hold | none |
| **T0+6h** | | `pauseLiquidation(token, T0+30h)` → cooldown to **T0+54h** |
| T0+30h → T0+54h | ⚠️ **UNPROTECTED, 24h** | none possible |
| **T0+54h** | if still split | `pauseLiquidation(token, T0+78h)` |

**Sequence for a ≤20% action** (no automatic hold): the first pause starts at **T0**, `until = T0+24h`,
cooldown to T0+48h, hole T0+24h → T0+48h.

**Contiguous protection maxes at 30h** (6h auto + 24h pause) for a >20% action, **24h** for a ≤20% one.

### 3.4 The honest limit: what happens past 30h

If the second leg has not landed by the end of the first pause, **there is no on-chain lever that
closes the 24h hole.** `disableMarket` does not stop liquidation (§1.2). The admin's only route —
raising `liqThresholdBps` through `proposeMarket`/`commitMarket` — pays the full 2-day
`PARAM_TIMELOCK` (`:725-746`, `:792`) and is far too slow to be an in-event response.

The response in the hole is therefore **operational, not on-chain**, and it must be said plainly:

1. Notify every open borrower on the affected market (§6) with the exact hole window.
2. Urge repay or `addCollateral` — both remain open under a pause and under `disableMarket`
   (`canLiquidate` is read only by `liquidate` at `EsseyPool.sol:708` and `writeOff` at `:794`;
   repay and addCollateral are not gated by it).
3. Accept that a liquidation landing in the hole may be wrongful and **is not reversible**.

**Pre-emptive option, for a KNOWN small-ratio action only, founder ruling required.** Because a ≤20%
action gets no automatic hold, the admin could pre-position 2+ days ahead by proposing a wider gap —
e.g. `liqThresholdBps` 7500 → 9000 against `ltvBps` 5000, giving a 40pp gap that absorbs a 20% leg.
`MAX_LIQ_THRESHOLD_BPS` is 9000 (`:105`) and `_validate` (`:882-895`) permits it. **The cost is that
positions go liquidatable later on a genuine crash too, for as long as it is installed, and reverting
it is another 2 days.** Not recommended as default; recorded so the founder can rule on it for a
specific event rather than rediscover it mid-incident.

---

## 4. Who holds the guardian key — and the failure mode nobody can undo

### 4.1 Constraints the deploy script enforces

`GUARDIAN` is required on mainnet and the script refuses to broadcast without it
(`DeployMarkets.s.sol:121-126`). It must differ from:

- the **deploy key** (`:123`),
- the **liveness keeper** (`:176-179`) — their union is "halt everything, indefinitely",
- the **liveness guardian** (`:196-199`) — otherwise the same union is reachable in one transaction.

`GUARDIAN == DEPTH_KEEPER` is explicitly allowed (`:174-175`): both are borrow-side only.

### 4.2 ⚠️ The guardian is IMMUTABLE. There is no rotation.

`address public immutable guardian` (`EsseyMarkets.sol:126`), assigned once in the constructor
(`:169`). Grep confirms **no `setGuardian`, no rotation path, nothing**.

> **If the guardian key is lost, compromised, or its holder is unreachable, the ex-date pause lever is
> gone for the life of the contract, and the only remedy is redeploying the registry and migrating
> every market and pool.**

This is a **founder decision before deploy, not after**:

| Question | Why it is load-bearing |
|---|---|
| Is the guardian a single EOA, or a 2-of-3 multisig? | A single EOA makes "the holder is on a plane" an unrecoverable outage of the only lever. A multisig removes that but adds signing latency against a 24h window — survivable, since ex-dates are known weeks ahead. |
| Where does it live, and who can physically reach it inside 1 hour? | The pause is time-critical only at T0 and T0+6h. Both are predictable to the hour. |
| Who is the named backup? | With an immutable single key, "backup" means a second signer on a multisig. There is no other form of backup. |

**Availability plan, until the founder rules:** because ex-dates are known weeks ahead, the guardian's
availability is **schedulable**. Confirm the holder is reachable for the T0 and T0+6h calls at the
T−5d check (§2.2). If they will not be, the correct action is **not** to improvise — it is to
`disableMarket` early and let the market sit closed to new borrows through the event. Losing new
borrows for a few days is cheap; a wrongful liquidation is not.

---

## 5. Verifying the pause actually took effect, and confirming both legs landed

Every step below is a read, not a claim. **Do not report a pause as in place without pasting the
output.** Placeholders: `$M` = `EsseyMarkets` (UNDEPLOYED — no 4663 address exists yet),
`$T` = the collateral token, `$RPC` = the 4663 RPC.

### 5.1 The pause took effect

```
# 1. the deadline is stored and in the future
cast call $M "liquidationPausedUntil(address)(uint256)" $T --rpc-url $RPC
# 2. the gate actually answers false — this is the one that matters
cast call $M "canLiquidate(address)(bool)" $T --rpc-url $RPC
# 3. when the next pause becomes possible
cast call $M "pauseCooldownUntil(address)(uint256)" $T --rpc-url $RPC
# 4. the event, from the receipt
cast receipt <txhash> --rpc-url $RPC | grep -i LiquidationPaused
```

Read (1) **and** (2). (1) alone is not proof the gate is closed — `canLiquidate` has four other ways to
return false (`:700-708`), and reading only the mapping would let a pause look installed while the true
reason liquidation is closed is something else entirely, which then expires without warning.

**End-to-end proof, the only one that is real:** a `liquidate` call against the market must revert
`LiquidationNotAllowed` (`EsseyPool.sol:707-708`). Simulate it — `cast call` against the pool's
`liquidate`, never `cast send`. A gate is not a gate until you have watched it block something.

### 5.2 Both legs have landed

Do **not** unpause on the calendar. Unpause on evidence that the product is continuous again:

```
# the multiplier the registry last recorded, vs what the token reports NOW
cast call $M "seenMultiplier(address)(uint256)"    $T --rpc-url $RPC
cast call $T "uiMultiplier()(uint256)"                --rpc-url $RPC
# when the multiplier last moved (branch (b) window is 1h from here)
cast call $M "multiplierMovedAt(address)(uint256)" $T --rpc-url $RPC
# is the feed leg still dislocated? nonzero == the breaker is ARMED
cast call $M "priceDesyncAt(address)(uint256)"     $T --rpc-url $RPC
cast call $M "desyncRefProduct(address)(uint256)"  $T --rpc-url $RPC
# the price the registry last recorded, and the live feed
cast call $M "seenPrice(address)(uint256)"         $T --rpc-url $RPC
cast call $M "priceOf(address)(uint256,uint8,bool)" $T --rpc-url $RPC
```

**All four of these must hold before standing the pause down:**

1. `uiMultiplier()` equals the announced post-action value — the multiplier leg landed.
2. `seenMultiplier` equals it too — the registry has *observed* the new value. If it lags, the keeper
   has not run a successful `syncMultiplier`; call it permissionlessly and re-read.
3. `priceDesyncAt` is **0** — the breaker disarmed. ⚠️ **Zero is ambiguous and this is the trap:**
   `_disarm` clears it both when *the legs agreed* (`PriceDesyncCleared`, `:612`) and when *the 6h hold
   simply expired without agreement* (`PriceDesyncExpired`, `:613`). **Check which event fired.** A
   `PriceDesyncExpired` means the dislocation is still real and the contract has merely stopped
   objecting — unpausing on it walks straight into the harvest.
4. `seenPrice × seenMultiplier` is within 20% of the pre-action product — the product is continuous.
   Compute it by hand from (5.2)'s reads; do not trust the absence of an alarm.

**Only then:** `cast send $M "pauseLiquidation(address,uint256)" $T 0` — `until` in the past stands the
pause down and is never rate-limited (`:863-864`). Then re-read `canLiquidate` and confirm `true`.

Re-enabling the market is separate and slow: `proposeMarket` + `commitMarket`, **2 days**
(`:725-746`, `PARAM_TIMELOCK` `:111`). Start it as soon as the legs land, not after the unpause.

---

## 6. What to tell borrowers — and the fact we must not bury

**VERIFIED, and it is the part borrowers will care about: interest keeps accruing throughout the
pause.** `accrue()` (`EsseyPool.sol:220`) compounds on `_growth()` (`:253-259`), and the **only** thing
that suspends the clock is the **borrow asset** (USDG) reporting `paused()` (`:280-283`). Grep confirms
`liquidationPausedUntil` is never read in `EsseyPool.sol`. A liquidation pause does not stop the clock,
and it was never designed to — a collateral-side pause deliberately does not forgive interest
pool-wide (`:247-252`).

Also verified: **repay and addCollateral stay open.** `canLiquidate` is consulted only by `liquidate`
(`:708`) and `writeOff` (`:794`). A borrower is never trapped.

### Notice template (send at T−1d, again at T0, again at each pause boundary)

> **[TICKER] corporate action — liquidations paused, borrowing closed**
>
> [TICKER] has a [ratio] [split/dividend] with an ex-date of [date]. Between the price feed and the
> token's share multiplier updating, your collateral can briefly be valued wrongly — by as much as
> [X]%. To make sure nobody is liquidated on a price that is not real, we have **paused liquidations**
> on the [TICKER] market and **closed it to new borrows**.
>
> **What this means for you, plainly:**
> - **You cannot be liquidated** while the pause holds: [start] → [end] UTC.
> - **Your interest keeps accruing.** The pause protects you from a wrongful seizure; it is not a
>   payment holiday, and your debt grows exactly as it normally would.
> - **You can still repay, and you can still add collateral.** Both work throughout. If you want to
>   reduce risk, now is a good moment.
> - **You cannot open a new borrow** on [TICKER] until the market reopens, roughly 2 days after the
>   action completes.
> - **There is a gap we cannot close.** The pause is capped at 24 hours per call and cannot be renewed
>   until the same length has passed. If the issuer's two updates land more than [30h / 24h] apart,
>   liquidations reopen from [hole start] → [hole end] UTC. **If you are near your liquidation
>   threshold, repay or add collateral before [hole start].** We will say so again when it approaches.
>
> We will post when both legs have landed and the pause is lifted.

**The gap disclosure is not optional.** A pause that a borrower believes is total, and is not, is worse
than no pause — they will stop watching a position precisely when it becomes exposed.

---

## 7. Pre-flight checklist

- [ ] T−5d: ex-date, ratio, and expected leg ordering recorded. Dislocation computed. **>20% or ≤20%?**
      That single answer sets the whole schedule (§3.2).
- [ ] T−5d: guardian holder confirmed available for the T0 and T0+6h calls (§4.2). If not → `disableMarket` early and stand down.
- [ ] T−5d: `cast call` the guardian address and confirm it matches the key you actually hold.
- [ ] T−1d: borrower notice sent, with the hole window named.
- [ ] T−1d: liveness keeper healthy — an unobserved market has no corroborated price and cannot be liquidated at all (`liveness-keeper.mjs:164-167`); it is also what keeps `seenMultiplier` current for §5.2.
- [ ] T0−1h: `disableMarket(token)`. Verify `canBorrow == false`.
- [ ] T0 (≤20%) or T0+6h (>20%): `pauseLiquidation`. Verify per §5.1 — **both reads, plus the revert.**
- [ ] Every 1h through the event: run the §5.2 block. Log it.
- [ ] Both legs landed and all four §5.2 conditions hold → stand the pause down; start the 2-day re-enable.
- [ ] Post-event: write what actually happened into `MAINNET-ACTIVATION.md`, including the real leg separation. That number is the only thing that will tell us whether 24h/50% is enough.

---

## 8. What this runbook cannot do — read before trusting it

1. **Announced actions only.** An oracle misprint or an off-schedule issuer produces no announcement
   and no calendar entry. Only the automatic breaker sees those.
2. **Leg separations over 30h are not coverable** by any sequence of calls (§3.3). The 50% duty cycle
   is a hard property of `:865-866`, not a tuning choice.
3. **≤20% actions get no automatic hold** (§3.2). The pause carries them alone, from T0, for 24h, then
   there is a hole.
4. **Nothing watches.** No corporate-action keeper exists (§2). This runbook runs on a human reading a
   calendar, and it will fail silently if that human is busy.
5. **The guardian cannot be rotated** (§4.2). Key loss is unrecoverable without a full redeploy.
6. **`EsseyMarkets` is not deployed.** Every address is a placeholder and none of §5's commands has
   been executed against a real chain. **This procedure is UNREHEARSED.** It should be rehearsed on a
   4663 fork — arm a pause, watch a `liquidate` revert, expire it, watch the cooldown reject the next
   call — before it is ever needed live. Recommend adding it to the `essey-harness` scope at G-LEND
   clear.

**None of the above is an argument for dropping the automatic breaker.** Items 1–5 are precisely the
cases the breaker exists for. The two mechanisms cover different failures and the honest answer is
both.
