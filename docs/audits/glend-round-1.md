# G-LEND gate — round 1 of 3

**Target:** the Stock-Token lending engine — `EsseyPool`, `EsseyMarkets`, `StaleFeedGuard`,
`MarketHealthOracle`, `EsseyMultiply`, and the supporting `CollateralReconciler` / `LivenessOracle`
/ `Note`.

**Date:** 2026-09-03 · **Lens:** Solidity / contract security (1 of 3) · **Substrate:** a real
Robinhood Chain mainnet fork, chain-id 4663.

## VERDICT: NOT CLEAN

**1 CRITICAL · 1 HIGH · 3 MEDIUM · 4 LOW · 3 INFO.** The three-clean-rounds counter stays at zero.

### Why this round exists

The activation register previously carried lending as *"audit-clean, 3 consecutive clean rounds,
pushed public."* There was no receipt behind that row and no report in this directory. It has been
retracted ([MAINNET-ACTIVATION.md](../MAINNET-ACTIVATION.md) row 3). This round starts the gate at
zero and treats the engine as completely unaudited.

### Publication note

Nothing in scope is deployed on any chain
([MAINNET-ACTIVATION.md](../MAINNET-ACTIVATION.md) row 3: *"ported into `rh-chain`; NOT DEPLOYED on
any chain"*). The fix-first convention in [README.md](README.md) exists to avoid handing a live
exploit to a reader; there is no live surface here, so this report carries full detail.

---

## Audited bytes

sha256, computed at the frozen SHA `99a5735c6743f8c3299a846edbac50c7dcb97b89`. No file below was
edited during the round.

| sha256 | file |
|---|---|
| `c418f6d3aaa7568a9e040d6b516b99a9656df2c0f2c025f9882307c750f2239d` | `rh-chain/src/EsseyPool.sol` |
| `21a6c1f1dcee000829319b4382deeec17bb0ce848306703aea29c7c60c33c751` | `rh-chain/src/EsseyMarkets.sol` |
| `1738944dc76842be1c02dc7d2ee8c9a85014dfe8a49b3e8d46c42e35bb058f08` | `rh-chain/src/StaleFeedGuard.sol` |
| `d9d07e0b4ffd59f50f52608b9b1a43dba8ceb4e6f405dabbf189779cd645a722` | `rh-chain/src/MarketHealthOracle.sol` |
| `62224f51036e157e17dcc3c169c4e488973fae3393e06a11c8c1ec99c32a7042` | `rh-chain/src/market/EsseyMultiply.sol` |
| `a1dab14f21284c4ec74f1da266ca7da05f34ac0155861acf0a06be24a581c36b` | `rh-chain/src/CollateralReconciler.sol` |
| `59f340284f1ede940cc9015d8bdfb95dfa8c81e69f817240265bd76760f1cb4d` | `rh-chain/src/LivenessOracle.sol` |
| `c703b6de05d924909daf5e4529e6228cfbe23cf274ace8a3ff069eae04337a92` | `rh-chain/src/market/Note.sol` |
| `74a504e38e8b92cacd257039adffb805869f18ff780a198009e76d975703511d` | `rh-chain/src/adapters/ConstantMultiplier.sol` |
| `b69886f13ad6f9aa815e8d7b1567042d034ffea490e65befd60d3396466b16a0` | `rh-chain/src/interfaces/IScaledUI.sol` |
| `8eb5a61ff90bb888866282998e5263376cfdf52510ab43bcd1c4daad5fadd4bf` | `rh-chain/src/interfaces/ISwapAdapter.sol` |
| `d7865ea0ea16b15f77abdd5c07e106ba1421ed711bd3feb8c6038534d1ae49fc` | `rh-chain/src/RobinhoodFeeds.sol` |
| `acb4ea4a66956ef746884bff0f2e6158262ac07af574a14fa6de849dfccf1cbb` | `rh-chain/script/DeployMarkets.s.sol` |
| `abef9a2dceac03c4caf785c713e580495ccce60658593d3d1aa9121d915c083e` | `rh-chain/src/testnet/ScaledUIStockMock.sol` |

**SHA drift, disclosed.** The tree was clean at `99a5735` when the round opened. A concurrent
session committed `2b330b1 fix(web): a dropped RPC read must not print as zero` mid-round.
`git diff --name-only 99a5735..HEAD` lists five files, all under `app/web/`;
`git diff --stat 99a5735..HEAD -- rh-chain/src rh-chain/script rh-chain/test` is empty. Every hash
above was recomputed from the git object store at `99a5735` and matches the working-tree bytes that
were audited. The verdict is NOT CLEAN regardless.

## Substrate

Real Robinhood Chain mainnet. No mock stands behind any load-bearing claim below.

| | |
|---|---|
| RPC | `https://rpc.mainnet.chain.robinhood.com` |
| chain-id | **4663** (`cast chain-id`) |
| block | **53963439** at round start; **53974383** at the final consolidated run, logged from inside the EVM (`chainid 4663, block 53974383, ts 1788495475`) |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` — decimals 6, `paused() == false` |
| AAPL Stock Token | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` — decimals 18, **BeaconProxy** (beacon `0xe10b6f6b275de231345c20d14ab812db62151b00`, impl `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2`), `uiMultiplier() == 1000566080061092436` |
| AAPL feed | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` — decimals 8, heartbeat 86400s, deviation 0.5% |
| whales | AAPL `0x9f736F87E6293AC1Bd9142E257dbfAC8b7AcF1ae`, USDG `0x2d4d2A025b10C09BDbd794B4FCe4F7ea8C7d7bB4` — real balances moved by impersonation |

The RPC is **not** an archive node: `--fork-block-number 53963439` fails with
`metadata is not found`, as does any historical `cast call --block`. Runs are at latest with the
block logged in-EVM. A reproduction will land on a later block.

Two hazards named in `CollateralReconciler.sol:11-20` were confirmed live on the deployed token
rather than taken from documentation: `adminBurn(address,uint256)` and `pause()` both exist and
revert with `AccessControlUnauthorizedAccount` (`0xe2517d3f`) — i.e. role-gated, not absent.

## Suites

```
forge test  (repo, non-fork, 14 lending suites)
  -> 493 passed, 0 failed        <-- all 493 pass while CRIT-1 is live

forge test --match-path test/ForkMvp.t.sol --fork-url <rh mainnet>
  -> 2 passed, 1 FAILED
     test_fullMvpPath_realTokenRealFeed  [FAIL: MarketClosed(0xaF3D…93f9)]

forge test --fork-url <rh mainnet>  (this round's harness, written outside the repo)
  -> 5 suites, 26 passed, 0 failed
```

The 26 harness tests are assertions about behaviour. The findings are the tests that **pass while
asserting the broken behaviour**, not tests that fail.

---

# CRIT-1 — `_desyncGuard` reverts against the real Stock Token, so `canBorrow` **and** `canLiquidate` revert

**CONFIRMED** on the fork. PoC: `test_F1_desyncGuardRevertsOnRealToken`, `test_F1_borrowIsUnreachable`.

## The mismatch

`IScaledUI` declares a two-value return (`rh-chain/src/interfaces/IScaledUI.sol:12`):

```solidity
function newUIMultiplier() external view returns (uint256 newMultiplier, uint256 effectiveAt);
```

The deployed Robinhood AAPL Stock Token returns **one** word:

```
$ cast call 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 "newUIMultiplier()" \
    --rpc-url https://rpc.mainnet.chain.robinhood.com
0x0000000000000000000000000000000000000000000000000de2b98c7058b254
```

32 bytes, where a `(uint256,uint256)` decode needs 64. In-EVM confirmation from the PoC:

```
newUIMultiplier ok/len  true 32
```

The call **succeeds**; it is the *decode* that fails.

## Why `try`/`catch` does not save it

`EsseyMarkets.sol:259-270`:

```solidity
function _desyncGuard(address token) internal view returns (bool) {
    try IScaledUI(multiplierSource[token]).newUIMultiplier() returns (uint256, uint256 effectiveAt) {
```

Solidity's `catch` does not catch return-data decoding failures — the exception is raised in the
caller's own frame and propagates. **This repository already knows that trap and names it twice**:

- `EsseyMarkets.sol:301` — *"whose try on a codeless token reverts OUTSIDE the catch (the solc
  `>=0.8.10` empty-returndata trap, see NoteArt)"*
- `Note.sol:51-53` — the same warning, and `setArt` guards against it.

It is also handled *correctly* elsewhere in the very same codebase: `EsseyPool._borrowAssetPaused`
(`EsseyPool.sol:257-260`) does a raw `staticcall`, checks `ret.length >= 32`, and decodes a raw word
precisely to avoid this. `_desyncGuard` did not get that treatment.

## Blast radius

Both gates call `_desyncGuard` unconditionally, and the pool calls both gates without a `try`:

| caller | line | consequence |
|---|---|---|
| `EsseyMarkets.canBorrow` | `EsseyMarkets.sol:236` | reverts |
| `EsseyMarkets.canLiquidate` | `EsseyMarkets.sol:309` | reverts |
| `EsseyPool.borrow` | `EsseyPool.sol:369` | **no borrow can ever open** |
| `EsseyPool.borrowMore` | `EsseyPool.sol:440` | reverts |
| `EsseyPool.removeCollateral` | `EsseyPool.sol:561` | reverts |
| `EsseyPool.liquidate` | `EsseyPool.sol:591` | **liquidation permanently bricked** |
| `EsseyPool.writeOff` | `EsseyPool.sol:656` | **write-off permanently bricked** |

`CollateralReconciler.pendingMultiplier` (`CollateralReconciler.sol:126-132`) carries the identical
`try`/`catch` shape and will revert for the UI and the keeper instead of returning `(0, 0)`.

PoC output, with liveness up, depth posted, market enabled and the session open:

```
canBorrow reverted     true
canLiquidate reverted  true
```

## Severity

Today the effect is a **total denial of service**: no borrow can open, so no funds are at risk —
this is exactly why the market would have looked merely "broken" on deploy day rather than
dangerous. The severity is CRITICAL for two reasons:

1. It is an absolute deploy blocker. The mainnet profile lists the Stock Token as its own
   multiplier source (`DeployMarkets.s.sol:88-90, 96`, `multiplierIsToken: true`), so every
   Robinhood market is affected.
2. **The token is a BeaconProxy.** Robinhood can change the return shape at any time. If a market
   were listed while `newUIMultiplier()` returned two words and the beacon were later upgraded to
   return one, every open loan would become unliquidatable and unwritable-off with real money in
   the pool. That is the fund-loss version of the same bug, and only the accident of the current
   shape decides which one you get.

## Why 493 tests miss it

`ScaledUIStockMock.sol:50`:

```solidity
function newUIMultiplier() external view returns (uint256, uint256) {
```

Two words. The mock does not match the token it stands for, so the entire suite is structurally
blind to the one call shape that matters. `ConstantMultiplier.sol` (the Ink profile's source) also
returns two words, so the Ink stack is unaffected — only the Robinhood profile is broken.

## Fix

Replace the `try`/`catch` in `_desyncGuard` with the raw-`staticcall` pattern the pool already uses
in `_borrowAssetPaused`: gas-capped `staticcall`, explicit `ret.length` check, and treat any shape
that is not exactly what is expected as "no scheduled action" (branch **(b)**, the
`syncMultiplier`-observed post-flip window, still covers a real corporate action). Apply the same
change to `CollateralReconciler.pendingMultiplier`. Then re-point `ScaledUIStockMock` at the real
token's one-word shape, or add a second fixture with it, so the suite can see this class again.

---

# HIGH-1 — the restart-liquidation race the LivenessOracle exists to prevent is open at the deployed parameters

**CONFIRMED** on the fork. PoC: `test_F2_restartRaceWithDeployedParams`, `test_F2_boundary`.

`LivenessOracle.sol:19-22` states the design guarantee:

> *"If the chain halts the keeper cannot post, so on restart the heartbeat is stale and liquidations
> are ALREADY disabled — no transaction needed at the critical moment, and nothing to front-run."*

That holds only when the outage exceeds `maxHeartbeatAge`. The deployed constructor
(`DeployMarkets.s.sol:181`) is:

```solidity
LivenessOracle liveness = new LivenessOracle(msg.sender, msg.sender, 90_000, 1 hours, 900);
//                                       maxHeartbeatAge ^^^^^^   resumeGrace ^^^^^  ^^^ gapThreshold
```

`maxHeartbeatAge` is **90,000 s (25 hours)**; `gapThreshold` is **900 s**. `liquidationsAllowed()`
(`LivenessOracle.sol:112-117`) only closes when the heartbeat is older than `maxHeartbeatAge`. The
`gapThreshold` protection at `LivenessOracle.sol:101-104` is applied **inside `heartbeat()`** — that
is, only *after* the keeper posts.

So for any outage between 900 s and 25 hours:

```
t0            keeper's last beat
t0 + 6h       chain restarts. liquidationsAllowed() == TRUE   <-- PoC assertion
              a liquidation bot's queued tx executes here
t0 + 6h + ε   keeper's heartbeat lands, gap registers, resumeGrace arms   <-- too late
```

PoC, verbatim assertions:

```solidity
vm.warp(block.timestamp + 6 hours);          // a 6-hour chain halt: nothing executes
assertTrue(liveness.liquidationsAllowed(),
    "F-2: liquidations are STILL ALLOWED in the first block after a 6h outage");
vm.prank(keeper); liveness.heartbeat();
assertFalse(liveness.liquidationsAllowed(), "gap only registers after the keeper posts");
```

Boundary, pinned: open at `t0 + 90_000`, closed at `t0 + 90_001`.

This is precisely the failure `LivenessOracle.sol:14-17` argues against — *"a safety control that
loses a race is not a safety control"* — reintroduced by the parameter choice.

**A second, contradictory consequence.** `LivenessOracle.sol:87` recommends beating at
`maxHeartbeatAge / 3` = 30,000 s ≈ 8.3 hours. With `gapThreshold = 900`, *every* beat at that
cadence registers as a gap and arms a fresh hour of `resumeGrace`. Following the code's own
recommendation would disable liquidations for the first hour after each beat, indefinitely. The
recommendation and the deployed parameters cannot both be right.

## Fix

Make the guarantee structural rather than operational, mirroring the bound that already exists one
line away (`LivenessOracle.sol:76` caps `resumeGrace <= 4 * gapThreshold`):

```solidity
if (maxHeartbeatAge_ > 4 * gapThreshold_) revert BadHeartbeatAge();
```

and deploy with a `maxHeartbeatAge` in the same order as `gapThreshold` (e.g. 1800 / 900 / 3600),
accepting the keeper cadence that implies. Correct the `maxHeartbeatAge / 3` comment at line 87 to
be expressed against `gapThreshold`.

---

# MED-1 — a collateral-token pause blocks repayment entirely, while interest keeps accruing

**CONFIRMED** on the fork. PoC: `test_F3_collateralPauseBlocksRepayEntirely`.

`EsseyPool.sol:220-226` reasons carefully about which pause suspends the interest clock and
concludes, correctly, that only a *borrow-asset* pause should. It records the residual as:

> *"Accepted residual: a borrower whose collateral is paused still accrues during the freeze."*

The residual is larger than that sentence says. `repay` **ends in a collateral transfer**
(`EsseyPool.sol:490`) and `addCollateral` **begins with one** (`EsseyPool.sol:534`), so under a
Robinhood `PAUSER_ROLE` pause the borrower can neither exit nor de-risk:

| call | under a collateral pause |
|---|---|
| `repay` | **reverts** (`EsseyPool.sol:490`) |
| `addCollateral` | **reverts** (`EsseyPool.sol:534`) |
| `removeCollateral` | reverts (`EsseyPool.sol:578`) |
| `liquidate` | reverts (`EsseyPool.sol:621`) |
| `repayPartial` | **succeeds** — it never touches the collateral token |
| `accrue` | keeps compounding (`EsseyPool.sol:227` watches `asset()` only) |

The only survivor cannot close a position: `repayPartial` reverts `UseFullRepay` at
`amount >= owed` (`EsseyPool.sol:502`). A borrower can pay down to 1 wei of debt and wait, which is
a real mitigation, but it is undocumented and unobvious, and the position stays open, exposed, and
accruing. If the price moves during the freeze the position becomes underwater and unliquidatable,
so the loss lands on lenders on unpause.

## Fix

Split collateral return from position closure: let `repay` settle the debt, burn the Note, and
credit the collateral to a `claimable[id]` balance whenever the transfer would fail, with a
permissionless `claimCollateral(id)` to pull it later. That turns a hard block into a pull payment
and removes the accrual-during-an-unexitable-freeze case entirely.

---

# MED-2 — the deploy script ships a single-key posture behind a `console.log`

**CONFIRMED** by reading `script/DeployMarkets.s.sol`.

```solidity
// DeployMarkets.s.sol:171-176
address guardian = vm.envOr("GUARDIAN", address(0));
if (guardian == address(0)) {
    guardian = msg.sender;
    console.log("!!! GUARDIAN unset - defaulting to the admin key. Single-key posture; !!!");
    console.log("!!! set GUARDIAN to a separate hot key before any mainnet deploy.     !!!");
}
```

A `console.log` in a broadcast is not a control — the transaction goes out either way, and the
result is immutable (`EsseyMarkets.guardian` is `immutable`, `EsseyMarkets.sol:106`).

And even with `GUARDIAN` correctly set, three further keys collapse onto the deployer:

| line | construction | consequence |
|---|---|---|
| `:181` | `new LivenessOracle(msg.sender, msg.sender, …)` | liveness **keeper *and* guardian** = admin |
| `:183` | `new MarketHealthOracle(msg.sender, guardian, msg.sender)` | depth **keeper *and* oracle admin** = admin |
| `:258` | `new EsseyPool(…, msg.sender, 0, …)` | `reserveTreasury` = admin, `bellShareBps == 0` → 100% of skimmed reserves to that EOA |

So one compromised deploy key is simultaneously: market admin, liveness keeper, liveness guardian,
depth keeper, health-oracle admin, and the reserve treasury — and, if `GUARDIAN` is unset, the
market guardian too.

## Fix

`require(!prof.testnet ? guardian != address(0) : true, "GUARDIAN required on mainnet")` before
`vm.startBroadcast()`, and take `LIVENESS_KEEPER`, `LIVENESS_GUARDIAN`, `DEPTH_KEEPER` and
`RESERVE_TREASURY` from the environment with the same requirement.

---

# MED-3 — the liveness keeper is an unbounded liquidation kill-switch, and the code documents the opposite

**CONFIRMED** on the fork. PoC: `test_M2_keeperSilenceHaltsLiquidationsWhileDebtGrows`.

`EsseyMarkets.sol:104-106` says of the guardian/keeper trust shape:

> *"the `LivenessOracle.keeper` trust shape. Compromise cost is a market outage, never funds."*

That is true of `EsseyMarkets.guardian` (which can only call `disableMarket`) and true of the
`MarketHealthOracle` keeper — verified: `effectiveCap` is read only at `EsseyMarkets.sol:234`
(`canBorrow`) and `EsseyPool.sol:414` (`_gateNewDebt`), so it has zero liquidation authority, exactly
as `MarketHealthOracle.sol:17-18` claims.

It is **false for the `LivenessOracle` keeper.** That key does not need to be compromised in an
active sense: it only has to *stop posting*. `liquidationsAllowed()` then returns false, and
`canLiquidate` (`EsseyMarkets.sol:304`) declines every liquidation protocol-wide while `accrue()`
keeps compounding.

PoC: a position at −50% (deeply underwater), keeper silent:

```
LiquidationNotAllowed(0xaF3D…93f9)        <-- liquidate() reverts
owed after 12 more months of enforced silence:  1644005111 -> 1815402919   (USDG, 6 dp)
```

`LivenessOracle.guardian` can also rotate that keeper (`LivenessOracle.sol:127-132`) with no
timelock, which reaches the same state actively. In the deploy script both roles are the admin key
(MED-2).

This is inherent to a fail-closed liveness design and is arguably the right trade — a wrongful
liquidation is worse than a delayed one. The finding is that **the code asserts a safety property it
does not have**, and the operational control that would bound it (redundant keepers, alerting on
`secondsUntilLiquidationsAllowed`) is not written down anywhere.

## Fix

Correct the comment at `EsseyMarkets.sol:104-106` to state the liveness keeper's real blast radius.
Run at least two independent keepers, and put a monitor on `lastHeartbeat` age with a page at
`maxHeartbeatAge / 2`.

---

# LOW-1 — `maxWithdraw` / `maxRedeem` overstate; both revert when passed back

**CONFIRMED** on the fork. PoC: `test_F6_maxWithdrawOverstatesWhatIsWithdrawable`.

`EsseyPool._withdraw` enforces a cash constraint (`EsseyPool.sol:305-306`):

```solidity
uint256 cash = IERC20(asset()).balanceOf(address(this));
if (assets_ > cash) revert InsufficientLiquidity(assets_, cash);
```

Neither `maxWithdraw` nor `maxRedeem` is overridden, so both return OZ's unconstrained conversion.
EIP-4626 requires the `max*` family to return a value that will not cause a revert. Measured:

```
cash 148355994889   maxWithdraw 150000000000     (USDG, 6 dp)
redeem(maxRedeem)     -> revert
withdraw(maxWithdraw) -> revert
```

Harmless to a direct user (they retry smaller); it breaks any 4626 router or aggregator that
follows the spec.

**Fix:** override both to clamp at available cash.

---

# LOW-2 — `EsseyMultiply.close()`'s pool binding is spoofable, leaving a standing allowance on the real borrow asset

**CONFIRMED** on the fork. PoC: `test_M1_hostilePoolLeavesDanglingAllowance`.

`close()` takes the pool as a caller-supplied argument, and its only binding check is
`EsseyMultiply.sol:212`:

```solidity
if (pool.markets() != markets) revert WrongPool(address(pool));
```

Any contract can return the right address. Everything downstream — `collateralToken()`, `asset()`,
`note()`, `debtOf()`, `repay()` — is then attacker-defined. `EsseyMultiply.sol:235` approves the
attacker's address for the real borrow asset and never resets it:

```solidity
s.asset.forceApprove(address(pool), owed);
```

PoC result:

```
dangling USDG allowance to the fake pool   10000000000       (10,000 USDG)
seed stranded in the periphery             10000000000
stray left in the periphery after the sweep 5000000000
```

**This is not a theft of user funds.** The balance-delta accounting (`EsseyMultiply.sol:236-244`,
`:275-278`) holds: `s.cash` only grows from the caller's own seed and from measured swap output, so
the attacker cannot end with more than they put in, and a hostile pool can only spend its own
caller's money — exactly as `EsseyMultiply.sol:200-202` claims. The residual is that the periphery
is left with a permanent, attacker-controlled claim sized by what the attacker temporarily posted,
which converts *"anything sent here outside a call is lost to the next caller"*
(`EsseyMultiply.sol:22-23`) into *"lost to whoever pre-positioned the largest allowance."*

**Fix:** require `pool == EsseyPool(markets.activePool(pool.collateralToken()))`, or accept only
pools registered by `PoolFactory`, and zero the approval after `repay` returns.

`EsseyMultiply` is DEFERRED per the register and has **no production `ISwapAdapter`** — a grep over
`src/` finds only the interface and `EsseyMultiply` itself. It cannot ship until one exists, and
that adapter will need its own round.

---

# LOW-3 — `repayPartial` lets a stranger move the market-cap accounting for 1 wei

**CONFIRMED** on the fork. PoC: `test_M5_strangerCanInflateMarketBorrowsTowardTheCap`.

`repayPartial` is permissionless by design (`EsseyPool.sol:494-495` — paying someone's debt only
helps them, and blocking it in an outage causes the liquidation the gates prevent). But it also
**rebases principal to the current index** (`EsseyPool.sol:508-519`), folding accrued interest into
`p.principal`; and `marketBorrows` tracks Σ principal, so it takes the increase.

```
marketBorrows before / after a 1-wei stranger repay:  1644005111 -> 1809392024
```

A third party, at a moment of their choosing and for 1 wei, moved a figure that gates every new
borrow against `markets.borrowCap` (`EsseyPool.sol:414-416`). The new figure is arguably the *more
honest* one — it reflects debt that genuinely exists — which is why this is LOW and not a value
leak. The finding is that an outside party controls the *timing* of a borrow gate.

**Fix (or accept):** either fold interest into `marketBorrows` on `accrue()` so the figure is never
timing-dependent, or record the acceptance in `EsseyPool.sol:505-507` where the current comment
already discusses the signed delta but does not mention that a stranger drives it.

---

# LOW-4 — per-second `accrue()` truncates both interest and the reserve cut to zero on a small book

**CONFIRMED** on the fork. PoC: `test_M6_perSecondAccrualTruncatesReserves`.

`EsseyPool.sol:240-244`:

```solidity
uint256 prev = totalBorrows;
uint256 scaled = (prev * num) / denom;
totalBorrows = scaled;
uint256 interest = scaled - prev;
totalReserves += (interest * reserveBps) / BPS;
```

`borrowIndex` is scaled from `1e18` and does not truncate; `totalBorrows` is scaled from the raw
6-decimal figure and does. On a 32.880102 USDG book, 600 consecutive one-second accruals:

```
totalBorrows  before / after   32880102 -> 32880102     (unchanged)
totalReserves before / after          0 -> 0            (unchanged)
borrowIndex                    1000001902589325630      (advanced)
```

Positions' debt grew (via the index) while the pool's aggregate did not. The threshold is
`totalBorrows * rate * dt < BPS * SECONDS_PER_YEAR`, i.e. roughly **$630 of total borrows at 5% with
`dt = 1`**. Above that it does not bite, and the deployed cap is 250,000 USDG. The consequence is a
griefable loss of the protocol's reserve cut on a tiny book, and a temporary understatement of
`totalAssets()` that self-corrects on repayment (`EsseyPool.sol:691` floors at zero).

**Accepted-with-rationale is legitimate here.** Recording the threshold so it is a decision rather
than an oversight.

---

# INFO

**INFO-1 — `v4DiscountBps` is dead storage.** `MarketHealthOracle.sol:85` declares it, `:102`
initialises it, `:238` commits it, and `:249` validates it. A grep across `src/` and `script/` finds
**no consumer** — only its own getter and `test/MarketHealthOracle.t.sol`. It occupies a slot in a
timelocked parameter struct, which implies an on-chain control that does not exist. Either wire it
or delete it; a keeper-side constant does not belong in a timelocked struct.

**INFO-2 — a load-bearing comment is false.** `EsseyMultiply.sol:14`:

> *"The pool has no `borrowMore()`: `borrow()` is the only debt-opening call…"*

`EsseyPool.borrowMore` is at `EsseyPool.sol:433`. The whole ladder-of-Notes rationale in that header
rests on a premise the pool no longer satisfies. The ladder may still be the right design, but the
argument for it needs rewriting against the current pool.

**INFO-3 — the "cannot be fooled by mocks" fork test is red.**
`test/ForkMvp.t.sol::test_fullMvpPath_realTokenRealFeed` fails at the frozen SHA with
`MarketClosed(0xaF3D…93f9)`. The file describes itself (`ForkMvp.t.sol:14-19`) as *"the check that
cannot be fooled that way"* — the one guard against mock-shaped blindness, which is exactly the
class CRIT-1 belongs to. The cause is in the helper, not the contracts: `_intoSession()` warps in
1-hour steps and beats each step, and with `gapThreshold = 1 minutes` (`ForkMvp.t.sol:53`) every
step registers as a gap, so the final beat arms `resumeGrace` and `canBorrow` returns false. A
permanently-red fork test trains people to ignore the one signal that would have caught CRIT-1.

---

# Verified clean this round

Asserted on the fork against real state, not assumed. These are the checks that passed, and they
are the reason the finding list is not longer.

**Liquidation.** Seizes exactly debt + bonus and refunds the surplus; every unit accounted for
(`seized + refund == collateral`). Measured: `owed 1644005111`, `seizedValue 1726205369` — 1.0500×,
against a configured 500 bps bonus. A healthy position reverts `PositionHealthy`. The surplus
follows `note.ownerOf` at execution time, not the original borrower — a transferred Note routes it
to the new holder and pays the old one nothing. *(`test_F5_*` ×3)*

**`adminBurn` burn-sharing.** With a third of the pool destroyed mid-loan, two borrowers recovered
`6666666666666666660` and `13333333333333333320` of a surviving `20e18` — pro-rata to 12 decimal
places, with 20 wei of rounding retained by the pool (the safe direction). A borrower who deposited
*after* a burn recovered 100% of their collateral while the pre-burn borrower took the whole loss.
Payouts never exceeded the surviving balance across a burn → rebase → burn sequence that exercises
the index-reset path in `CollateralReconciler._creditCollateral:140`. *(`test_F4_*` ×2, `test_N2`)*

**Reentrancy.** A hostile collateral token that calls back on every `_update` was armed against all
five pool entry points (`borrow`, `repay`, `liquidate`, `addCollateral`, `removeCollateral`) from
inside a collateral transfer. Every attempt reverted, and `totalBorrows`, `marketBorrows` and
`recordedRaw` were unchanged by the attempt. *(`test_N1`)*

**Authority.** `repay`, `borrowMore` and `removeCollateral` all revert `NotBorrower` for a
non-holder. *(`test_N3`)*

**Health gating.** `borrowMore` reverts one step past the LTV ceiling and succeeds inside it;
`removeCollateral` reverts on a withdrawal that would breach LTV and succeeds on one that would not.
*(`test_N4`)*

**Isolation.** A second pool on the same registry and the same token holds nothing and cannot open a
borrow — `NotActivePool`. The founder's isolated-pools ruling holds structurally: `collateralToken`
is `immutable` (`EsseyPool.sol:98`) and `activePool` flips only through the 2-day
propose/commit pipeline. *(`test_F9`)*

**Write-off.** Refuses a merely-underwater position (that is the liquidator's job), refuses
`recovered` below the market floor, and the lender loss equals exactly the shortfall:
`owed 1644005111`, `value 1315204089`, `lenderLoss 328801022` = `owed − value` to the wei.
*(`test_F8`)*

**The rate curve, including the leg the repo suite only `assertGt`s.** `RateModes.t.sol:158-159`
checks the above-kink leg with `assertGt` only. Pinned exactly here, for the deployed Kink curve
(base 1000, slope1 500, slope2 6000, kink 8000 — `EsseyPool.sol:110`, `DeployMarkets.s.sol:42`):

| utilisation (bps) | rate (bps) |
|---|---|
| 0 | 1000 |
| 4000 | 1250 |
| 8000 | 1500 |
| 8001 | 1503 |
| 9000 | 4500 |
| 10000 | 7500 |

Continuous at the kink — the two legs agree at 8000 — and 75% APR at full utilisation. *(`test_F7`)*

---

# Deploy-parameter ruling

The founder asked for a judgement, not a reading. Parameters under review
(`DeployMarkets.s.sol:274-282`): **LTV 5000 bps · liquidation 7500 bps · bonus 500 bps · cap
250,000 USDG · 20% of cap per position.**

**The 25-point gap gives a max-LTV position a 33.3% price cushion, and that is what it actually
does.** Verified against the real AAPL feed rather than derived:

```
price −30%  ->  not underwater
price −35%  ->  underwater
```

**The bonus is payable at the trigger.** At the 75% threshold the collateral is worth 1.333× the
debt and the seizure is 1.05×, leaving a real surplus for the borrower — measured exactly
(LOW/`test_F5`), so a borrower 1 bp underwater is not wiped out.

**Where it is thin.** Liquidation gates on *freshness*, not session
(`EsseyMarkets.sol:313-323`), so weekday nights stay actionable. The uncovered window is
Friday's close plus the 25-hour staleness bound — roughly Saturday 21:00 UTC until Monday's first
fresh print. A Monday gap-down beyond 33% on a single name is rare but not fantastical; single-name
earnings and guidance gaps of 20–30% are ordinary. Bounded by the per-position cap, the worst single
position is 50,000 USDG of notional.

**Where it is irrelevant.** The two tails that dominate *this* collateral are not price tails at
all. `adminBurn` destroys the collateral outright — no LTV protects against that; the reconciler
socialises the loss, it does not prevent it. A `PAUSER_ROLE` pause blocks the exit entirely (MED-1).
Both surfaces are live and role-gated on the deployed token, confirmed on chain this round.

**Ruling.** The gap is adequate for routine volatility and is doing its job; I would not move it. If
one number changes before mainnet, **cut `cap`** for the first months. Exposure size is the lever
that bounds every tail here, including the two that no LTV can reach.

---

# Privileged-key blast radius, enumerated

| key | powers | timelock | worst case |
|---|---|---|---|
| `EsseyMarkets.admin` (`immutable`, no rotation) | `proposeMarket` / `cancelMarketProposal` / `disableMarket` / `proposeResolver` | 2 days on params; `disableMarket` immediate | Over two timelocked stages (~4 days of public notice) can set `ltvBps = 0` then `liqThresholdBps = 1` and make **every open position liquidatable at an unmoved price** — `test_M3` confirms it; the borrower keeps the surplus above debt + bonus (4.744 AAPL of 10 refunded). Can also repoint `activePool` to a pool it deployed. **Cannot** swap the feed, the multiplier source, or the freshness pair — all append-only (`EsseyMarkets.sol:377-391`). |
| `EsseyMarkets.guardian` (`immutable`) | `disableMarket` only | none needed | Stops new borrows. Cannot touch funds. **The "outage, never funds" claim holds for this key.** |
| `MarketHealthOracle.keeper` | `postDepth` | none | Can zero `effectiveCap` and stop new borrows. **Zero liquidation authority — verified**, `effectiveCap` is read only at `EsseyMarkets.sol:234` and `EsseyPool.sol:414`. Claim holds. |
| `MarketHealthOracle.guardian` (`immutable`) | `setKeeper` | none | Safe direction only. |
| `MarketHealthOracle.admin` (`immutable`) | `proposeParams` / `commitParams` | 2 days | Bounded by `_validate` (`MarketHealthOracle.sol:245-251`). |
| `LivenessOracle.keeper` | `heartbeat` | n/a | **Liquidation kill-switch by silence (MED-3).** |
| `LivenessOracle.guardian` | `setKeeper` | **none** | Reaches the same state actively. |
| `resolver` | `writeOff` | 2 days to install | Only on positions where collateral is worth less than the debt; must pay at least market value (`EsseyPool.sol:662`) and receives the residual collateral. Cannot profit; cannot touch healthy or merely-underwater positions. |
| `EsseyPool.reserveTreasury` (`immutable`) | receives skims | n/a | 100% of skimmed reserves under the deployed config (`bellShareBps == 0`). |
| `EsseyPool.deployer` (`immutable`) | `setNoteArt`, one-shot | n/a | Spent at deploy. |
| `EsseyMultiply` admin (= `markets.admin()`) | `listMarket`, append-only | **none** | Can list a hostile `ISwapAdapter`. Bounded only by the caller's `minOut`, which is 0 per leg on the close path (`EsseyMultiply.sol:243`). |

**External powers no key of ours holds, and no parameter defends against:** the Robinhood issuer can
`adminBurn` collateral out of the pool, `pause` the Stock Token (MED-1), and upgrade the token
implementation through the beacon (CRIT-1's second scenario). The USDG issuer can pause or blocklist
the pool address, which would freeze every borrow-asset transfer in and out.

---

# What the next round must not repeat

CRIT-1 survived 493 green tests because the fixture did not match the token. Before this gate can
return clean, at least one test in the repo must **execute the production call shape against the
production address** for every external surface the engine depends on: `uiMultiplier()`,
`newUIMultiplier()`, `decimals()`, `paused()`, `latestRoundData()`. A mock is a hypothesis about the
world; the fork is the only place that hypothesis gets checked.
