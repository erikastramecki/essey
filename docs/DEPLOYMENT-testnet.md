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

Wiring verified from chain state: `seat.minter() == distributor`, `seat.hook() == bell`,
`seat.art() == art`, `maxSupply == 2222`. Smoke: Seat Nº 0001 minted
(tx `0x8411bee7ceb45c4da076eec8dd9cb7adf07af84db36bcb10d448dee59ea2ccea`), its on-chain
`tokenURI` decoded to valid JSON + SVG with the Vault attribute populated, and the Tape indexer
printed the mint as its first real `proven` row.

**Testnet caveats:** USDG + feed are mock fixtures (real USDG is 6-decimal; fee/minRing env values
were scaled to the mock's 18 decimals). Admin/treasury/seeder/bankroll are all the throwaway
deployer — mainnet uses the multisig. The launch tier ladder + prices in the script are defaults
pending founder review.

**Not yet on testnet:** EsseyPool with `BELL_SINK` (lending-side redeploy), StockConverter,
whitelist roots, Exchange float seeding, Case inventory.
