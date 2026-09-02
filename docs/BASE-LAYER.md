# The base layer — $ESSEY and the equity-pegged reserve

**This is the current protocol. It is LIVE on Robinhood Chain mainnet (chainId 4663).** Everything
else Essey builds — lending, shielded/private, the Dons game — sits on top of the two contracts
described here. If you read one protocol doc, read this one.

Addresses (mainnet 4663):

| Contract | Address | What it is |
|---|---|---|
| **$ESSEY** (`EsseyToken`) | `0x315790B57C19141B34C4653a91b096Cf3f071610` | the fixed-supply claim token |
| **EsseyReserve** | `0xd970Ca726188e38982906Ae2284D2bdB80205A7b` | the adminless equity-pegged floor |

> Addresses and the on-chain reserve holdings below are the founder's deploy ground truth
> (base-layer status **LIVE mainnet** in [MAINNET-ACTIVATION.md](MAINNET-ACTIVATION.md) flow #1). The
> *contract properties* are cited to source (`rh-chain/src/market/`) throughout so each is falsifiable.

---

## 1. $ESSEY — a fixed-supply, adminless token

`EsseyToken` is `ERC20 + ERC20Burnable + ERC20Permit` and nothing else
(`rh-chain/src/market/EsseyToken.sol:21`).

- **Fixed supply: 8,888,888,888 × 1e18**, minted once to the treasury at construction and never again
  (`EsseyToken.sol:22` `TOTAL_SUPPLY = 8_888_888_888e18`; `:28` the single `_mint`). There is **no mint
  function** — supply only ever goes down, via burns.
- **Adminless.** No owner, no pause, no blocklist, no upgrade — "nothing for a key to do"
  (`EsseyToken.sol:14`). There is no privileged EOA that can touch a holder's balance or the supply.
- **`ERC20Permit`** so activating a Tier or buying a Case is one transaction (`EsseyToken.sol:20`).
- **Real burns** (`ERC20Burnable`) reduce `totalSupply` outright — the property the reserve's solvency
  math depends on (`EsseyToken.sol:18`).

The token is deliberately dumb. All value logic lives in the reserve and the fee hook, not in the token.

---

## 2. EsseyReserve — the equity-pegged floor

The reserve holds a pile of real tokenized-equity backing. **Holding $ESSEY is a redeemable, pro-rata,
in-kind claim on that pile** (`rh-chain/src/market/EsseyReserve.sol:17-18`). The peg is the *value of
the equities*, not the price of any single position.

### Fully adminless

`EsseyReserve` has **no owner, no registrar, no roles, no setters, no withdraw, no upgrade, no pause**
(`EsseyReserve.sol:21`). The only two things the contract can do with a token are (a) accept a deposit
and (b) pay out a holder's own claim (`EsseyReserve.sol:22-23`). It never trusts a price and never
reasons about which tokens are "real" — valuation, legitimacy, and bond eligibility live off-contract
(`EsseyReserve.sol:23-25`).

### The backing basket (on-chain today)

The reserve currently backs $ESSEY with a **12-token equity basket** plus a **FLR bootstrap position**:

- NVDA, AAPL, GOOGL, TSLA, GLD, SPY, MSTR, QQQ, NFLX, DJT — tokenized equities/ETFs
- CASHCAT, PONS — the two non-equity legs
- **FLR bootstrap position** at `0x8ad25c65587979533fa1ca0d2194a76d5bae305d`

The contract is token-agnostic by design: backing can be 12 tokens or 12,000, and any address can
`fund()` any token in (`EsseyReserve.sol:31, :89-96`). Basket composition is founder-supplied on-chain
state, not a contract constant — the reserve does not enumerate an allow-list.

### The floor only ratchets up

Every deposit raises the floor for every holder and never lowers it — fee streams and FLOOR
distributions deposit stock here, and each deposit ratchets the floor
(`EsseyReserve.sol:18-19`). There is no path that removes backing except a holder redeeming their own
proportional slice.

### Redemption — units, not dollars

Redemption is **in-kind and denominated in units of the underlying tokens, never in a dollar figure**
the contract has to price. It is a two-step, O(1)-per-token flow so the basket can grow unbounded
(`EsseyReserve.sol:27-31`):

1. **`redeem(esseyAmount)`** burns your $ESSEY and mints an owner-bound Receipt
   (`EsseyReserve.sol:105-110`). The burned $ESSEY leaves circulation permanently — burned if supported,
   else stranded at `0xdEaD` (`EsseyReserve.sol:114-116`).
2. **`claim(id, token)` / `claimMany(id, tokens[])`** pulls your named slice of each token, one O(1)
   call each (`EsseyReserve.sol:28-31, :126-127`).

### The 5% exit fee and provable solvency

Each redeem's claim **weight** is `w = e·(BPS − EXIT_FEE_BPS)/BPS` = **95% of the $ESSEY burned**; the
forfeited **5% stays in the reserve as permanent over-collateralisation**
(`EsseyReserve.sol:34-41, :53` `EXIT_FEE_BPS = 500`).

Every token's payout divides by a **fixed** denominator `claimBase` = the genesis $ESSEY supply, captured
once at construction (`EsseyReserve.sol:35, :57, :83`). Because every receipt claims against that same
fixed denominator and `Σw ≤ 0.95·claimBase < claimBase`, the denominator always exceeds the weight, so
**every payout ≤ live balance and the reserve can never be over-drawn** (`EsseyReserve.sol:41-42`). The
accounting is **order-independent**: splitting a stake into many receipts cannot dodge the fee, and late
claiming cannot recapture it (`EsseyReserve.sol:36-40`).

A paused or misbehaving stock leg (Robinhood Stock Tokens are upgradeable and can pause) must never brick
another token's claim: each claim isolates its token in a self-call and, on revert or zero payout, emits
`ClaimSkipped` and stays retryable rather than reverting the whole claim (`EsseyReserve.sol:45-52, :72`).

---

## 3. The fee model — LOCKED at 50 / 40 / 10, no burn

Fees accrete the base layer through `EsseyReserveHook`, the $ESSEY launch/swap hook. The model is
**locked** and its audit gate is **MET** (`docs/audits/esseyreservehook-gate-2026-08-31.md`).

- The hook skims a fee **always denominated in USDG** (`feeCurrency`, never $ESSEY) on every swap and
  splits the base fee three ways — **holders / floor(reserve) / dons** — with an anti-snipe surcharge
  routed 100% to the floor (gate doc, "What the hook is").
- **Default split: 45 floor(reserve) / 40 holders / 15 dons** (constructor arg) — verified against the code
  the deploy actually uses: `script/DeployEsseyV4Pool.s.sol:47-49` (`RESERVE_SHARE_BPS = 4_500`,
  `HOLDERS_SHARE_BPS = 4_000`, `DONS_SHARE_BPS = 1_500`), matched by `test/EsseyReserveHook.t.sol:132-134`.
  *(Corrected 2026-09-02: this line previously read "50 holders / 40 floor / 10 dons", inherited from an
  error in the gate receipt that mistook the **rails** below for the **split**. The rails are 40/50/20; the
  split is 45/40/15 and sits with real margin inside them, not on their limits.)* There is **NO burn** —
  the hook never mints or skims $ESSEY; the fee is always the USDG leg (gate doc, invariants).
- **Rails**, enforced at construction and on any `proposeSplit`:
  `MIN_RESERVE_BPS = 4000`, `MAX_HOLDERS_BPS = 5000`, `MAX_DONS_BPS = 2000`, and the split must sum to
  10,000 bps. The floor floor is therefore **≥40% of every base fee + 100% of every surcharge, always**
  (gate doc, invariants).
- The fee **rate and all sinks are immutable** (no setter). A governor may change *only the split*,
  within the rails, behind a **48h timelock**, and `lock()` is a one-way renounce to full immutability
  (gate doc, invariants).

The hook accretes the reserve; the reserve stays adminless. Nothing in the fee path can mint $ESSEY or
skim the reserve.

**Gate status:** three consecutive complete-clean 3-agent rounds on byte-identical code; 92 tests passing
under `FOUNDRY_PROFILE=v4` (gate doc, header). Remaining before it goes live: two deploy-config asserts
(`feeCurrency` = USDG leg; $ESSEY non-circulating until the atomic seed) and the founder's per-instance
deploy (gate doc, "Status"). The hook is **not yet deployed to mainnet**; $ESSEY and the reserve are.

---

## 4. What is live vs. what is next

| Piece | Status |
|---|---|
| $ESSEY token (fixed supply, adminless) | **LIVE mainnet 4663** |
| EsseyReserve (adminless floor, 12-token basket + FLR bootstrap) | **LIVE mainnet 4663** |
| Fee hook (default split 45 floor / 40 holders / 15 dons; rails 40/50/20; no burn) | code gate **MET**, **not yet deployed** |
| Lending (borrow vs Stock Tokens) | ported to `rh-chain`, audited, **not yet deployed** — see [MAINNET-LENDING-SCOPE.md](MAINNET-LENDING-SCOPE.md) |
| Shielded / private transfers | **testnet (46630)**, mainnet-blocked — see [ESSEY-PRIVATE.md](ESSEY-PRIVATE.md) |

The whole cross-flow register lives in [MAINNET-ACTIVATION.md](MAINNET-ACTIVATION.md); protocol-only open
items in [OUTSTANDING.md](OUTSTANDING.md).
