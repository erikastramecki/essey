# Essey Private — Testnet E2E Report (shielded / privacy money flows)

_Chain `46630` (Robinhood Chain testnet). Explorer: `https://explorer.testnet.chain.robinhood.com/tx/<hash>`._

Every privacy flow driven **client-side through the exact modules the `/private` UI uses** — `app/web/src/poolsdk.ts`
(depth-20 Groth16 prover) and `app/web/src/stealth.ts` (ERC-5564 secp256k1) — broadcasting real testnet
transactions with real proofs. This is the privacy-layer counterpart to `docs/TESTNET-E2E.md` (the 109/109 Don
harness). Actor / gas wallet: `0x976EBff4…993D`.

## Summary

| Flow | Proof time | Status |
|---|---|---|
| (a) shielded **USDG** pool — deposit → withdraw | 1.8s / 1.4s | ✅ VERIFIED |
| (b) shielded **AAPL** — deposit → withdraw | (p1b) | ✅ VERIFIED |
| (b) shielded **STOCK** — issuer `adminBurn` → **pro-rata haircut** | 1.5s / 1.3s | ✅ VERIFIED (identical-bytecode instance — see note) |
| (c) shielded **NVDA** — deposit → withdraw | 1.5s / 1.3s | ✅ VERIFIED |
| (d) shielded **SUPPLY** (private yield) — supply → redeem | (p1b) | ✅ VERIFIED |
| (e) **stealth pay** — register → pay → view-key scan → sweep | n/a (secp256k1) | ✅ VERIFIED |
| USDG private **transfer** + cross-recovery (bonus) | (p2) | ✅ VERIFIED (assertion-based, see note) |
| **relayer** (gasless `viaRelayer`) path | n/a | ⚠️ **CODE VERIFIED — production GAP: `RELAYER_PK` unset in Vercel** |

> **On proof time:** proving ran locally at **~1.3–2.0s per proof** (local wasm/zkey artifacts + fast node), not
> the 30–120s a cold browser can see. All times above are observed, not estimated.

## Per-flow detail (real tx hashes)

### (a) shielded USDG pool — deposit → withdraw  ✅
`ADDR.shieldedPool` `0xcD79…29aB`. Deposited 100 USDG into a hidden note, withdrew the full note to a fresh sink;
recipient delta = exactly 100e18.
- deposit — [`0x7d9b…f313`](https://explorer.testnet.chain.robinhood.com/tx/0x7d9b9417a6ce48fa947c9f7bbbfc7378f8eaef03e35b1a844da893988c58f313)
- withdraw — [`0x2f2b…222c`](https://explorer.testnet.chain.robinhood.com/tx/0x2f2b8820b3b06d8c9526154b451a8324761a301d176548c8ec9affc3e00c222c)

### (b) shielded AAPL — deposit → withdraw  ✅
`ADDR.shieldedStockAapl` `0x49f1…Ae53`. Recipient received exactly 100 AAPL from a hidden note (pool solvent → par).
- deposit — [`0xb66e…c35a`](https://explorer.testnet.chain.robinhood.com/tx/0xb66e8ee646cd8ef0a7239bbb0915d2ee106c4d586d7208e03db674cfe773c35a)
- withdraw — [`0x96b1…fe63`](https://explorer.testnet.chain.robinhood.com/tx/0x96b1caf422ea787f218a65c56f9dc6fb21aca0456731775c88baf75b7aeffe63)

### (b) shielded STOCK — issuer `adminBurn` → pro-rata haircut  ✅  _(identical-bytecode instance)_
Deposited 100 → issuer burned 40% of the pool's backing → withdrew the **full 100-note**: recipient received
**exactly 60** (the `previewWithdrawable`/`quoteHaircut` value), `isImpaired()==true`, `totalShielded` 100→0. The
note was **consumed, not frozen** — the holder exits at the live solvency ratio, no bank run.
- deposit — [`0x2e19…d193`](https://explorer.testnet.chain.robinhood.com/tx/0x2e19646a5f15d4c8dbf6c7f732bb1dcdbca5af8a809d53a2fe4b78900087d193)
- issuer `adminBurn(pool, 40)` — [`0x7c7b…cb11`](https://explorer.testnet.chain.robinhood.com/tx/0x7c7b4343284caf2efe0d9678f7b1a277de4af0b3d6e90f17a1a6e97ddafbcb11)
- haircut withdraw (paid 60/100) — [`0xfdf0…6c0c`](https://explorer.testnet.chain.robinhood.com/tx/0xfdf040539b0a80046c6a1f00eb33d0a7d1e86c7ef90d359a842f78d343d16c0c)

> **Why an identical-bytecode instance, not the live AAPL/NVDA pools:** the live shielded-stock pools are wired to
> the testnet stock tokens `0xaC6c…` / `0x8393…`, which are plain **`ERC20Mock`** ("E20M") — they expose **no**
> `adminBurn`/`burn`/`burnFrom` (verified on-chain). The impairment scenario therefore **cannot be triggered against
> the live pools**. The haircut was proven end-to-end against a **throwaway `EsseyShieldedStock` of identical
> bytecode** reusing the live AAPL pool's **same** depth-20 verifier (`0x0BAe…EffA`) and Poseidon hasher
> (`0xA074…7dbb`), backed by a `BurnableStock` mock that does expose the issuer-burn hazard. The accounting under
> test (`totalShielded` / `quoteHaircut` / `isImpaired`) is the deployed contract's, unchanged.
> Throwaway pool `0x9e3067a2b3403da33c099408d30a1e33b35db102`, stock `0xbf22bfdc122a5bd4054c6e09d5c29445ba404a63`.
> The contract-level socialization / order-independence invariants are additionally proven by
> `rh-chain/test/EsseyShieldedStock.t.sol`.

### (c) shielded NVDA — deposit → withdraw  ✅
`ADDR.shieldedStockNvda` `0x8e35…9cB3`. Recipient delta = exactly 100e18.
- deposit — [`0x5549…5800`](https://explorer.testnet.chain.robinhood.com/tx/0x5549fbeb4b19696bd214446334b0b3667f2dd335f0d099981fb8a7fab1705800)
- withdraw — [`0xac1f…fe20`](https://explorer.testnet.chain.robinhood.com/tx/0xac1f53efaa86e2ec78b75fb0377421e188320132b1a63b264f03c5fde01efe20)

### (d) shielded SUPPLY (private yield) — supply → redeem  ✅
`ADDR.shieldedSupply` `0xeF52…EecC` wrapping the ERC-4626 lending pool `0x283a…a748`. Supplied 100 USDG (shielded as
`previewDeposit` shares), redeemed the share-note → recipient received ≥ principal (principal + any accrued yield).
- supply — [`0x57e3…945e`](https://explorer.testnet.chain.robinhood.com/tx/0x57e3332e8db4b78b69b910297d5b7c9ab22098cd69fc0a5f86e4fb4fb385945e)
- redeem/withdraw — [`0xaf45…0d13`](https://explorer.testnet.chain.robinhood.com/tx/0xaf45d796da6a8e3efe756aae4724a02dbe62eca9112d43d2cbe166eab3270d13)

### (e) stealth pay (ERC-5564/6538) — register → pay → view-key scan → sweep  ✅
`ADDR.stealthRegistry` `0x7f28…880f`, `ADDR.stealthPay` `0x36B7…7403`, announcer `0xe386…F402`. Paid 5 USDG to a
one-time stealth address, detected it with the **view key only** off the announcer, then swept it with the derived
key (`spendPriv + s`) — confirming that derived key controls the address. Full round-trip.
- registerKeys — [`0x9904…a1f4`](https://explorer.testnet.chain.robinhood.com/tx/0x9904de811602b7cab48fac0cbdeacb09c2dc28d573815a4e8ca402a8d447a1f4)
- pay → stealth addr — [`0x08dd…e488`](https://explorer.testnet.chain.robinhood.com/tx/0x08ddb39e2f74f2a7ecb6cb48745ba58dcc0c907af42918b3bcdd26490903e488)
- gas-fund stealth addr — [`0x83f3…c82e`](https://explorer.testnet.chain.robinhood.com/tx/0x83f376dbeb04924143bfb7666a0e937d5a398eb37ed7fea51d6846387be3c82e)
- sweep out — [`0xf399…d86a`](https://explorer.testnet.chain.robinhood.com/tx/0xf3992559298fa153d929bc790be5c029be5bb13507582b0959097ddd740d86a5)

### USDG private in-pool transfer + cross-recovery (bonus)  ✅
Proven by `_pool_p2_smoke.mjs`: register + deposit 100 → private transfer 30 to a second account (extAmount=0, no
token movement) → both parties' notes recovered **from the chain** (B sees 30, A sees 70 change). The assertion is
the on-chain cross-recovery itself; that smoke does not print per-tx hashes.

## Relayer (gasless `viaRelayer`) path — ⚠️ CODE VERIFIED, PRODUCTION GAP

The UI defaults `viaRelayer = true` (`private.tsx:59`), so the **default** withdraw/transfer path routes through
`POST /api/relay` (`live.ts` `relaySubmit`, ~1088/1103).

- **Production is a GAP.** The live endpoint returns **`500 {"error":"relayer not configured"}`** on
  `https://essey.xyz/api/relay` and `https://www.essey.xyz/api/relay` — i.e. `RELAYER_PK` is **unset** in Vercel.
  Every gasless withdraw/transfer in the UI's default mode currently fails until this is set. (Users can toggle
  "via relayer" **off** to self-submit — that path works, see all flows above.)
- **The code is sound.** Running the **actual `api/relay.ts` handler in-process** with a stand-in key, fed a real
  client-built withdraw proof serialized exactly as `relaySubmit` does, submitted a real tx and paid the recipient:
  - self deposit — [`0xc65c…10b2`](https://explorer.testnet.chain.robinhood.com/tx/0xc65ccfc9d2c55b352e2b0adf316f6d2f3dee5df117fc9bfde9d2ae63d3bb10b2)
  - **relayed** withdraw submitted by the handler — [`0x71b4…4d22`](https://explorer.testnet.chain.robinhood.com/tx/0x71b41cefc0b9831833d8e126ab108e5816ff6179970b366b2337da26e5234d22)
  - negative-path guard: POSTing a deposit (`extAmount>0`) is correctly rejected `400 "relay handles withdrawals/transfers only"`.
  - _Caveat:_ the stand-in relayer was the deployer key (the dedicated relayer wallet's key isn't held here), so
    this proves the handler's parse→allowlist→simulate→submit→pay path, not the distinct-tx-origin privacy property
    (which is structural).

### 🔧 FOUNDER ACTION REQUIRED (do not commit the key)
The relayer wallet `ADDR.poolRelayer` `0x1Ed246983ca4E022f31CEb2b1280FDD46362C23c` is **funded (0.002 ETH) and has
never transacted (nonce 0)** — it is ready. To turn on the gasless path in production:

```
# in the app/web Vercel project:
vercel env add RELAYER_PK production      # paste the PRIVATE KEY for 0x1Ed2…C23c (a DEDICATED key, never a privileged one)
vercel --prod                             # redeploy so the function picks it up
# verify:  curl -s -X POST https://essey.xyz/api/relay -d '{}' -H 'content-type: application/json'
#          should now return 400 "missing proof/extData" instead of 500 "relayer not configured"
```

## UI parity (smoke == UI)

The smokes call the **same modules** `/private` (`private.tsx`) imports via `live.ts`:

| UI action (`private.tsx` → `live.ts` `flows.*`) | poolsdk.ts / stealth.ts function | Smoke calls the same? |
|---|---|---|
| `shieldDeposit` | `buildDepositProof` | ✅ |
| `shieldWithdraw` (self & viaRelayer) | `buildWithdrawProof` | ✅ (+ relayer handler) |
| `shieldTransfer` | `buildTransferProof` | ✅ (p2) |
| `unlockPool` / `registerPool` | `deriveKeypair` / `deriveEncKeypair` / `packAccountKey` | ✅ |
| `payPrivate` | `generateStealthAddress` | ✅ |
| `scanPrivateInbox` | `checkAnnouncement` | ✅ |
| `sweepStealth` | `computeStealthPrivKey` | ✅ |

`private.tsx` renders a selector over `SHIELDED_POOLS` (all four: **USDG, AAPL, NVDA, USDG·yield**) plus the stealth
pay/inbox panel, so every flow proven here is reachable in the UI. A passing smoke therefore == the UI's flow works.

## No contract bug found
No bug in the shielded contracts or `poolsdk.ts`/`stealth.ts`. The two initial smoke failures were **harness**
issues, not product issues: (1) the live AAPL token has no burn (so the burn had to run against an identical-bytecode
instance), and (2) the first stealth smoke scanned the announcer once and hit RPC `getLogs` indexing lag — adding a
retry (as the pool smokes already do) makes it pass; the crypto/detection was correct throughout.

## Repro
From `app/web`, with `DEPLOYER_PK` set (`set -a && source ../../rh-chain/.env && set +a; DEPLOYER_PK="$TESTNET_DEPLOYER_PK"`):
- `node _pool_p1b_smoke.mjs` — AAPL deposit→withdraw + SUPPLY supply→redeem
- `node _pool_p2_smoke.mjs` — USDG deposit + private transfer + cross-recovery
- `node _private_e2e_smoke.mjs` — USDG (a) + NVDA (c) deposit→withdraw
- `node _private_haircut_smoke.mjs` — shielded-stock adminBurn haircut (b), throwaway identical-bytecode pool
- `node _stealth_smoke.mjs` — stealth pay round-trip (e)
- `node _relayer_smoke.mjs` — relayer handler code proof (runs `api/relay.ts` in-process)
