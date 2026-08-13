# D.O.N. Game Guide: Welcome to Solvency

**D.O.N. is the Developing On-chain Nation:** a city called Solvency, 8,888 founding families called Dons,
and a game where the jobs are timed, the odds are published, and nothing bleeds but a balance sheet.

> **This is the Skirmish: Season Zero, live on the test network.** Everything this season is played in
> Scrip, the city's season money, on testnet funds with no real value. It is the proving season: same
> rules, same odds, zero real stakes. Real-asset seasons come later, one audited step at a time.
> Every number in this guide is the number on the chain. Check us. And where a room is still being
> built, we say so with a stamp: anything marked **· ARRIVES WITH A LATER POSTING ·** is roadmap,
> written and priced but not on this season's chain. Everything unstamped is live now, and checkable.

---

## The 60-second start

1. **Connect.** Browser wallet, testnet, the site will offer to switch networks for you. Grab testnet funds
   from the Faucet.
2. **Get a Don.** Whitelist claim, a reroll, or build your own in the builder. Your Don is your character,
   your seat, and your wallet in one.
3. **Claim your Safehouse.** Free with every Don. It is small. Nobody sneers at a Safehouse.
4. **Deploy a little Scrip to the House.** Vault money earns nothing and can never be touched. House money
   earns daily and can be robbed while you are out. That choice is the whole game. Start small.
5. **Take your first job.** Open the board, pick PAPER ROUTE, the 3-hour escort run. Reading the folder is
   reading the odds: the dossier is the risk disclosure.
6. **Dispatching prints your first line on the Tape.** This season the Keeper also attests your Starting
   Kit class on the record at first dispatch; the kit's mint into the wallet, and the Don's sealed Edge
   envelope, carry the stamp: · ARRIVES WITH A LATER POSTING · (see Your Don is the loadout).
7. **Come back when the window closes.** Your pay lands in the House hopper.
8. **Bank it.** Hopper to Vault, free, forever. Banked money is sacred. Bank before you brag.

That is the loop: deploy, work, come home, bank. Everything else in this guide is how to do it with style.

---

## The world in one page

Solvency is a port city built on one piece of civil engineering and one piece of accounting, which here
are the same discipline. The city stands on **the Floor**: the great reserve vault sunk beneath the
streets at the Founding, one share under every family's deed. Surveyors confirm its single physical
property every year: it only rises. A city whose foundation keeps coming up under the buildings can never
be finished, which is why the Nation is named what it is. Developing. On-chain. Nation.

8,888 families signed the founding instrument, **the Ledger**. Not a constitution. Constitutions are
promises. The Ledger is arithmetic. Three clauses, recited at every deed transfer because they are still
literally true:

1. **What's in your Vault is yours forever, and earns nothing.**
2. **What you put to work can be taken, but only what you put to work.**
3. **The Floor only rises.**

Then somebody hung **the Bell** over the Exchange, rang it, and split the first pot across every seated
family. It has rung ever since, whenever the pot fills, which the city considers the only honest way to
run a bell.

Everything prints on **the Tape**: every job dispatched, every bell rung, every house hit, one line each,
verifiable by anyone who cares to pull the record. Solvency has no secrets, only **fog**: things that
have not printed yet. The city's entire criminal economy lives in that gap, in the hours between a Don
walking out his front door and the Tape saying where he went.

**The Keeper** resolves the jobs and rings the Bell. The Keeper can be slow. The Keeper cannot steal.
The city checked. Twice.

**Why your Don is a portfolio:** your Don carries his own wallet. His Vault balance, his House deed, his
kit, his crew's loot: all of it lives inside the token. Sell the Don and the estate goes with him. A Don
listing is a portfolio listing. The face is permanent; the books travel.

---

## Where money lives

The core decision of the game, drawn as a floor plan:

```
  THE VAULT ──────────── THE HOUSE ─────────────── THE HOPPER
  banked, yours forever   deployed working capital   earnings waiting to be banked
  earns: nothing, ever    earns: 0.15% per day       earns: nothing
  robbable: never         robbable: the big score,   robbable: yes, the common
                          only while your Don        hit takes exactly this,
                          is away on a job           only while your Don is away
        ▲                        │                          │
        └────── bank() ── free, forever, gas only ──────────┘
```

- **Exposure is always a choice.** Money sits in the Vault by default. Deploying it is an explicit act.
  Taking a job is a second explicit act, and it is the one that opens the robbery window.
- **Your House can only be hit while your Don is away.** Home means untouchable, and home means you can
  bank the hopper instantly. The whole defensive art is: bank often, garrison well, choose your windows.
- **Banking is free. Forever.** No fee, no delay, no future knob. Every exit in this game is free: bank,
  claim, withdraw, unstake. The city charges you to take risks and to buy services. It never charges you
  to stop.

The lazy man's summary: the Vault is a mattress, the House is a business, the hopper is the till. Robbers
go for the till. Empty it nightly.

---

## Missions: the job board

A job arrives as a **dossier**: a case file over the map, your Don's portrait clipped to the corner, the
brief typed inside. One screen, one decision, one transaction. The folder shows the odds because the folder
is the odds: the dossier is the on-chain table wearing a trench coat, and the dispatcher never lies.

**How a job works:** pick a brief, choose your provisions, dispatch. Your Don departs, locked and visibly
away, which the whole street can read on the Tape. At the window's end the Keeper rolls the outcome against
the published ladder and pays the House hopper. Three outcomes on every folder: **clean** (full pay),
**sideways** (the job went sideways: the partial pay printed on the folder), **bust** (nothing,
provisions gone).

If the Keeper ever stalls, anyone can settle a stuck job two hours past its window, and it settles at the
sideways floor, never at zero. The valve is never better than a real roll, so it cannot be gamed, only
un-stuck.

### The Skirmish board: the four briefs

| Codename | The job | Window | Clean | Sideways | Bust | Clean pays | Sideways pays | Door fee |
|---|---|---|---:|---:|---:|---:|---:|---:|
| **PAPER ROUTE** | escort the armored T-bill run down Ledger Row (SGOV) | 3h | 78% | 15% | 7% | 36 Scrip | 14.4 Scrip | 0.45 Scrip |
| **GLASS HARVEST · RUSH** | walk finished wafers out of the fab through Dock 4, one shift (NVDA) | 5h | 70% | 18% | 12% | 75 Scrip | 30 Scrip | 0.87 Scrip |
| **PROOF OF WORK** | cut the Rig's output over to your wallet for one power cycle (CLSK) | 12h | 60% | 22% | 18% | 236 Scrip | 94.4 Scrip | 2.44 Scrip |
| **ABSOLUTE ZERO** | lift the prototype from the lab that isn't in the Registry (IONQ/RGTI) | 24h | 12% | 23% | 65% | **2,775 Scrip** | 222 Scrip | 5.76 Scrip |

Read the table honestly and it tells you three things. Longer jobs pay more per hour: that is the exposure
premium, the city paying you for time spent robbable. Longer jobs fail more: risk and reward rise together
because time exposed is the unit of both. And ABSOLUTE ZERO is not a job, it is a lottery with a
dossier: 65% of the time you get nothing and your provisions are gone. The folder says so. The folder
always says so.

Every brief is pegged to a real ticker because in later seasons the take will BE the ticker: the chip-fab
job pays the chip company. This season the take is Scrip, marked to the peg. The full quest log, with
every mission's token contract and price wire printed for verification, is the Mission Compendium below.

**Board texture · ARRIVES WITH A LATER POSTING ·** The living board: briefs posting in windows and
expiring, odds jittering inside published bands, no two identical folders at once, codenames retiring
for a season once used. This season the four folders above stand posted and steady while the loop proves
out. The jitter comes later; the ladders are already law.

### Provisioning: pressing your own bet

You can provision a job with Scrip, burned at dispatch. Burned, not staked, and hear this part the way
the contract says it: **provisions never move your odds.** The dispatcher's ladder is the ladder whether
you walk in empty-handed or loaded to the cap. What a provision buys is a fatter take on the clean
outcome, and only the clean outcome: the payout grows by your provision times the folder's posted beta,
IF the job lands. Go sideways or bust and the provision is simply gone. You are pressing the bet: same
door, same odds, bigger swing. And the city's cut applies: across the whole city, every 100 Scrip
provisioned returns about 90 in expectation. Provision because you like the job, not because it beats
the math. It does not. Nothing here does; see The house rules.

| Brief | Provision cap | Posted beta | A full carry adds to the clean take |
|---|---:|---:|---|
| PAPER ROUTE | 15 Scrip | 1.1538x | ~17.3 Scrip, IF the 78% lands |
| GLASS HARVEST · RUSH | 30 Scrip | 1.2857x | ~38.6 Scrip, IF the 70% lands |
| PROOF OF WORK | 80 Scrip | 1.5x | 120 Scrip, IF the 60% lands |
| ABSOLUTE ZERO | 200 Scrip | 7.5x | 1,500 Scrip on the jackpot, IF the 12% hits |

Run the arithmetic on that last row and understand what you are buying: burn 200, and 65% of the time it
was a bonfire. Variance is the product. The odds were never for sale.

### The Moonshot and the Big Pot · ARRIVES WITH A LATER POSTING ·

When this room opens, ABSOLUTE ZERO will sometimes post a variant folder: **the Moonshot**. Same window,
same expected pay, entirely different shape:

| | Long Con (standard) | Moonshot variant |
|---|---:|---:|
| Jackpot odds | 12% | **5%** |
| Jackpot | 2,775 Scrip | **5,614 Scrip** |
| Consolation (23%) | 222 Scrip | 449 Scrip |
| Bust | 65% | 72% |
| Door fee | 5.76 Scrip | **20 Scrip** |

The Moonshot's fat door fee is not a rake: 80% of the premium goes into **the Big Pot**, a citywide
progressive pot. Every Moonshot resolution has an independent **0.4%** chance to win the entire pot. Some
days it pays in hours. Some weeks it builds into a number the whole city watches. When it goes, the Tape
prints a name.

### Reputation: how leveling works · ARRIVES WITH A LATER POSTING ·

Work raises your standing. Standing raises your wage, never your odds. This season the ladder is not yet
on the chain: every Don works at a flat 1.00x wage and every posted folder is open to every Don. Here is
the standing system as it will post:

| Standing | Unlocks | Wage multiplier |
|---|---|---:|
| Level 1 | Errand tier (3h) | 1.00x |
| Level 3 | Job tier (5h) | 1.10x |
| Level 6 | Score tier (12h) | 1.25x |
| Level 10 | Long Con tier (24h) | 1.45x |
| Level 21 | (cap) | **2.00x, the ceiling** |

Odds never scale with standing. A level-21 Don busts 7% of escort runs like everybody else; his envelope is
just thicker. One published ladder per tier, same for every Don in the city, auditable at a glance. One
rule that is already the law this season: **one active job per Don at a time.** Even legends work single
file.

---

## The Mission Compendium

The quest log, in full. Every brief in Solvency is **pegged to a real tokenized stock with a live price
wire**, and no two payout curves are alike because no two charts are alike: the take's personality is not
a design decision, it is the asset's own volatility, read off the wire. A traditional game can theme a
heist on a chip fab. Only here can the loot BE the chip company, because the company's token actually
exists on-chain, and we print the address so you can check.

> **Read this before the flex.** The contracts below are the pegged assets' verified main-network
> contracts. Every printed token passed a four-check proof read directly off the chain (official
> registry beacon, 18 decimals, live multiplier, not paused). Impostor tokens with identical display
> names exist out there, which is why we never list from an explorer label, and why a ticker whose
> token has not yet cleared the proof is marked **pending the proof** instead of guessed at.
> And the honest line, in bold so nobody misses it: **the season you are playing settles in Scrip,
> marked to these wires on test-network stand-ins. The seasons that settle in the tokens themselves
> are the roadmap.** Every mission already knows its token. That is the flex. It is not a promise of
> tomorrow morning.

### How the take pays

1. **Every brief carries a peg.** The folder names its ticker, and the mission's payout curve inherits
   that asset's chart: T-bill briefs drip, chip briefs swing, quantum briefs are lotteries.
2. **The take is marked to the wire.** The pegged token's price feed marks the value of what you took.
   This season, that mark pays out in Scrip.
3. **In the real-settlement seasons,** the claim edge does the rest: at claim, the converter buys the
   take at the wire price and the tokens land in your Don's Vault. Held, not owed: the loot is acquired
   when the job posts, so the payout exists before you earn it. Won stock banks to a claim box of its
   own, a ledger no raid can reach: what you win is claimable and safe the instant the job resolves,
   never sitting in a hopper for someone to knock over.
4. **Fail-open, always.** A stale wire never blocks a payout; it settles to base instead. Slow is
   possible. Stuck is not.

### The master ledger: every brief, every token, every wire

The first four rows are this season's live board. Everything below them is the runway and the drawer,
posted here so the pegs are on the record before the folders are.

| Brief | Window | The take | Token contract | Price wire | The chart's personality |
|---|---:|---|---|---|---|
| PAPER ROUTE | 3h | SGOV | pending the proof | on the wire | the safe drip |
| GLASS HARVEST · RUSH | 5h | NVDA | [`0xd060…9EEC`](https://robinhoodchain.blockscout.com/address/0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC) | [`0x379E…9F15`](https://robinhoodchain.blockscout.com/address/0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15) | the flagship, volatile |
| PROOF OF WORK | 12h | CLSK | pending the proof | on the wire | feast or famine |
| ABSOLUTE ZERO | 24h | IONQ / RGTI | pending the proof | on the wire | the lottery |
| IDLE CYCLES | 5h | ORCL / DELL | pending the proof | on the wire | the steady meter |
| GLASS HARVEST · SPREAD | 12h | NVDA / TSM / AMD | AMD [`0x8692…3fdC`](https://robinhoodchain.blockscout.com/address/0x86923f96303D656E4aa86D9d42D1e57ad2023fdC); TSM pending | AMD [`0x943A…2C72`](https://robinhoodchain.blockscout.com/address/0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72) | the basket takes the edge off |
| HOT WAFER · RUSH | 5h | NVDA | [`0xd060…9EEC`](https://robinhoodchain.blockscout.com/address/0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC) | [`0x379E…9F15`](https://robinhoodchain.blockscout.com/address/0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15) | the flagship, in and out |
| STATIC FIRE | 12h | RKLB | pending the proof | on the wire | long odds |
| GRAVITY TAX · LONG | 24h | SPCX | [`0x4a0E…5eEa`](https://robinhoodchain.blockscout.com/address/0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa) | [`0xB265…Bffb`](https://robinhoodchain.blockscout.com/address/0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb) | long odds, bigger board |
| HOT WALLET | 5h | COIN | pending the proof | on the wire | hot in every sense |
| SHORT FUSE | 5h | GME | [`0x1b0E…153E`](https://robinhoodchain.blockscout.com/address/0x1b0E319c6A659F002271B69dB8A7df2F911c153E) | [`0x27C7…5B67`](https://robinhoodchain.blockscout.com/address/0x27C71df6A64fB476468EdF256CF72c038baB5B67) | a heart monitor |
| SECOND PRICE | 5h | META / GOOGL | [`0xc0D6…2f35`](https://robinhoodchain.blockscout.com/address/0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35) / [`0x2e08…4FE3`](https://robinhoodchain.blockscout.com/address/0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3) | [`0x7C38…71b1`](https://robinhoodchain.blockscout.com/address/0x7C38C00C30BEe9378381E7B6135d7283356D71b1) / [`0xF6f3…638b`](https://robinhoodchain.blockscout.com/address/0xF6f373a037c30F0e5010d854385cA89185AE638b) | the respectable middle |
| BILL OF LADING | 12h | BABA / EWY | pending the proof | on the wire | weather from abroad |
| DOUBLE EXPOSURE | 12h | MSTR | pending the proof | on the wire | levered, both directions |
| NO SERIALS | 5h | MU / SNDK | pending the proof | on the wire | the cycle |
| THE FULL BASKET | 12h | SPY | [`0x117c…4C0C`](https://robinhoodchain.blockscout.com/address/0x117cc2133c37B721F49dE2A7a74833232B3B4C0C) | [`0x3197…9f6A`](https://robinhoodchain.blockscout.com/address/0x319724394D3A0e3669269846abE664Cd621f9f6A) | professionally average |

Fifteen briefs, one rule: the peg is real, all different, and dynamic. The armored run pays paper, the
fab pays silicon, the cold rooms pay a coin flip on the future, and each one's swing is its ticker's
swing. The Tape prints the mark; the wire sets it; you can audit both.

### Live this season: the Skirmish four

---

#### ▪ PAPER ROUTE
**The Treasury Run · Ledger Row · 3h window · Errand tier · stamp: LOW**

*Ride escort on the armored run from the Long Window to the Registry.*

| The line | |
|---|---|
| Odds | 78% clean · 15% sideways · 7% bust |
| Pays | 36 Scrip clean · 14.4 sideways · 0.45 door fee |
| Carry | provision up to 15 Scrip; a full carry adds ~17.3 to the clean take |
| Pegged | **SGOV**, 0-3 month T-bills: the safe drip |
| Token | pending the proof; prints here the day it clears |
| Price wire | live on the city wire |

THE WORD: Nobody ambushes a T-bill run; the paper yields four percent and the paperwork yields none.
There's no shame in the Paper Route. There's barely any interest, either.

---

#### ▪ GLASS HARVEST · RUSH
**The Chip-Fab Job, rush cut · The Foundry · 5h window · Job tier · stamp: STANDARD**

*Walk one pallet of finished wafers out of the fab through Dock 4, in and out inside a single shift.*

| The line | |
|---|---|
| Odds | 70% clean · 18% sideways · 12% bust |
| Pays | 75 Scrip clean · 30 sideways · 0.87 door fee |
| Carry | provision up to 30 Scrip; a full carry adds ~38.6 to the clean take |
| Pegged | **NVDA**: the flagship, volatile |
| Token | [`0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC`](https://robinhoodchain.blockscout.com/address/0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC) · verified |
| Price wire | [`0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15`](https://robinhoodchain.blockscout.com/address/0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15) |

THE WORD: The wafers manifest as "glass, industrial," which is technically true and legally hilarious.
You'll be lint-free, badge-forward, and carrying the most valuable objects per gram in the Nation. Try
to look bored. You have five hours, not twelve. The rush is the mercy.

---

#### ▪ PROOF OF WORK
**The Rig Job · The Racks · 12h window · Score tier · stamp: STEEP**

*Cut the Rig's output over to your wallet for one full power cycle.*

| The line | |
|---|---|
| Odds | 60% clean · 22% sideways · 18% bust |
| Pays | 236 Scrip clean · 94.4 sideways · 2.44 door fee |
| Carry | provision up to 80 Scrip; a full carry adds 120 to the clean take |
| Pegged | **CLSK**: feast or famine |
| Token | pending the proof; prints here the day it clears |
| Price wire | live on the city wire |

THE WORD: The name of the job is the whole philosophy of this town. You did the work. Here's the proof.

---

#### ▪ ABSOLUTE ZERO
**The Quantum Grab · The Kelvin Quarter · 24h window · Long Con tier · stamp: UNINSURABLE**

*Lift the prototype from Annex K while the refrigerators are cycling.*

| The line | |
|---|---|
| Odds | 12% jackpot · 23% consolation · 65% bust |
| Pays | **2,775 Scrip** jackpot · 222 consolation · 5.76 door fee |
| Carry | provision up to 200 Scrip; a full carry adds 1,500 to the jackpot, and only the jackpot |
| Pegged | **IONQ or RGTI**, posted per window |
| Token | pending the proof |
| Price wire | live on the city wire |

THE WORD: A full day exposed, long odds, and a number on the other side with more zeros than sense.
That's not a warning. That's the pitch.

---

### The runway: posting soon

Eleven more folders, written, pegged, and waiting their season. Odds post on the tier ladders above,
jittered inside published bands per window.

#### ▪ HOT WAFER · RUSH
**The Chip-Fab Job, rush variant · The Foundry · 5h · stamp: STEEP** · pegged **NVDA**
([token](https://robinhoodchain.blockscout.com/address/0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC) verified).
One pallet, one dock, one shift. THE WORD: You're not stealing chips. You're stealing a rounding error.
Move like one.

#### ▪ STATIC FIRE
**The Rocket Heist · The Launch Yards · 12h · stamp: STEEP** · pegged **RKLB** (pending the proof).
Take the payload out of the Integration Hall between mate and rollout. THE WORD: The Scrub Bar opens on
delays. If you're drinking there, you're winning.

#### ▪ GRAVITY TAX · LONG
**The Rocket Heist, long con · The Launch Yards · 24h · stamp: STEEP** · pegged **SPCX**
([token](https://robinhoodchain.blockscout.com/address/0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa) verified ·
[wire](https://robinhoodchain.blockscout.com/address/0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb)).
The full campaign: in with the pad crew, out with the flight hardware a day later. THE WORD: Everything
that flies pays the gravity tax; you're just collecting it early.

#### ▪ HOT WALLET
**The Exchange Raid · The Exchange District · 5h · stamp: STEEP** · pegged **COIN** (pending the proof).
Crack the wallet the Exchange officially does not keep on premises. THE WORD: Walk, don't run. Running
prints on the Tape.

#### ▪ SHORT FUSE
**The Exchange Raid, float squeeze · The Exchange District · 5h · stamp: STEEP** · pegged **GME**
([token](https://robinhoodchain.blockscout.com/address/0x1b0E319c6A659F002271B69dB8A7df2F911c153E) verified ·
[wire](https://robinhoodchain.blockscout.com/address/0x27C71df6A64fB476468EdF256CF72c038baB5B67)).
Corner the borrowable float in the Pit and make the shorts come to you. THE WORD: The odds table on this
one reads like a heart monitor. We printed it anyway. We print everything.

#### ▪ SECOND PRICE
**The Ad-Auction Sting · The Exchange District annex · 5h · stamp: STANDARD** · pegged **META or GOOGL**
([META](https://robinhoodchain.blockscout.com/address/0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35) ·
[GOOGL](https://robinhoodchain.blockscout.com/address/0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3), both verified).
Seat a ringer in the auction and win every lot at one bid over the house's own floor. THE WORD: It's the
politest theft on the board. Dress accordingly.

#### ▪ BILL OF LADING
**The Silk-Road Freight Job · The Freeport · 12h · stamp: STANDARD** · pegged **BABA**, SPREAD 60/40
BABA/EWY (pending the proof). Re-paper one container between the Stacks and the Customs House. THE WORD:
Twelve hours because paperwork cannot be rushed. That's not our rule. It's the clerk's.

#### ▪ DOUBLE EXPOSURE
**The Leverage Play · The Exchange District · 12h · stamp: STEEP** · pegged **MSTR** (pending the proof).
Rob the corporate treasury that borrowed money to buy digital gold, and inherit the leverage with the
loot. THE WORD: Double exposure: it's on the folder because we're required to say it twice. Consider it
said.

#### ▪ NO SERIALS
**The Warehouse Heist · The Foundry, warehouse row · 5h · stamp: STANDARD** · pegged **MU**, SPREAD 50/50
MU/SNDK (pending the proof). Take the flash-memory pallets that were never serialized off the overnight
dock. THE WORD: Either way it stacks flat and sells everywhere. The classics survive for a reason.

#### ▪ IDLE CYCLES
**The Data-Center Skim · The Racks · 5h · stamp: STANDARD** · pegged **ORCL / DELL** per window (pending
the proof); CRWV/NBIS on the SPREAD posting. Siphon unmetered compute off Hall C between the midnight
batch jobs. THE WORD: Whatever runs in the gap ran for free, and whatever ran for free ran for you. The
skim's been run so many times the night crew waves. Wave back. It keeps the premium down.

#### ▪ THE FULL BASKET
**The Index Job · The Exchange District · 12h · stamp: STANDARD** · pegged **SPY**
([token](https://robinhoodchain.blockscout.com/address/0x117cc2133c37B721F49dE2A7a74833232B3B4C0C) verified ·
[wire](https://robinhoodchain.blockscout.com/address/0x319724394D3A0e3669269846abE664Cd621f9f6A)).
Hit the custodian's settlement cage on rebalance night and take one of everything. THE WORD: You will not
get rich on this job. You will get average, professionally, at scale.

### In the drawer

Briefs written but not yet on the runway, plus tokens already verified and waiting for a folder. The
board is provably far enough out for seasons of new work:

| Brief in the drawer | The take | Status |
|---|---|---|
| THE EV CHOP-SHOP | TSLA | token [`0x322F…3b2d`](https://robinhoodchain.blockscout.com/address/0x322F0929c4625eD5bAd873c95208D54E1c003b2d) verified · wire [`0x4A11…7C38`](https://robinhoodchain.blockscout.com/address/0x4A1166a659A55625345e9515b32adECea5547C38) |
| THE HANDSET HIJACK | AAPL | token [`0xaF3D…93f9`](https://robinhoodchain.blockscout.com/address/0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9) verified · wire [`0x6B22…2cD0`](https://robinhoodchain.blockscout.com/address/0x6B22A786bAa607d76728168703a39Ea9C99f2cD0) |
| THE CLOUD CONTRACT | MSFT / AMZN | tokens [`0xe932…2e74`](https://robinhoodchain.blockscout.com/address/0xe93237C50D904957Cf27E7B1133b510C669c2e74) / [`0x12f1…bF54`](https://robinhoodchain.blockscout.com/address/0x12f190a9F9d7D37a250758b26824B97CE941bF54) verified |
| THE FAB-TOOL EXTORTION | ASML | pending the proof |
| THE STABLECOIN JOB | CRCL | pending the proof |
| (no folder yet) | PLTR · QQQ · USAR | tokens [`0x894E…4F2A`](https://robinhoodchain.blockscout.com/address/0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A) / [`0xD5f3…de68`](https://robinhoodchain.blockscout.com/address/0xD5f3879160bc7c32ebb4dC785F8a4F505888de68) / [`0xd917…86a6`](https://robinhoodchain.blockscout.com/address/0xd917B029C761D264c6A312BBbcDA868658eF86a6) verified; USAR is the Dig's whole economy, draw your own conclusions |

---

## Robberies: the other family business

Every family in Solvency is in two businesses. This is the second one.

### How you rob someone

1. **Find a window.** Depart lines print on the Tape. A Don who took a 12-hour job left a House standing
   open for 12 hours, and everyone knows it.
2. **File the job, sealed.** Your Hitter commits to a target without naming it in public: a sealed filing,
   plus **50 Scrip, sunk win or lose**. Walk away without kicking the door and the 50 burns at the city
   incinerator. Cowardice is a fee like everything else.
3. **Kick the door.** Reveal inside the 10-to-40-minute window. The defense that counts is the roster
   the defender signed at depart: the House cannot change shape mid-window, so nobody conjures guards
   at the last second. You are attacking blind: garrison composition is fog until you are through the door.
4. **The roll.** One published ladder, two stages: did you get in, and what did you find.

### What a hit takes

If you get in, a second roll decides what kind of night it was:

| Outcome | Odds | What moves | What it does NOT touch |
|---|---:|---|---|
| **The common hit** ("they cracked the back office") | **92%** | the House's **hopper**: every unbanked Scrip in the till, plus the House earns **-40% until repaired** | deployed principal, the Vault |
| **The big score** ("they found the safe") | **8%** | **15% to 30% of DEPLOYED holdings** (rolled: 15% + 15% x u squared, average 20%). One big score in 20 crits for 1.5x, hard-capped at 30% | the Vault, ever |

- **The 7.5% tax.** The city takes 7.5% of every transferred score. The Floor eats with the winners.
- **The safe gets moved.** One big score per House per **48 hours**, maximum, no matter who is knocking.
  **· ARRIVES WITH A LATER POSTING ·** the real-asset seasons keep this same 48-hour lockout, but the
  bite becomes skill-scaled: a marginal win stays in this same modest band, while a dominant crew that
  scouted a wide-open House can reach a rare, earned ceiling of 65% of DEPLOYED. The Vault is never
  touched, at any number, and the Fixer's Book sells a cushion for the rest. The road is in
  *Coming to Solvency*.
- **Repairs** cost about 1.5 days of that House's earning rate, pro-rated by damage. A scarred, unrepaired
  House is a public confession on the Tape: dealing with it is a fee, and everyone can see you have not.

### Your odds at the door

Attack strength comes from your Hitter; defense comes from the House and its garrison. The success band
is clamped: never below 5%, never above 70%. There are no sure things in Solvency, in either direction.

**The Skirmish truth first:** levels and gear carry the stamp, · ARRIVES WITH A LATER POSTING ·, so this
season every Hitter swings at base power and the door runs richer than the mature table below. One fresh
Hitter kicking an undefended starter House lands about **40%** right now; a full crew of five pushes the
same door to about **62%**. The 5% / 70% clamps still apply. The table is the worked outlook for a seasoned, kitted Hitter of later seasons, printed so you
can see where the road goes. Illustrative, not this season's roll:

| The door you're kicking | Hit chance |
|---|---:|
| Undefended starter House, Don away | **52%** |
| Undefended upgraded House | 33% |
| Two guards on the door | 26% |
| Full garrison, five guards | 14% |
| Full garrison, upgraded House | 12% |
| Anything, floor / ceiling | 5% / 70% |

Read it plainly: **robbing negligence is a profession; robbing a defended House is a donation.** The math
is built so that every victim is one garrison decision away from making you unprofitable. Their move.

### What you risk when you knock

A failed attempt is not free. On a bust, your Hitter risks being taken: **20%** against a naked house,
up to **43%** against a full crew. Taken means a **48-hour hospital stay**, benched and useless while
the street keeps moving. In later seasons the stakes climb further: a taken Hitter's equipped kit will
transfer to the defender. What you carry on the job, you will have carried on the job. For now, in
Skirmish, the hospital bed is the bill.

### The cooldown curve: patience is a weapon

After any attempt, win or lose, a Hitter needs **20 hours** to work at full odds. You can send him early.
You should not:

| Hours since last attempt | Odds you keep |
|---:|---:|
| 5h | 6% |
| 10h | 25% |
| 15h | 56% |
| 20h | **100%** |

The curve is quadratic, which means spam is self-punishing: two hasty attempts are worth less than one
patient one, always. The math caps a Hitter at about 1.2 real attempts a day, and no bookkeeping is
needed to enforce it. The curve is the law.

**The full cap stack**, for the spreadsheet crowd:

| Rule | Limit |
|---|---|
| Hitter cooldown | 20h to full odds, early attempts on the curve above |
| Same attacker, same target | 1 attempt per 24h |
| Target heat | 8h immunity the moment an attempt is filed against you, from anyone |
| Big-score lockout | 1 per House per 48h (Skirmish); 72h in real-asset seasons |
| Garrison | frozen at depart. The guard roster you sign is the roster for the whole window |
| Mission dispatches | 1 active job per Don at a time |

### Getting back up: the comeback kit · ARRIVES WITH A LATER POSTING ·

Losses in Solvency come with paperwork, and the paperwork comes with help. The desk below is drafted and
priced but not yet open; this season a bad night's remedy is the oldest one: bank, garrison, go again.
Every one of these exists so a bad night converts into a next move instead of a quit:

| It | Cost | When | What it does |
|---|---:|---|---|
| **The Envelope from the Don** | free | you took a big score; 48h to use | one free 3h or 5h dispatch + 50% off your next repair |
| **The Rebuild Bundle** | 1.50 marks | within 72h of any hit, once per hit | full repair + provision pack + a crate, about 40% off list |
| **The Grudge Contract** | 25 Scrip | you got hit; lasts 7 days | +10% raid success **against the family that hit you** |
| **The Marker** | free credit | anytime | a Scrip credit line: limit starts at 50, +5 per completed job (to 300), +100 per fully repaid Marker, hard cap 500. Repaid by a 50% garnish on future job pay. Unpaid Markers lock everything above the Errand tier. No interest this season |

The Marker is a progression lock, never a seizure: the worst case of borrowed Scrip is a closed door, not
a loss. Real credit, borrowing real value against your Don with the Floor as backing, arrives with the
real-asset seasons.

---

## Hitters and the Favor

A Don works jobs. A **crew** does the other thing. Hitters are the Nation's working class of the working
class, and every one is either **on the hunt** or **on the door**, never both. Offense and defense hire
from the same bench, and that choice is the whole profession.

- **One SKU, 9 marks, sealed.** Every Hitter mints with one slot unrevealed.
- **Crew cap: 5.** Slots unlock at posted prices as you build up the House.
- A garrisoned Hitter adds real defense (see the door-odds table) but cannot hunt while he stands there.
  His foregone hunting is the price of your safety. Everything in this city costs its alternative.

### The Favor: the sealed slot

Clipped inside every Hitter's dossier is an unopened envelope from the family. It opens on his first job,
and not before. The odds are published on-chain before a single one is sold:

| The envelope | Odds | Inside |
|---|---:|---|
| **Empty** | **70%** | nothing mechanical. A stamp on the dossier so the moment still prints |
| **A small favor** | **20%** | one minor edge: +2% job success, or -5% hunt cooldown, or +1 provisioning step |
| **A real favor** | **8.5%** | one real edge: +5% job success, or +1 garrison defense point, or -15% repairs |
| **The Don owes you** | **1.5%** | a named, capped signature edge, announced citywide when it opens. 1 in 67 |

The rules that keep it an edge and not a wall:

- **Odds on the button.** The four bands print on the purchase screen itself, and the assignment is
  committed at mint: fixed before anyone, including us, can see or steer it.
- **Transfer opens the envelope.** A sealed Hitter cannot be sold sealed. No secondary market in secrets.
- **Sealed once, ever.** Nothing re-seals, nothing re-rolls the envelope. There is no slot machine here,
  only one envelope per soul.
- **Favors bend odds, never money.** No Favor touches yields, the Bell, or what a robbery can take.
- **The 30-day rule.** An envelope left sealed 30 days can be opened by anyone, and a forced envelope
  always comes up empty. Pay for your own reveal and you keep the full odds ladder.

**· ARRIVES WITH A LATER POSTING ·** Dons will run the same ritual from the other side: the custom
builder sells determinism, and the random path carries its own sealed Edge envelope at the same published
odds. Dons choose their fate; Hitters roll theirs. Same city, two thrills. The Don's envelope is not on
this season's chain yet; when it posts, the odds post first.

---

## Your Don is the loadout

The art was the item system all along. Whatever your Don holds in his portrait, whatever he wears, whatever
stares back from his eyes: it plays. One honest stamp over this whole wing of the guide: the item and
trait mechanics below carry the mark, **· ARRIVES WITH A LATER POSTING ·**. This season the Keeper attests
your kit class on the record at first dispatch, so your place in line is provable now; the mints and the
combat effects post later, at these published shapes.

### The Starting Kit · ARRIVES WITH A LATER POSTING ·

At first dispatch, alongside the Favor, your Don takes the item painted in his hand **off the canvas and
into his wallet**: a real token, minted once, ever. (This season: the kit class prints on the record at
first dispatch by Keeper attestation; the token itself mints with a later posting.) Rarer paint mints a
rarer item; the portrait's own rarity table is the loot table, publicly verifiable from the art. One kit per Don for all time. Rerolling
your art before first dispatch re-aims the future kit; rerolling after changes the wardrobe, never the
inventory. And if your Don holds nothing? **The Empty Hand** mints instead: the badge for a short quest
line ("get yourself a piece") ending in a Common item of your chosen class. Nothing in this city is a dud.

### The kit chart · ARRIVES WITH A LATER POSTING ·

Every grip in the collection, what it becomes, and its band. **Tiers: Common / Uncommon / Rare / Epic /
Legendary.** Weapons add raid and garrison power by tier; everything else does what it says.

**His side:**

| Grip | Class | The item does | Tier |
|---|---|---|---|
| Shotgun | Weapon | "the Lupara": raid/garrison power | Common |
| Sword | Weapon | raid/garrison power | Common |
| Knife | Weapon | raid/garrison power | Common |
| Cigar | Presence | "the lingering smoke": robbers face +5% failure odds while you're away | Common |
| Ace | Gambler's Charm | Moonshot door fee -15%, crate price -10% | Common |
| Whiskey | Consumable | 3 charges: +3 points on your next dispatch | Common |
| Poker Chips | Gambler's Charm | Moonshot door fee -15%, crate price -10% | Uncommon |
| Billfold | Stake | +75 Scrip on activation, +1 Marker credit step | Uncommon |
| Martini | Consumable | 2 charges: +2 points on a social brief | Uncommon |
| Peach | Consumable | the collection's only heal: clears one Hitter's hospital stay | **Rare** |
| MVHQ Martini | Relic | the club set key + a permanent +1 provisioning step | **Legendary** |
| (empty hand) | | the quest badge; ends in a Common item of your choice | |

**Her side:**

| Grip | Class | The item does | Tier |
|---|---|---|---|
| Audrey | Presence | +3 points on Con-family briefs | Common |
| Swordceress | Weapon | raid/garrison power | Uncommon |
| Knife | Weapon | raid/garrison power | Uncommon |
| Appletini / Whiskey Rocks / Wine | Consumable | charge items, same shapes as his | Uncommon |
| Ace / Chips | Gambler's Charm | Moonshot door fee -15%, crate price -10% | Uncommon |
| Stack | Stake | +75 Scrip on activation, +1 Marker credit step | Uncommon |
| Havannah | Presence | the lingering smoke, hers | Uncommon |
| Bird | Companion | "the Canary": a free scouting glance every 72h | Uncommon |
| .357 | Weapon | the collection's only revolver | **Rare** |
| Doggy | Companion | "the Doberman": +20 flat House defense while she's away | **Epic** |

Note the accident the archive was hiding: the shotgun is common and the healing Peach is rare. The art was
balanced like a loot table before anyone knew it was one.

Your kit is property: equippable, lendable to your crew, and losable. Carry it on a job and it can be
taken like anything else carried. The exposure law applies to sentiment too.

### The Callings · ARRIVES WITH A LATER POSTING ·

Your Don's wardrobe declares a trade. Every Calling grants the same three things: **+3 points** on its
mission family, **-20%** on its service fees, and a fatter draw on its quest line when the Specialists
arrive. Affinity, never exclusivity: any Don can attempt anything at list price. Traited Dons do it
better and cheaper.

| Calling | The look | Mission family | Fee break |
|---|---|---|---|
| **THE MUSCLE** | face mods (Terminator, Bane, Doom, Samurai, Cthulu), weapon kit, The General / Badass suits | escorts and sieges (PAPER ROUTE) | repairs -20% |
| **THE EYES** | eye mods, laser eyes, AR HUDs, Bladerunner / Weeb suits, the Hawk, the Bird | recon and tech jobs (PROOF OF WORK, ABSOLUTE ZERO) | scouting -20% |
| **THE CON** | Cigar / Havannah / Audrey, Pimp / Couture / Jennifer / Riviera / Hotlanta / Scarlet suits | social-engineering jobs (coming to the board) | market royalties -20% |
| **THE LEDGER** | Scholar / Windsor / Duchess / Opera suits, Knowledge Throne, Billfold / Stack, Rolex / Watch | finance jobs (coming to the board) | Marker credit builds +20% faster |
| **THE TABLE** | Ace / Chips kit, Devilish, Jester face mod | the degen lane (Moonshots) | Moonshot door fee -20%, fee leg only, never the pot |
| **THE WILDCARD** | **the Joker suit** | dealt fresh each season | whatever the deal says |

**The Wildcard, explained:** at each season's start the city deals every Joker a Calling, drawn by
entropy and announced on the Tape: "this season, the Joker plays the Eyes." He holds that Calling's full
package for the season. Over time it averages out to any fixed Calling; what you are buying is the drama
of the deal. And the **Full Motley** (Joker suit plus Jester face) carries the Jester's Gambit: once a
week, swap a posted brief for its variant twin. A choice among published ladders, so the math never moves,
only the mood.

### Signature edges · ARRIVES WITH A LATER POSTING ·

Rare paint, real perks. Each one line, each inside the caps:

| Trait | Edge |
|---|---|
| **The Ghost background** (1 in 5,000) | appears as "unknown" in every scouting report. The wallpaper was hiding the best trait all along |
| **The Hawk** (1 in 1,000) | a free scouting glance every 24h + early warning in the field |
| **The Serpent** (snake) | scouting reports return your window as a noisy band |
| **Ceasar** | the laurel: a crew he leads gains +1% job success |
| **Canes** | command auras: The Bull +5% garrison power, Swift -5% hunt cooldown, Cobra +5% counter-ambush, Claw -10% fence royalty |
| **Zombie / Golden / Glitch bodies** | hospital stays -50% ("already dead") / your own sale royalties waived / re-seed one brief's posted jitter once a season |
| **MVHQ set** (background + AR + Martini) | the club set: permanent +1 provisioning step + the aura |
| **Rolex / Watch** | dispatch fee -10% |
| **Prayer Bead / Black Pearl** | once a week, +1 point on a chosen dispatch |
| **Horseshoe** | once a week, redraw a brief's posted jitter |
| **Neko** | cat reflexes: harder to jump in the field |

Everything not listed is cosmetic, and we say so out loud. "Every trait secretly matters" is how a game
becomes a spreadsheet with a lawsuit attached.

### The Donna's edge · ARRIVES WITH A LATER POSTING ·

The women of Solvency run the systems that decide games: information, command, and resilience. Not a
bonus. A boss. Four powers, every one of them mechanical:

| Power | What it does |
|---|---|
| **Counter-recon** | every Donna is hard to time: any scouting report covering her returns her away-window as a noisy band, +/-25%, and never her exposure. What a man needs a 1-in-5,000 background for, every woman has by identity |
| **The Matriarch's House** | a House deed she holds runs better: **defense +15%, repairs -15%**. A Donna on a Compound is the hardest target in the city, as the fiction demands |
| **The Con line** | con-family briefs run **+5 points** success and **+1 provisioning step** for her. Offense, not just defense |
| **Outfit leadership** | a crew organization led by a Donna grants members **+2% job success** (the Ceasar laurel gives +1: the two leadership traits, deliberately ranked). Lands with the Syndicate update |

And her signature riders: **Medusa** (a failed attacker against her garrison is petrified: hospital +50%),
**the Phoenix** (once a season, a big score against her triggers an instant free repair: she takes the hit
and stands back up), **Neko** (cat reflexes), **Devilish** (the Table's icon: Moonshot fee -20%).

His identity is breadth: more edges, more volume, more variance. Hers is depth: know more, lose less.
The optimal family is mixed, which is exactly the point.

### The Edge Budget: why gear is an edge and not a wall · ARRIVES WITH A LATER POSTING ·

Everything stacks on one curve with a hard ceiling: **no combination of traits, Favors, and items ever
shifts a roll more than +10 points**, item power saturates at **1.35x**, fee discounts stack to **25%**
maximum, and nothing, ever, touches the published ladders, the 7.5% tax, or what a robbery can take.
"Maxed edge" is a real, reachable, knowable state. Screenshot it when you get there.

---

## The House ladder

Your address is your biography. Every tier raises three things together: how much you may deploy, how many
doors your crew can hold, and how hard the place is to crack.

| Deed | Price | Deploy cap | Garrison slots | Defense | Repair (full scar) | This season |
|---|---:|---:|---:|---|---:|---|
| **Safehouse** | free | 50 marks | 2 | base | 0.11 | **open** |
| **Row House** | 15 marks | 150 | 3 | + | 0.34 | **open** |
| **Brownstone** | 40 marks | 400 | 3 | ++ | 0.90 | opening soon |
| **Estate** | 120 marks | 1,000 | 4 | +++ | 2.25 | opening soon |
| **Compound** | 400 marks | 2,500 | 5 | ++++ | 5.63 | opening soon |

(1 mark = 100 Scrip. Skirmish prices post in test funds; this is the standing rate card.)

- **A bigger house earns nothing by itself.** It raises the cap on what you may expose. Every Scrip earned
  still traces to a deploy choice and a job window. The ladder sells capacity, never yield.
- **Deployed money earns 0.15% per day**, a fixed constant this season, posted on-chain. The floating
  rate that moves with the city's budget (floor 0.12%), and deployment queues when a district fills,
  carry the stamp: · ARRIVES WITH A LATER POSTING ·. The rate never lies and never promises what the
  books cannot pay.
- Upgrades consume the prior tier: the deed levels up in place. The deed itself is property in your Don's
  wallet, and a property market for standalone deeds, plus rare off-ladder deeds ("the Docks Warehouse,"
  "the Funeral Parlor"), arrives on the roadmap.

---

## The risk ladder

Every play in the city, rated the Solvency way: as an insurance opinion. Swings are typical
month-of-play amplitude for a mid-sized bankroll, not promises.

| The play | Rating | What's at risk | The swing |
|---|---|---|---|
| Vault sitting | **INSURED BY ARITHMETIC** | nothing. Earns nothing. Clause one | none, ever |
| PAPER ROUTE + bank nightly | **LOW** | door fees, small provisions | small, steady, dull as paint |
| Deployed + defended, 5h/12h jobs | **STANDARD** | the hopper, door fees, repair bills | modest drift, occasional bad night |
| Deployed + **undefended**, long jobs | **STEEP** | the hopper nightly, the safe eventually | ruinous. Negligence is a career opportunity: someone else's |
| ABSOLUTE ZERO nightly | **UNINSURABLE** | 200-Scrip carries, 65% busts | brutal weeks, then 2,775 prints your name |
| The Moonshot + the Big Pot | **UNINSURABLE** | 20-Scrip doors, 72% busts | months of nothing, then the whole pot |
| Robbing the careless | **STEEP** | 50 Scrip a knock, your Hitter's kit | a profession, if you're patient |
| Robbing a defended Compound | **UNINSURABLE** | your kit, 43% hospital odds, your dignity | a donation with paperwork |

---

## Strategy corner: five ways to play

**THE GRINDER.** Free Don, Safehouse, PAPER ROUTE on repeat, bank every night. How it feels: quiet
compounding competence; the city's honest workman. What you risk: nearly nothing, and you earn like it.
Every empire in Solvency started exactly here.

**THE RAIDER.** No deployment, a lean crew, the Tape open all evening reading depart lines. How it feels:
predatory chess with a stopwatch; the best skill-payout channel in the game. What you risk: 50 Scrip a
knock, your Hitter's coat, and long dry runs when the city gets disciplined. You eat because others get
lazy. Some weeks nobody is lazy.

**THE LANDLORD.** Climb the deed ladder, deploy to the cap, garrison heavy, repair fast, bank twice a
day. How it feels: running a real estate empire that shoots back; the defended House quietly out-earns
everything. What you risk: robbery drag if you slack on discipline, and the tallest deed draws the most
planning. Every statement in this city eventually gets audited.

**THE WILDCARD.** Joker suit, Table gear, Moonshots and the Big Pot, Grudge Contracts on anyone who
touches you. How it feels: the loudest seat in the room; a heart monitor with a wardrobe. What you risk:
the widest swings on this page, by design. The comeback kit exists because of you.

**THE DONNA.** Counter-recon, the Matriarch's House, the con line, and eventually the head of the table.
How it feels: everyone else plays cards; you play the room. Lose less, know more, and make the meta come
to you. What you risk: less than the men, which is the entire point, and it still isn't nothing.

---

## The house rules: what we owe you

This game sits next to real money, so it holds itself to the standard the city is named for.

1. **Every roll's odds are published on-chain before you pay.** Mission ladders, robbery bands, the
   Favor's four bands, the big-score curve: all of it, posted, versioned, checkable by anyone. Odds never
   change mid-season. A new table is a new posting, never a quiet edit.
2. **The Floor takes its cut, and we say the number.** On every gamble in the city, roughly 10 of every
   100 staked stays with the house. Mission wages are funded pay for time; the gambling lives in
   provisioning, crates, and the door, and it carries that edge. If you play purely to profit, the Floor
   wins slowly. Play because it is a good table with real loot on it, and know the number going in. The
   number is on every folder.
3. **Banked is sacred.** Nothing in this game, no mechanic, no robbery, no admin, can touch your Vault.
   What can be lost is exactly what you chose to expose: deployed Scrip, the hopper, provisions carried,
   items carried, and fees paid. Clause two is the whole trust model.
4. **Exits are free, forever.** Banking, claiming, withdrawing: no fee, no delay, no future knob. Any
   change that fee-gates an exit is wrong by definition, and the contracts are written to that rule.
5. **The Keeper cannot steal.** It resolves jobs and refreshes prices. If it stalls, your job settles at
   the sideways floor and your money remains yours. Slow is possible. Theft is not.
6. **No pity mechanics are hidden, because none exist.** The 1.5% is really 1.5%. Streaks are real
   randomness, verifiable per roll. We would rather you trust a cold table than doubt a warm one.
7. **This season is testnet.** Scrip and test funds only, no real value at stake, and the Skirmish exists
   precisely to prove the loop before real assets ride it.

---

## Coming to Solvency

No dates. The city does not promise schedules, it prints arrivals.

- **The Syndicate update.** Outfits: chartered crews of families. The Understanding (3 seats), the
  Syndicate (6), the Combine (10). Group jobs, pooled muscle, pledged garrisons, contribution-split
  loot, and a wax seal on the Tape. Solo stays a real identity: the Independent keeps the whole take
  and zero paperwork.
- **The Specialists.** Four public institutions, rare enough that the Tape prints when one changes hands.
  The Scout ("everyone's somewhere. I sell you where"). The Snitch ("I don't betray anybody. I just
  remember out loud"). The Broker ("while you were out doing jobs, the index did mine"). The Fixer
  ("you're paying me for the robbery that doesn't happen").
- **Seasons and the four victories.** Thirty-day seasons with escrowed prize pots, era bonuses that
  crescendo, and four public, interceptable roads to a title: the Portfolio, the Sieges, the Venture,
  and Renown. Announce your ambition, then defend it.
- **The real-asset rungs.** The take stops being Scrip and starts being the ticker on the folder, and
  the road is written and priced in the panels below: the prize map, the claim box, the Fixer's Book,
  the self-refilling board, and the board that expands itself. Riding in alongside them: the property
  market for standalone deeds, the field ambush, the item marketplace and crates, the Family's real
  credit line against your Don with the Floor as backing, and the districts opening one by one, each with
  the Fixer's actuarial rating stamped on the map: LOW, STANDARD, STEEP, UNINSURABLE.

### The prize map: every district pays its own metal · ARRIVES WITH A LATER POSTING ·

When the take goes real, the district you work decides the asset you carry home. The map is already drawn:

| The district | The work | What it pays |
|---|---|---|
| The tech quarters (Foundry, Racks, Kelvin, Exchange, Launch Yards) | chip, rig, quantum, and market jobs | the tokenized equity on the folder: NVDA, AAPL, AMD, META, GOOGL, SPY, and the rest of the wire |
| Ledger Row | the armored T-bill run | short T-bills (SGOV), the safe drip |
| The Refinery | the barrel job | oil (USO) |
| The Mint | the bullion run | silver (SLV) |

You do not buy the stock. You **win** it, by playing: work the job, roll the published odds, and a fixed
tranche of the district's asset lands in your name. A clean chip-fab run pays you a fixed cut of the chip
company; the Refinery pays oil; the Mint pays silver. The loot IS the asset, not a promise of it, and the
size of your cut is fixed in units of the thing itself, so no price feed sits between you and getting paid.

### The claim box: winnings a raid can never reach · ARRIVES WITH A LATER POSTING ·

Real stock you win does not sit in the hopper waiting to be robbed. It banks to a claim box of its own, a
ledger no raid can touch, and sweeps to your Don's Vault whenever you like. Raids stay a Scrip fight,
exactly as they are today: the till and the working capital are contested, the Vault never is, and your
won stock is claimable and safe the instant the job resolves. You win it, it is yours, and no one can kick
a door to take it.

### The Fixer's Book: the cushion for a brutal night · ARRIVES WITH A LATER POSTING ·

The real-asset seasons hit harder than the Skirmish. A dominant crew that scouted a wide-open House can
take a real bite, on a skill-scaled ladder that tops out at a rare 65% of a victim's DEPLOYED capital. The
Vault is never touched, at any number, and **banking is, and always will be, the free protection**. But
for the working capital you chose to leave exposed, there is the Fixer's Book: buy a policy before you
leave an exposed House, and a bad night is cushioned, roughly a quarter of the loss handed back. The Book
pays for itself four ways: the premiums people pay, a slice of the tax on every landed raid, a small skim
off the city's whole fee stream, and a season seed to open the doors. Banking is the real skill and the
free armor; the Book is the second net for the money you deliberately put to work.

### The self-refilling board: the pool you win from is the pool you feed · ARRIVES WITH A LATER POSTING ·

Every real spend in the city routes instead of vanishing. Repair a House with silver, upgrade a deed with
T-bills, provision a job with the district's own asset, and most of what you spend flows straight back
into the prize pool you won it from, minus a thin protocol cut and a slice to the Book. The same metal you
win, you spend, and it circulates back to be won again. The pools refill themselves off their own
velocity, which is why the board can keep paying real assets without a bottomless treasury behind it.

### The self-expanding board: new listings become new work · ARRIVES WITH A LATER POSTING ·

The board is built to grow without a rebuild. When a new asset lists on the chain and clears its proof,
the city wires a new district or a new folder around it and posts fresh quests, no rebuild, no new season
required. The drawer of written-but-unposted briefs, and the standing job of watching the chain for new
listings, mean Solvency keeps opening streets for as long as the market keeps making them.

Solvency will never be finished. That was never the point. It was founded by 8,888 families who couldn't
sit still, and it's being built, street by street, job by job, season by season, by everyone who takes a
seat at the table.

The Bell is about to ring. Bank before you brag.

---

*The Skirmish runs on the Robinhood Chain test network with test funds only. Nothing in this guide is
financial advice, and nothing this season has real-world value. Odds, rates, and fees are published
on-chain and may be re-posted between seasons, never within one. The full rate card and contract
addresses live in the docs room.*
