# Robinhood Chain testnet deployment (chainId 46630)

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
seeded, 10% base APR, 50% of skimmed loan-interest → the pot. AAPL/NVDA collateral markets are
PROPOSED; the 2-day parameter timelock (a safety feature) means **borrowing opens 2026-08-05 18:55
UTC** — supply/withdraw works now. After the timelock, call `markets.commitMarket(aapl)` and
`commitMarket(nvda)` to open borrowing (and keep a keeper beating the LivenessOracle for liquidations).

**Not yet on testnet:** StockConverter (stock-denominated payouts), whitelist roots, CoinVoyage onramp.
