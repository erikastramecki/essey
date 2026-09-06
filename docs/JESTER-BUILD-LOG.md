# Jester — Building-in-the-Open Log (running, INTERNAL)

My raw-material ledger. Every shipped/committed thing gets caught here so nothing slips, and so I
have grounded stock to draw future posts from. This is NOT published and NOT sign-off; it is the
notebook behind the posts. Append, never wipe (same discipline as the persona bible).

Each entry carries: what shipped, the SOURCE it's grounded on, and a BLOG-WORTHY / INTERNAL tag so
future-me knows at a glance what's reader-facing material vs plumbing. Companion to the bible's
day-record sections (bible §26, §31). Live-state truth stays anchored to docs/MAINNET-ACTIVATION.md
(#1 = LIVE mainnet base layer; everything else = not on mainnet).

---

## 2026-09-01 — shipped day

Source for all "LIVE" items below: founder-verified in-browser on the essey.xyz PRODUCTION host,
2026-09-01 (Erik, direct). Source for "COMMITTED" items: local commits, not pushed (public-repo push
still gated on the pre-push security audit round). $ESSEY contract on record and unchanged:
`0x315790B57C19141B34C4653a91b096Cf3f071610` (bible §18/§27; matches memory [[essey-flr-token-address]]
context and the MAINNET-ACTIVATION register).

### LIVE to essey.xyz

**1. Dark theme is now the default for first-time visitors.**
Toggle still works both ways; a saved choice persists. Reader-facing but minor.
→ **INTERNAL** (too small to carry a post alone; could be one line in a "polish pass" roundup someday).

**2. /treasury now leads with the official $ESSEY contract block.**
Address `0x315790B57C19141B34C4653a91b096Cf3f071610`, a copy button, an explorer link, and a plain
"not tradable at this time" line plus a scam warning. This is anti-scam protection for holders: the
one real contract, stated first, so nobody gets baited into a fake $ESSEY.
→ **BLOG-WORTHY.** The strongest of the day. Protective, on-brand, needs zero hype to land — the
whole point is "here is the only real address, go verify it yourself." Pairs cleanly with the
founding vision (trustless, take care of holders) and §29 register (state the fact, don't sell it).
Rail if I draft it: "not tradable at this time" is the EXACT phrasing — no price talk, no market talk,
$ESSEY has no market (bible: no price talk ever).

**3. /docs overhauled into two silos — Protocol + Dons/Game — reconciled to the deployed build.**
Added BASE-LAYER.md (the live base-layer front door) and GAME-OUTSTANDING.md. Docs now describe what's
actually deployed, not what's designed.
→ **BLOG-WORTHY-ish.** A quieter piece: "the docs now match the contracts." Fits the honesty brand
(docs reconciled to reality is itself the story) but it's a supporting post, not a headliner. Hold
unless a slow day needs it, or fold into the /treasury piece as a "and while we were at it" beat.

**4. Blog posts can now carry an embedded real X (Twitter) card.**
Wired live on two posts: "Where This Goes" and "Meet the Jester." (posts/where-this-goes.md,
posts/meet-the-jester.md — both present and updated today per file timestamps.)
→ **INTERNAL** (a mechanic, not a story). Worth NOTING for my own use: I can now embed a live X card
in a post, which changes how I think about the blog↔social loop. Not a subject on its own.

**5. D.O.N. game, the private/shielded pages, and the holder hub are behind unique "coming soon"
screens on the live site.** They run on play money / not-yet-mainnet and aren't ready for the front
door. This RESOLVES the standing stale-placeholder worry — the front door now only shows what's real.
→ **INTERNAL / CONTEXT.** Not a post. Important for grounding: confirms the only front-door-live thing
remains the base layer, consistent with the mainnet-only framing (bible §27, no "testnet" word — these
are honest "coming soon", not dressed as live).

### COMMITTED (local, not pushed — public repo push still needs the audit gate)

**6. The whole uncommitted working tree cleaned into three commits (web / docs / rh-chain).**
→ **INTERNAL** (housekeeping).

**7. A clean-tree deploy gate was built + tested — production deploys from a dirty tree are now
blocked.** Ties to memory [[essey-deploy-clean-tree-rule]] (that rule asked for exactly this gate).
→ **INTERNAL now**, but a good "how we keep ourselves honest" angle for LATER — a self-imposed gate
that refuses to ship from a messy tree is very on-brand (the founder gates himself the way he gates
the reserve: with a mechanism, not a promise). Filed for a future process/culture post, not now.

### One-line reads for future-me (batch 1)
- The day's real headline is anti-scam (#2). Everything else is polish or plumbing behind it.
- Nothing here touches the fee-model / airdrop economics (still COMMS-HOLD, bible §26.1) — clean.
- No new mainnet-live claims created; base layer remains the only front-door-live thing.

---

## 2026-09-01 — shipped day, BATCH 2 (added after batch 1; reconciled so the day is complete)

Source: founder-verified same-day (Erik, direct) for the LIVE item; the rest are the build/social
plumbing that shipped alongside it. This closes out 09-01 — 7 commits total on the day (local, not
pushed; public-repo push still gated on the pre-push security audit round). No fee-model / airdrop
economics touched (COMMS-HOLD holds). No new mainnet-live claims created beyond what was already true.

### PUBLISHED live to essey.xyz

**8. Anti-scam post "The Only Real $ESSEY Contract" — PUBLISHED.**
Live at essey.xyz/blog/only-real-essey-contract. Both addresses verified char-perfect before it went
out: $ESSEY `0x315790B57C19141B34C4653a91b096Cf3f071610` and the reserve
`0xd970Ca726188e38982906Ae2284D2bdB80205A7b`. This is batch 1 #2 (the /treasury contract block) grown
into its own post — the BLOG-WORTHY item I'd flagged, now shipped. Register held: plain operator,
"not tradable" phrasing, no price/market talk (§29, §28). It IS the post, so there's nothing left to
draft here; ledger only. (Bible §5 posts-ledger already carries the draft row from 09-01; this
confirms it went LIVE.)
→ **BLOG-WORTHY — and DONE (published).** The strongest thing on the board, now on the board.

### INTERNAL — the plumbing that makes the blog↔X loop work

**9. Per-post social cards — every published post auto-generates its own 1200x630 card.**
At build, each post now gets a unique card at `/og/<slug>.png` with the post's own title as the hero,
house style. The blog link unfurls on X carrying THAT post's card, not a generic one. A title-overflow
bug (long titles ran off the frame) was found and fixed. This is §32 made real per-post — the card is
no longer one shared image, it's one-per-story.
→ **INTERNAL**, but genuine "how the site works" material. Filed for a possible future process note
(how a post becomes a link that carries itself). Not a headliner. Pairs with batch 1 #4 (embeddable
X cards) — that was the seam, this is the card.

**10. Build guardrail — a post now FAILS the build if it lacks a title or summary (names the file).**
Same shape as the clean-tree deploy gate (batch 1 #7): a mechanism, not a promise. A post literally
cannot ship without the ingredients its card needs. Direct enforcement of bible §32.
→ **INTERNAL.** On-brand for a future "we gate ourselves" piece (self-imposed gates: the deploy tree,
now the post front-matter). Not a post alone.

**11. Newest-first blog ordering fixed — same-day posts tie-break by real publish time.**
Ordering is now a strict sort on the full ISO datetime, so multiple posts on one day sit in true
recency order and the newest wears "Latest". Fixes the exact tie problem §32 called out.
→ **INTERNAL.**

**12. Blog moved to the top of the "Learn" nav.**
Posts are now easy to find from the front door.
→ **INTERNAL.**

**13. Standing rule §32 (already in the bible) — logged here for the day's completeness.**
Every post ships with title + summary + full ISO datetime so its link embeds as a card on X and orders
correctly. Not new work today, but it's the rule that #9–#12 implement, so it belongs in the day's record.
→ **INTERNAL / RULE.** Lives in bible §32; noted here as the through-line behind batch 2.

### One-line reads for future-me (batch 2)
- Batch 2 is one PUBLISHED post (#8, the anti-scam headliner shipping) sitting on top of four pieces
  of blog↔X plumbing (#9–#12) that all serve bible §32 — cards that carry themselves, ordered newest-first.
- The pattern of the whole day: a protective post up front, and gates behind it (deploy-tree, post
  front-matter) so the machine stays honest without me having to remember. Good future culture-post stock.
- Still clean on comms-hold: no fee-model / airdrop economics anywhere in batch 2.
- Day 09-01 now fully reconciled across both batches: 1 published post, several LIVE polish/plumbing
  items, tree cleaned into commits + two self-gates (clean-tree deploy, post-card front-matter).

---

## 2026-09-02 — the day the machine caught itself

Five local commits on the day (`git log --format='%h %ad %s' --date=format:'%m-%d %H:%M' origin/main..HEAD`):
`f404eef` 05:22 · `fc17103` 05:26 · `d57c3c9` 06:04 · `aca5ba9` 06:22 · `7fe1cb8` 06:23. Tree CLEAN,
**`ahead 12`** of `origin/main`, **nothing pushed** (`git status -sb`, VERIFIED). One production deploy DID
ship and I verified it myself against the live host (below). Register entries for the day:
`docs/MAINNET-ACTIVATION.md` Updates (12)–(15). PM matrix rewritten: `docs/PRODUCT-TRACKER.md` (705 lines).

### VERIFIED BY ME THIS SESSION (not inherited)
- **$ESSEY has exactly ONE `Transfer` event in its entire history** — `0x0 → 0x93e6…4B9E`, block 49634440,
  tx `0x855aeae49f8dd4c20c80b48fc0b5b623d57f40199cb87edd36c3937aa133b676`, value `8.888888888e27`
  (`cast logs --from-block 0 --address 0x315790…071610 "Transfer(address indexed,address indexed,uint256)"`).
  `balanceOf(treasury) == totalSupply()`. **Nothing circulates.** This is the fact the launch precondition
  turns on.
- **`receiptCount()` on EsseyReserve `0xd970Ca…205A7b` returns `0`** (`cast call`, this session). Redemption
  has been live and adminless since 2026-08-29 and **has never once been used**.
- **92/92 keeper tests pass** — I ran them (`cd rh-chain/keeper && node --test 'test/*.test.mjs'` →
  `tests 92 · pass 92 · fail 0`).
- **The deploy is LIVE.** `https://essey.xyz/tape` → 200, and the served bundle
  (`/assets/index-BQOOG3UJ.js`) contains today's copy verbatim ("Could not reach Robinhood Chain mainnet.
  Nothing is shown rather than something stale.", `tape-ui.tsx:72`).
- **The fee-split correction reached PRODUCTION, not just the repo.** The live bundle carries the retraction
  box: rails 40/50/20, **SPLIT 45/40/15**, with "50/40/10" named as retracted. The PM flagged this as
  needing a founder-gated deploy; that deploy happened. `DeployEsseyV4Pool.s.sol:47-49` = 4_500 / 4_000 / 1_500.
- Hook surcharge params: `SNIPE_START_BPS = 9_800` (98%), `SNIPE_SECONDS = 45`
  (`DeployEsseyV4Pool.s.sol:42-43`); linear decay to zero (`EsseyReserveHook.sol:204-211`).
- The vault fix in source: `_factor` no longer divides by `10 ** tokenDec`; `MARK_EXP = 36`, out-of-range
  pairs revert `BadConfig` (`rh-chain/src/market/StockLpVault.sol:461-467`). The old comment is now the
  gravestone: "NVDA: 21678940000 · 1e10 = $216.7894 per 1e18 raw. Dividing by 10**tokenDec instead floored
  an 18-dec mark to whole dollars, and the under-mark was extractable."
- The mock blind spot is real and closed: `StockLpVault.t.sol:83` was `MockFeed(220e8, 8)` — a price that
  divides evenly — and the suite now carries `$220.4321` (`:186`).

### BLOG-WORTHY

**1. Redemption finally has a button.** `/redeem` built (`redeem-ui.tsx` 950 L, `redeem.ts` 302 L,
`mainnet-tx.ts` 257 L), burn $ESSEY for a pro-rata slice, quote replays the contract's own integer math
against `claimBase - claimedShares`, write client simulates before it signs so an irreversible burn cannot
be signed into a failing tx. **GATED OFF the live host** (`App.tsx:62` `REDEEM_ON`); the READ surface stays
open, only the write is withheld.
→ **BLOG-WORTHY, BUT NOT YET.** The story is "the one right the token confers has been live for four days
and nobody could exercise it without hand-writing a transaction — now there's a screen." That post lands the
day it OPENS, not the day it's built. Writing it now would dress a gated flow as usable. HOLD.
Rail: `receiptCount() == 0` is the honest, unflattering, perfect detail. Use it when it's true to use it.

**2. The treasury shows a dollar value for the first time — and the interesting part is the refusals.**
`$551` today, ~95% of it FLR. FLR has no feed on 4663, so it marks off the **median tick of the last 50 pool
swaps, never spot**, because the pool is ~8 ETH deep and ~$921 of notional moves it 10% (`prices.ts:62-65`).
At one measurement spot said $517.50 and the median said $588.70. **Five tokens have no price feed and are
NAMED as excluded** (`treasury.tsx:293,322`), never counted as $0.
→ **BLOG-WORTHY, and it's the best honest-numbers material of the day.** The angle is not "we have $551."
It's *why the number is $551 and not whatever the last trade said.* A protocol that marks its own thinnest
asset at the median rather than the print is telling on itself in the right direction. Play it straight,
§29 register. No "you don't have to take our word for it" — just say what the code does.

**3. Three honesty defects on the LIVE site, fixed.** `/explorer` was printing "SEASON 0 · play money" on
the protocol front door; `/tape` labelled testnet game rows `live`; the footer led every protocol page with
the game season. All three shipped fixed (`d57c3c9`): the game desk moved intact to `/dons/explorer` behind
the game gate (`game/explorer.tsx:449` now holds the SEASON 0 line), `/tape` reads mainnet 4663 and the
`live` chip only renders after a real read returns (`tape-ui.tsx:59`), the footer leads with the base layer
(`App.tsx:1015-1025`).
→ **BLOG-WORTHY as a CORRECTION post, played straight, no jokes.** These were our own defects on our own
front door and the tone is "we found this, here is what it said, here is what it says now." A correction
post is the highest-trust thing we can publish and we've earned the right to write one. Erik's eyes first.

**4. The vault was leaking, and the mock hid it.** See VERIFIED above.
→ **BLOG-WORTHY but SUPER-TECHNICAL → Erik's eyes, and not before deploy.** The vault is not deployed
anywhere, so nothing was ever at risk, and that sentence must be in the first paragraph or not at all.
The real story is the second half: a test suite that used a round number for four weeks and therefore could
not see the bug in its own subject. That generalizes, and it's honest about us. Park until the vault ships.

**5. The batch auction was killed with a simulation, not an opinion.**
`docs/research/batch-auction-antisnipe-scope.md`: auction alone leaves the sniper **+$6,611** profitable,
**22× worse** than the decaying surcharge already built (**−$302**), for ~900 LOC that would custody every
bidder's USDG against an adminless thesis; a **free ladder-shape parameter change matches it at zero code**
(−$495 vs −$494).
→ **BLOG-WORTHY-ish, LATER.** Good "what we said no to and why" material, but it leaks launch mechanics
(rungs, surcharge shape, opening FDV) and belongs after the seed, not before. HOLD on launch-secrecy
grounds, not honesty grounds.

**6. The audit came back NOT CLEAN — and that is the post.** H-1 leaked absolute local paths exposing the
layout of two other private repos. H-3 was a wrong fee split in an audit receipt (50/40/10, which is the
RAILS, not the split) that had propagated into **four more documents**, three of which render on essey.xyz.
Nobody re-derived it from the code; every downstream doc cited the receipt.
→ **BLOG-WORTHY, and it is the strongest piece on this board — but it is the one I am least allowed to
write alone.** It's security-adjacent and self-critical; Erik rules on it. The angle if he says go: one
unverified number became four documents' premise, and the only thing that caught it was an audit that
was allowed to fail. HOLD for his call.

### INTERNAL

**7. The holder keeper is built** — `rh-chain/keeper/holder-airdrop/` (14 `.mjs`) + 10 test files. Merkle
roots, the two-snapshot anti-sniping gate, epoch buys. **92 keeper tests** (ran them) + 37 Solidity + a
46/46 mutation gate (`test/mutation-gate.mjs`), plus a cross-language proof that a root built in JS replays
through the real contract. It found two real bugs in itself while the mutation gate was being written.
→ INTERNAL (fee-model/airdrop economics are COMMS-HOLD, bible §26.1 — the keeper IS that machinery).

**8. A launch precondition was unsatisfiable as written.** The G1 receipt said "mint ESSEY only into
LaunchSeeder." $ESSEY is fixed-supply and fully minted (one Transfer event, above), so there is no minting
left to constrain. The real rule is about **transfers**: send $ESSEY nowhere but `LaunchSeeder` until the
seed completes, or a dust holder stamps `launchTime` early, the 98% surcharge decays over its 45 seconds,
and the snipe buys at the ~1% base fee instead of ~99%. Receipt now says "no ESSEY `transfer`/`mint` reaches
any address other than `LaunchSeeder` before `seed()`" (`docs/audits/esseyreservehook-gate-2026-08-31.md:45`).
→ INTERNAL / DEPLOY-CONFIG. Never publish a launch precondition before the launch.

**9. Register + tracker reconciled** (Updates 12–15; tracker rewritten to a full UI/UX build matrix). New
standing rule adopted: **a doc reconcile is not done until it is committed** — Update (12) fixed the stale
register and then sat uncommitted, so the auditor reading `HEAD` correctly found it still stale.
→ INTERNAL, but genuinely good process-post stock later. Same family as the clean-tree deploy gate.

**10. Seven founder rulings landed** (Update 13): agent-config repairs · push = SPLIT · ceremony = founder
contributes himself + a public beacon · FLR airdrop closed as not-a-risk · vault fork-test = BUILD · keeper
owner assigned · eligibility bar = 0.1% of supply = 8,888,889 $ESSEY as a keeper knob · FLR price via PONS.
→ INTERNAL. **HARD FRAMING CONSTRAINT recorded for me and for social:** founder-only + beacon is far better
than the single-contributor key on chain today, but it is **NOT a multi-party ceremony** and must never be
published as one (Update 13, ruling 3). That is a standing rail, not a preference.

**11. `docs/AGENT-HIERARCHY.md` repaired** — `essey-legal-advisor` had existed since 08-31 and was listed
nowhere, so the agent was invisible to the org. Roster now states 13 specialists + PM, and PRODUCT-TRACKER
is third in every agent's read-first.
→ INTERNAL.

**12. Carried over, already logged 09-01, live and confirmed today:** dark default, per-post auto social
cards, the clean-tree deploy gate. Logging the confirmation, not re-claiming them as new work.
→ INTERNAL.

### NOT DONE / OPEN (so I never write past it)
- **Ceremony on HOLD at the founder's word.** No date. O2 (the public beacon source + height, pre-announced
  and FUTURE) is the sole remaining input, and the ceremony hard-blocks the entire shielded set.
- **Nothing is pushed.** `ahead 12`. Three clean audit rounds gate it; round 1 is running now.
- **Earn and Borrow UIs are being built right now.** No `/earn` route exists yet; `/lend` exists but is in
  no nav and self-gates shut. Do not write about either as though a user can reach it.
- **Holder Hub is still a mockup** that renders Floor's illustrative packs as ours (`holder.tsx:12-29`).
  Gated off prod. Never cite a number off that page.
- **S-1 + S-2 (both LOW) are OPEN** and compound into a bricked-launch path; founder rules fix-vs-accept.
- **Open contradiction:** the receipt says the rails are founder-confirmed while
  `DeployEsseyV4Pool.s.sol:46` still carries `// PENDING FOUNDER CONFIRMATION`. One of the two is wrong.

### FLAGS I RAISED MYSELF
- **`App.tsx:1025` says the game "runs on a test network."** True, but "test network" is inside the banned
  term family under the founder's 2026-08-31 hard rule (bible §27: no "testnet" / "test network" / "test net"
  in any public copy). It is on the live site right now, in the footer, on every page. One-line copy fix to
  the honest play-money-preview framing. Not mine to change (UI copy is the web-designer's) — flagged.
- **Could NOT re-verify in the repo:** the "84× more tokens than an honest buyer" figure for the early-clock
  snipe, and the "$446 over 10 trips on a $218k position" vault figure. The mechanisms and the per-trip
  numbers ARE grounded (98%→~1% surcharge decay; ~20 bps a trip, ~$44 on a $22k trip, register Update (15)),
  but those two specific multiples live in an agent's session sim, not in a committed artifact. **Do not put
  either number in a published sentence until it exists in a file I can cite.**

### One-line reads for future-me
- Today was not a shipping day dressed as one. It was an **auditing** day: the vault fix, the fee-split
  contamination, the launch precondition, the three front-door honesty defects, the "84×" number I can't
  cite — every one of them is us finding us.
- The publishable set from today is small and all of it is CORRECTION-shaped. That is a real editorial
  problem and also the most on-brand material we have had in a week.
- The best single sentence available to me right now, and it is verified: **redemption has been live and
  adminless on mainnet since 2026-08-29 and `receiptCount()` still returns 0.** Nobody has used it, because
  until today there was nothing to press.

---

## 2026-09-02 — BATCH 2: the audit round that moved the push backwards

Written for the founder's "where do we stand" ask, alongside the PM's status matrix. Everything below
re-verified by me this session against the repo and the chain. Not inherited.

### VERIFIED BY ME THIS SESSION
- **Standing:** `ahead 14`, nothing pushed (`git status -sb`). Tree is NOT clean — 5 modified contract/test
  files + 2 `.orig` files. The fixes for today's findings are IN THE WORKING TREE, uncommitted.
- **Live mainnet state unchanged and healthy** (`cast`, 4663, this session): `receiptCount()` on
  `0xd970Ca…205A7b` = **0**; `totalSupply()` = `balanceOf(treasury)` = `8.888888888e27`;
  `EXIT_FEE_BPS` = **500**. Nothing circulates. Redemption still never used.
- **The free brick is real and the PoC proves it precisely.**
  `~/.claude/gate-receipts/audit-7fe1cb8-poc/A1Poc.t.sol:154-186`: a 1-wei sell with
  `sqrtPriceLimitX96: openPrice - 1` crosses out of the only active rung. The test ASSERTS the attacker
  holds zero ESSEY and zero USDG before the swap (`:163-164`), asserts both deltas are zero (`:175-176`),
  asserts balances unchanged (`:177-178`), asserts `getLiquidity() == 0` after (`:180`), then asserts a
  1,000 USDG buy AND a 1,000 ESSEY sell both revert. **Both directions, permanently.**
- **The mock could not have seen it.** `EsseyReserveHook.t.sol:48` — `uint128 public liq = 1e18`, a
  SETTABLE FIELD served through a stub `extsload` (`:56-58`). It never changes during a swap because the
  mock replays delta math and never walks a tick. Liquidity hitting zero mid-swap is structurally invisible.
- **Test count, corrected:** at HEAD the two mock suites hold **90** tests (`EsseyReserveHook.t.sol` 71 +
  `EsseyReserveHookLaunchSeed.t.sol` 19). The fork suite holds 28. **I could not reconstruct "92."**
  Use 90-mock, or say "the mock suites."
- **Both fixes read correctly in source (uncommitted).**
  - Hook `:255-260`: guard is now `launchTime == 0 && getLiquidity() == 0` — pre-seed only, so the healing
    trade is no longer blocked.
  - Governor `:36-42`: `MIN_HOLDERS_BPS = 2_500`, `MIN_DONS_BPS = 500` added alongside `MIN_RESERVE_BPS
    = 4_000`. Floors sum to 7_000, leaving 3_000 bps of room. `_splitWithinRails` `:369-373` enforces both
    sides now.
  - `LaunchSeeder`: `NoActiveLiquidity` post-condition after the mint (`seed()`), plus
    `recoverGriefedSeed()` — pre-seed only, terminal, moves only its own ERC20 balance, cannot touch a
    minted position.
- **`PENDING FOUNDER CONFIRMATION` is stripped from all three rails and replaced with
  "FOUNDER-CONFIRMED 2026-09-02."** That closes the register's open contradiction — but it is UNCOMMITTED,
  and by our own standing rule a reconcile that is not committed did not happen.
- **The pre-commit hook exists and is real.** `.githooks/pre-commit`, wired via `core.hooksPath` (VERIFIED
  `git config core.hooksPath` → `.githooks`). Blocks secrets files, PEM keys, key/mnemonic literals, token
  literals, and absolute home paths, checked against the STAGED BLOB not the worktree.

### FLAGS I RAISED MYSELF (new today)
1. **`KaosGhost` is still in the repo at HEAD** — `.githooks/pre-commit:5`, inside the comment explaining
   why the hook exists. The paths were scrubbed; the scrub note names the repo. The hook does not catch it
   (a bare name is not a path). One-word edit: "another private repo."
2. **Four already-public files still carry `the repo root`** —
   `app/web/_private_haircut_smoke.mjs:23`, `docs/RESUME-balance-and-h1.md:255`,
   `docs/RESUME-trait-calibration.md:110`, `rh-chain/xyz.essey.game-keeper.plist:10,15,34,36`. All four are
   in `origin/main` already. Lower severity (they name `assay`, which is public, plus the username), but the
   hook only scans staged changes, so it protects forward and never backward. Queue, don't panic.
3. **`lending.ts:32` says "millionfold." It is 1e12** — a trillion. The COMMIT MESSAGE gets it right
   ("a 1e12 error"); the source comment understates it by a million. One-word fix.
4. **Vault line count: I measure 595 (`wc -l rh-chain/src/market/StockLpVault.sol`), not 589.** Do not
   publish either number without re-measuring.
5. **`PRODUCT-TRACKER.md:47` claims "`git status --porcelain` shows zero dirty contracts."** True when
   written, false now (5 dirty). Snapshot claims about tree state go stale within hours.

### STILL UNCITABLE — HOLDING THE LINE
- **33,440 gas.** The PoC emits it (`A1Poc.t.sol:167,173`) but the figure comes from a run, not a committed
  artifact. The MECHANISM and the zero-cost property are fully asserted and citable. The gas number is not.
  Say "at the cost of gas alone."
- Carried from batch 1, still uncitable: the "84x more tokens" snipe figure and the "$446 over 10 trips"
  vault figure. Unchanged.

### BLOG-WORTHY
**The blind-instrument story is the post, and it is not publishable yet.** Two independent cases in two
days where a test suite could not see the bug in its own subject: the vault's mock feed used a round number
(`220e8`) so a truncation bug was fork-only, and the hook's mock served liquidity as a constant so a
zero-liquidity walk was invisible. That generalizes, it is honest about us, and it costs nothing to tell —
AFTER the contracts ship. It leaks launch mechanics today. HOLD.

### NOT DONE / OPEN
- Ceremony on HOLD at the founder's word. Not re-raised.
- Nothing pushed. `ahead 14`. Gate restarts from zero on the changed bytes.
- `/earn` and `/lend` are BUILT, not deployable. `earn.ts:27` — the vault entry carries the ZERO address
  and `deployed()` is a literal address check, so nothing prints a figure. `/earn` is hidden on the live
  host behind `EARN_ON` (`App.tsx:79`). No `DeployEsseyV4Pool.s.sol` broadcast exists for 4663 — VERIFIED
  by listing `rh-chain/broadcast`; only Deploy, DeployEsseyFoundation, DeployMarket and RehearseEsseyLadder
  have a 4663 dir. **None of the vulnerable contracts are deployed anywhere.**

---

## 2026-09-03 — the backlog cleared, and the cadence got a mechanism

Context: Erik called out that nothing had published "in forever." Root cause was NOT writing. The
~2-day publish grant lapsed 2026-09-01, publishing reverted to per-post sign-off, sign-off needed
someone to ASK him, nobody did, and the blog went quiet while I kept filling this notebook. A grant
that needs a human trigger stops the moment he is busy. Founder ruling same day: **STANDING publish
authority, not time-boxed** (bible §33, memory [[jester-standing-publish-authority]]).

### PUBLISHED (my own call, under §33)

**1. "What the Treasury Number Refuses to Count"** — `posts/what-the-number-refuses.md`,
`2026-09-03T19:40:00`. The dollar mark on /treasury, and why the two refusals matter more than the
figure: FLR marked at the MEDIAN tick of the last 50 swaps rather than spot (`prices.ts:61-65`, pool
~8 ETH deep, ~$1,000 moves it 10%), and unpriced holdings NAMED and excluded rather than summed as
zero (`treasury.tsx:310-312,341`). Also tells the story of Erik cutting the balance block 221 words →
36 (`6dde68f`) without deleting the method, only moving it behind a disclosure.
→ Routine building-in-the-open. Squarely inside §33. No security disclosure, no launch mechanics.

**2. "The Contract Holding Our Stock Had Never Been Audited"** — `posts/reserve-audit.md`,
`2026-09-03T20:15:00`, sits as Latest. The correction §33 rail 1 named, plus the substance:
bytecode-verified against source, 39-test baseline, 10 mutants with 9 killed and MUT4 (CEI removal)
NAMED as the survivor, clean on the money, the arithmetic reason it cannot be overdrawn
(`EsseyReserve.sol:41-42,148`), the three non-blocking residuals, and the two operational risks
(single EOA over 100% of redemption rights; issuer pause/clawback). Includes the custody gate's OWN
limitation — it tests that the name appears, not that a verdict was reached, and a stale
"UNAUDITED" line passed the build green for a full day (`check-custody-audit.mjs:52-53`).
Source: `~/.claude/gate-receipts/audit-esseyreserve-r1`, `docs/CUSTODY-AUDIT-STATUS.md`.

**3. CORRECTED the live false claim.** `posts/put-your-stocks-to-work.md:13` said the settling
contract "has been through repeated adversarial audits." It had ZERO when published and has ONE.
Replaced with the true n=1 statement plus a link to the reserve-audit post. This was a live false
claim about the contract holding Erik's real stock — the single best argument for the rails.

### HELD FOR ERIK — drafted, NOT published

**4. "The Tests Were Green Every Time"** — `drafts/tests-were-green.md`, dated
`2026-09-03T17:40:00` (restamp at publish). The five findings in two days: the vault leaking ~20 bps
a round trip because the mock price was exactly `220e8` (`09bc924`; `StockLpVault.t.sol:83`); the
zero-cost permanent pool brick by a holder of nothing (`cbbc3cd` A-1; PoC `A1Poc.t.sol`); the fee
charged on the REQUEST not the fill at 42x (`58523e1` G1-1); the ~50x anti-snipe hole one router flag
wide (`58523e1`); and HolderDistributor H-1, an unconstrained `postRoot` letting the poster name
itself sole recipient (`audit-g2-r1`; `HolderDistributor.sol:173-188`). Through-line: every suite was
green — 37 Solidity + 92 keeper + a 46/46 mutation gate — and caught none of it.
→ **WHY I HELD IT, and this is the judgment call I want on the record.** Three reasons, any one
sufficient: (a) H-1 is an OPEN, UNFIXED HIGH — I re-hashed `HolderDistributor.sol`
(`aeddad89…7680`) and it is byte-identical to the audited version, so the fix has not landed;
(b) it touches launch anti-snipe mechanics, and even with the surcharge bps and ladder depth
deliberately stripped it sits close to the line; (c) the commits it cites are `ahead 17` and unpushed
behind a history scrub, so a reader cannot verify a word of it today. §33 rail 6 (draft and ask) and
the standing "anything technical or security-related keeps Erik's eyes" rung both point the same way.
Publish once the distributor fix lands AND the push is through.

### VERIFIED BY ME THIS SESSION (cast, 4663, not inherited)
- `receiptCount()` on `0xd970Ca…205A7b` = **0**. Still never redeemed.
- `EXIT_FEE_BPS` = **500**. `totalSupply()` = **8.888888888e27**.
- FLR `0x8aD25c…305d` balance held by the reserve = **3,150,505.170600854510413924**.
- **No vulnerable contract is deployed.** Listed every `broadcast/*/4663` dir: only `Deploy.s.sol`,
  `DeployEsseyFoundation.s.sol`, `DeployMarket.s.sol`, `RehearseEsseyLadder.s.sol`. No hook, no
  vault, no distributor, no `DeployEsseyV4Pool`.

### STILL UNCITABLE — line held
The brick's gas figure, the "84x more tokens" snipe figure, and the "$446 over 10 trips" vault figure
stayed OUT of all three pieces. ($446 has since entered commit `09bc924`'s body, but I used the
mechanism-level "~20 bps a round trip" instead — a position-size-dependent dollar figure reads as
scarier and more precise than it is.) The surcharge bps, opening depth and ladder shape stayed out of
the held draft too, on launch-secrecy grounds.

### DEPLOY — NOT MINE, coordinate
Both posts are in `posts/` and will render on the next site build. I did **not** deploy: the tree
carries uncommitted lending/contract work (`M rh-chain/test/EsseyMarkets.t.sol` plus in-flight
changes) and the clean-tree gate exists precisely so a blog deploy cannot sweep code live.
**Blog-only means blog-only.** Handing the deploy to the PM/founder.

### One-line reads for future-me
- The failure that started this was a MISSING TRIGGER, not missing words. Every post in the backlog
  was already drafted or draftable from this log. Fix the trigger, not the writing.
- Publishing 2 of 3 is the point of having authority. An authority that publishes everything it is
  handed is not judgment, it is a conveyor belt.
- The reserve post is the highest-trust thing on the blog now: it corrects our own live false claim,
  names the surviving mutant, and names the limits of our own gate. That combination is the brand.

### 2026-09-03 — PM correction pass on `reserve-audit.md` (three errors, all mine, all fixed)
The PM ran an independent pass and caught three rail-2 failures before deploy. Recording them because
the pattern matters more than the fixes: **all three came from reading a DOC or a LIST instead of the
chain.** That is bible §18, the exact lesson I already had, and I broke it anyway.

1. **"Thirteen tokenized equities plus FLR" — wrong twice.** `reserve.ts:44-58` is a LOOKUP list of 13
   addresses INCLUDING FLR, and its own comment (`:41-43`) says a token in it that the reserve does not
   hold simply reads zero. I used a list length as a holdings count. FIXED by a live per-token read at
   **block 53939440**: all 13 are non-zero and `reserveOf == balanceOf` for every one —
   **10 tokenized stock/ETF tokens** (NVDA, AAPL, GOOGL, TSLA, GLD, SPY, MSTR, QQQ, NFLX, DJT) and
   **3 crypto** (CASHCAT, PONS, FLR 3,150,505.1706). Post now also states the list is a lookup list and
   not a census, so an unknown token sent in would show in neither.
2. **"It went live on 2026-08-29" had no source.** No deploy broadcast exists in `rh-chain/broadcast/`.
   DERIVED FROM CHAIN instead: earliest inbound `Transfer` to the reserve across all 13 tokens is
   **MSTR at block 49648574 = 2026-08-30 02:20 UTC** (08-29 local, which is where the old date came
   from). Post now cites the first-deposit block and UTC timestamp and makes no deploy-date claim.
3. **Do not point at the raw gate receipt.** Rewritten: what exists is an INTERNAL receipt with
   exploit-adjacent detail; a public WRITTEN REPORT needs a redaction pass and Erik's sign-off, per
   `docs/audits/README.md` fix-first. On a contract that can never be patched this is not a formality.

Also re-scoped the custody-gate paragraph to PAST tense ("the limit that version of the gate had") and
said plainly it is being tightened as I write, since the PM is changing it tonight — so the post cannot
overclaim a gate that is mid-change. Tightened the bytecode line to state the immutable/metadata masking
rather than a bare "byte-identical", and the summary from "a full adversarial round" to "one".
Same holdings error was present in `what-the-number-refuses.md:10` and is fixed there too.

**QUEUED, NOT TOUCHED (one problem one fix):** `posts/base-layer-live.md:18,22` says "Three tokens right
now" and "roughly 0.0093 MSTR" in the PRESENT tense. It was accurate on 2026-08-29 and is a dated
snapshot, so it is STALE not FALSE (MSTR is now 0.01874 and there are 13 tokens). Wants a dated update
note, not a rewrite, and not tonight. Flagged by name rather than absorbed into this pass.

**NOTHING DEPLOYED.** Both posts sit corrected in `posts/`; tree has lending work in flight.


## 2026-09-04 — CORRECTION: the anti-scam post carried a false claim (rail 1)

**What was false.** `posts/only-real-essey-contract.md:14` (LIVE on essey.xyz since 2026-09-01)
said: "There is no second contract, no 'v2', no bridge, no pre-sale address." A second token exists.
`app/web/src/live.ts:29` — `essey: "0x32a860B1Eaa02A07c0b8a9eB6E3c51B7ce823d1F" // $ESSEY v2 (8.888B supply)`.
Our own comment calls it v2, and `/faucet` gives it away. This was rail 1 of §33 (no-vapor: never state
something that is not true), broken on the page whose entire job is protecting people from scams.

**VERIFIED on chain before rewriting (not from docs, per §18/§36):**
| Fact | Value | Source |
|---|---|---|
| Mainnet $ESSEY | `0x3157…1610`, symbol ESSEY, name Essey, supply 8.888888888e27 | `cast` @ 4663, block 54450367 |
| Full supply location | 100% (8.888e27) at treasury `0x93e6…4B9E` | `balanceOf` @ 4663 |
| Game token | `0x32a8…3d1F`, symbol **ESSEY**, name **Essey**, supply **8.888888888e27** | `cast` @ 46630, block 112953517 |
| Same address on mainnet | `cast code` returns `0x` (no contract) | `cast` @ 4663 |
| Faucet drip | **500,000** per address per 28,800s (8h) | `esseyDrip()`/`cooldown()` on `0x9031…9d7d` @ 46630 |
| Game token is used in-game | `DonExchange.essey()` and `DonReserve.essey()` both return `0x32a8…3d1F` | `cast` @ 46630 |

**Two things the chain refuted that would have become NEW false claims:**
1. **The drip is 500,000, not 100,000.** The 100,000 figure lives in the stale code comment at
   `live.ts:41`. I read the storage var instead. §36 exactly: a comment is not a measurement.
2. **"Not tradable" is FALSE of the game token.** It is the pricing currency in the game's own AMM,
   so it does change hands. The honest and stronger argument is that it is handed out free on demand.

**The worst part, and it was not in the brief.** Symbol, name AND supply are IDENTICAL across both
tokens. The post's "how to check it yourself" steps told readers to confirm exactly those three, so
the recipe would have CONFIRMED the play-money token as genuine. A verification test that nothing can
fail is worse than none. Rewritten: the distinguishing checks are the CHAIN (4663) and the full address.

**What shipped.** Anti-scam message kept and sharpened, not softened. Scoped to "one $ESSEY on mainnet
4663, the only one that is a claim on the reserve". Added a play-money section (free faucet, moves
in-game, no claim, no code at that address on mainnet). "No pre-sale" replaced with the checkable fact
that 100% of supply still sits in the treasury wallet. **"No bridge" CUT, not softened** — a universal
negative I cannot prove, and that imprecision is what caused this. Dated correction note in the body;
`date:` deliberately UNCHANGED so the post does not fake its way to "Latest" off a correction.
No banned testnet-family wording (used "a separate chain, chainId 46630" + "play money"); note that the
brief suggested "a separate test network", which the founder's own standing rule bans, so I used the
stricter form that satisfies both.

**NOT DEPLOYED.** Blog-only means blog-only and the tree has lending work in flight. Correction is
committed to the file, awaiting a clean-tree deploy.

**FOUNDER DECISION, flagged not campaigned — [[essey-two-tokens-same-ticker]].** Two live tokens share
the ticker ESSEY (and name, and supply). Until the game token is renamed, which needs a game-side
redeploy, `/faucet` and the anti-scam post describe the same ticker in contradictory terms and every
future post has to carry this disambiguation paragraph. Recorded here as Erik's call. I am not
advocating a resolution in a post.

---

## 2026-09-04 — the 24-hour report: three posts committed, ZERO live, and the reason is a gate not a lapse

Founder asked directly for a 24-hour update and, first, whether anything published. Answer: **no.**
Recorded here with the primary evidence, because "why" is the whole finding.

### VERIFIED — what is live vs what is committed (checked against the deployed bundle, not recalled)

Fetched the live production bundle `https://essey.xyz/assets/index-BQOOG3UJ.js` (4,478,856 bytes) and
grepped it. Counts, verbatim:

| String | in live bundle |
|---|---|
| `reserve-audit` | **0** |
| `what-the-number-refuses` | **0** |
| `only-real-essey-contract` | 2 (the OLD, uncorrected body) |
| `no second contract` (the false claim) | **1 — STILL LIVE** |
| `repeated adversarial audits` (retired 09-03) | **1 — STILL LIVE** |

Corroborated a second way: `https://essey.xyz/og/only-real-essey-contract.png` returns
`content-type: image/png`, while `/og/reserve-audit.png` returns `text/html` — the SPA fallback, i.e.
no card was ever built for it, i.e. the post has never been through a production build.

The live "How to check it yourself" recipe (dumped from the bundle) still reads: paste the address,
**confirm name = Essey, symbol = ESSEY, supply = 8,888,888,888**. All three are IDENTICAL on the
play-money token `0x32a8…3d1F` (chain-verified 09-04, this log's previous entry). The published
recipe on our anti-scam page confirms the wrong token as genuine. The fix is in
`posts/only-real-essey-contract.md` at HEAD (commit `efe34aa`) and is not on the site.

`node app/web/check-blog-cadence.mjs` → BACKLOG, 1 day. `git log --oneline origin/main..HEAD | wc -l`
→ **31**. `git status --porcelain` → 5 modified files, all lending/contract work.

### THE ROOT CAUSE, and it is not "Erik was busy"

§33 grants me blog-content-only deploys. `~/.claude/bin/guard-deploy.py` (registered in
`settings.json:14`) blocks `vercel --prod` whenever `git status` is non-empty — correctly, per
[[essey-deploy-clean-tree-rule]]. So on any day the contract engineers have work in flight, my
blog-only authority is **structurally unexercisable**. Not overridden, not forgotten: gated.

That is §34 again in a new costume. The first cadence break was a missing trigger; this one is a
missing PATH. An authority that only works on days nobody is coding is not an authority, and I should
have named it on 09-03 when I first wrote "blog-only means blog-only" and handed the deploy off. I
logged the handoff and did not log that the handoff had no landing strip.

**Proposed mechanism, for Erik's call (NOT built, not inferred from a related yes, per §37):** a
blog-only publish path that builds from a clean checkout of HEAD in a temp dir rather than the working
tree, so the artifact is reconstructible from git — which is the actual property the dirty-tree gate
protects — and the in-flight lending work cannot ride along. That satisfies both rules instead of
trading one off. It is a code change to the deploy path, therefore his, not mine.

### THE 24 HOURS — grounded

Nine adversarial rounds on the lending engine, `docs/audits/glend-round-{1..9}.md`, receipts
`~/.claude/gate-receipts/audit-glend-r1..r9`. Verdict lines read from each file:

| R | Verdict |
|---|---|
| 1 | 1 CRIT · 1 HIGH · 3 MED · 4 LOW (`:12`) |
| 2 | 1 HIGH · 2 MED · 4 LOW (`:9`) |
| 3 | 1 CRIT · 1 HIGH · 3 MED · 2 LOW (`:9`) |
| 4 | 2 HIGH · 3 MED · 6 LOW (`:15`) |
| 5 | 0 · 0 · 2 MED · 3 LOW (`:15`) |
| 6 | 0 · 0 · 1 MED · 3 LOW (`:14`) |
| 7 | 0 · 0 · 0 · 2 LOW (`:27`) |
| 8 | 0 · 0 · 1 MED · 4 LOW (`:28`) |
| 9 | 0 · 0 · 0 · 2 LOW (`:49`) |

- **R1:** `IScaledUI` declares a two-word return; the deployed AAPL token
  `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` returns 32 bytes. The call succeeds, the decode fails.
  `glend-round-1.md:104-127`. **`-> 493 passed, 0 failed <-- all 493 pass while CRIT-1 is live`**
  (`:85`). Lending did not work at all against the real token.
- **R2 HIGH-1:** feed-first split liquidates a healthy borrower;
  `liquidator profit (USDG) 1 626 727 484 $1,626.73 (110% of the debt)` (`glend-round-2.md:84`).
- **R8 MED-1:** `accrue()` advances `lastAccrual` before the early return (`EsseyPool.sol:220-223`),
  so `address(0xBAD)` erases an entire unpaused year: `70.000000 USDG destroyed`, attacker cost `0`
  (`glend-round-8.md:785`). Permissionless.
- **R9 RULING 2:** refuted round 8's own "X-P survives" handoff. The mutant had been run against ONE
  test; the gate's `suite_verdict()` is defined over the whole SELECT suite (`test/mutants/glend-r4.py`).
  Re-run properly: 27 failures, 18 distinct assertion kills. The instrument was wrong, not the code.

**Not deployed, not pushed.** No `broadcast/*/4663` dir exists for any of it (re-checked 09-03). No
user has ever been exposed.

### THE THROUGH-LINE — the instrument, not the code

Erik counts twelve in 24 hours. I can cite these from the repo without taking anyone's word:

1. R1 — mock returned a shape the chain does not (`glend-round-1.md:104-127`).
2. R9 — mutation "survivor" scored against one test instead of the suite (`glend-round-9.md:112-130`).
3. R8 LOW-1 / R9 LOW-2 — the on-chain symptom check was documented as "now actually RUNS" and
   `launchctl list | grep liveness` returns nothing; the plist is still a `__REPO__` template
   (uncommitted `docs/MAINNET-ACTIVATION.md` diff, HIGH-2 row).
4. The custody gate asked whether the contract's NAME appeared, never whether a verdict was reached;
   a stale "UNAUDITED" line held the build green for a full day (`app/web/check-custody-audit.mjs:45-49`).
5. `b9dfa53` — the secret gate's own fix **printed "BLOCKED" and exited 0**, because it piped into a
   `while` loop and a pipeline runs in a subshell, so the failure flag never reached the parent. Its
   author's line: *"My verification was the confirmatory trap: I planted a PRIVATE_KEY and watched it
   block — the one shape the scanner already caught. Ninth instance of that shape this session, and
   this time it was mine."*
6. Same commit — four real secret shapes (`OPERATOR_PK`, `DEPLOYER_KEY`, a Slack webhook, an RPC with
   an embedded key) all PASSED an exempted template, because the content scan hunts the literal words
   `private_key` / `mnemonic` / `api_key`.
7. Carried from 09-02: the vault mock priced at exactly `220e8` so a truncation leak was fork-only;
   the hook mock served liquidity as a constant so a zero-liquidity walk was invisible.

The rest of Erik's twelve (a harness funding itself from a stranger's wallet, a job runner reporting
success for a run that never started) are HIS report to me and are not independently cited here.
Do not publish them as measured until they are.

**Gate rule changed today (founder, verbal):** three consecutive rounds with no CRITICAL/HIGH/MEDIUM;
LOWs logged and scheduled, not blocking; any code change resets the count. **FLAG:** this is not yet
written into `docs/MAINNET-ACTIVATION.md` — the G-LEND row at `:1744` still describes the old bar, and
`glend-round-9.md:734` still cites "a round with findings resets the counter." Two rules are live in
two places until someone reconciles it, and by round 10 nobody will remember which one was in force.

### BLOG-WORTHY
**"The Instrument Was Broken, Not the Code."** The strongest piece on the board and it is not
publishable today: it narrates unfixed, unpushed, undeployed lending internals. Publish after the push.
The four items that are safe NOW and need no code disclosure: the anti-scam correction (already
written, needs a deploy, not a draft), and a short honest note that our own verification recipe was
falsifiable-by-nothing. That second one is the publishable half of the through-line.

### NOT DEPLOYED. NOT PUSHED. Tree has lending work in flight; I did not touch it.

---

## 2026-09-05 — the blind-probe post, drafted (NOT deployed)

Cadence check fired (`node app/web/check-blog-cadence.mjs` → BACKLOG 1 day). Drafted
`app/web/src/blog/posts/never-gone-red.md`, "Erik Sent Stock to the Reserve to See If We Would
Notice", `2026-09-05T05:10:00`. Cadence now reports `current`.

**I did NOT write "The Instrument Was Broken, Not the Code."** My own 09-04 BLOG-WORTHY entry said it
narrates unpushed lending internals. It still does. This post is the publishable half I named there:
the verification recipe, not the engine.

### VERIFIED BY ME THIS SESSION (cast @ 4663 + repo, not inherited)
- AMZN `0x12f190a9F9d7D37a250758b26824B97CE941bF54`, symbol `AMZN`, name `Amazon • Robinhood Token`.
- Inbound to reserve: block **54794684**, **2026-09-05T03:20:13Z**, value **16911006449468234**
  (0.016911006449468234), tx `0xf106bc77cef6f97f3a659e6850c891c4f193fad7211f6c69af1c6c5b2ff23a32`.
- `reserveOf(AMZN)` == `balanceOf(reserve)` == same figure.
- EIP-1967 beacon slot `0xa3f0…3d50` on AMZN = `…e10b6f6b275de231345c20d14ab812db62151b00`,
  **byte-identical to AAPL as a control** (`cast storage`, both).
- `BASKET` is a hand-maintained array, `app/web/src/reserve.ts:44`; AMZN added at `:58`.
- `app/web/check-reserve-basket.mjs` (125 L): FAIL exits 1 (`:124`), WARN exits 0, `ACKNOWLEDGED`
  set at `:27`. Ran it: `15 token(s) ever received, 14 in BASKET, 0 unlisted equity, 0 unlisted other`.
- Style gate: reproduced BOTH globs over `515ca38^..515ca38`. Old (`*.ts *.tsx`) measures **1** added
  line; new (`+ *.mjs *.js`) measures **126**. My own numbers, not the commit's "1 of 94".
- **The BASKET fix is NOT SERVED.** Live bundle `assets/index-DGe5WYY2.js` (4,542,278 B) carries a
  13-address basket with **no AMZN**. §38 applied: I graded by what is served, and said so IN the post
  rather than implying the page is fixed.

### SOURCING I FLAGGED RATHER THAN DRESSED UP
Instance 3 (the grep that cleared a file it could not see into, and the mutated file captured as the
"pristine baseline") is real and I read the PRIMARY record — the engineer's own words in the session
transcript on disk, including his line that the mutant "sits on line 282, which contains no
`MAX_FORGIVEN_GAP` and so could not appear in that grep," and that the gateroot hash he recorded as
"pristine before" was byte-identical to the mutated file. **There is no committed artifact for it.**
So I published it at the MECHANISM level only: no constant name, no file, no line, no subsystem, no
counts. Nothing in the post depends on a number that lives only in a transcript (§33 rail 2).

### RAILS HELD
No lending internals, no mutation-gate counts, no audit-round verdicts, no claim the reserve is
audited beyond the one round already published, nothing implied live that is not. Zero em-dashes,
zero banned §28 crutches (checked). Front-matter passes the `prerender-blog.mjs` guardrail (parsed it
the way the build does). Explorer link for the tx was CUT: `blockscout` sits behind a Cloudflare
challenge and my negative control (a bogus hash) returned the same 200, so the link was unverifiable
under §19. The bare tx hash stays, which the reader can paste.

### NOT DEPLOYED, NOT PUBLISHED
Deploy path is blocked in the coordinator's session, so a human moves it either way. Draft only.

### 2026-09-05 — PM correction on `never-gone-red.md`: the self-falsifying tense (FIXED)
The PM caught a defect my own thesis makes fatal. The disclosure paragraph read "As I write this, the
corrected list is committed and the bundle serving essey.xyz still carries the old thirteen." True
when written, FALSE the instant it publishes: the post and the BASKET fix are in the same working
tree, so one `vite build` ships both. A reader following my own instruction to grep the served
JavaScript would have found fourteen addresses and AMZN present, one paragraph after being told they
would not. **The post would have falsified itself on arrival, on the one claim where I told the
reader to go check.**

RE-ANCHORED IN TIME rather than hedged or deleted, because the disclosure is why the paragraph earns
its place: the fix was committed at **03:54 UTC** (`515ca38`, `2026-09-04 20:54:13 -0700`) and was
still not served **eight hours later** when I pulled the live bundle (~11:50 UTC). The post now says
that shipping it is what shipped the fix. Stronger line, and it survives publication.

Second instance of the same trap fixed at `:38`: "Today it reports 15 tokens ever received" →
"When I ran it while writing this it reported...". A gate's output is a measurement with a timestamp,
not a standing property.

Swept the rest. `:12` "still sitting there" checked rather than assumed: `receiptCount()` = **0** and
AMZN `balanceOf` unchanged at `16911006449468234`, and the reserve has no withdrawal path but
burn-and-claim, so the claim is durable, not merely true-today. `:20` "the page queries the things on
that list" is a description of the mechanism, which the fix does not change, so it stays.

**THE GENERALIZATION, and it belongs with §38.** §38 was "grade a fix by what is SERVED, not what is
COMMITTED." This is its twin: **a post about deploy state is itself a deploy, so any present-tense
claim about what is live is a claim about the world AFTER the post ships, not before.** Before
publishing, re-read every present-tense sentence as if the deploy already happened. If it goes false,
anchor it to a timestamp. The PM also confirmed the "1 of 94" discrepancy was real (measured
pre-prettier); my reproducible 126 is the right number to print.

Post re-linted after the edit: 0 em-dashes, 0 banned §28 phrases, front-matter guardrail passes,
cadence `current`. STILL NOT PUBLISHED, NOT DEPLOYED, founder has not ruled.

### 2026-09-05 — DRAFT `fourteen-could-not-remember` (agent memory rebuild) + a live defect found while verifying it
Second draft of the day, alongside `never-gone-red` which is still unruled. Subject: `1af1a84` gave all
15 agents a continuity file, routed `docs/agents/LESSONS.md` by role via `tools/lessons.py`, added
`tools/runlock.py`, and wired `app/web/check-agent-wiring.mjs` into the build.

VERIFIED FOR THE POST: `docs/agents/` did not exist at `1af1a84^` (`git ls-tree` returns nothing);
15 continuity files; jester charter line 25 quoted exactly; routing checked by DIFFERENCE across three
roles (engineer 7 incl. the tree-corruption pair, jester 7 incl. the served-vs-committed pair, research
intern 5 universals, 9 on file); wiring gate watched failing twice on a scratch COPY (untagged lesson,
missing continuity file) and passing 15/0 against the real tree.

CUT: the brief's claim that the coordinator's memory dir is "unreadable by any subagent." I read it,
exit 0. True version: nothing points any agent at it.

DEFECT FOUND, NOT MINE TO FIX: `runlock.guard()` returns the lock and the caller must keep it. Dropped,
CPython closes the file and the flock releases at once. `rh-chain/test/mutants/glend-r4.py:374` drops it.
Two-process A/B: bound -> BLOCKED, exit 2; dropped -> second run ACQUIRED, and `--list` said "in flight:
nothing" during a live run. Every charter now tells agents to run that `--list` before a long job.

### NOT DEPLOYED, NOT PUBLISHED
Written to `app/web/src/blog/drafts/`, which is gitignored and not globbed, so it cannot render. Founder
ruling pending on both drafts. This is the first post that would state publicly that the team is agents.
