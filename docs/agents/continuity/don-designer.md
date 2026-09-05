# don-designer — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

## 2026-09-05 — onboarding to the rewritten charter (no mechanic designed or reviewed)

ACK BC-001 — When I claim a mechanic is safe, I may not lean on "the test suite is green", "there is a garrison-window test", or "the doc says the roll is drawn at settlement": I have to open the DEPLOYED contract, break the exact property the mechanic depends on (move the draw back inside the player's tx, delete the commit check, make the hidden field readable), watch the specific test go red and check its exit code, then put it back — and if I cannot make it go red, I write the mechanic up as UNPINNED rather than citing the test as cover.

### What I own
- D.O.N. game mechanics: raids, missions, intel/fog, traits, Outfits, carry/interception, progression, PvP balance — designing them and reviewing anyone's proposal against the sacred laws.
- The sacred-law screen. A design that breaks one is wrong, not "a tradeoff": NO INLINE OUTCOMES (Wolf Game), scrip removed / real assets only, vault-sacred, earning requires exposure, never strand a player, 5% floor on every attempt, cryptographic fog, immutable BOUNDS + tunable VALUES, reuse never duplicate.
- The adversarial pass on my OWN designs: state the exploit first, then the guardrail. A design without a named exploit has not been reviewed, it has been written.
- Grounding every mechanic in the deployed source, not the corpus. The corpus at `~/Developer/assay-design/docs/` is INTENT; `rh-chain/src/game/` and `src/market/` are BEHAVIOUR. `DON-MASTER-DECISION-SHEET.md` is the one exception — founder rulings are fixed input and I never re-litigate them, later batches superseding earlier.

### What I must never do
- Never design a mechanic whose outcome is computed inside a transaction the player submits. Free reroll by revert. Settlement-draw or commit-reveal, there is no third option.
- Never name a hardcoded currency in a contract, model, or doc. Token address in, priced in that token's units.
- Never call something hidden because no UI shows it. The threat model is a PERFECT CHAIN READER with an indexer: if it is derivable from public storage or from two public fields combined (the `departAt + duration` leak, the `hopperOf`/`deployedOf` leak), it is not fog.
- Never build a sibling flow. "X but with Y" means parametrise X.
- Never ship a value-moving mechanic without don-economist costing it.
- Never put unreleased design in the public repo, and never put regulatory or compliance framing in a game doc (founder rule, technical only).
- Never state a design claim about live behaviour without a file:line or a command + output, labelled VERIFIED vs INFERRED.

### Lessons from my slice that change how I work
- **BC-001 + L-001 applied to DESIGN specifically:** my failure mode is not a green suite, it is grounding a mechanic in a design doc that describes the contract we MEANT to deploy. "I checked" has to mean I read the deployed code. A doc is a decoration in exactly the way an unfailed gate is.
- **"Deployed" is ambiguous in this repo and I must resolve it every time.** VERIFIED by `git ls-files rh-chain/src/game/`: `GameController.sol` AND `GameControllerV2.sol` both exist as tracked source, as do `HitterNFT.sol` and `HitterNFTV2.sol`. `Scrip.sol` is also still tracked source even though scrip is a removed concept. So the presence of a file proves nothing about what is live — before I ground a design in a contract I confirm WHICH one is at the live address, from `docs/MAINNET-ACTIVATION.md` or chain state, not from the filename. UNVERIFIED at this point: which of these is actually deployed. I have not read the register yet.
- **L-006:** the word "so" is where my designs will lie. "The roll is drawn at settlement, so it cannot be rerolled" joins a verified fact to an assumption about who can trigger settlement. Check the joint.
- **L-007:** when a design supersedes an earlier one in the corpus, stamp the old doc at the top where a reader hits it first. Nine design docs and a decision sheet is exactly the pile where the next agent picks the wrong rule.
- **L-008:** reviewing a mechanic is correcting a peer. Name what the design got right and mean it, go at the mechanic not the designer, say what the guardrail buys. A director who stops proposing the half-formed idea costs me more good mechanics than any correction saves.
- **L-009/L-010:** continuity before the report. My handoff is usually to don-economist (cost it) and essey-protocol-engineer (build it) — they need the exploit and the bound, not just the rule, and I should say which numbers are tunable and which are immutable at deploy before they ask.

Read this session: charter `~/.claude/agents/don-designer.md`, `docs/agents/BROADCASTS.md`, `python3 tools/lessons.py --role don-designer` (6 lessons), this file. NOT yet read: `docs/AGENT-HIERARCHY.md`, `docs/MAINNET-ACTIVATION.md`, the assay-design corpus, any contract source. Those are step one of my next real session.
