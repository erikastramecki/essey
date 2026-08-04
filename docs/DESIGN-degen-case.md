# Degen Case — the provably-fair, provably-solvent multiplier gacha (spec)

Status: **design / ungated parts spec'd; entropy + legal are gated (see §7).** Extends `EsseyCases.sol`
variant (b), the "degen case" already scoped in `TOKENOMICS-essey.md` §"Two variants".

## 1. Positioning — beat them at their own game
StonkBrokers' Broker Box is a 0.70×–50× multiplier roll at ~90% RTP. Two things they **cannot** show:
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
- **This *is* the progression/FOMO mechanic** (the same one StonkBrokers has: *"a tier opens when free
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

## 7. THE TWO GATES (the reason it isn't live — from your own docs)
**7a. Entropy (technical, hard blocker).** Blockhash is fine for fair-value (manipulation wins nothing)
but exploitable for multipliers (a sequencer could bias toward the 50×). `EsseyCases.sol` + the audit
gate hold it *"insufficient for the degen variant — requires a hardened VRF."* And `DESIGN-seats-
market-layer.md`: *"no Chainlink VRF on the production path."* So we need an unmanipulable, verifiable
source. **Options one-pager below (§8).** This is the long pole.

**7b. Legal (jurisdiction).** A win-more/less-than-paid roll is a **game of chance**. `TOKENOMICS-
essey.md`: *"higher reg risk — StonkBrokers US-restricts their Degen Mode for exactly this. Gated,
jurisdiction-aware, separately legal-reviewed."* Requires **geo-gating (US + restricted regions) from
day one + a separate legal review** before production. Founder's call; the docs assume yes.

## 8. Entropy options one-pager (pick the randomness path)
Requirement: at open, a random word that (i) the RH sequencer/buyer/house cannot bias, and (ii) anyone
can verify was used correctly. **First unknown to resolve: which of these is actually live on Robinhood
Chain — no Chainlink VRF is (per the docs); the others need on-chain verification before committing.**

| Option | How | Pros | Cons | Fit |
|---|---|---|---|---|
| **A — ZK-verifiable draw** | Draw proven (ZK) to be correctly derived from committed inputs; unmanipulable by construction | Strongest moat; ties into the existing single-VK IVC/ZK work; no external liveness dep | Most R&D (VDF/threshold + a ZK proof of correct draw); latency | Best long-term; on-brand with the ZK moat |
| **B — External VRF oracle** | Request randomness from a VRF service (Gelato VRF, API3 QRNG, Randamu/drand-VRF); callback delivers a proof-verified word | Battle-tested, simple, provable via the VRF proof | **Must confirm a provider is live on RH Chain** (Chainlink VRF is not); external dep + fees + callback liveness | Fastest IF a provider exists |
| **C — drand beacon + relayer** | Commit at buy; resolve against a future **drand** round (League of Entropy public beacon) posted on-chain by a permissionless relayer | Unmanipulable by the RH sequencer; simpler than ZK; the round+signature are publicly verifiable | Needs a relayer to post rounds (liveness); a light trust assumption on the beacon | Pragmatic middle — real unmanipulable randomness without full ZK |

**Recommendation:** design against the `IEntropySource` interface now (so the ladder/solvency/UX are
built and audited independent of this choice). For the source: **if a VRF provider is verified live on
RH Chain → Option B** (ship fastest). **If not → Option C (drand + relayer)** for time-to-market with
genuine unmanipulable randomness, and slot in **Option A (ZK draw)** as the v2 moat once the IVC work
can absorb it — no game changes required, just a new `IEntropySource` implementation.

## 9. Open decisions for the founder
1. **Entropy path** (A / B / C) — gated on verifying what's live on RH Chain (I can research this next).
2. **Jurisdiction gating + legal review** — geo-gate US day one? Getting sign-off?
3. **Ladder + RTP** — the §2 numbers, or tune the floor/jackpot.

## 10. What I can build now (no gates)
`EsseyCasesDegen` with the ladder, the worst-case backing invariant, fee routing, sell-back, and the
`IEntropySource` seam stubbed — plus the reveal UX and the full test suite + audit. Only the live
entropy wiring and the geo-gate policy wait on §9.
