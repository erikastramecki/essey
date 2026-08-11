# Degen Case — the provably-fair, provably-solvent multiplier gacha (spec)

Status: **design / ungated parts spec'd; entropy + legal are gated (see §7).** Extends `EsseyCases.sol`
variant (b), the "degen case" already scoped in `TOKENOMICS-essey.md` §"Two variants".

## 1. Positioning — beat them at their own game
the reference desk' Broker Box is a 0.70×–50× multiplier roll at ~90% RTP. Two things they **cannot** show:
- that the RNG was fair (it's their box, their draw), and
- that the top multiplier is actually backed (no solvency proof).

Essey ships the same variance and RoI, but **provably fair AND provably solvent** — the odds are
on-chain and disclosed, and every open is backed by real reserved stock before you pull. Tagline from
`TOKENOMICS-essey.md`: *"the only case system where the odds AND the bankroll are provable."* Same
dopamine, ours is the one you can verify.

## 2. The multiplier ladder (illustrative — on-chain, tunable, disclosed)
The house pays `multiplier × referenceValue` in stock (referenceValue ≈ one Case's USD worth, e.g. $100).
Odds are stored on-chain and shown in the UI, so RTP is provable, not marketed.

| Roll | Multiplier | Probability | p × m |
|---|---|---|---|
| Common | **0.65×** | 84.00% | 0.5460 |
| Break-even | **1.00×** | 10.50% | 0.1050 |
| Green | **2.00×** | 4.00% | 0.0800 |
| Big | **5.00×** | 1.30% | 0.0650 |
| **Gold Bell** | **50.00×** | 0.20% (1 in 500) | 0.1000 |

**RTP = Σ(p×m) = 0.896 → 89.6%** (≈ their 90%). House edge **10.4%** funds the bankroll + routes to the
Bell (same fee engine as fair-value Cases). Ladder is a parameter set — tune the floor/jackpot to taste;
the *provable-fairness* is that whatever it is, it's on-chain and the draw verifies against it.

## 3. Economics (reuses the EsseyCases fee engine)
- **Buy** in `$ESSEY` (sunk to treasury) + a base-token fee split `boosterShareBps` → Bell / treasury.
- **The 10.4% edge** accrues to the buyback/prize reserve → grows the bankroll → routes a share to the
  Bell. Every open feeds distributions, exactly like the fair-value pack.
- **Sell-back** unchanged: return a won stock unit for oracle value − spread (session-gated).
- New `$ESSEY` sink + NFT volume (Cases are NFTs → royalties → Bell) + a third stock-acquisition path
  → borrow against winnings on EsseyPool. Closes the flywheel from a new angle.

## 4. Provably-solvent bankroll — the moat, and the progression mechanic
Extend the `EsseyCases` backing invariant (`buy` reverts unless inventory exceeds unopened cases) to the
**worst-case multiplier payout**:

- Every unopened degen case reserves its tier's **max multiplier × referenceValue** in real stock until
  it resolves. `buy` reverts unless the free reserve covers the new case's worst case on top of all
  outstanding reservations. So "the house had the 50× reserved before you opened" is an on-chain
  invariant, not a promise.
- **This *is* the progression/FOMO mechanic** (the same one the reference desk has: *"a tier opens when free
  stock can reserve one worst-case round"*). The **max-multiplier tier scales with the bankroll**:
  small reserve → top tier is 5×; as the edge compounds the reserve, **the 50× "Gold Bell" unlocks** —
  provably. A live "Gold Bell: LOCKED / UNLOCKS at $X reserve" meter turns solvency into hype.

## 5. Contract shape (ungated logic; entropy abstracted)
A separate `EsseyCasesDegen` (cleaner audit surface than a mode flag on the reg-sensitive fair-value
contract), reusing `StaleFeedGuard` + the reserve/sell-back patterns. **The draw is the only gated
piece — abstract it behind an interface so the ladder/solvency/payout are buildable and auditable now:**

```solidity
interface IEntropySource {
    // Commit at buy; resolve with an unmanipulable, verifiable random word at open.
    function requestDraw(uint256 caseId) external returns (bytes32 commitment);
    function drawReady(uint256 caseId) external view returns (bool);
    function randomWord(uint256 caseId) external view returns (uint256); // reverts until ready
}
```
- `buy(tierId)` — checks worst-case backing (§4), sinks `$ESSEY`, routes the fee, mints the Case NFT,
  calls `entropy.requestDraw`.
- `open(caseId)` — requires `entropy.drawReady`, maps `randomWord % 1e6` onto the on-chain ladder to a
  multiplier, pays `multiplier × referenceValue` in stock from the reserve, releases the worst-case
  reservation. Fails open like the Bell if the reserve/oracle can't settle.
- **Jurisdiction gate**: an `allowedToOpen(address)` hook (on-chain allowlist or an attestation) so
  restricted regions are blocked at the contract, not just the UI — see §7. Fair-value Cases stay
  ungated.
- Full Foundry suite + the standing 3-round adversarial audit before any deploy (esp. the ladder-mapping
  fairness, the worst-case backing math, and the entropy integration).

## 6. Reveal UX (already built for this)
The CS:GO reel + rarity glow in `cases.tsx` was made for variance. Additions: a multiplier readout on
the card, escalating tension for high tiers, a full-screen **Gold Bell** moment on the 50×, and the
"Gold Bell unlocks at $X" reserve meter on the case picker. Minimal lift over the existing reel.

## 7. Entropy — the one real gate (DECIDED)
Blockhash is fine for fair-value (manipulation wins nothing) but exploitable for multipliers (a
sequencer could bias toward the 50×). `EsseyCases.sol` + the audit gate hold it *"insufficient for the
degen variant — requires a hardened VRF."* No Chainlink VRF on RH Chain; no BLS precompile (EIP-2537)
on Orbit's ArbOS, so direct on-chain drand verification is out. **Decision: Dice Protocol** (§8).

*(Legal/jurisdiction is handled out-of-band by the founder and is explicitly out of scope for this
spec — no geo-gating hook is required in the contract.)*

## 8. Entropy options one-pager (pick the randomness path)
Requirement: at open, a random word that (i) the RH sequencer/buyer/house cannot bias, and (ii) anyone
can verify was used correctly. **First unknown to resolve: which of these is actually live on Robinhood
Chain — no Chainlink VRF is (per the docs); the others need on-chain verification before committing.**

| Option | How | Pros | Cons | Fit |
|---|---|---|---|---|
| **A — ZK-verifiable draw** | Draw proven (ZK) to be correctly derived from committed inputs; unmanipulable by construction | Strongest moat; ties into the existing single-VK IVC/ZK work; no external liveness dep | Most R&D (VDF/threshold + a ZK proof of correct draw); latency | Best long-term; on-brand with the ZK moat |
| **B — External VRF oracle** | Request randomness from a VRF service (Gelato VRF, API3 QRNG, Randamu/drand-VRF); callback delivers a proof-verified word | Battle-tested, simple, provable via the VRF proof | **Must confirm a provider is live on RH Chain** (Chainlink VRF is not); external dep + fees + callback liveness | Fastest IF a provider exists |
| **C — drand beacon + relayer** | Commit at buy; resolve against a future **drand** round (League of Entropy public beacon) posted on-chain by a permissionless relayer | Unmanipulable by the RH sequencer; simpler than ZK; the round+signature are publicly verifiable | Needs a relayer to post rounds (liveness); a light trust assumption on the beacon | Pragmatic middle — real unmanipulable randomness without full ZK |

**DECISION (2026-08-04, after research): Dice Protocol** — the only randomness actually deployed on RH
Chain, and it's Option B *and* C's best traits combined: a Pyth-Entropy-compatible **two-party
commit-reveal** (user randomness + a keeper hash-chain reveal), **verifiable on-chain via Keccak256**
(on-brand — anyone can check), neither party can bias. Oracle `0xd8a0680e7699526b57140ed4eafdcc7219dc0a0c`
on RH Chain 4663; fee 0.000025 ETH (or $0.05 USDG via x402); `IEntropyConsumer` /
`entropyCallback(uint64 seq, address provider, bytes32 random)` — ~50 lines.
- **Async open (better UX):** buy → the keeper callback (~1–3s) *is* the reveal; no manual open step.
- **Only residual risk:** a keeper can *withhold* (not bias) → handle with a per-case timeout +
  re-request/refund path in the contract.
- **Swappable:** the Dice/Pyth interface is standard, so a later move to Pyth Entropy or Gelato VRF (or
  the ZK draw, Option A, as the eventual moat) is a thin adapter — the game never changes.
- **Testnet:** Dice confirmed on mainnet 4663; if absent on 46630, a `MockEntropy` (immediate reveal)
  drives tests + the testnet demo. Same `IEntropyConsumer` interface.

## 9. Status
- **Entropy: DECIDED — Dice Protocol** (§8).
- **Legal: handled out-of-band** (founder), out of scope here.
- **Ladder: tunable** (§2 is the starting set; on-chain + disclosed).

## 10. Build (in progress)
`EsseyCasesDegen` against the `IEntropyConsumer` interface: ladder, worst-case-backed provably-solvent
bankroll, fee routing, sell-back, a keeper-withhold timeout/refund path, and a `MockEntropy` for
tests/testnet. Then the standing 3-round adversarial audit before any push/deploy.
