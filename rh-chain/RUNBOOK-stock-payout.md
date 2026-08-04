# Stock-payout deploy runbook (testnet)

Enables real-stock Bell Payouts (hybrid: default bundle + opt-in single stock, USDG fail-open). This
is a **fresh market stack** — the Seat hook is one-shot, so a converter-wired Bell needs a new
Seat+Bell+Exchange+Cases. Current testnet Seats/tiers/quest progress reset. Built + 3-round-audited
clean (feat `de27380`); converter deploy dry-run-validated against real chain (~3.4M gas).

## Prereqs
- **Run DURING a US market session: 14:30–20:00 UTC, weekday.** Off-session the converter reverts and
  the claim proof fails open to USDG (by design). Deploying in-session also stamps the MockFeeds fresh
  (the holiday guard needs `feed.updatedAt >= session open`).
- Deployer key in gitignored `rh-chain/.env` as `PK`; RPC alias `rh_testnet`; `FOUNDRY_PROFILE=script`.
- Reused (existing) addresses — the pool + its markets keep working:
  - `USDG=0x7461E670d44FF4397A3E48030C5b06f6163a5De2`
  - `USDG_FEED=0x6ac94CAb7302415A9a29d9746Fb6051523592E3b`
  - `AAPL=0xaC6cd493e69eb82e8f113E33De8e5542F313B731`
  - `NVDA=0x8393cc99FAC1CF79E3bEceA56f344159ddFd91E9`
  - `QUEST=0x3DD40673665e13bD4A8A7B1D6e27Cb43EDfE0427`
  - `POOL=0x283a4891458180f502E82E40470d3e06321ba748`

Each step prints the new addresses; feed them into the next step's env.

## Steps
1. **Converter + reserve** — prints `CONVERTER`, `BUNDLE` (0x…B0B1), feeds:
   ```
   USDG=$USDG USDG_FEED=$USDG_FEED AAPL=$AAPL NVDA=$NVDA \
   FOUNDRY_PROFILE=script forge script script/DeployBundleConverter.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
   ```
2. **Market (fresh Seat+Bell+Exchange+Cases, hook wired)** — prints `DISTRIBUTOR SEAT ESSEY BELL EXCHANGE CASES SEATART`:
   ```
   USDG=$USDG USDG_FEED=$USDG_FEED CONVERTER=<step1 CONVERTER> DEFAULT_PAYOUT=<step1 BUNDLE> \
   FOUNDRY_PROFILE=script forge script script/DeployMarket.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
   ```
   (deployer == admin, so DeployMarket also runs `wireAll` — setSeatHook + SeatArt.)
3. **Gate convert() to the Bell** (must run before payouts settle in stock):
   ```
   CONVERTER=<step1 CONVERTER> BELL=<step2 BELL> \
   FOUNDRY_PROFILE=script forge script script/WireConverterBell.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
   ```
4. **Seed the market** (float, Case inventory reusing AAPL/NVDA, faucet) — prints new `faucet`:
   ```
   DISTRIBUTOR=<s2> SEAT=<s2> ESSEY=<s2> EXCHANGE=<s2> CASES=<s2> USDG=$USDG AAPL=$AAPL NVDA=$NVDA \
   FOUNDRY_PROFILE=script forge script script/SeedStockMarket.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
   ```
5. **Redeploy QuestLens** with the new Seat — prints new `LENS`:
   ```
   QUEST=$QUEST SEAT=<s2 SEAT> POOL=$POOL AAPL=$AAPL NVDA=$NVDA \
   FOUNDRY_PROFILE=script forge script script/DeployLens.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
   ```
6. **Update the frontend + docs**: `app/web/src/live.ts` ADDR (`converter`, `seat`, `bell`, `exchange`,
   `cases`, `lens`, `faucet`) — keep `usdg/aapl/nvda/pool/quest` — and `docs/DEPLOYMENT-testnet.md`.
7. **Prove it (in-session)**: connect → drip → buy a Seat → stake a Tier → grow the pot (buy a few) →
   ring → set payout to Bundle (default) → **claim, confirm AAPL+NVDA land in the Vault**. Capture it.
8. **Flip prod (#2)**: `git checkout main && git merge --ff-only feat/essey-market-layer && git push origin main`
   (triggers the Vercel prod deploy to essey.xyz). Merge only after step 7 passes.

## Rollback
No reset of the *reused* tokens/pool/quest. If a step fails, re-run it (scripts are idempotent-ish per
deploy; a partial market deploy just needs re-running from the failed step — nothing is wired to the old
Bell). Until step 3 runs, convert() reverts and payouts fall open to USDG — safe.
