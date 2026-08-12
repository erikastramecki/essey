# Essey Don Market — Testnet E2E Report

_Generated 2026-08-12 01:03:54 UTC from `broadcast/DonE2E.s.sol/46630/run-latest.json` — chain `46630`._

Deterministic, multi-wallet end-to-end exercise of the Don v3 market (see `rh-chain/script/DonE2E.s.sol`). Every row is a real broadcast transaction from a fresh, throwaway actor wallet; the harness asserts each flow's invariants on-chain (clear revert strings) before the tx is recorded here.

## Summary

| Result | Count |
|---|---|
| ✅ pass | 109 |
| ❌ fail | 0 |
| ⏳ pending | 0 |
| **total** | **109** |

**All 109 transactions confirmed successful.**

## Setup (deployer: fund + seed the stack)  
_23/23 pass_

| Flow | Actor | Contract | Tx | Status |
|---|---|---|---|---|
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x0808…b245 | [0xbc7b…4866](https://explorer.testnet.chain.robinhood.com/tx/0xbc7bbb21cd18c05177ae24c878f7a70a1481f27e78a88ede968ded6a77df4866) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x5e5b…a9fd | [0x9b2b…6e9a](https://explorer.testnet.chain.robinhood.com/tx/0x9b2bcda57a814c8ffc6a45d3539e0f229b0ed7768b14aaeed738633e3f3a6e9a) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x31a4…7f0a | [0x1ecd…d924](https://explorer.testnet.chain.robinhood.com/tx/0x1ecd0e2603f8ae21a88bb3b4830e02a499d4875a6990e6ac1a8e97ab0167d924) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x73f9…0ab1 | [0x6b6d…835b](https://explorer.testnet.chain.robinhood.com/tx/0x6b6d0216412466fa1f48fdaa4698fcfdefa92e649109b469150c0a774af2835b) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x7e65…df21 | [0x86f5…2f98](https://explorer.testnet.chain.robinhood.com/tx/0x86f5cbce16306eff1a66a0cdf5d2e1de317ccc27ca13faa76b1936a3b0352f98) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x3fc2…c7be | [0x91ad…6fda](https://explorer.testnet.chain.robinhood.com/tx/0x91ad3c5d1e6535470a6e72731e50f6b7d65e6ae44635e4af209e487f85626fda) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x2094…71fe | [0xf546…7280](https://explorer.testnet.chain.robinhood.com/tx/0xf546cbd62888a2701a47e94f9533eb45f409ab23918467b610a1eeef13677280) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x7337…b8cc | [0x606c…467e](https://explorer.testnet.chain.robinhood.com/tx/0x606c09bf85c5345f9ec526460ddb4a2163195cf4a09595458428523abcef467e) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x6c55…67f6 | [0x7385…e575](https://explorer.testnet.chain.robinhood.com/tx/0x7385a8f8fd36c979323b3163e5c33ad66eac447a315ed1ed4e94fa3928e5e575) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x951a…8908 | [0x2e69…db32](https://explorer.testnet.chain.robinhood.com/tx/0x2e69fff5a34a309718b4b68da17307e883536c13a2d6b8f273c2174171bedb32) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x49b1…3d6f | [0x002e…f7b5](https://explorer.testnet.chain.robinhood.com/tx/0x002e95e317b3da36ea30e31023338589120e66f29faba258e1457ac60dacf7b5) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x0716…5de2 | [0x26f7…cd5e](https://explorer.testnet.chain.robinhood.com/tx/0x26f7f63bc86cce51a0dee3c4b3b66a42d8b3a4ebaa35257d9b3d7450c42ccd5e) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0xe4fc…bfd4 | [0x2f18…d35c](https://explorer.testnet.chain.robinhood.com/tx/0x2f1802bfd83bcb763b6bdccbd968f051a27d288c9a83efa4e9b2305bc719d35c) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x8c27…6efb | [0x9bc4…ed59](https://explorer.testnet.chain.robinhood.com/tx/0x9bc47d7ae6e1fa274cde7c21f14c94764e6c98ccfe22a0bb1ead104baaf8ed59) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x0928…3e70 | [0xaec3…c3c5](https://explorer.testnet.chain.robinhood.com/tx/0xaec31743a4f48c1e7d4b38f47a957eef6254a373ac49adae4bcc53683325c3c5) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0x4e7d…cff6 | [0xfedb…a277](https://explorer.testnet.chain.robinhood.com/tx/0xfedb36fab5d03f49846e99dfcbde9a10eb3ba00c1d11683869bdac4663d1a277) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0xa40f…9764 | [0xeaa5…76b3](https://explorer.testnet.chain.robinhood.com/tx/0xeaa59d7f2c9c5a06cab3d6177cf0b1440f15d821f703824d8b01d5d6057276b3) | ✅ pass |
| gas-fund wallet (native ETH) | `0x976e…993d` | 0xfde4…5b71 | [0x4910…107b](https://explorer.testnet.chain.robinhood.com/tx/0x4910e9497c8e7db7ff8108871c561e9d7bf1399dd34e38bac8395b93b4a9107b) | ✅ pass |
| tune faucet drips | `0x976e…993d` | FAUCET | [0xa05a…b048](https://explorer.testnet.chain.robinhood.com/tx/0xa05a43e4e92d6c8cb24e476772fcae56b10371aa57060f2e8179ac2c6d26b048) | ✅ pass |
| fund faucet with ESSEY | `0x976e…993d` | ESSEY | [0xa3db…a5b3](https://explorer.testnet.chain.robinhood.com/tx/0xa3dbe73d0dfa46481f908d2b4c08fc42694c39237e71c8e0e03f7388e294a5b3) | ✅ pass |
| seed desk float (mintReserved) | `0x976e…993d` | DISTRIBUTOR | [0x656d…3856](https://explorer.testnet.chain.robinhood.com/tx/0x656d1de65842d2f47af63dc7c0863d75d3212f1616e3ddaacd87db44660b3856) | ✅ pass |
| approve exchange (all Dons) | `0x976e…993d` | DON | [0xb727…1578](https://explorer.testnet.chain.robinhood.com/tx/0xb72735723c4d38c9965d1b1640200718602cd66e250232486395ef80b4141578) | ✅ pass |
| seed exchange inventory | `0x976e…993d` | EXCHANGE | [0x34b0…9339](https://explorer.testnet.chain.robinhood.com/tx/0x34b0743b5e5b09a64e9b5120bb099a091cfd62139ce1ade0b16533cd67bf9339) | ✅ pass |

## Faucet  
_18/18 pass_

| Flow | Actor | Contract | Tx | Status |
|---|---|---|---|---|
| drip() — ESSEY + USDG | `0x0808…b245` | FAUCET | [0x75fc…d499](https://explorer.testnet.chain.robinhood.com/tx/0x75fc9406f35e044c5dd50b338f0e909a4b74e71a3a7db2d95f3a36dd4236d499) | ✅ pass |
| drip() — ESSEY + USDG | `0x5e5b…a9fd` | FAUCET | [0xaaaa…af38](https://explorer.testnet.chain.robinhood.com/tx/0xaaaad10f4194c82b2bf2e242ed8d9b8864aa908976df43eccf472ea991f0af38) | ✅ pass |
| drip() — ESSEY + USDG | `0x31a4…7f0a` | FAUCET | [0xd00a…85ff](https://explorer.testnet.chain.robinhood.com/tx/0xd00a19126beb64c03353c083d037093539ec77d032e766de94d8161798ba85ff) | ✅ pass |
| drip() — ESSEY + USDG | `0x73f9…0ab1` | FAUCET | [0xfd20…cc12](https://explorer.testnet.chain.robinhood.com/tx/0xfd20e410c2518f95012538d15a18fc031af187ce4b6227ccec12f5d3d562cc12) | ✅ pass |
| drip() — ESSEY + USDG | `0x7e65…df21` | FAUCET | [0xde05…1756](https://explorer.testnet.chain.robinhood.com/tx/0xde050eb0c0016799922b57e68769fe69093a04a69faec523d009c85af24e1756) | ✅ pass |
| drip() — ESSEY + USDG | `0x3fc2…c7be` | FAUCET | [0x7b16…17ec](https://explorer.testnet.chain.robinhood.com/tx/0x7b166d142928777a96996862125ebfa5779e689cd166a665ebacb188280217ec) | ✅ pass |
| drip() — ESSEY + USDG | `0x2094…71fe` | FAUCET | [0x62c6…76c7](https://explorer.testnet.chain.robinhood.com/tx/0x62c6dc8ac86640bd46d5031f266b44aab44c5fc54ffc76b8f8ec713ac01f76c7) | ✅ pass |
| drip() — ESSEY + USDG | `0x7337…b8cc` | FAUCET | [0x50d5…3bd5](https://explorer.testnet.chain.robinhood.com/tx/0x50d5f6ed3802ac32194d8767c6bd6d171fb287f0258dba75e10a7ef7dc0e3bd5) | ✅ pass |
| drip() — ESSEY + USDG | `0x6c55…67f6` | FAUCET | [0x9fdb…c7bb](https://explorer.testnet.chain.robinhood.com/tx/0x9fdbdefa31174162e0023390576389462798f6325dcc52a6c64cb3b0ab27c7bb) | ✅ pass |
| drip() — ESSEY + USDG | `0x951a…8908` | FAUCET | [0x7d15…1fe0](https://explorer.testnet.chain.robinhood.com/tx/0x7d152cd430628a45b07a07460e211888ed071d864dbb7c88cca6212cc6fa1fe0) | ✅ pass |
| drip() — ESSEY + USDG | `0x49b1…3d6f` | FAUCET | [0x124c…25d6](https://explorer.testnet.chain.robinhood.com/tx/0x124ccede736f36005125439c25962412b78dbb02aa489b831d32e9958eb425d6) | ✅ pass |
| drip() — ESSEY + USDG | `0x0716…5de2` | FAUCET | [0xecba…57b3](https://explorer.testnet.chain.robinhood.com/tx/0xecba904dde9f5e3fadd231c40876b9eff2e67956e70b0bc442cfc09df1a757b3) | ✅ pass |
| drip() — ESSEY + USDG | `0xe4fc…bfd4` | FAUCET | [0xe94e…4226](https://explorer.testnet.chain.robinhood.com/tx/0xe94ebc9b7e3e8a4bcd06b2d1e43d81a2d3866c29979531e711ac930d2bbd4226) | ✅ pass |
| drip() — ESSEY + USDG | `0x8c27…6efb` | FAUCET | [0xac97…7ffe](https://explorer.testnet.chain.robinhood.com/tx/0xac972af2f7a8885dadee6fb9c8a8b52652eac5ffd04a45bab0010fbcb2e77ffe) | ✅ pass |
| drip() — ESSEY + USDG | `0x0928…3e70` | FAUCET | [0x5896…ab0f](https://explorer.testnet.chain.robinhood.com/tx/0x589636b2ff4c8342a1ed62e06647b4e92c28332f1de31a0a4094b9849738ab0f) | ✅ pass |
| drip() — ESSEY + USDG | `0x4e7d…cff6` | FAUCET | [0x03b3…62bc](https://explorer.testnet.chain.robinhood.com/tx/0x03b3dc030cff7fb0b0f06b013b682b1c9b4f1d28ec82a32d73dcef0b11d862bc) | ✅ pass |
| drip() — ESSEY + USDG | `0xa40f…9764` | FAUCET | [0x4bab…0a7f](https://explorer.testnet.chain.robinhood.com/tx/0x4babed22804b7eb908e7444db69d9d65a33068c55c13cdb6112c9e9593940a7f) | ✅ pass |
| drip() — ESSEY + USDG | `0xfde4…5b71` | FAUCET | [0x57a3…a729](https://explorer.testnet.chain.robinhood.com/tx/0x57a3f3bad5d930d3989ac46e57a213a29f1a7b3c3739ed8d2c7d3d306d85a729) | ✅ pass |

## Mint (custom path + reroll)  
_7/7 pass_

| Flow | Actor | Contract | Tx | Status |
|---|---|---|---|---|
| custom mint (ETH fee) | `0x0808…b245` | DISTRIBUTOR | [0xbfcc…a549](https://explorer.testnet.chain.robinhood.com/tx/0xbfccdee341166615761b6e7cfa824328efc89cf608e077e657244e207b78a549) | ✅ pass |
| custom mint (ETH fee) | `0x5e5b…a9fd` | DISTRIBUTOR | [0x2fe5…16c7](https://explorer.testnet.chain.robinhood.com/tx/0x2fe5b97801d806693006be21f54bdcecb01c311a1531bff60d51d410ca8b16c7) | ✅ pass |
| custom mint (ETH fee) | `0x31a4…7f0a` | DISTRIBUTOR | [0x012e…3b22](https://explorer.testnet.chain.robinhood.com/tx/0x012eff17c6a2bbd776dfbec55322d6bd8c4df7725b997ec4aa240c87bb2b3b22) | ✅ pass |
| custom mint (ETH fee) | `0x73f9…0ab1` | DISTRIBUTOR | [0x4c64…9d03](https://explorer.testnet.chain.robinhood.com/tx/0x4c64631a92e759d132b4011f7aa408ee747a6da98a16d052243c727a2f639d03) | ✅ pass |
| custom mint (ETH fee) | `0x7e65…df21` | DISTRIBUTOR | [0x666d…7177](https://explorer.testnet.chain.robinhood.com/tx/0x666da7b42b26033120dc5725596802ac99169e99b01da2706ec1f3863f2e7177) | ✅ pass |
| custom mint (ETH fee) | `0x3fc2…c7be` | DISTRIBUTOR | [0x79ba…6ff5](https://explorer.testnet.chain.robinhood.com/tx/0x79ba00b48ddc22da85f078192a0125b440263561ae8ba5d8929ab7d7e0326ff5) | ✅ pass |
| reroll traits (ETH fee) | `0x3fc2…c7be` | DISTRIBUTOR | [0xa806…f27d](https://explorer.testnet.chain.robinhood.com/tx/0xa80654a9c260031dc3b606a623c7a08241efe1ee513981ef3b2a385f23b8f27d) | ✅ pass |

## Stake (Bell tiers)  
_6/6 pass_

| Flow | Actor | Contract | Tx | Status |
|---|---|---|---|---|
| approve ESSEY → Bell | `0x73f9…0ab1` | ESSEY | [0xb962…1ca6](https://explorer.testnet.chain.robinhood.com/tx/0xb96201b6c8514361528a8df826d91fe0a833e4d2a34599e1792f80f72d1f1ca6) | ✅ pass |
| activate Bell tier | `0x73f9…0ab1` | BELL | [0xe683…d221](https://explorer.testnet.chain.robinhood.com/tx/0xe683dfd0eac9fc552dd75db2f2efcbd9fcaaa0c12dac78fe76b9404bcc38d221) | ✅ pass |
| approve ESSEY → Bell | `0x7e65…df21` | ESSEY | [0xa876…572c](https://explorer.testnet.chain.robinhood.com/tx/0xa876a313afce18482b5c2f22cbc3f61cd9b08ca0ea8598d446f2bc159654572c) | ✅ pass |
| activate Bell tier | `0x7e65…df21` | BELL | [0xbb78…9326](https://explorer.testnet.chain.robinhood.com/tx/0xbb78052f098c6e18006fc114892b680222e2e9578367165582730219270d9326) | ✅ pass |
| approve ESSEY → Bell | `0x7e65…df21` | ESSEY | [0xae56…4cc9](https://explorer.testnet.chain.robinhood.com/tx/0xae56ef124aa51afbf8957aa1c4cd9d3d9f91ce6e76dde5706aa81b350be74cc9) | ✅ pass |
| upgrade Bell tier | `0x7e65…df21` | BELL | [0x8d40…4de9](https://explorer.testnet.chain.robinhood.com/tx/0x8d400f74280fa094a7c5f151152cee1d428cdfea831d2ed0dc82f8e133734de9) | ✅ pass |

## Borrow (fixed-draw term loan)  
_3/3 pass_

| Flow | Actor | Contract | Tx | Status |
|---|---|---|---|---|
| borrow (fixed-draw, prepaid ETH) | `0x0808…b245` | LOAN | [0xed99…42b6](https://explorer.testnet.chain.robinhood.com/tx/0xed994662e29cd0ab58e252c1f5c942d929bedde54540adc19f991cc1510b42b6) | ✅ pass |
| borrow (fixed-draw, prepaid ETH) | `0x5e5b…a9fd` | LOAN | [0xc83d…d06b](https://explorer.testnet.chain.robinhood.com/tx/0xc83da8a0ab5d97984671d1561a01433c07c479732d917c116e1cea154b19d06b) | ✅ pass |
| borrow (fixed-draw, prepaid ETH) | `0x31a4…7f0a` | LOAN | [0x1391…7c50](https://explorer.testnet.chain.robinhood.com/tx/0x1391036289c7075c5ea5359f9766d3f104e1e9ab869c17fb3c68bdddbb817c50) | ✅ pass |

## Repay  
_6/6 pass_

| Flow | Actor | Contract | Tx | Status |
|---|---|---|---|---|
| approve ESSEY → Loan | `0x0808…b245` | ESSEY | [0x3d8c…d0ff](https://explorer.testnet.chain.robinhood.com/tx/0x3d8c0305211f61ffee73f7a4959617ad2092ae366082e2a9d4946ed7a5a0d0ff) | ✅ pass |
| repay 1:1 (lien released) | `0x0808…b245` | LOAN | [0x1fc8…323a](https://explorer.testnet.chain.robinhood.com/tx/0x1fc8b8c06c311d785cd905522eedf7addd578e0be253bbaf4ebfc63a0069323a) | ✅ pass |
| approve ESSEY → Loan | `0x5e5b…a9fd` | ESSEY | [0x8e9e…acc6](https://explorer.testnet.chain.robinhood.com/tx/0x8e9ea74a77dcf40fad80e4c80ac40f765f4c5f42333c46dab90742d675f8acc6) | ✅ pass |
| repay 1:1 (lien released) | `0x5e5b…a9fd` | LOAN | [0xe545…c579](https://explorer.testnet.chain.robinhood.com/tx/0xe545c51e7ce13e8ebd986790b70a3db9ac72ec37679cb8a3c3d8cd60c80fc579) | ✅ pass |
| approve ESSEY → Loan | `0x31a4…7f0a` | ESSEY | [0x6566…7522](https://explorer.testnet.chain.robinhood.com/tx/0x6566d866e9ebc7939ee5d60e74963d175830016340d38f2960c1f37daa047522) | ✅ pass |
| repay 1:1 (lien released) | `0x31a4…7f0a` | LOAN | [0x07f3…972f](https://explorer.testnet.chain.robinhood.com/tx/0x07f3b9fabfd3ca86d8bc8a1c910d08461525dddfd2b16b8a84a3207adb97972f) | ✅ pass |

## Reserve (fund floor + redeem)  
_4/4 pass_

| Flow | Actor | Contract | Tx | Status |
|---|---|---|---|---|
| approve → Reserve | `0x2094…71fe` | DON | [0xbb3c…b992](https://explorer.testnet.chain.robinhood.com/tx/0xbb3cfb47417914ad6dfc02949f6cbd1a450365a92fa3482026070b8cdd98b992) | ✅ pass |
| redeem Don for floor | `0x2094…71fe` | RESERVE | [0xe228…ebf8](https://explorer.testnet.chain.robinhood.com/tx/0xe2282c6aa0f86c95d813eeed42bf5ed8e041b174be44116cafb987b5e5beebf8) | ✅ pass |
| approve → Reserve | `0x7337…b8cc` | ESSEY | [0x1253…1b0d](https://explorer.testnet.chain.robinhood.com/tx/0x1253b98263097735d756c22bb9d997c33c34432f96ef01cdd0587e088a331b0d) | ✅ pass |
| fund the floor | `0x7337…b8cc` | RESERVE | [0xa52c…3927](https://explorer.testnet.chain.robinhood.com/tx/0xa52c1d4f633d7bc22b4e9c26c4220a98f0cf53f20fb4af654497c2a850633927) | ✅ pass |

## Desk swaps (buy / snipe / sell)  
_42/42 pass_

| Flow | Actor | Contract | Tx | Status |
|---|---|---|---|---|
| approve → Exchange | `0x2094…71fe` | ESSEY | [0xd91f…1cf4](https://explorer.testnet.chain.robinhood.com/tx/0xd91f4e5d9a549318b3fea9980ac57c3432ce0a827efb6bc201a2b45dbe0a1cf4) | ✅ pass |
| buy (price + 8%) | `0x2094…71fe` | EXCHANGE | [0x6cb3…c5db](https://explorer.testnet.chain.robinhood.com/tx/0x6cb3bb1d92ced7875fbba5b0dddbafe55c27fc4623bda8c01420cb78840dc5db) | ✅ pass |
| approve → Exchange | `0x6c55…67f6` | ESSEY | [0x930c…01e6](https://explorer.testnet.chain.robinhood.com/tx/0x930c5016b3fa43e4326ef192c03dcc322c5d6dcc2ef038d585509cec058701e6) | ✅ pass |
| buy (price + 8%) | `0x6c55…67f6` | EXCHANGE | [0xcad9…5956](https://explorer.testnet.chain.robinhood.com/tx/0xcad90d87401ed0a0d686dce7d86e838f0294811b8442586422520b7dba585956) | ✅ pass |
| approve → Exchange | `0x6c55…67f6` | DON | [0x5057…b0eb](https://explorer.testnet.chain.robinhood.com/tx/0x5057acf4b655f5150de1eb9762ac6bf3ed221ecf7f630db08378bd37b92fb0eb) | ✅ pass |
| sell (price − 8%) | `0x6c55…67f6` | EXCHANGE | [0x60b3…5849](https://explorer.testnet.chain.robinhood.com/tx/0x60b332fe3fe5e999931788b3f72fd734986a6fb7cb9c27cc66c738d373165849) | ✅ pass |
| approve → Exchange | `0x951a…8908` | ESSEY | [0xbbb4…bb20](https://explorer.testnet.chain.robinhood.com/tx/0xbbb41533ca10b34c270da1df1af135349edcd197bc9ba2653ab7f7c7c02abb20) | ✅ pass |
| snipe (price + 12%) | `0x951a…8908` | EXCHANGE | [0x791b…5a84](https://explorer.testnet.chain.robinhood.com/tx/0x791b0acd44a1e83652c50b0ce2940ed0ee6e0de623b833210b03f81dc3645a84) | ✅ pass |
| approve → Exchange | `0x951a…8908` | DON | [0x50b8…4fe7](https://explorer.testnet.chain.robinhood.com/tx/0x50b8936f9432c7c17184509bd0b3f32e5a5814971a7ba795edc406a622944fe7) | ✅ pass |
| sell (price − 8%) | `0x951a…8908` | EXCHANGE | [0xd5dd…22fd](https://explorer.testnet.chain.robinhood.com/tx/0xd5dd42e0ab4c773cd48615191278b28d7f5cb3b75243b24d6b2244b470c122fd) | ✅ pass |
| approve → Exchange | `0x49b1…3d6f` | ESSEY | [0x7f65…6213](https://explorer.testnet.chain.robinhood.com/tx/0x7f65c3d8e7621b875f04da4cd84535152c534ea721a07565b790066394456213) | ✅ pass |
| buy (price + 8%) | `0x49b1…3d6f` | EXCHANGE | [0xd354…95fc](https://explorer.testnet.chain.robinhood.com/tx/0xd354456b596e274f9b10bf8c3af464806a3585b2f259a9de098c0363f0c295fc) | ✅ pass |
| approve → Exchange | `0x49b1…3d6f` | DON | [0xcd4f…59b0](https://explorer.testnet.chain.robinhood.com/tx/0xcd4f5bf3f82ac6ead5fccc194761441c3f748f9181eafd66861f99f0bc3b59b0) | ✅ pass |
| sell (price − 8%) | `0x49b1…3d6f` | EXCHANGE | [0xe0fa…4aea](https://explorer.testnet.chain.robinhood.com/tx/0xe0fade77a3611a4552c9f68872f22c0f6d804434754a756dfc9ebee70c934aea) | ✅ pass |
| approve → Exchange | `0x0716…5de2` | ESSEY | [0xec96…14b0](https://explorer.testnet.chain.robinhood.com/tx/0xec967b9217fa7a0cf1290d8bde796cca36387cdaea53f2c013bf62448da014b0) | ✅ pass |
| snipe (price + 12%) | `0x0716…5de2` | EXCHANGE | [0x94dc…c801](https://explorer.testnet.chain.robinhood.com/tx/0x94dc3704b785369b5a83fc5ca368ba42860a5953cd7dd758bb9005e38ea9c801) | ✅ pass |
| approve → Exchange | `0x0716…5de2` | DON | [0xb45f…6e76](https://explorer.testnet.chain.robinhood.com/tx/0xb45fe98745cf8a392aa8e5c21523d8a235377aff55a5d69b79064d3aa4786e76) | ✅ pass |
| sell (price − 8%) | `0x0716…5de2` | EXCHANGE | [0xcd74…884b](https://explorer.testnet.chain.robinhood.com/tx/0xcd744a9a6d337215bc739e5d8de70dcd1c4fe64247f379bc1d32dd84c91c884b) | ✅ pass |
| approve → Exchange | `0xe4fc…bfd4` | ESSEY | [0xd738…bf69](https://explorer.testnet.chain.robinhood.com/tx/0xd738aa715fc68f1b5ab04235f427c81e587fc805639a67f12044781d1994bf69) | ✅ pass |
| buy (price + 8%) | `0xe4fc…bfd4` | EXCHANGE | [0x504c…edc4](https://explorer.testnet.chain.robinhood.com/tx/0x504c23a6d484f92e0ce8455be1b9d13a6de699705145620d11efa05ac9c5edc4) | ✅ pass |
| approve → Exchange | `0xe4fc…bfd4` | DON | [0x19b1…00b5](https://explorer.testnet.chain.robinhood.com/tx/0x19b10199243064e80cd1e41e18e054ddfef04c6a82044adf157c5365627b00b5) | ✅ pass |
| sell (price − 8%) | `0xe4fc…bfd4` | EXCHANGE | [0x054a…9dc5](https://explorer.testnet.chain.robinhood.com/tx/0x054a5d4dfe0cc417b75733075f42756d4461e47c124889f5951b4db656409dc5) | ✅ pass |
| approve → Exchange | `0x8c27…6efb` | ESSEY | [0xebb4…0fa7](https://explorer.testnet.chain.robinhood.com/tx/0xebb40a70fa9e076522ef2bc297fbf3c14c5d47554c0e9b1fa976498506200fa7) | ✅ pass |
| snipe (price + 12%) | `0x8c27…6efb` | EXCHANGE | [0x2d36…70b8](https://explorer.testnet.chain.robinhood.com/tx/0x2d36b1bed4106f2a3f4b4e549c5c8f884cf6fbc251449e4c617d74ab93bb70b8) | ✅ pass |
| approve → Exchange | `0x8c27…6efb` | DON | [0xafd7…6a67](https://explorer.testnet.chain.robinhood.com/tx/0xafd7aec637ae6bcc404feb8e5f6f7bd5bf0895dcf6e230fe3db5536b44c36a67) | ✅ pass |
| sell (price − 8%) | `0x8c27…6efb` | EXCHANGE | [0xd638…ffef](https://explorer.testnet.chain.robinhood.com/tx/0xd638ba9042afebdde8c34e6b429e25945a5e65c126c5c4de66e0bca77d26ffef) | ✅ pass |
| approve → Exchange | `0x0928…3e70` | ESSEY | [0x96bc…fcfd](https://explorer.testnet.chain.robinhood.com/tx/0x96bc07a5a98f84844f56005704fc06523a8ab3e5234635cd77efa9b84e41fcfd) | ✅ pass |
| buy (price + 8%) | `0x0928…3e70` | EXCHANGE | [0xeccf…b52c](https://explorer.testnet.chain.robinhood.com/tx/0xeccf42b087ec1a86e00b943674024b8efa0e7b91dbd6f7a0a42f292856f3b52c) | ✅ pass |
| approve → Exchange | `0x0928…3e70` | DON | [0xaa5d…67ff](https://explorer.testnet.chain.robinhood.com/tx/0xaa5d8de9f905ec8e8c756ca125bd53f731a12abaf01bbf8c3a5510e966a467ff) | ✅ pass |
| sell (price − 8%) | `0x0928…3e70` | EXCHANGE | [0xeb78…de05](https://explorer.testnet.chain.robinhood.com/tx/0xeb7851579598f8960f856bed0240cfbb55f24a949db734f5671c7d2cc72ade05) | ✅ pass |
| approve → Exchange | `0x4e7d…cff6` | ESSEY | [0x163b…0dcd](https://explorer.testnet.chain.robinhood.com/tx/0x163b5c1445b6c4b6734a27e18ae6752d0212d1b22c43609cd3692d5d01fc0dcd) | ✅ pass |
| snipe (price + 12%) | `0x4e7d…cff6` | EXCHANGE | [0x3e3d…f985](https://explorer.testnet.chain.robinhood.com/tx/0x3e3d80449511a84ba36d71a8e0ca5a2ac8acf9146fddc2c8ec5dc6a63bfcf985) | ✅ pass |
| approve → Exchange | `0x4e7d…cff6` | DON | [0x0b38…f610](https://explorer.testnet.chain.robinhood.com/tx/0x0b38335257d619d0e04a470a6ee87624db5a9b2b524034137e85ae8e959df610) | ✅ pass |
| sell (price − 8%) | `0x4e7d…cff6` | EXCHANGE | [0x2b56…1fd4](https://explorer.testnet.chain.robinhood.com/tx/0x2b56570e09204acc34b16579577468fbb3e7e196d5abd95cd172431ca21a1fd4) | ✅ pass |
| approve → Exchange | `0xa40f…9764` | ESSEY | [0xc34b…7dda](https://explorer.testnet.chain.robinhood.com/tx/0xc34b97cca4077a59c0b9a152baa9e097c65dff61f35a6f4255c40c757ea67dda) | ✅ pass |
| buy (price + 8%) | `0xa40f…9764` | EXCHANGE | [0xb3bf…821f](https://explorer.testnet.chain.robinhood.com/tx/0xb3bf95a213264eb681605dc27a7eff91633b9a37cc5a80375d6c3640cf42821f) | ✅ pass |
| approve → Exchange | `0xa40f…9764` | DON | [0xf75b…3c79](https://explorer.testnet.chain.robinhood.com/tx/0xf75b4037fb7c0881d728722ca66b1475a045d42f1ee4b7fcbd2c8d64974a3c79) | ✅ pass |
| sell (price − 8%) | `0xa40f…9764` | EXCHANGE | [0x57e5…4b67](https://explorer.testnet.chain.robinhood.com/tx/0x57e5172820190a7e62301b399b989c3042b26808c512a402fa716c78bd444b67) | ✅ pass |
| approve → Exchange | `0xfde4…5b71` | ESSEY | [0x237e…5840](https://explorer.testnet.chain.robinhood.com/tx/0x237e1ae6d412dd737b0f9fa3f68c57d852ddd63ee1a5b3d7b65b7372357e5840) | ✅ pass |
| snipe (price + 12%) | `0xfde4…5b71` | EXCHANGE | [0x3962…4697](https://explorer.testnet.chain.robinhood.com/tx/0x3962ed257ec31596d9440b2b3530190ce8c8e498bbc2f02e86be80f23f304697) | ✅ pass |
| approve → Exchange | `0xfde4…5b71` | DON | [0x7285…1c2c](https://explorer.testnet.chain.robinhood.com/tx/0x7285561bfda40d68bb33c67de4fc8719416e4f6076c0217f2949dc2445061c2c) | ✅ pass |
| sell (price − 8%) | `0xfde4…5b71` | EXCHANGE | [0x731e…021c](https://explorer.testnet.chain.robinhood.com/tx/0x731e6697215dde53b7d421b5dccf25821c0125aa62e5069c4f3917233011021c) | ✅ pass |

## Not covered on live testnet

- **Liquidation (calendar default)** — needs time travel past `expiry + 30-day grace`, impossible on a live chain. Proven in a **fork simulation**: `forge script script/DonE2E.s.sol:DonE2E --sig "liquidationFork()" --rpc-url rh_testnet` (no `--broadcast`).
- **feeSink → Bell (USDG)** — the harness proves trade/mint fees REACH the fee sink; converting them to USDG for the Bell is a keeper `flushEssey`/`flushEth` that needs a live Uniswap-V3 pool, out of scope for this harness.
