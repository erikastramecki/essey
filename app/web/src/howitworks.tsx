// /how-it-works — the full Dons v3 story as a designed scroll page (not a markdown dump).
// Copy is the approved explainer set (2026-08-11); every number mirrors the deployed contracts and
// the page says so up front. Styling: the house design system (styles.css hw-* classes, theme
// tokens — works in both themes). Wide tables + diagrams scroll inside their own container; the
// page never scrolls sideways.
import type { ReactNode } from "react";

/* ------------------------------- tiny primitives ------------------------------ */

/// Render **bold** spans from the approved copy without a markdown dependency.
function md(s: string): ReactNode {
  const parts = s.split("**");
  if (parts.length === 1) return s;
  return parts.map((p, i) => (i % 2 ? <b key={i}>{p}</b> : p));
}

function P({ children }: { children: ReactNode }) {
  return <p className="hw-p">{children}</p>;
}

function Section({ id, kicker, title, children }: { id: string; kicker: string; title: string; children: ReactNode }) {
  return (
    <section id={id} className="hw-sec">
      <span className="eyebrow">{kicker}</span>
      <h2>{title}</h2>
      {children}
    </section>
  );
}

/// accent: an optional CSS color for the card's top rule (the mint paths use green/blue/brass).
function Card({ children, accent }: { children: ReactNode; accent?: string }) {
  return (
    <div className="hw-card" style={accent ? { borderTop: `2px solid ${accent}` } : undefined}>
      {children}
    </div>
  );
}

function Warn({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="hw-warn">
      <div className="hw-warn-h">⚠ {title}</div>
      <div>{children}</div>
    </div>
  );
}

function Stat({ big, label }: { big: string; label: string }) {
  return <div className="hw-stat"><b>{big}</b><span>{label}</span></div>;
}

/// Wide content (tables, diagrams) scrolls inside its own box — the page body never scrolls sideways.
function Scroller({ minWidth, children }: { minWidth: number; children: ReactNode }) {
  return (
    <div className="hw-scroll">
      <div style={{ minWidth }}>{children}</div>
    </div>
  );
}

/* ----------------------------------- page ------------------------------------ */

const TOC = [
  ["#what-is-a-don", "What is a Don"],
  ["#get-one", "Get one"],
  ["#the-floor", "The Floor"],
  ["#trade", "Trade"],
  ["#earn", "Activate & Earn"],
  ["#borrow", "Borrow"],
  ["#flywheel", "The Flywheel"],
  ["#faq", "FAQ"],
] as const;

export function HowItWorksPage() {
  return (
    <div className="hw">
      {/* ---- hero ---- */}
      <div className="hw-hero">
        <span className="eyebrow">Essey · Dons v3</span>
        <h1>How Essey works</h1>
        <p>
          {md("A Don is a **seat**, a **floor**, and a **margin account** — all in one NFT. Every number on this page is read from the deployed contracts, not a pitch deck. Where a value is admin-tunable, we say so.")}
        </p>
        <nav className="hw-toc">
          {TOC.map(([href, label]) => <a key={href} href={href}>{label}</a>)}
        </nav>
      </div>

      {/* ---- 1 · what is a Don ---- */}
      <Section id="what-is-a-don" kicker="01" title="What is a Don">
        <P>{md("A Don is one of **8,888** NFTs on Robinhood Chain — and it is not just a picture. A Don is three things at once:")}</P>
        <div className="hw-grid">
          {[
            ["♛", "A seat at the table", "Stake it and it earns a share of every fee the protocol collects, paid out in tokenized Robinhood stock."],
            ["⬢", "A hard floor of $ESSEY", "Every Don is backed by a reserve you can always cash it in against — currently 300,030 $ESSEY per Don, and that number can only go up."],
            ["◈", "A margin account", "Borrow $ESSEY against your Don's floor while it stays in your wallet, still earning."],
          ].map(([icon, t, b]) => (
            <Card key={t}>
              <div style={{ fontSize: 20, color: "var(--gold-hi)", marginBottom: 7 }}>{icon}</div>
              <div className="hw-card-h">{t}</div>
              {b}
            </Card>
          ))}
        </div>
        <P>{md("Each Don also carries its own on-chain **Vault** — a token-bound account created at mint. Everything the Don earns lands in its Vault, and the Vault travels with the Don. Sell the Don, and the Vault goes with it.")}</P>
      </Section>

      {/* ---- 2 · get one ---- */}
      <Section id="get-one" kicker="02" title="Get one — three ways in">
        <P>{md("All mint fees are paid in ETH, and **100% of every fee buys stock for staked holders** — there is no team cut on mints (the split is configurable on-chain and set to 0).")}</P>
        <div className="hw-grid">
          <Card accent="var(--good)">
            <div className="hw-card-k" style={{ color: "var(--good)" }}>Free · whitelist</div>
            <div className="hw-card-big">Gas only</div>
            {md("If you hold a whitelist allocation, you claim your Dons for gas only. Each comes with a randomly rolled set of traits. The whitelist is a Merkle root committed on-chain behind a **2-day public timelock** — the list is visible before it goes live, and no one can swap it in quietly.")}
          </Card>
          <Card accent="var(--r-bluechip)">
            <div className="hw-card-k" style={{ color: "var(--r-bluechip)" }}>Reroll · unlimited</div>
            <div className="hw-card-big">0.00075 ETH <i>~$3</i></div>
            {md("Don't love the roll? Re-randomize any Don you own — as many times as you like, until you stake it. Every reroll frees your old trait combo for someone else and locks in your new one. A random Don stays random: rerolling re-rolls, it never converts to a custom build.")}
          </Card>
          <Card accent="var(--gold)">
            <div className="hw-card-k" style={{ color: "var(--gold)" }}>Custom · exact traits</div>
            <div className="hw-card-big">0.0025 ETH <i>~$10</i></div>
            {md("Open the builder, choose every trait, and mint exactly that Don. Trait combos are unique by contract — the uniqueness ledger lives on-chain, so no two Dons can ever share a look.")}
          </Card>
        </div>
        <P>{md("The team reserve is hard-capped on-chain at **2,722 Dons**: 2,222 of those are the AMM's trading inventory (protocol-owned, seeded into the exchange — not held by anyone), and up to 500 are for partners and team. The cap is immutable; it cannot be raised.")}</P>
        <div className="hw-note">{md("Your Don's art stays changeable until the moment you stake it. **Staking locks the art forever.**")}</div>
      </Section>

      {/* ---- 3 · the floor ---- */}
      <Section id="the-floor" kicker="03" title="The Floor">
        <P>{md("Behind every Don sits the **DonReserve**: a pot funded with **2,666,666,666 $ESSEY** — 30% of the total supply — split across the 8,888-Don cap.")}</P>
        <div className="hw-stats">
          <Stat big="2,666,666,666" label="$ESSEY in the reserve — 30% of total supply" />
          <Stat big="÷ 8,888" label="Dons backed — read from the immutable cap" />
          <Stat big="= 300,030" label="$ESSEY floor per Don, today — it only rises" />
        </div>
        <ul className="hw-list">
          <li>{md("**Redemption is always open.** At any moment, any Don's owner can redeem it against the reserve and receive its full floor share in $ESSEY. No permission, no window, no admin.")}</li>
          <li>{md("**The floor only rises.** Anyone can fund the reserve (and the protocol routinely does — 30% of all loan interest goes here), but the only way $ESSEY leaves is a redemption, which pays exactly one Don's pro-rata share. The math guarantees the floor for everyone else never drops.")}</li>
          <li>{md("**Nobody can touch it.** The reserve has no owner, no admin, no upgrade path, and no setter on its accounting. The backed-supply figure is read from the Don contract's own immutable cap. There is nothing to rug.")}</li>
        </ul>
        <Warn title="Redeeming is a one-way door">
          {md("The reserve pays you the floor and locks your Don inside it permanently. That Don's membership is over: no more staking, no more payouts — and its Vault, with everything in it, is locked away too. **Claim and empty your Vault before you redeem.** Redemption is the exit hatch that guarantees the floor; it is not a trade you reverse.")}
        </Warn>
        <P>{md("Because redemption is always open at the floor, a Don can never trade below it — anyone who saw a cheaper price would buy and redeem for instant profit until the price snapped back.")}</P>
      </Section>

      {/* ---- 4 · trade ---- */}
      <Section id="trade" kicker="04" title="Trade">
        <P>{md("The **DonExchange** is the broker desk: a vault holding Dons on one side and $ESSEY on the other, trading at one price. That price is pinned on every trade to **the live redemption floor** (never below the 300,000 $ESSEY deploy minimum), read fresh from the reserve — so the desk can never be arbitraged against a risen floor.")}</P>
        <Scroller minWidth={560}>
          <table className="hw-table">
            <thead>
              <tr><th>Action</th><th>You pay / receive</th><th className="n">Fee</th><th className="n">At today's floor</th></tr>
            </thead>
            <tbody>
              <tr><td className="k">Buy</td><td>Pay price + fee → next Don from inventory</td><td className="n">8%</td><td className="n">~324,032 $ESSEY</td></tr>
              <tr><td className="k">Snipe</td><td>Pay price + fee → the exact Don # you want</td><td className="n">12%</td><td className="n">~336,034 $ESSEY</td></tr>
              <tr><td className="k">Sell</td><td>Send your Don → receive price − fee</td><td className="n">8%</td><td className="n">~276,028 $ESSEY</td></tr>
            </tbody>
          </table>
        </Scroller>
        <div className="hw-note">
          {md("**70% of every trade fee buys tokenized stock for staked Dons.** The remaining 30% goes to the protocol treasury. Every trade — yours or anyone's — pays the people seated at the table.")}
        </div>
        <P>{md("Every trade takes a slippage bound (max cost on buys, min proceeds on sells): because the floor can rise between your click and your transaction, the trade reverts rather than filling at a worse price than you approved.")}</P>
        <P>{md("The desk is adminless over funds. The only privileged role can *add* Dons to inventory — it can never withdraw the $ESSEY reserve or touch fees.")}</P>
      </Section>

      {/* ---- 5 · activate & earn ---- */}
      <Section id="earn" kicker="05" title="Activate & Earn">
        <P>{md("Owning a Don gets you the floor. **Staking it gets you paid.** To take your seat, activate a tier by paying a one-time fee in $ESSEY. Higher tiers multiply your share of every payout:")}</P>
        <Scroller minWidth={460}>
          <table className="hw-table">
            <thead>
              <tr><th>Tier</th><th className="n">Activation fee ($ESSEY)</th><th className="n">Payout weight</th></tr>
            </thead>
            <tbody>
              {([
                ["Base", "66,666", "1.00×"],
                ["Tier 1", "166,666", "1.25×"],
                ["Tier 2", "366,666", "1.60×"],
                ["Tier 3", "666,666", "2.00×"],
                ["Tier 4", "1,666,666", "3.33×"],
              ] as const).map(([tier, fee, w]) => (
                <tr key={tier}><td className="k">{tier}</td><td className="n">{fee}</td><td className="n" style={{ color: "var(--gold-hi)", fontWeight: 700 }}>{w}</td></tr>
              ))}
            </tbody>
          </table>
        </Scroller>
        <P>{md("Fees are cumulative — upgrading later costs only the difference (Base → Tier 4 is 1,600,000 $ESSEY whether you climb rung by rung or jump).")}</P>
        <P>{md("The activation fee is a **sink, not a deposit**: **50% is burned forever, 50% goes to the treasury.** You don't get it back. What you get is your weight on every payout for as long as you hold the Don. There are no seasons, no vesting, no cooldowns — **activate, and you earn from the next ring onward.**")}</P>
        <div className="hw-grid">
          <Card accent="var(--good)">
            <div className="hw-card-h">🔔 The Bell</div>
            {md("Every fee in the protocol — mint fees, trade fees — flows into one pot. When the pot fills, the Bell rings: the pot is split across all active Dons, pro-rata by weight, in a single on-chain operation. A protocol keeper rings it (there's no ringer tip to race for — the whole pot goes to holders), and anyone may ring it themselves once the pot passes the threshold.")}
          </Card>
          <Card accent="var(--r-preferred)">
            <div className="hw-card-h">📈 Paid in stock</div>
            {md("Payouts are delivered as **Robinhood tokenized stock**. Elect up to 3 stocks with your own weights (say, 60% AAPL / 40% NVDA) — or elect nothing and receive the default BUNDLE basket. If a conversion can't settle (market closed, stale feed), that payout arrives as USDG instead — your money is never stuck behind a swap.")}
          </Card>
        </div>
        <P>{md("Everything lands in your Don's Vault. Claims are permissionless because they can only ever go one place: the Don's own Vault.")}</P>
        <Warn title="Two things clear when a Don changes hands">
          {md("Its tier and its stock elections. The buyer starts fresh and activates their own seat. Rewards already credited stay with the Don — they're in its Vault, and the Vault goes where the Don goes. So before you sell: **claim, and empty the Vault.** And remember: **activating locks your art.** The look you stake is the look forever.")}
        </Warn>
      </Section>

      {/* ---- 6 · borrow ---- */}
      <Section id="borrow" kicker="06" title="Borrow">
        <P>{md("Your Don is collateral you don't have to give up.")}</P>
        <div className="hw-stats">
          <Stat big="150,015 $ESSEY" label="max borrow per Don today — 50% of the live floor" />
          <Stat big="15% APR" label="simple (non-compounding) interest, accrued per second" />
          <Stat big="70% of floor" label="liquidation threshold — 210,021 $ESSEY today" />
        </div>
        <ul className="hw-list">
          <li>{md("**The Don stays in your wallet — still staked, still earning.** A lien blocks it from being sold, swapped, or redeemed until the debt clears; nothing else changes. Your seat keeps collecting stock the entire time you're borrowed against it.")}</li>
          <li>{md("Repay any amount, any time; anyone may repay on your behalf. Interest settles first, then principal. Full repayment releases the lien on the spot.")}</li>
          <li>{md("**Interest splits 70/30 — stock pot / floor** — borrowing pays staked Dons in stock AND raises the floor under every Don, including yours.")}</li>
        </ul>
        <P>{md("**Liquidation.** If your debt exceeds **70% of the live floor**, anyone can trigger liquidation: the facility seizes the Don and redeems it at the floor. The debt is settled from the proceeds, a 1% tip pays the caller, and **any surplus is returned to you**. But the Don itself is consumed — locked in the reserve, seat gone.")}</P>
        <Warn title="The Vault goes down with the ship">
          {md("A liquidated (or redeemed) Don takes its Vault with it — including every unclaimed dividend inside. Claim regularly, and service your loan.")}
        </Warn>
        <P>{md("The math is deliberately forgiving: at a full 50% borrow, simple interest takes about **2.7 years** to push you from 50% to the 70% threshold — and that assumes the floor never rises, which it does every time interest flows (30% of every payment lands in the reserve — plus anyone may fund it). Funding the reserve heals every open loan.")}</P>
        <div className="hw-note">
          {md("Because debt and collateral are both in $ESSEY, there is **no price oracle to fail and no keeper to trust** — and every open loan emits a solvency statement that Essey's zero-knowledge prover verifies on-chain: `debt ≤ 50% of floor` at origination, proven cryptographically, not promised.")}
        </div>
      </Section>

      {/* ---- 7 · flywheel ---- */}
      <Section id="flywheel" kicker="07" title="The Flywheel">
        <P>{md("Follow any fee to its destination and it ends in one of two places: **stock for holders, or the floor under every Don.**")}</P>
        {/* Master fee map — from the fee-flow diagram set (2026-08-11) */}
        <Scroller minWidth={860}>
          <div dangerouslySetInnerHTML={{ __html: FEE_MAP_SVG }} style={{ lineHeight: 0 }} />
        </Scroller>
        <ul className="hw-list">
          <li>{md("**Mint & reroll fees (ETH):** 100% → swapped to USDG → the Bell → tokenized stock for staked Dons.")}</li>
          <li>{md("**Trade fees (8% / 12%):** 70% → the Bell → stock for staked Dons; 30% → treasury.")}</li>
          <li>{md("**Activation fees ($ESSEY):** 50% burned (supply shrinks), 50% treasury.")}</li>
          <li>{md("**Loan interest ($ESSEY):** 70% → stock for staked Dons / 30% → the DonReserve floor — the same split as AMM fees.")}</li>
        </ul>
        <P>{md("More minting means more stock for seats. More trading means more stock for seats. More borrowing means a higher floor — which means a higher trade price, a bigger max borrow, and a stronger backstop under everything. There is no fee in the system that leaks out of it.")}</P>
        {/* Flywheel loop — from the fee-flow diagram set (2026-08-11) */}
        <Scroller minWidth={700}>
          <div dangerouslySetInnerHTML={{ __html: FLYWHEEL_SVG }} style={{ lineHeight: 0 }} />
        </Scroller>
        <p className="hw-close">A seat at this table pays you to sit in it.</p>
      </Section>

      {/* ---- 8 · FAQ ---- */}
      <Section id="faq" kicker="08" title="FAQ">
        <div className="hw-faq">
          {FAQ.map(({ q, a }) => (
            <details key={q}>
              <summary>{q}</summary>
              <div>{md(a)}</div>
            </details>
          ))}
        </div>
      </Section>
    </div>
  );
}

/* --------------------------------- FAQ copy ---------------------------------- */

const FAQ: { q: string; a: string }[] = [
  {
    q: "Why is the trade fee 8%? That's high for an AMM.",
    a: "This isn't a token AMM — it's an NFT broker desk trading whole Dons at a floor-pinned price. The fee is the anti-arbitrage margin: because any Don can always be redeemed for its floor, a fee-free desk at floor price would be drained by buy-then-redeem loops. 8% (12% to snipe a specific Don) makes that loop strictly unprofitable — and 70% of every fee buys tokenized stock for staked Dons. For reference, the mechanic we adapted charges 10%/15%; we softened both while keeping the 1.5× snipe ratio.",
  },
  {
    q: "What happens if I sell a staked Don?",
    a: "Two things clear the instant it transfers: the tier (your activation fee is a sink — it isn't refunded) and your stock elections. What doesn't clear: rewards already credited to the Don, because they live in its Vault, and the Vault goes with the Don. Practical rule — claim and empty the Vault before selling, and price the Don knowing the buyer re-activates from scratch.",
  },
  {
    q: "Can the team rug the floor?",
    a: "No, and you can verify it in the contract, not a promise. The DonReserve has no owner, no admin functions, no upgrade path, and no setter on its accounting. The number of Dons it backs is read from the Don contract's own immutable 8,888 cap. Money goes in permissionlessly; the only way it comes out is a Don's owner redeeming that one Don for its exact pro-rata share — which by construction never lowers the floor for anyone else.",
  },
  {
    q: "What exactly is the floor and can it go down?",
    a: "Floor = reserve balance ÷ Dons still backed. It's funded with 2,666,666,666 $ESSEY against 8,888 Dons — 300,030 $ESSEY per Don today. It cannot go down: funding raises it, redemptions are pro-rata (neutral, with rounding dust left in the reserve), and 30% of all loan interest flows into it. It only rises.",
  },
  {
    q: "What's \"provable solvency\"?",
    a: "Every loan the protocol writes carries an on-chain solvency statement — borrower, debt, floor, LTV — that Essey's zero-knowledge prover (the dregg circuit) commits and proves under a Groth16 verifier: debt × 10,000 ≤ floor × 5,000. The rounding is deliberately conservative (debt rounds up, floor rounds down), so the proof can only overstate risk, never hide it. Most protocols ask you to trust their dashboard; Essey's book is checkable by anyone with the verifier.",
  },
  {
    q: "Why are loans in $ESSEY and not USDG?",
    a: "Because the Don's floor is denominated in $ESSEY. With debt and collateral in the same unit, LTV and liquidation need no price oracle, no keeper, and no trading session — none of the usual failure points. Solvency reduces to two on-chain facts: the floor never decreases, and every loan starts at ≤50% of it. Want dollars? Swap the borrowed $ESSEY yourself — that's one trade, not a protocol risk.",
  },
  {
    q: "What happens to my art when I stake?",
    a: "It locks, permanently. Until you stake, traits are fluid — reroll for ~$3 as often as you like. The moment you activate a tier, the reroll path closes and the traits freeze on-chain. The art you take your seat with is the art forever, even through future sales.",
  },
  {
    q: "I got a random Don. Can I convert it to custom traits?",
    a: "No. Random Dons stay on the reroll path — unlimited ~$3 re-rolls until you're happy or you stake. The ~$10 custom path mints a new Don with exactly the traits you build; it isn't an edit to an existing one.",
  },
  {
    q: "Can I unstake and get my activation fee back?",
    a: "No — there is nothing to unstake. The fee is a sink (50% burned, 50% treasury), and in exchange your Don earns at its weight for as long as you hold it. No seasons, no vesting, no cooldown, no exit paperwork. The tier only ends when the Don changes hands.",
  },
  {
    q: "Who rings the Bell, and do they get paid?",
    a: "Anyone can, once the pot passes the threshold — a protocol keeper does it routinely. The ringer's tip is set to 0%, so 100% of the pot goes to active Dons. Ringing is one division on-chain no matter how many Dons are seated; it never gets more expensive as the table fills.",
  },
  {
    q: "What if the Bell rings and nobody has activated?",
    a: "It can't — the ring reverts if no Don is active. The pot just waits and keeps growing until someone takes a seat. Early activators inherit everything accumulated before them.",
  },
  {
    q: "Do I have to claim, or do payouts arrive automatically?",
    a: "Rings credit your Don instantly; claiming moves the credited amount into its Vault, converted to your elected stocks. Anyone can trigger a claim (it can only pay the Vault), but do it yourself regularly — anything unclaimed rides with the Don if it's sold, redeemed, or liquidated.",
  },
  {
    q: "How do stock elections work?",
    a: "Per Don, choose up to 3 supported tokenized stocks with weights summing to 100% — your personal dividend basket. No election means the default BUNDLE basket. Every slice fails open: if a conversion can't settle (market closed, stale feed, thin pool), that slice is delivered as USDG instead. Elections are per-owner and clear on transfer.",
  },
  {
    q: "If I borrow, do I stop earning?",
    a: "No — that's the point. The loan is a lien, not an escrow: the Don never leaves your wallet, stays staked, and keeps collecting stock the whole time. The only restriction is that it can't be transferred (sold, swapped, or redeemed) until the debt clears.",
  },
  {
    q: "How close is liquidation, really?",
    a: "You're liquidatable only when debt exceeds 70% of the live floor. Borrowing the full 50% at 15% simple APR takes about 2.7 years to drift to 70% — assuming the floor never rises, which it does as interest and fees flow into the reserve. Liquidation checks the live floor, so a rising floor actively heals every open loan.",
  },
  {
    q: "What do I lose if I do get liquidated?",
    a: "The Don is seized and redeemed at its floor; the proceeds pay a 1% caller tip, then your interest, then principal — and any surplus is returned to you. What's gone is the Don itself and its Vault, including unclaimed dividends. Claim often and repay early; anyone (a friend, a bot you run) may repay on your behalf.",
  },
  {
    q: "Where does each fee actually go?",
    a: "Mint and reroll fees (ETH): 100% converted and sent to the Bell — stock for staked Dons. Trade fees: 70% to the Bell, 30% treasury. Activation fees: 50% burned, 50% treasury. Loan interest: 100% to the reserve — the floor rises for all 8,888. Nothing leaks out of the loop.",
  },
  {
    q: "How many Dons does the team keep?",
    a: "The admin mint is hard-capped on-chain at 2,722 — and 2,222 of those are the exchange's trading inventory, owned by the desk, not by people. Up to 500 cover partners and team. The cap is immutable, and the whitelist itself sits behind a 2-day public timelock before it can go live.",
  },
  {
    q: "Testnet vs mainnet — what am I looking at today?",
    a: "Today's deployment is the Robinhood Chain testnet: real contracts, rehearsed live (mint → trade → borrow → repay → sell, all on-chain), but with mock USDG, mock price feeds, and an interim fee route while the ETH-side plumbing gets its mocks. Mainnet ships the same audited bytecode with real assets, per the published go-live plan. Testnet balances do not carry over.",
  },
];

/* ------------------------------ inline diagrams -------------------------------
   Static, trusted SVGs authored in-repo (fee-flow diagram set, 2026-08-11). Fixed width/height
   were swapped for width="100%" so they scale with the viewBox inside their Scroller. */

const FEE_MAP_SVG = `<svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 1200 675" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
  <defs>
    <marker id="aG" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#ad8938"/></marker>
    <marker id="aB" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#5b8fd9"/></marker>
    <marker id="aU" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#2f9e6e"/></marker>
    <marker id="aP" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#a06fd0"/></marker>
    <marker id="aR" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#c25050"/></marker>
  </defs>

  <rect width="1200" height="675" fill="#0b0c10"/>

  <text x="30" y="52" font-size="34" font-weight="700" fill="#e6c877">WHERE EVERY FEE GOES</text>
  <text x="30" y="80" font-size="16" fill="#9a958a">Essey Dons v3 · 8,888 seats at the table · every route is on-chain and immutable</text>

  <text x="186" y="112" font-size="13" font-weight="700" letter-spacing="2" fill="#9a958a" text-anchor="middle">FEES IN</text>
  <text x="610" y="112" font-size="13" font-weight="700" letter-spacing="2" fill="#9a958a" text-anchor="middle">ROUTED</text>
  <text x="1026" y="112" font-size="13" font-weight="700" letter-spacing="2" fill="#9a958a" text-anchor="middle">PAID OUT</text>

  <g>
    <rect x="28" y="122" width="316" height="70" rx="10" fill="#15161c" stroke="#5b8fd9" stroke-width="2"/>
    <text x="44" y="150" font-size="20" font-weight="700" fill="#ece9e1">MINT FEES <tspan fill="#5b8fd9">· ETH</tspan></text>
    <text x="44" y="176" font-size="15" fill="#b8b3a6">reroll ~$3 · custom mint ~$10</text>

    <rect x="28" y="206" width="316" height="70" rx="10" fill="#15161c" stroke="#ad8938" stroke-width="2"/>
    <text x="44" y="234" font-size="20" font-weight="700" fill="#ece9e1">AMM TRADE FEES <tspan fill="#ad8938">· $ESSEY</tspan></text>
    <text x="44" y="260" font-size="15" fill="#b8b3a6">8% buy / sell · 12% snipe a specific Don</text>

    <rect x="28" y="290" width="316" height="70" rx="10" fill="#15161c" stroke="#ad8938" stroke-width="2"/>
    <text x="44" y="318" font-size="20" font-weight="700" fill="#ece9e1">TIER STAKING <tspan fill="#ad8938">· $ESSEY</tspan></text>
    <text x="44" y="344" font-size="15" fill="#b8b3a6">the 666 ladder: 66,666 → 1,666,666</text>

    <rect x="28" y="374" width="316" height="70" rx="10" fill="#15161c" stroke="#ad8938" stroke-width="2"/>
    <text x="44" y="402" font-size="20" font-weight="700" fill="#ece9e1">LOAN INTEREST <tspan fill="#ad8938">· $ESSEY</tspan></text>
    <text x="44" y="428" font-size="15" fill="#b8b3a6">15% APR on Don-backed loans</text>

    <rect x="28" y="458" width="316" height="70" rx="10" fill="#15161c" stroke="#ad8938" stroke-width="2"/>
    <text x="44" y="486" font-size="20" font-weight="700" fill="#ece9e1">LIQUIDATION PROCEEDS</text>
    <text x="44" y="512" font-size="15" fill="#b8b3a6">Don seized &amp; redeemed at the floor</text>
    <text x="28" y="552" font-size="13.5" fill="#9a958a">also from proceeds:  <tspan fill="#ece9e1">1% tip → caller</tspan> · <tspan fill="#ece9e1">principal → loan pool</tspan></text>
    <text x="28" y="572" font-size="13.5" fill="#9a958a"><tspan fill="#ece9e1">surplus → borrower</tspan> — the Don itself is consumed (locked in the reserve)</text>
  </g>

  <g>
    <rect x="470" y="132" width="280" height="96" rx="10" fill="#15161c" stroke="#2f9e6e" stroke-width="2.5"/>
    <text x="486" y="160" font-size="20" font-weight="700" fill="#ece9e1">DonFeeRouter</text>
    <text x="486" y="184" font-size="15" fill="#b8b3a6">ETH + $ESSEY → <tspan fill="#2f9e6e" font-weight="700">USDG</tspan></text>
    <text x="486" y="206" font-size="15" fill="#b8b3a6">min-out ≥ 97% oracle-fair</text>

    <rect x="470" y="282" width="280" height="52" rx="10" fill="#15161c" stroke="#4a453a" stroke-width="2"/>
    <text x="486" y="315" font-size="20" font-weight="700" fill="#ece9e1">TREASURY</text>

    <rect x="470" y="370" width="280" height="52" rx="10" fill="#15161c" stroke="#c25050" stroke-width="2.5"/>
    <text x="486" y="396" font-size="20" font-weight="700" fill="#ece9e1">BURNED FOREVER</text>
    <text x="486" y="415" font-size="13.5" fill="#b8b3a6">sent to 0x…dEaD — supply only shrinks</text>

    <rect x="470" y="460" width="280" height="112" rx="10" fill="#1a1710" stroke="#c9a24b" stroke-width="3"/>
    <text x="486" y="490" font-size="20" font-weight="700" fill="#e6c877">THE FLOOR · DonReserve</text>
    <text x="486" y="516" font-size="15" fill="#ece9e1">2,666,666,666 $ESSEY ÷ 8,888 Dons</text>
    <text x="486" y="540" font-size="15" fill="#ece9e1">= <tspan font-weight="700" fill="#e6c877">300,030 $ESSEY each</tspan></text>
    <text x="486" y="562" font-size="14" fill="#b8b3a6">redeem any Don for it · it ONLY rises</text>
  </g>

  <g>
    <rect x="880" y="132" width="292" height="86" rx="10" fill="#15161c" stroke="#2f9e6e" stroke-width="2.5"/>
    <text x="896" y="162" font-size="20" font-weight="700" fill="#ece9e1">THE BELL <tspan fill="#2f9e6e">· USDG pot</tspan></text>
    <text x="896" y="186" font-size="15" fill="#b8b3a6">rings at ≥ 10 USDG · ringer tip 0%</text>
    <text x="896" y="207" font-size="15" fill="#b8b3a6">one O(1) split, no middleman</text>

    <rect x="880" y="298" width="292" height="140" rx="10" fill="#181222" stroke="#a06fd0" stroke-width="3"/>
    <text x="896" y="330" font-size="21" font-weight="700" fill="#ece9e1">STAKED DONS EARN</text>
    <text x="896" y="356" font-size="21" font-weight="700" fill="#a06fd0">TOKENIZED STOCK</text>
    <text x="896" y="384" font-size="15" fill="#b8b3a6">pro-rata by tier weight (100 → 333)</text>
    <text x="896" y="406" font-size="15" fill="#b8b3a6">straight into each Don's Vault</text>
    <text x="896" y="428" font-size="15" fill="#b8b3a6">elect up to 3 tickers · default: BUNDLE</text>
  </g>

  <path d="M344 157 C 410 157, 400 168, 462 172" fill="none" stroke="#5b8fd9" stroke-width="2.5" marker-end="url(#aB)"/>
  <text x="404" y="152" font-size="15" font-weight="700" fill="#ece9e1" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">100%</text>
  <path d="M344 231 C 410 231, 402 208, 462 200" fill="none" stroke="#ad8938" stroke-width="2.5" marker-end="url(#aG)"/>
  <text x="404" y="212" font-size="15" font-weight="700" fill="#ece9e1" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">70%</text>
  <path d="M344 254 C 414 262, 404 292, 462 298" fill="none" stroke="#ad8938" stroke-width="2" marker-end="url(#aG)"/>
  <text x="404" y="290" font-size="15" font-weight="700" fill="#ece9e1" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">30%</text>
  <path d="M344 318 C 410 318, 404 316, 462 314" fill="none" stroke="#ad8938" stroke-width="2" marker-end="url(#aG)"/>
  <text x="404" y="336" font-size="15" font-weight="700" fill="#ece9e1" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">50%</text>
  <path d="M344 341 C 416 352, 400 386, 462 392" fill="none" stroke="#c25050" stroke-width="2.5" marker-end="url(#aR)"/>
  <text x="410" y="382" font-size="15" font-weight="700" fill="#ece9e1" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">50% burned</text>
  <path d="M344 409 C 420 420, 400 492, 462 500" fill="none" stroke="#ad8938" stroke-width="3" marker-end="url(#aG)"/>
  <text x="402" y="466" font-size="15" font-weight="700" fill="#e6c877" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">100%</text>
  <path d="M344 493 C 410 493, 404 522, 462 528" fill="none" stroke="#ad8938" stroke-width="2" marker-end="url(#aG)"/>
  <text x="404" y="520" font-size="14" font-weight="700" fill="#ece9e1" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">interest</text>
  <path d="M750 178 C 810 178, 812 175, 872 175" fill="none" stroke="#2f9e6e" stroke-width="3" marker-end="url(#aU)"/>
  <text x="812" y="168" font-size="15" font-weight="700" fill="#ece9e1" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">USDG</text>
  <path d="M1026 218 L 1026 290" fill="none" stroke="#a06fd0" stroke-width="3.5" marker-end="url(#aP)"/>
  <text x="1036" y="250" font-size="15" font-weight="700" fill="#ece9e1" paint-order="stroke" stroke="#0b0c10" stroke-width="4">100% of pot</text>
  <text x="1036" y="270" font-size="15" font-weight="700" fill="#a06fd0" paint-order="stroke" stroke="#0b0c10" stroke-width="4">as stock</text>

  <text x="880" y="466" font-size="14.5" fill="#b8b3a6">Mint fees: <tspan fill="#e6c877" font-weight="700">100% to holders' stock</tspan></text>
  <text x="880" y="486" font-size="14.5" fill="#b8b3a6">— the team takes 0%.</text>
  <text x="880" y="510" font-size="14.5" fill="#b8b3a6">Borrow up to <tspan fill="#ece9e1" font-weight="700">50%</tspan> of the floor · liq at <tspan fill="#ece9e1" font-weight="700">70%</tspan>.</text>
  <text x="880" y="532" font-size="14.5" fill="#b8b3a6">AMM price = max(300,000, live floor).</text>

  <text x="1170" y="652" font-size="15" font-weight="700" fill="#c9a24b" text-anchor="end">essey.xyz</text>
  <text x="30" y="652" font-size="13" fill="#6f6a5e">numbers read from the deployed contracts · Dons v3</text>
</svg>`;

const FLYWHEEL_SVG = `<svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 1200 675" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
  <defs>
    <marker id="fwA" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#c9a24b"/></marker>
  </defs>

  <rect width="1200" height="675" fill="#0b0c10"/>

  <text x="600" y="330" font-size="30" font-weight="700" fill="#e6c877" text-anchor="middle">THE DONS FLYWHEEL</text>
  <text x="600" y="358" font-size="16" fill="#9a958a" text-anchor="middle">8,888 seats · every route on-chain</text>
  <text x="600" y="382" font-size="16" font-weight="700" fill="#c9a24b" text-anchor="middle">essey.xyz</text>

  <rect x="415" y="42" width="370" height="92" rx="12" fill="#15161c" stroke="#4a453a" stroke-width="2.5"/>
  <text x="600" y="76" font-size="23" font-weight="700" fill="#ece9e1" text-anchor="middle">ACTIVITY</text>
  <text x="600" y="102" font-size="16" fill="#b8b3a6" text-anchor="middle">mint · reroll · trade · stake · borrow</text>
  <text x="600" y="123" font-size="16" fill="#b8b3a6" text-anchor="middle">every action touches the machine</text>

  <rect x="836" y="266" width="342" height="130" rx="12" fill="#15161c" stroke="#ad8938" stroke-width="2.5"/>
  <text x="1007" y="298" font-size="23" font-weight="700" fill="#ece9e1" text-anchor="middle">FEES <tspan fill="#ad8938">· ETH + $ESSEY</tspan></text>
  <text x="1007" y="325" font-size="15.5" fill="#b8b3a6" text-anchor="middle">100% of mint fees · 8–12% AMM fees</text>
  <text x="1007" y="347" font-size="15.5" fill="#b8b3a6" text-anchor="middle">tier ladder 66,666 → 1,666,666</text>
  <text x="1007" y="369" font-size="15.5" fill="#b8b3a6" text-anchor="middle">15% APR loan interest</text>

  <rect x="368" y="524" width="464" height="120" rx="12" fill="#181222" stroke="#a06fd0" stroke-width="3"/>
  <text x="600" y="556" font-size="23" font-weight="700" fill="#a06fd0" text-anchor="middle">STOCK + FLOOR + BURN</text>
  <text x="600" y="583" font-size="15.5" fill="#ece9e1" text-anchor="middle">fees buy tokenized stock for staked Dons</text>
  <text x="600" y="605" font-size="15.5" fill="#ece9e1" text-anchor="middle">interest lifts the 300,030 $ESSEY floor — it only rises</text>
  <text x="600" y="627" font-size="15.5" fill="#ece9e1" text-anchor="middle">half of every tier fee is burned forever</text>

  <rect x="22" y="266" width="342" height="130" rx="12" fill="#1a1710" stroke="#c9a24b" stroke-width="3"/>
  <text x="193" y="298" font-size="23" font-weight="700" fill="#e6c877" text-anchor="middle">HOLDERS WIN</text>
  <text x="193" y="325" font-size="15.5" fill="#ece9e1" text-anchor="middle">your PFP pays real stock dividends</text>
  <text x="193" y="347" font-size="15.5" fill="#ece9e1" text-anchor="middle">floor only rises · supply only shrinks</text>
  <text x="193" y="369" font-size="15.5" fill="#ece9e1" text-anchor="middle">borrow against it while it earns</text>

  <path d="M 800 88 C 950 100, 1030 160, 1022 256" fill="none" stroke="#c9a24b" stroke-width="4" marker-end="url(#fwA)"/>
  <text x="962" y="152" font-size="15.5" font-style="italic" fill="#b8b3a6" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">every action pays a fee</text>
  <path d="M 1022 406 C 1030 500, 950 566, 844 578" fill="none" stroke="#c9a24b" stroke-width="4" marker-end="url(#fwA)"/>
  <text x="990" y="502" font-size="15.5" font-style="italic" fill="#b8b3a6" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">routed on-chain,</text>
  <text x="990" y="522" font-size="15.5" font-style="italic" fill="#b8b3a6" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">no middleman</text>
  <path d="M 356 578 C 250 566, 170 500, 178 406" fill="none" stroke="#c9a24b" stroke-width="4" marker-end="url(#fwA)"/>
  <text x="212" y="502" font-size="15.5" font-style="italic" fill="#b8b3a6" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">a richer seat</text>
  <text x="212" y="522" font-size="15.5" font-style="italic" fill="#b8b3a6" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">at the table</text>
  <path d="M 178 256 C 170 160, 250 100, 400 88" fill="none" stroke="#c9a24b" stroke-width="4" marker-end="url(#fwA)"/>
  <text x="238" y="145" font-size="15.5" font-style="italic" fill="#b8b3a6" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">more reasons to mint,</text>
  <text x="238" y="165" font-size="15.5" font-style="italic" fill="#b8b3a6" text-anchor="middle" paint-order="stroke" stroke="#0b0c10" stroke-width="4">trade, stake, borrow</text>
</svg>`;
