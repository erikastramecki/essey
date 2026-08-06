# Robinhood Chain testnet deployment (chainId 46630)

## STOCK-PAYOUT + DEGEN REDEPLOY — 2026-08-04 (CURRENT / live on essey.xyz)

Fresh converter-wired market (Bell pays out real STOCK — a default AAPL/NVDA bundle — via the claim-edge
converter) + the degen multiplier gacha. **Stock payouts proven on-chain** (AAPL+NVDA delivered into a
Seat's Vault by a Bell claim). Reuses the existing USDG/AAPL/NVDA/pool/quest/markets.

| Contract | Address |
|---|---|
| Seat | `0x7bcc821cdf7e3ad9e43188d0f0b24049db0b1bee` |
| EsseyToken ($ESSEY) | `0x0659eca47665da545e1157ede11fcb4c8222879f` |
| Bell (converter-wired, DEFAULT_PAYOUT=BUNDLE) | `0x31115d449f359a05298295415665af18fd708d0d` |
| EsseyExchange | `0x57864a956a13d42837f121790715713cbaa7df09` |
| EsseyCases (keeper-enabled: 1-sign reveal) | `0x97ad3b44d0B362F70460c90993E9eF79b9D2D749` |
| EsseyCases (old, buyer-only reveal — retired) | `0x151696d171443cfb7e69422e0dc456c0dca13972` |
| SeatArt | `0xdf4c763ead237d80f817036dca070e0a97030383` |
| MintDistributor | `0xa9c8953dcd72dd5cbe03fcbe60e13c3ef91a38cd` |
| BundleConverter (stock payouts) | `0x3c6a57b21c000caecc61655568eabb6cfbb67fb0` |
| QuestLens | `0xaAC27dBbDF85096fe0481F8E194ac2ffef146df3` |
| TestnetFaucet | `0x11c696cf869c1caace32e7ea6d1d2074c452ded2` |
| EsseyCasesDegen (multiplier gacha, 24/7 share-denominated) | `0xA0B438Da1b489748D863C9529D19A29C36309599` |
| EsseyCasesDegen (old, USD-priced/session-gated — retired) | `0x96d5CE89fB10044882F144430EDeC2Eb412Af42d` |
| **Essey Private — Phase 0 (stealth addresses, ERC-5564/6538)** | |
| EsseyStealthAnnouncer (ERC-5564) | `0xe386345BB307166F59A191130230bA445F05F402` |
| EsseyStealthRegistry (canonical ERC-6538) | `0x7f28EbFfC1310849f4Cb5612e1Ff892fd892880f` |
| EsseyStealthPay (private pay — zero custody) | `0x36B750Ac415DC1f05E39C6D13A05FDbC29567403` |
| **Essey Private — Phase 1 (shielded USDG pool, HIDES AMOUNTS, Nova-derived, depth 20)** | |
| EsseyShieldedPool (app pool, gate openMode) | `0xcD7953960bbc1276F0856Dad5E502fc01cE629aB` |
| EsseyPoolGate (operator front door) | `0xcBdA12dF938d665fF5752b9C49740A7D47ff5562` |
| PoolVerifier (Groth16, depth-20) | `0x46a8121ea850AA5F6497a20642e11cFd964E14C9` |
| Poseidon(2) hasher | `0xF9A2D0b462221c017c74bACB26d43bd2165C98a1` |
| MockEntropy (degen keeper) | `0xb9b82A4900642A98e29F59B937FDE6B2DDaF1E6F` |
| USDG / AAPL / NVDA / pool / quest / markets | *unchanged (see below)* |

**⚠️ FEED KEEPER REQUIRED:** the mock Chainlink feeds go stale after ~25h (`FEED_HEARTBEAT+GRACE`). When
stale, the converter reverts and the Bell fails open to USDG (degen `buy` reverts). Refresh with
`cast send <feed> "set(int256,uint256)" <answer> <now> --private-key $PK --rpc-url rh_testnet`. The
USDG/USD feed `0x6ac94CAb7302415A9a29d9746Fb6051523592E3b` was refreshed at deploy; a periodic keeper
(cron) should refresh USDG + the converter's AAPL/NVDA feeds to keep stock payouts + degen live.

---

## Original stack — 2026-08-03 (superseded by the 2026-08-04 redeploy above)

**Deployed 2026-08-03** via `rh-chain/script/DeployMarket.s.sol` · RPC `https://rpc.testnet.chain.robinhood.com`

| Contract | Address |
|---|---|
| MintDistributor | `0xa8FAb12C03D274262D1ECEB769B5A5A2192dB27E` |
| Seat | `0x0Fd7889F09B1846388240B08Acc60723b17022d6` |
| EsseyToken ($ESSEY) | `0xC253674DA4347BFa2E6A14d6a6F78166803D14B5` |
| Bell | `0x9E760482877C6139C32Da745aa2a8116d86a14D0` |
| SeatArt | `0x2500Dad298a65c09bab3d602E0F8F54B37D568c6` |
| EsseyExchange | `0x6C4b1EcC2903f12796c3909547Def413353ac43f` |
| EsseyCases | `0xf8B6D4a83c5afe6c1339390947cb8dbf9AF2D8bd` |
| Mock USDG (test fixture, 18-dec) | `0x7461E670d44FF4397A3E48030C5b06f6163a5De2` |
| Mock USDG/USD feed (test fixture) | `0x6ac94CAb7302415A9a29d9746Fb6051523592E3b` |
| TestnetFaucet | `0xFF9866C43BbaeDD143AF7224c49ba7681beD0eAA` |
| Mock AAPL / NVDA (Case stock) | `0xaC6cd493e69eb82e8f113E33De8e5542F313B731` / `0x8393cc99FAC1CF79E3bEceA56f344159ddFd91E9` |
| **EsseyPool** (lending, BELL_SINK=Bell) | `0x283a4891458180f502E82E40470d3e06321ba748` |
| EsseyMarkets | `0x6dAE0540bcC78756BB7b2e936ACBFA9cA5439732` |
| LivenessOracle | `0x750e88be1621902486Cd612D866E63587F3A2bf7` |
| QuestRegistry (whitelist quest referral graph) | `0x3DD40673665e13bD4A8A7B1D6e27Cb43EDfE0427` |
| QuestLens (leaderboard scoring view) | `0x307d0E17e0c7412E61657f6BA6dE96f0c29294eB` |

Wiring verified from chain state: `seat.minter() == distributor`, `seat.hook() == bell`,
`seat.art() == art`, `maxSupply == 2222`. Smoke: Seat Nº 0001 minted
(tx `0x8411bee7ceb45c4da076eec8dd9cb7adf07af84db36bcb10d448dee59ea2ccea`), its on-chain
`tokenURI` decoded to valid JSON + SVG with the Vault attribute populated, and the Tape indexer
printed the mint as its first real `proven` row.

**Testnet caveats:** USDG + feed are mock fixtures (real USDG is 6-decimal; fee/minRing env values
were scaled to the mock's 18 decimals). Admin/treasury/seeder/bankroll are all the throwaway
deployer — mainnet uses the multisig. The launch tier ladder + prices in the script are defaults
pending founder review.

**Lending (deployed 2026-08-03):** EsseyPool wired with `BELL_SINK` = the Bell, 100k USDG liquidity
seeded, 10% base APR, 50% of skimmed loan-interest → the pot. AAPL/NVDA collateral markets were
**committed 2026-08-05 18:55 UTC** (timelock elapsed) and are `enabled` with correct risk params +
live feeds; supply/withdraw works.

⚠️ **`canBorrow` is still `false` on testnet — a fixture gap, not a contract bug.** `collateralValue`
hard-requires the collateral token to implement `IScaledUI.uiMultiplier()` (share/split normalisation).
The testnet AAPL/NVDA are plain OZ `ERC20Mock`s (also used by Cases/Bell/converter), which lack that
function, so `collateralValue` reverts and `canBorrow` catches → `false`. On MAINNET the real Robinhood
Stock Tokens implement ScaledUI, so borrowing works there. To exercise borrowing ON TESTNET, deploy
ScaledUI-compatible mock stock tokens (`uiMultiplier() = 1e18`) and re-propose the markets against them
(fresh 2-day timelock) — note this forks the collateral token identity away from the live Cases/Bell
AAPL/NVDA, so ideally the whole testnet stock stack moves to the ScaledUI mock together. (The other
gate, the session flag, is satisfied once the market feed is refreshed after the day's 14:30 UTC open —
same keeper that keeps the converter/degen feeds fresh.)

**Not yet on testnet:** StockConverter (stock-denominated payouts), whitelist roots, CoinVoyage onramp.
