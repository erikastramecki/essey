# Payout-token expansion — verified scoping (2026-08-12)

Scope: expand the Bell's electable payout universe from {AAPL, NVDA, USDG passthrough, BUNDLE
default} to (a) the broader Robinhood-Chain tokenized-stock universe, (b) **$ESSEY** as an electable
payout, (c) **ETH** as a payout option. Everything in §1 was verified against **live mainnet**
(chainId 4663, `https://rpc.mainnet.chain.robinhood.com`) on 2026-08-12 — nothing trusted from
memory, docs, or explorer labels.

---

## 1. Verified mainnet table — what exists

**Canonicity method** (the same proof standard as `MAINNET-CONFIG.md`): a candidate token is
official iff its EIP-1967 **beacon slot reads `0xe10b6f6b275de231345c20d14ab812db62151b00`** (the
beacon the already-verified AAPL points to) AND `decimals()=18`, `uiMultiplier()=1e18`,
`paused()=false`. Feeds are proxy addresses from Chainlink's own directory JSON
(`reference-data-directory.vercel.app/feeds-robinhood-mainnet.json`, 56 feeds), each read live via
`latestRoundData()` (dec=8, fresh inside the 24h heartbeat). Token discovery: Blockscout search on
the real explorer host (`explorer.mainnet.chain.robinhood.com` → `robinhoodchain.blockscout.com`)
— `docs.robinhood.com/chain/contracts` renders its token table client-side from an on-chain
registry and statically lists only WETH/USDG, so it cannot be used for discovery.

### Newly verified this round (all four checks passed)

| Ticker | Token (beacon-proven) | Feed (read live) | Price @ check | Feed age |
|---|---|---|---|---|
| **PLTR** | `0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A` | `0x820ABedFF239034956B7A9d2F0a331f9F075eB4c` | $170.75 | 2.1h |
| **GME** | `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` | `0x27C71df6A64fB476468EdF256CF72c038baB5B67` | $18.58 | 4.9h |
| **AMD** | `0x86923f96303D656E4aa86D9d42D1e57ad2023fdC` | `0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72` | $483.40 | 1.4h |
| **USAR** | `0xd917B029C761D264c6A312BBbcDA868658eF86a6` | `0xA994d3684e8400A6c8078226925779FdeE682DD9` | $18.34 | 41m |
| **SPCX** (SpaceX Class A) | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` | `0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb` | $146.24 | 27m |

⚠️ **The beacon check is load-bearing:** Blockscout returned **impersonator tokens with the exact
official display name** — "GameStop • Robinhood Token" at `0x1c8a…80F4` and "␣USA Rare Earth •
Robinhood Token" at `0x38D6…2Ea1` — both with a **zero beacon slot** (fakes). Never list a token
off an explorer name; always run the four-check proof.

### Already verified (2026-08-11, `MAINNET-CONFIG.md` registry — unchanged)

AAPL `0xaF3D…93f9` · NVDA `0xd060…9EEC` · TSLA `0x322F…03b2d` · SPY `0x117c…4C0C` ·
MSFT `0xe932…2e74` · GOOGL `0x2e08…4FE3` · AMZN `0x12f1…bF54` · META `0xc0D6…2f35` ·
QQQ `0xD5f3…de68` — each with its `RobinhoodFeeds.sol` feed.

### Not found / not shippable (honest negatives)

| Candidate | Result | Discovery methods tried |
|---|---|---|
| **GOOG** (Alphabet C) | **No feed exists** (directory has GOOGL only) → unlistable regardless of any token. Ship GOOGL. | Chainlink directory (56 feeds), `RobinhoodFeeds.sol` |
| **OpenAI** | **Not found**: no feed in the directory; every explorer match for OAI/OPENAI/OpenAI is a memecoin (none beacon-canonical). No address discovered ≠ proven nonexistent — but with **no Chainlink feed it is unlistable today** even if a token appears. | Chainlink directory, Blockscout search (3 query patterns), docs contracts page, `MAINNET-CONFIG.md` |

### The universe is bigger than our snapshot

The Chainlink directory now carries **35 Robinhood equity feeds** (`RobinhoodFeeds.sol` snapshots
only 9 — stale; regenerate with `script/fetch-feeds.mjs`, its 86400s-heartbeat assertion still
passes). Additional feed-backed tickers available for future config-adds once their tokens pass the
beacon proof: ASML, BABA, CLSK, COIN, CRCL, CRWV, DELL, EWY, INTC, IONQ, MSTR, MU, NBIS, ORCL,
RGTI, RKLB, SGOV, SLV, SNDK, TSM, USO.

---

## 2. What each addition class requires

**Bell: ZERO changes — confirmed.** The elect list is entirely converter-driven
(`setPayout` → `converter.isSupported`), and every slice already fails open per-slice
(`_deliver` try/catch → base USDG). Proven by the new test
`test_ConfigOnlyStockExpansion` (`rh-chain/test/BundleConverter.t.sol`): stocks listed on an
**already-wired** converter become electable and pay out, with no Bell change.

**The one hard constraint — immutability sequencing.** `Bell.converter` and `Bell.defaultPayout`
are immutable, and on the Dons stack the Bell itself is pinned one-shot
(`distributor.setBell`/`setDonHook`), so **the converter contract shipped at #81 is permanent**:
swapping it later = full-stack redeploy + holder migration. What stays open forever is the
converter's own **append-only config** (`listStock`/`seedReserve`/`addBundleMember`, bankroll-only,
works after `initBell`). Consequence:

- **New payout *tokens* with a Chainlink feed** → config, addable any time post-deploy.
- **New payout *classes* needing new price plumbing** (ESSEY: no feed; ETH: 24/7 asset under an
  equity session gate) → must be in the converter **code at #81** or they are locked out.

### Class (a) — more tokenized stocks: **config-only**

Per ticker: beacon-proof the token, verify the feed, `listStock(token, feed)`,
`seedReserve` (real shares — the standing B2 rule: mainnet inventory must be *acquired*, not
minted), add a UI entry. No audit round. Bundle membership is a separate, deliberate choice — the
bundle splits **equal parts**, so a wide bundle makes small claims fail `DustAmount` (→ USDG
fallback); keep the bundle a curated 4–6 names and let the *elect* list be wide.

### Class (b) — ETH: config-possible, small code change preferred

- **Config-only path (works today):** `listStock(WETH, ETH_FEED)` on the existing converter —
  WETH `0x0Bd7…AD73` and ETH/USD `0x78F3…d3A9` are both verified; `_fairOut`'s 18-dec/8-dec math is
  generic. **Wart:** the converter session-gates *every* listed token, so ETH slices would settle
  only in the 14:30–20:00 UTC weekday window and fail open to USDG the rest (~73% of hours). Safe,
  disclosed, but wrong-shaped for a 24/7 asset. (Holiday-print check is a non-issue: ETH moves
  >0.5% intraday, the feed prints.)
- **Code path (recommended, pre-#81):** a per-token **session-exempt flag** on the listing
  (crypto legs skip `NotInSession`, exactly as the base USDG leg already does). ~10–15 line diff to
  `BundleConverter` + one audit round + tests. Inventory stays WETH seeded by bankroll.
- **ETH as *default*:** recommend **no** — `defaultPayout` is immutable and a session-gated (or
  even 24/7) single-asset default is strictly worse than the BUNDLE; keep ETH elective.

### Class (c) — $ESSEY: **new code, unavoidable**

`listStock` requires a Chainlink feed; $ESSEY will never have one at launch. Design in §3.

### UI (the elect mixer)

`app/web/src/live-ui.tsx` hardcodes the list in three places (`prefKey` L16, `MIX_TOKENS` L269,
the single-choice row L400). Refactor to one `SUPPORTED_PAYOUTS: {key, addr}[]` table (reuse, don't
build a sibling) when the expanded stack ships. **Do not widen it before then** — see §5's testnet
finding.

### Deploy-checklist delta (`MAINNET-DEPLOY-CHECKLIST.md`)

- §D/E-step-1 (converter first): the converter deployed must be the **expanded, audited** build if
  the ETH/ESSEY legs are wanted (they cannot be retrofitted); the `listStock` sequence grows to the
  §6 ticker set; `seedReserve` per ticker with real shares.
- Regenerate `RobinhoodFeeds.sol` from the directory (9 → 35 equity feeds) as part of the deploy
  round (constants change → include in the audit round's diff).
- New ops line: per-ticker reserve top-up from converter treasury proceeds now spans ~14 names.

---

## 3. $ESSEY as an electable payout — design + risk

Peer elector data says most members (~80%) choose the protocol token when offered — this is the
highest-leverage addition, and it is also structural demand for $ESSEY *if the mechanism actually
buys*. Two mechanisms:

**A. Claim-time swap through the ESSEY/USDG V3 pool** (the `StockConverter` shape, Router02).
Every ESSEY-elected slice market-buys $ESSEY with pot USDG → **real, recurring buy pressure** on
every ring. Risk: there is **no external oracle** to anchor `amountOutMinimum`.
- Spot-anchored minOut is **not acceptable**: `claim()` is permissionless, so an attacker can
  trigger claims and sandwich them at will through our own thin pool, extracting from claimants.
- **TWAP-anchored minOut** (e.g. 30-min Uniswap V3 TWAP, `minOut = twapFair × (1 − slippageBps)`,
  bps ≤ 500) is the workable variant. Residual surface: *moving the TWAP itself* — a sustained
  30-min price push against protocol-owned liquidity; cost scales with pool depth, loss is bounded
  by `slippageBps`. Mitigations: deep POL before activation, longer window if depth stays thin,
  optional per-claim notional cap.

**B. Treasury-provided ESSEY desk** (the BundleConverter's own inventory doctrine): add-only ESSEY
reserve, paid at TWAP-derived desk rate minus spread, no pool touched at claim time → no sandwich
at all; the only surface is again the TWAP. **But** it *distributes* treasury ESSEY and banks the
USDG — no buy pressure unless paired with a treasury buyback loop. It also consumes the fixed
treasury allocation.

**Fail-open: fully covered.** Any revert on the ESSEY leg — pool missing, TWAP cardinality/history
insufficient, minOut unmet, reserve short — is caught per-slice by `Bell._deliver` and the slice
pays USDG. A payout can never be blocked by the ESSEY leg; it can only decline into base.

**Recommendation: mechanism A** (TWAP-anchored pool swap). The buy-pressure flywheel is the point
of the feature; B recreates the payout without the demand. Size: ~200–300 LOC (V3 TWAP reader +
Router02 swap leg + append-only crypto listing) as an extension of the converter, full 3-agent
audit round, fork-battery tests against the real router/pool (the WETH/USDG fork battery is the
template).

**Sequencing (this decides #81 vs fast-follow):** the ESSEY/USDG pool **cannot pre-exist** —
$ESSEY deploys fresh at #81 (`MAINNET-CONFIG.md` blocker 3) and the pool + POL seeding is a
post-deploy step; a TWAP additionally needs observation cardinality + warm-up. So the ESSEY
election **cannot function on day one no matter what**. But because the converter is permanent
(§2), the *capability* must ship in the #81 converter, designed so the ESSEY listing itself is a
**post-deploy append-only config call** (list-with-pool instead of list-with-feed). Net: **code +
audit before #81; activation fast-follows** pool seeding + TWAP warm-up (days, an ops gate, not a
code gate).

---

## 4. Effort per addition class

| Class | Contract code | Audit | Ops | UI |
|---|---|---|---|---|
| (a) more stocks (feed exists) | **none** | none | beacon-proof + `listStock` + acquire/seed real shares | 1 list entry |
| (b) ETH, config path | none | none | seed WETH reserve | 1 entry + session-window copy |
| (b) ETH, session-exempt flag | ~10–15 lines | 1 focused round | same | same |
| (c) ESSEY leg (TWAP swap) | ~200–300 LOC | full 3-agent round + fork tests | create/seed pool, warm TWAP, then 1 config call | 1 entry + flywheel copy |

---

## 5. Testnet status (what was and wasn't done, and why)

**Chain-verified finding:** the live testnet Dons Bell `0x8a77…0552` was deployed with
**`converter = address(0)` and `defaultPayout = address(0)`** (read on-chain 2026-08-12). Both are
immutable. The only deployed BundleConverter (`0x3c6a…7fb0`) is **one-shot `initBell`-wired to the
retired Seats-era Bell** (`0x31115d…8d0d`). Consequences:

- `DEPLOYMENT-testnet.md`'s "Bell … BUNDLE default" line for the Dons stack is **stale vs chain**:
  the live Dons Bell is base-USDG-only.
- Every non-empty `setPayout` election against the live testnet Bell **reverts**
  (`UnsupportedPayoutToken`) — the `/trade` payout-mix panel cannot function on the current stack.
- "Wire new mock stocks into the testnet converter" is therefore **not a config-only change on the
  live stack**: it needs a new converter *and* a new Bell, and the distributor's `setBell` /
  `setDonHook` are one-shot → **full Dons-stack redeploy**. Not low-risk; not done.

**What was done instead (safe, green):** `test_ConfigOnlyStockExpansion` in
`rh-chain/test/BundleConverter.t.sol` proves the exact claim the testnet exercise was meant to
prove — new mock stocks (TSLA $330, PLTR $165) listed on an **already-wired** converter, a 3-way
50/25/25 election accepted only *after* listing, and one `claim` delivering all three legs
oracle-fair into the Vault. 16/16 suite tests pass. No contract code was changed (audit-gate rule),
no UI change (widening the mixer against a Bell that rejects all elections would ship a broken
control).

**Next testnet Dons redeploy** (whenever one happens for other reasons): deploy the converter
FIRST with the expanded mock set (AAPL/NVDA/TSLA/PLTR/AMZN + feeds, the `DeployBundleConverter`
pattern), pass `CONVERTER`/`DEFAULT_PAYOUT` env to `DeployDons`, run `WireConverterBell`, and the
FeedKeeper cron must stamp the additional mock feeds (each mock feed goes stale in ~25h).

---

## 6. Recommendation — the #81 ticker list

**Ship at #81 (verified-only, config-only, 14 electable):**
AAPL · NVDA · TSLA · MSFT · GOOGL · AMZN · META · SPY · QQQ · **PLTR · GME · AMD · USAR · SPCX**
— every one has a beacon-proven token + a live proxy feed. Keep the **BUNDLE default a curated
subset** (suggest AAPL/NVDA/TSLA/SPY) to avoid equal-split dust fallbacks; USDG passthrough stays
the opt-out.

**Wait:** GOOG (no feed — GOOGL covers Alphabet), OpenAI (nothing official on-chain), and the 21
other feed-backed directory tickers (config-add any time post-deploy once each token passes the
beacon proof — no redeploy ever needed for these).

**ETH:** ship the session-exempt flag in the #81 converter (small diff, rides the same audit round
as the ESSEY leg); if the round slips, fall back to config-only WETH listing with the disclosed
settlement window.

**$ESSEY:** capability (TWAP-anchored swap leg) **must be in the #81 converter** — it cannot be
retrofitted. Activation is a **fast-follow** config call after the ESSEY/USDG pool is created,
POL-seeded, and the TWAP is warm. Do not gate the deploy on the warm-up; do gate the converter
build on the audit round.

**The one decision that cannot be deferred:** whether #81's converter ships with the ETH/ESSEY
code legs. Everything else in this doc is reversible or post-deploy addable; that isn't.
