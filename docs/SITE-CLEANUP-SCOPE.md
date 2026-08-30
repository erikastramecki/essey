# Site cleanup / mainnet-reconciliation scope (2026-08-29)

Execution checklist for **essey-web-designer**. Grounded per-page audit of both web apps after the base
layer went live on RH mainnet. KEY FRAMING (verify before acting): the mainnet base layer ($ESSEY
`0x315790…1610`, EsseyReserve `0xd970Ca…5A7b`) is referenced NOWHERE in either repo — the game/markets
layer is *deliberately* testnet while mainnet is a separate curated beta. So this is mostly (a) copy that
falsely says "not on mainnet", (b) dead/test/demo removal, (c) one wrong explorer-link block. **Do NOT
blanket-relink the game/markets to the base-layer addresses — different contract sets.** Each item below
must be re-verified against the live code (line numbers drift) and, for copy, against the deployed contract.

## Two apps
- `assay/app/web` — essey.xyz, game-first main site (~20 routes). Config `live.ts:14-21`, `don-config.ts:5-18` (testnet 46630).
- `essey-markets/web` — Essey Markets lending demo. Config `chain.ts:21-38` (testnet). NOTE: `Treasury.tsx`/`reserve.ts` are being wired to mainnet separately — don't touch those.

## QUICK WINS (mechanical, low risk)
1. `App.tsx:597-604` footer + `market.tsx:83,249-252` + EngineSection: reword blanket "not on mainnet" → the true split (base layer $ESSEY+floor LIVE on mainnet; game season on testnet Scrip).
2. `docs.generated.ts` `DOCS_BRANCH` "feat/essey-market-layer" → `main` (regenerate) once merged — fixes `App.tsx:769-770` source links.
3. `builder.tsx:319` delete dead `MINT_LIVE=true` branch (dead code at `:863-864,1139-1147`).
4. `don-config.ts:9,12-17` delete never-read `DON_NET` fields (essey/reserve/bell/exchange/loan/feeRouter/affinity); `usePortfolio.ts:17,26` drop unused `loading`.
5. `coming.tsx:10` cut the 5 unwired tickers (only aapl+nvda wired, `live.ts:44-45`) or mark pending.
6. `game/house.tsx:217-228` add "later posting" disclaimer to (or drop) the BROKER box.

## LARGER REMOVALS (decision needed)
1. **DELETE `/launch` operator console** — `operator.tsx` + route `App.tsx:179-186` + nav `:82` + import `:31` + `live.ts:385-467` launchpad block. `backedAssetFactory` is `0x0` (`live.ts:67`), page only ever shows the not-deployed gate. Strongest single removal.
2. **`/faucet`** (`faucet.tsx`) — testnet drip as top-level nav; gate to the game or remove from nav (`App.tsx:73`). Copy `:83` "everything runs on testnet" now false at base layer.
3. **`explorer.tsx`** — remove dead PROOF/VERIFY column (`:300-312,781,792-794` fetch nonexistent `/proof/*.json`) + permanent "—" price columns (`:457-460,710,748,755`). PEGS table (`:700-711`) hardcodes mainnet blockscout + UNVERIFIED addresses under a "verified" pill — verify each on-chain or drop the pill; move to a config constant.
4. **essey-markets whole app** — self-labeled testnet demo, separate contract set. Going mainnet = a real deploy project (delete `Faucet.tsx` + `chain.ts:63-64,396-402` drip, relink `chain.ts:22-43`, resolve stubbed Perps `Perps.tsx:24-46`). Decide its fate vs the main-site markets narrative (duplicate tagline).

## COPY to VERIFY against contracts before trusting (don't assert)
- `builder.tsx:959-960,1080-1082` "100% of fee buys stock for holders" vs testnet `feeRouter=0x0`/treasury sink — confirm deployed DonDistributor sink.
- `portfolio.tsx:100` "borrowing coming to testnet" — confirm still gated vs live.
- `explorer.tsx:167-170` PEGS mainnet addresses — confirm on-chain before any "verified" claim.
- `App.tsx:102`, `Markets.tsx:146` "machine-proved loans" tagline vs `Proof.tsx:47-50` (verifier "not yet wired into the pool") — reword to match reality.

## KEEP (clean/honest — no action)
`/private` (trim `:468` stub), `/lend`, `/how-to-play`, `/tape`, `/portfolio`, `notfound`, Markets/Perps/Proof copy that's already honestly stubbed. essey.xyz game pages correctly use the TESTNET explorer for testnet contracts — leave those.
