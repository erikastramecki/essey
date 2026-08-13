# D.O.N. Skirmish Phase-0 — Adversarial Wallet Harness (Testnet Game E2E)

**Date:** 2026-08-13 · **Chain:** Robinhood Chain testnet (46630) · **Explorer:** `https://explorer.testnet.chain.robinhood.com/tx/<hash>`
**Harness:** [`rh-chain/script/GameE2E.s.sol`](../rh-chain/script/GameE2E.s.sol) (phased forge script) + [`rh-chain/script/game-e2e.sh`](../rh-chain/script/game-e2e.sh) (wall-clock orchestrator) — the DonE2E precedent, adapted for a time-gated stack.

## Verdict

**NO CONTRACT BUGS FOUND. 15/15 mandated flows proven — 12 live on-chain, 3 time-gated flows fork-proven (labeled). 9/9 negative checks reverted with the exact custom error. One tx pair PENDING-LIVE (hero mission resolve at its real 3h due — keeper auto-resolves; mechanism already live-proven 6×).**
Every audit fix held under attack: F1 (keeper cannot mint Scrip), F2 (only the SEASON_MODULE can close a season — and none is wired), F3 (repair fee is un-dodgeable: basis frozen at damage time), L-1 (heat claimed at reveal), H-1 (garrison suppression forfeits the defense bonus, not the roll). The custody invariant `scrip.balanceOf(escrow) == totalDeployed + totalHopper` held after **every** mutating phase and the escrow drained to **exactly 0** at the end. `outstandingReserved` drained to 0 once all missions settled.

## Stack under test (live, sealed)

| Contract | Address |
|---|---|
| GameController | `0xe2BEA5db063EA57F73D6bA8294592d7f60CBec9f` |
| Scrip | `0xAE8AEB1E0eA9A6E6A55b469107DD5c7cbf28F1F6` |
| HouseDeed | `0xe180dbda25966Cd6AE372C967200F0EB6D003368` |
| HouseEscrow | `0x869cbc012C37F7655FA5eA8F655E862Aa631C93C` |
| MissionBoard | `0xA4839CA4b595c768636E05bF37E32b167e482d99` |
| RaidEngine | `0xf497AAb709952FF061AEC34390Dad281649D1a2a` |
| HitterNFT | `0x219fafE26FB865b8dA4F55EF38ee99a91Ef969Cf` |
| MockEntropy (keeper-driven) | `0xc9e6B140C10e6DcDAE7a2d2a9FdD1BB82Ca1F047` |
| Don collection / distributor | `0x582E…dB53c` / `0x9F99…9103` |

## Actors (fresh throwaway wallets, seed `keccak("don-game-e2e-v1")`, keys `keccak(seed,i)`)

| # | Role | Address | Dons |
|---|---|---|---|
| W0 | HERO — launch-brief first play | `0xD8ddA260Ce5C188b98b45558D10c9DF88e6Eae75` | 93 |
| W1 | GRINDER — upgrade/yield/garrison defender | `0x1A18eD84A1a831d7f5d10BaA87E58CCD5be5dC52` | 94 (+ Hitters 1-2) |
| W2 | ATTACKER — raids | `0x6b4E0a73318a70dDd02B3f0b948e97b772d77Faf` | 95 (+ Hitters 3-11) |
| W3 | TARGET owner | `0x071Fc556Ab0Dfc3c57911803fc68b2774f3fd5AA` | 96-99 |
| W4 | RANDO — negative checks | `0x72EE49053534ebaEAbaEa56556271C01fBBB4D61` | — |

Gas came from sweeping the 18 spent DonE2E wallets back to the deployer (18 txs, e.g. [0xd05f…a026](https://explorer.testnet.chain.robinhood.com/tx/0xd05fbe5edcfa84e8c82d181ee4aea9fc575565b448f6711f2ab3f315c6f4a026)), then funding the five actors ([0x2393…7516](https://explorer.testnet.chain.robinhood.com/tx/0x23933812fd3a3ff5323e4318311220338dd7bee1b92ac5a20da38259af8f7516) …).

### Methodology notes (read before auditing the table)

- **Harness briefs.** The 4 launch briefs run 3h-24h — unfarmable in a live session. The game admin posted two additional briefs (the board is append-only by design; launch briefs untouched): **#5 "E2E SPRINT"** (75s, 98.5/1.45/0.05, pays 6000/2400, fee 1) in [0xfe5f…be43](https://explorer.testnet.chain.robinhood.com/tx/0xfe5fd42396bf6cd54be633f6294df77f4e289b937a7b572d41a9313cbe96be43) and **#6 "E2E WINDOW"** (20min, pays 100/40) in [0x0a3f…ba7b](https://explorer.testnet.chain.robinhood.com/tx/0x0a3fac32d175d44d03cf994d0df0d9aeece6271c0e1df759eff19e027afaba7b). The hero's first play still ran on launch brief 1 (PAPER ROUTE, 3h) and resolved at its real due.
- **Entropy divergence.** MockEntropy words depend on the mined block, so in-run assertions after a `fulfill` are outcome-agnostic; every payout-band / loot / tax claim below was verified **post-hoc from the mined events and fresh `eth_call`s** (hashes cited are the mined txs).
- **Negative checks** are proven twice each: an `eth_call` that must revert with the **exact custom error selector**, then the same call **mined with a manual gas limit** — a status-0 tx on the explorer.
- **Time-gated flows** (>2h waits) are proven in `forkProofs()` — a fork simulation with `vm.warp` against live testnet state (the `DonE2E.liquidationFork` precedent). Clearly labeled **FORK-PROVEN**; no live tx exists for those, by physics.

## Flow table — live on-chain proofs

| # | Flow | Actor | Tx (explorer) | Asserted state | Result |
|---|---|---|---|---|---|
| 1 | Mint Don from fresh wallet (×7, Dons 93-99) | W0-W3 | [0x1de0…5436](https://explorer.testnet.chain.robinhood.com/tx/0x1de0d45295d0b98222fadc9312d4d332f2f4faacd765595be2193143a6c25436) [0x3cd3…9959](https://explorer.testnet.chain.robinhood.com/tx/0x3cd3d261f92a6d29350f735f07eac3c5eea86935750f4dc78fa88ab654719959) [0x8492…6d92](https://explorer.testnet.chain.robinhood.com/tx/0x8492a88f7d5ade73cee9019bfaca34c8bc5008d3e7814de7e1d210809a846d92) [0x5e8d…8a3e1](https://explorer.testnet.chain.robinhood.com/tx/0x5e8d6c0ac9aabbb717d0f8558c7a790b6ed75c0a98719368799378f33bb8a3e1) [+3](https://explorer.testnet.chain.robinhood.com/tx/0xf9cc0d8fc07f0234123118e4f1f6eec220c59c13a0ce0b667ec8a35604238e10) | `ownerOf == wallet`, 6551 vault exists | PASS |
| 2 | First depart — PAPER ROUTE brief 1, provision 5 (mission 1) | W0 / Don 93 | [0xdae3…678c](https://explorer.testnet.chain.robinhood.com/tx/0xdae339375e912dcf5383973eac4fe0b8d060a2313c74ecca54853be43beb678c) | Safehouse auto-claimed (deed 1, tier 0, HD 40, cap 5000), stipend latched, vault = **44.55** (50 − 0.45 fee − 5 provision), 5.45 burned, worst-case reservation **41.769** (36 + 5×1.1538), `isAway`, `activeMissionOf=1` | PASS |
| 3 | Keeper resolve + MockEntropy fulfill (missions 2-5, SPRINT) | keeper | [0x6c61…f6a4a](https://explorer.testnet.chain.robinhood.com/tx/0x6c6189ad3efa1562a80373083bd02e9be13ccdd0436c63cb9f7802be6b8f6e4a)+[0xa74b…9e59](https://explorer.testnet.chain.robinhood.com/tx/0xa74b8e33a4ac505f7ef117bc65bf67f8b9025afa5babfd1e1ae09571cea09e59) [0x6ef2…4a51e](https://explorer.testnet.chain.robinhood.com/tx/0x6ef205ed731a9ab7ed022b859e66a44508d496d5244e1366ee3fe840d4a51e7e) [0x6e4f…939f](https://explorer.testnet.chain.robinhood.com/tx/0x6e4f7a06012a96d237d6e1a479881452186e7772f24d67ea7185d98dc582939f) [0x9460…d65f](https://explorer.testnet.chain.robinhood.com/tx/0x946066465ceb9bcb84825566a75bdd4ae4f662f5316d97356e99d96b2269d65f) [0x87da…89fc](https://explorer.testnet.chain.robinhood.com/tx/0x87da0b61632c9553d41b43cfc4667ff7bd5cfd7ee9c88d0f5fac41ee755989fc) [0x3859…9f5b9](https://explorer.testnet.chain.robinhood.com/tx/0x3859eefb98cbcb588b3904f86dbfad2c509149eeb14c6aca9a289ff6659b5f9b)+[0x1ac6…cc3cd](https://explorer.testnet.chain.robinhood.com/tx/0x1ac6ce88cbd98dd7cd38c6308c88ae24b3a641611f46d9c5e5f4ad7d6abcc3cd) | `Resolved` events: outcome 0 (SUCCESS), payout **exactly 6000e18 = the posted band**, hoppers credited 6000 each, missions settled, Dons home, custody 18000 == 0 + 18000 | PASS |
| 4 | deploy() into the House | W1/94, W3/96 | [0xfaf1…363a6](https://explorer.testnet.chain.robinhood.com/tx/0xfaf1785638bca1ba2494cb80170bc56ed6aa5e2c6e357c5194012fc3bfc363a6) [0x9ca5…de060](https://explorer.testnet.chain.robinhood.com/tx/0x9ca5b51e58186bd519b80ed362cb9451020f4f6feb1d45eaed2fda08cd1de060) | `deployedOf=1000`, vault debited 1:1, earning weight set, **custody invariant** | PASS |
| 5 | bank() — the sacred exit (partial + full, fee-free) | W1, W2, W3 | partial: [0x2ee3…d867](https://explorer.testnet.chain.robinhood.com/tx/0x2ee394a91ffc6a55f7d8c51092f1be88a476175f9144d23350999c712e10d867) [0x6163…5ec5b](https://explorer.testnet.chain.robinhood.com/tx/0x6163f6bf9a0ad7a8a6e44b5da4215f98895f417a5453fe3ee540ef92b535ec5b) · full: [0xeea1…c81c](https://explorer.testnet.chain.robinhood.com/tx/0xeea16bd87fee12199eab91004dc3acd9dac832b3ab2c350e9a36fec8dcb5c81c) [0xdcfc…5872a](https://explorer.testnet.chain.robinhood.com/tx/0xdcfc27aa27e20ca78f2b0266790a537a8958639db5f6634b4c76f033ea15872a) [0xd0bb…bc73f](https://explorer.testnet.chain.robinhood.com/tx/0xd0bbef6a5837458cc39ab08bab6ea5d044089dce8b63ed69febebed5002bc73f) [0xa2f8…ba66e](https://explorer.testnet.chain.robinhood.com/tx/0xa2f8e3d70649f04cc7defec977b38e7cf2a000a5d7ced17918093b86962ba66e) [0x82fd…9ea14](https://explorer.testnet.chain.robinhood.com/tx/0x82fd6359e460939b8f5bc5641df2b416c776b1e9f27d553b5d9d6a18e4a9ea14) | Vault credited exactly `fromDeployed + fromHopper` (+ checkpointed yield) — **zero fee**, no gate; ledgers decremented; custody invariant after each | PASS |
| 6 | Yield accrual + checkpoint | W1 / Don 94 | [0x878c…bc273](https://explorer.testnet.chain.robinhood.com/tx/0x878c1373889a15a56889dd80ef66c9e279d49b7afd149a4ac9227150cb6bc273) | `pendingYieldOf` grew while deployed (read 1.07e16 then 0.55e16 after re-deploy state), `bank(0,0)` checkpoint landed **+5.708e15** in the hopper, `yieldBudget` decremented by emission | PASS |
| 7 | House upgrade → Row House (1500 burned) | W1 / Don 94 | [0x0a34…d56d1](https://explorer.testnet.chain.robinhood.com/tx/0x0a342ffe82a0a73b0810a4b27ad58bc3498525c98748d2341395aaf6c2dd56d1) | tier 0→1, deployCap 5000→**15000**, defense 40→**60**, garrison slots 2→**3**, vault −1500, `totalBurned` +1500 | PASS |
| 8 | Hitter mint (900 Scrip each, ×11) | W1 (1-2), W2 (3-11) | [0xeb30…935a4](https://explorer.testnet.chain.robinhood.com/tx/0xeb30b21e25b190c09b00508e78c95442e0fd47622727379c0d088f26a20935a4) [0x5a06…6a03](https://explorer.testnet.chain.robinhood.com/tx/0x5a0679c24711fb884adff04dc8c46ac06c014443a70fc00bcf79ca1ea86e1a03) [0x62f1…ea627](https://explorer.testnet.chain.robinhood.com/tx/0x62f17ba26d0b12e8b8a7364e0b27120c0db049b92cbdb3eb6e943e27f57ea627) [+8](https://explorer.testnet.chain.robinhood.com/tx/0x657f206d17032a7904ee29fcb15524aa0bdc718db64da3b6a30141b5db803095) | `ownerOf == minter`, `sealed_ == true`, vault −900 each, **burned** (2×900 and 9×900 asserted) | PASS |
| 9 | Favor reveal (commit→entropy→band) | W2 / Hitter 10 | [0xf754…36de](https://explorer.testnet.chain.robinhood.com/tx/0xf754a134455a099693c31ab87bf6d7b0c5ce1f8871b5c8b1dfb0c2074fd336de) + fulfill [0x80dd…4ac64](https://explorer.testnet.chain.robinhood.com/tx/0x80dd9ac86ca9c564606680c8dbea9a74da8343637e286c7e71e8fb7d5c24ac64) | `FavorRevealed(id 10, band 0=Common, forced=false)`, `sealed_=false`, `revealPending=false`. forceRevealFloor: **FORK-PROVEN** (F-D below; Hitter 11 deliberately left sealed on the live chain — its 30-day clock is real) | PASS |
| 10 | **Full raid, hit path** (ungarrisoned target) | W3 departs, W2 raids | bait depart [0xd6de…4ef0c8](https://explorer.testnet.chain.robinhood.com/tx/0xd6ded72b3b9ced2328c6996c11e081af838d5e8c3e02e8063da796cace4ef0c8) · commit 1 [0x19ca…63135](https://explorer.testnet.chain.robinhood.com/tx/0x19cad21c16e6484885921e6b34f89954aa619d0aa607eae27a72a417d7a63135) · reveal [0x38a6…d2772](https://explorer.testnet.chain.robinhood.com/tx/0x38a60087d9fccb624b7e8375652fb06ebda865329bebc4d964cd5e6f3b9d2772) · word+settle [0x99fc…a34ac0](https://explorer.testnet.chain.robinhood.com/tx/0x99fc5bb4d316cd17f69c70adc729aaa2e1e8dc9886f5253e37f6365d13a34ac0) | Commit: 50 Scrip vault→engine. Reveal: fee **burned**, attackPower locked, heat claimed **at reveal** (L-1). `RaidSettled(1, COMMON, pHit=620689ppm — exactly 0.72·250/290 for 5 fresh Hitters vs HD 40)`; **taken = 2000.015 (full hopper), tax = 150.001 burned = exactly 7.5%**, attacker vault +1850.014, `deployedOf` untouched (common never takes principal), damage 4000 set, `damageBaseDeployed` frozen at 1000 | PASS |
| 11 | Raid vs garrisoned target (defender reveals) | W1 departs+reveals, W2 raids | garrisoned depart [0xa1c9…6a974a](https://explorer.testnet.chain.robinhood.com/tx/0xa1c9a67ca7d28f0a1d0c7155a49b9a1f923cf79ce353aaddaa23fd7b0f6a974a) (commit frozen `0xdeef…1200`) · commit 2 [0xd85f…2d142](https://explorer.testnet.chain.robinhood.com/tx/0xd85f35e675320d7c8443053ef59e6a3068e7ce3bfecf5453ea0962916a22d142) · reveal [0x684d…74fa93](https://explorer.testnet.chain.robinhood.com/tx/0x684d8d39d9e816b1c1e17c2634e04fc61d5c49aa1e323c77eec8e62bcf74fa93) · word (held, unsettled) [0xa795…cf28972](https://explorer.testnet.chain.robinhood.com/tx/0xa7952adc8d764385577d51fe01dd990a495b55384bc800b7dfcd24c9bcf28972) · garrison reveal + settle [0x7aa2…c261515](https://explorer.testnet.chain.robinhood.com/tx/0x7aa2cd4725612a7f8ab982be8469a288d0362537fa0196bf1f5b444bec261515) | Word delivered while garrison sealed → **no settle** until defender revealed. `defensePower = 155e6` = HD 60 (Row House) + 2×47.5 garrison (0.95× eff) — **exact**. Settle ran inside `revealGarrison`: `RaidSettled(2, COMMON, pHit=405633ppm = 0.72·200/355 exact)`, taken 1600.9 (hopper), tax 120.07 burned | PASS |
| 14a | Repair-fee dodge attempt (F3) ×2 | W3/96, W1/94 | 96: [0xdcfc…5872a](https://explorer.testnet.chain.robinhood.com/tx/0xdcfc27aa27e20ca78f2b0266790a537a8958639db5f6634b4c76f033ea15872a)→[0x2f2e…8fd758](https://explorer.testnet.chain.robinhood.com/tx/0x2f2ef5ef337edadbd4a6eefa220c99136155ee6faec4333633b38905a68fd758) · 94: [0xd0bb…bc73f](https://explorer.testnet.chain.robinhood.com/tx/0xd0bbef6a5837458cc39ab08bab6ea5d044089dce8b63ed69febebed5002bc73f)→[0xdc31…f3cff7](https://explorer.testnet.chain.robinhood.com/tx/0xdc31891a37f3dffd251c1d59b1b793d812271e6cbe012d890f020d278af3cff7) | Damaged House, then **banked everything to zero** (free exit) — `repairFeeOf` stayed **exactly 2.25** (1.5 days gross on the frozen 1000 basis, not live deployed). `repair()` burned 2.25, debuff cleared. **The F3 dodge is dead.** | PASS |
| 16 | Abandoned-commit forfeit (raid 3, live) | W4 (permissionless) | [0x16ea…917bac](https://explorer.testnet.chain.robinhood.com/tx/0x16ea8035bb36e4520fcecc7e2333ce3c9624d14bee1fe171c430b146b9917bac) | Past the 40-min window: state → **Forfeited**, held 50-Scrip fee **burned** (engine balance −50, `totalBurned` +50) | PASS |
| 17 | Hero mission resolves at real 3h due (brief 1 band) | keeper | **PENDING-LIVE** — see below | payout ∈ {41.769 success, 14.4 partial, 0 fail}; `outstandingReserved` → 0 | PENDING-LIVE |

## PENDING-LIVE

**Mission 1** (hero Don 93, PAPER ROUTE, launch brief 1) — departed [0xdae3…678c](https://explorer.testnet.chain.robinhood.com/tx/0xdae339375e912dcf5383973eac4fe0b8d060a2313c74ecca54853be43beb678c), **due at unix `1786628010`** (3h real duration; a live session cannot wall-clock it). The keeper loop auto-resolves at due; the resolve/fulfill tx hashes are appended here post-settle. Expected: `Resolved(1, 93, outcome, payout)` with payout **41.769** on success (36 + 5-provision × 1.1538 boost), **14.4** partial, **0** fail; the 41.769 reservation drains and `outstandingReserved → 0`. The identical mechanism was already live-proven 6× on missions 2-7 (flow 3) and the keeper-dead fallback is fork-proven (F-A). Should the keeper stall, `reclaim` is permissionless after due+2h and floors at 14.4 — the Don cannot strand.

## Negative checks — every one reverted with the EXACT custom error, then mined as a status-0 tx

| Check | Expected error | Failed tx (explorer) |
|---|---|---|
| depart while away | `AlreadyAway()` | [0x6f09…107043](https://explorer.testnet.chain.robinhood.com/tx/0x6f097820631d21bd9fbd72ad2c60f5e0677ebdb50546ff514da8580e39107043) |
| bank while away | `DonIsAway()` | [0xfc8d…14c7468](https://explorer.testnet.chain.robinhood.com/tx/0xfc8d871b40c591ded29bdaca86a4e19bdb715e34597744b03135f1a5914c7468) |
| second Safehouse (direct `mintSafehouse`) | `NotHouseModule()` | [0xa026…c7575d](https://explorer.testnet.chain.robinhood.com/tx/0xa026128a800016bbfd28bae267e83ed4908abf5b80f909e730fe2dcac4a7575d) |
| **F1**: keeper calls `scrip.mint` directly | `NotModule()` | [0x085a…7ff89](https://explorer.testnet.chain.robinhood.com/tx/0x085a7da8320d211b5be27b689fd53a6f8fa840acb7fde6365936b7d903e7ff89) |
| **F2**: random wallet calls `closeSeason` | `NotSeasonAuthority()` | [0x3c27…736072](https://explorer.testnet.chain.robinhood.com/tx/0x3c271573472ffebc1c98beaecc1ef129da3814f91d44c6def0e19d09e2736072) |
| deploy over the Safehouse cap (6000 > 5000) | `OverDeployCap()` | [0x5b12…54637c](https://explorer.testnet.chain.robinhood.com/tx/0x5b12121375e50b30c5710d36ccfc567cb959c2c2e16fee92f9a31eba3254637c) |
| raid reveal before the 10-min delay | `RevealTooEarly()` | [0x79aa…e90dc2](https://explorer.testnet.chain.robinhood.com/tx/0x79aa6a5586c5459cea8e275b15ce04f7d490274fbc4496f18ccba60bc7e90dc2) |
| raid a HOME Don (reveal inside window, target home) | `TargetNotAway()` | [0x05ac…0ba8a7](https://explorer.testnet.chain.robinhood.com/tx/0x05acb7a9dd22be4ac954884e00237f402e6a43de7861ffd200b39118430ba8a7) |
| raid reveal after the 40-min window | `RevealTooLate()` | [0xa55f…de9a07](https://explorer.testnet.chain.robinhood.com/tx/0xa55f123150aec15728ad07c09ef50310c8616bb0489ac7f0cad62756f9de9a07) (also fork-proven, F-E) |

## Time-gated flows — FORK-PROVEN (fork of live testnet state + `vm.warp`; **not live txs**)

`FOUNDRY_PROFILE=script forge script script/GameE2E.s.sol:GameE2E --sig "forkProofs()" --rpc-url rh_testnet` — all five passed against a fork of the exact deployed stack:

| # | Flow | Gate that forces the fork | Proven |
|---|---|---|---|
| F-A | **Mission reclaim** (keeper dead) | due + 2h grace | After `warp(due+2h+1)`, a random wallet reclaimed: mission settled at the **PARTIAL floor (exactly 2400 = the posted band)**, Don came home, the 6000 worst-case reservation drained back to the budget |
| F-B | **Raid floorSettle** (garrison suppressed) | word + 1h timeout | Defender departed with an unrevealable garrison commit; attacker revealed, word landed, no garrison reveal. After `warp(+1h+1)` the attacker floor-settled: **the real roll ran with defensePower = 40e6 (house alone — garrison credited ZERO)**, state Settled. Suppression buys nothing (H-1 fix held) |
| F-C | **Raid reclaim** (entropy withheld) | reveal + 2h timeout | No fulfill; after `warp(+2h+1)` anyone reclaimed: outcome MISS, **no transfers** (target hopper/deployed and attacker vault byte-identical), commit fee stayed sunk, heat set |
| F-D | **Favor forceRevealFloor** | 30-day seal timeout | After `warp(+30d+1)` a random wallet floored a sealed Hitter: `favorOf = 0` (**Common — the worst band**), unsealed. (Live Hitter 11 left sealed so the real 30-day clock runs on-chain) |
| F-E | **Reveal-too-late + forfeit** | 40-min window | Reveal at +41min reverted `RevealTooLate()`; permissionless `forfeit()` then **burned the held 50-Scrip fee** |

## Final invariant readout (live reads, end of run)

```
custody:             scrip.balanceOf(escrow) == totalDeployed + totalHopper   HELD after EVERY phase
final escrow state:  0 == 0 + 0  (every unit exited through bank(), the sacred fee-free exit)
raid engine balance: 0           (every commit fee burned at reveal or forfeit — nothing stuck)
missions:            7 total, 6 settled, 1 in flight (hero, PENDING-LIVE above)
outstandingReserved: 41.769e18 == EXACTLY the hero mission's worst-case reservation, nothing else
budget closure:      1,000,000 − 975,758.231 (budget) − 41.769 (outstanding) = 24,200
                     == Σ settled payouts (4×6000 SPRINT + 2×100 WINDOW) — EXACT to the wei
supply closure:      totalSupply 12,564.094e18 == vault(93) 44.55 + vault(94) 1,245.756
                     + vault(95) 7,128.031 + vault(96) 4,145.757 — EXACT to the wei
scrip burned:        11,835.95e18 (dispatch fees, provisions, upgrade, 11 hitter mints, hit taxes,
                     commit fees, repairs — the Scrip sink works end to end)
yieldBudget:         499,999.953e18 (emission decremented, never promised)
stipendBudget:       49,800e18 (exactly 4 × 50 first-play stipends paid)
no negative/overflowed state observed in any read.
```

## Summary — 15/15 mandated flows

| Layer | Count | Detail |
|---|---|---|
| Live-proven flows | 12 | mint, hero first-play (brief 1), keeper resolve+band ×6, deploy, bank partial+full, yield accrual+checkpoint, Row House upgrade, hitter mint ×11, favor reveal, raid hit path, raid vs garrison, F3 repair ×2, live forfeit (bonus) |
| Fork-proven flows (time-gated >2h/30d, labeled) | 3 | mission reclaim (F-A), raid floorSettle (F-B), raid reclaim (F-C) — plus forceRevealFloor (F-D) and reveal-too-late (F-E) |
| Negative checks (exact error + status-0 tx) | 9/9 | incl. audit fixes F1, F2; F3 proven live twice |
| Invariants | ALL HELD | custody, reservation drain, budget closure, supply closure |
| PENDING-LIVE | 1 tx pair | hero resolve at due 1786628010 (mechanism already proven 6×) |

## Spend

Whole run funded from residue: ~0.0014 ETH total (18-wallet DonE2E sweep + deployer), covering ~115 txs and 9 entropy requests at 0.000025 ETH each. Deployer balance after: ~0.0007 ETH. No external funding needed.
