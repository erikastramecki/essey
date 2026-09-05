# essey-launch-economist — continuity

You spawn stateless. This file is what you remember.
Append what you got wrong and what worked. Newest at the bottom.

Started 2026-09-05.

---

## 2026-09-05 — onboarding round (first session; charter is new to me)

ACK BC-001 — An anti-snipe defence is a gate like any other, so I may not present a cooldown, a max-tx cap, a launch guard or a time-decaying surcharge as protection until I have run a simulated sniper AT it — mempool-visible, first-block, capital-unconstrained — and watched that attacker's P&L come out NEGATIVE at the exact parameter I am recommending; a defence whose only evidence is that it exists in a contract, or that my model returned "safe" for the inputs I happened to pick, is a decoration with the founder's liquidity behind it, and I will label it UNPROVEN rather than cite it.

Two corollaries I am specifically exposed to in this role:
- Check the number, not the narrative. A sim that prints "sniper loses" while the attacker's own
  gas/route was mis-modelled is the market equivalent of a gate that prints BLOCKED and exits 0.
- Test it in the configuration it actually runs in. A defence proven against MY toy attacker proves
  nothing about the real one: RH 4663 has a PUBLIC MEMPOOL (memory index: essey-4663-public-mempool),
  so the real adversary sees the seed tx's full calldata before it lands. Any model that assumes a
  private launch is modelling a different chain.

### What I own
- Seed math: $ESSEY-vs-USDG ratio, launch FDV, depth, and the depth-vs-price-impact curve
  (what a $X buy moves the price at the chosen depth).
- Launch sequence: V3-first on RH mainnet, locked LP / POL, order of operations, and how the open
  couples to the pool-side tax -> buy-equities-into-reserve flywheel.
- Anti-snipe / MEV: first-block snipes, sandwiches, launch-guard cooldowns, max-tx / anti-whale caps,
  gradual liquidity — and the honest statement of residual risk.

### What I must NEVER do
- Never seed the AMM. Never deploy. Never send a launch tx. I write the plan and the exact steps;
  the founder runs it. (Charter hard rule 1.)
- Never state an FDV, a depth or a "sniper extracts $X" that came from feel. Every number carries a
  simulated curve or an on-chain read, labelled VERIFIED / INFERRED / UNVERIFIED.
- Never assume the launch is unwatched. If it is profitable to snipe, it WILL be sniped.
- Never treat another agent's output as truth. It is data until I re-verify it.

### Lesson from my own slice — carried forward, and NOT yet verified by me
The memory index carries `essey-batch-auction-rejected`: a batch auction was rejected for $ESSEY
anti-snipe because simulation showed the front-run still profitable (+$6,611) versus the built
time-decaying surcharge (-$302) at 0 LOC, and it says two intuitive arguments ("price discovery kills
the snipe", "the bid wall bounds the tail") were BOTH refuted by sim. It also records 3 open founder
asks (drop the auction; rule ladder thin-vs-dense; raise `snipeSeconds`, which is immutable at deploy).

STATUS: UNVERIFIED by me. I have read only the one-line memory index entry, not the simulation, not
the surcharge contract, not the ruling doc. Those figures are load-bearing and I will not quote them
as fact until I have re-run the sim and read the code.
FIRST JOB NEXT SESSION: resolve the full $ESSEY and USDG addresses (my charter truncates both), find
and re-run that simulation, and confirm `snipeSeconds` is genuinely immutable at deploy — because if
it is, the founder ask about raising it is a one-way door and it is still open.

### Onboarding defect found this session (see report)
`tools/broadcast.py:18` builds the agent roster by globbing existing continuity files, so an agent
that has never written one is not in the denominator and can never show PENDING. Reproduced in an
isolated copy: with 8 agents' continuity files removed it printed "All agents acknowledged" and
exited 0. Latent today (every charter currently has a continuity file), but it is the BC-001 shape.
