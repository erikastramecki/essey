// /how-it-works — the full Dons story as a designed scroll page (not a markdown dump).
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
        <span className="eyebrow">Essey · The Dons</span>
        <h1>How Essey works</h1>
        <p>
          {md("A Don is a **seat**, a **floor**, and a **margin account**, all in one NFT. Every number on this page is read from the deployed contracts, not a pitch deck. Where a value is admin-tunable, we say so.")}
        </p>
        <nav className="hw-toc">
          {TOC.map(([href, label]) => <a key={href} href={href}>{label}</a>)}
        </nav>
      </div>

      {/* ---- 1 · what is a Don ---- */}
      <Section id="what-is-a-don" kicker="01" title="What is a Don">
        <P>{md("A Don is one of **8,888** NFTs on Robinhood Chain. It is not just a picture. A Don is three things at once:")}</P>
        <div className="hw-grid">
          {[
            ["♛", "A seat at the table", "Stake it and it earns a share of every fee the protocol collects, paid out in tokenized Robinhood stock."],
            ["⬢", "A hard floor of $ESSEY", "Every Don is backed by a reserve you can always cash it in against: currently 300,030 $ESSEY per Don, and that number can only go up."],
            ["◈", "A margin account", "Borrow $ESSEY against your Don's floor while it stays in your wallet, still earning."],
          ].map(([icon, t, b]) => (
            <Card key={t}>
              <div style={{ fontSize: 20, color: "var(--gold-hi)", marginBottom: 7 }}>{icon}</div>
              <div className="hw-card-h">{t}</div>
              {b}
            </Card>
          ))}
        </div>
        <P>{md("Each Don also carries its own on-chain **Vault**, a token-bound account created at mint. Everything the Don earns lands in its Vault, and the Vault travels with the Don. Sell the Don, and the Vault goes with it.")}</P>
      </Section>

      {/* ---- 2 · get one ---- */}
      <Section id="get-one" kicker="02" title="Get one: three ways in">
        <P>{md("All mint fees are paid in ETH, and **100% of every fee buys stock for staked holders**. There is no team cut on mints (the split is configurable on-chain and set to 0).")}</P>
        <div className="hw-grid">
          <Card accent="var(--good)">
            <div className="hw-card-k" style={{ color: "var(--good)" }}>Free · whitelist</div>
            <div className="hw-card-big">Gas only</div>
            {md("If you hold a whitelist allocation, you claim your Dons for gas only. Each comes with a randomly rolled set of traits. The whitelist is a Merkle root committed on-chain behind a **2-day public timelock**: the list is visible before it goes live, and no one can swap it in quietly.")}
          </Card>
          <Card accent="var(--r-bluechip)">
            <div className="hw-card-k" style={{ color: "var(--r-bluechip)" }}>Reroll · unlimited</div>
            <div className="hw-card-big">0.00075 ETH <i>~$3</i></div>
            {md("Don't love the roll? Re-randomize any Don you own, as many times as you like, until you stake it. Every reroll frees your old trait combo for someone else and locks in your new one. A random Don stays random: rerolling re-rolls, it never converts to a custom build.")}
          </Card>
          <Card accent="var(--gold)">
            <div className="hw-card-k" style={{ color: "var(--gold)" }}>Custom · exact traits</div>
            <div className="hw-card-big">0.0025 ETH <i>~$10</i></div>
            {md("Open the builder, choose every trait, and mint exactly that Don. Trait combos are unique by contract: the uniqueness ledger lives on-chain, so no two Dons can ever share a look.")}
          </Card>
        </div>
        <P>{md("The team reserve is hard-capped on-chain at **2,722 Dons**: 2,222 of those are the AMM's trading inventory (protocol-owned, seeded into the exchange, not held by anyone), and up to 500 are for partners and team. The cap is immutable; it cannot be raised.")}</P>
        <div className="hw-note">{md("Your Don's art stays changeable until the moment you stake it. **Staking locks the art forever.**")}</div>
      </Section>

      {/* ---- 3 · the floor ---- */}
      <Section id="the-floor" kicker="03" title="The Floor">
        <P>{md("Behind every Don sits the **DonReserve**: a pot funded with **2,666,666,666 $ESSEY** (30% of the total supply), split across the 8,888-Don cap.")}</P>
        <div className="hw-stats">
          <Stat big="2,666,666,666" label="$ESSEY in the reserve, 30% of total supply" />
          <Stat big="÷ 8,888" label="Dons backed, read from the immutable cap" />
          <Stat big="= 300,030" label="$ESSEY floor per Don today, and it only rises" />
        </div>
        <ul className="hw-list">
          <li>{md("**Redemption is always open.** At any moment, any Don's owner can redeem it against the reserve and receive its full floor share in $ESSEY. No permission, no window, no admin.")}</li>
          <li>{md("**The floor only rises.** Anyone can fund the reserve (the protocol routes proceeds here, and any well-wisher can top it up), but the only way $ESSEY leaves is a redemption, which pays exactly one Don's pro-rata share. The math guarantees the floor for everyone else never drops.")}</li>
          <li>{md("**Nobody can touch it.** The reserve has no owner, no admin, no upgrade path, and no setter on its accounting. The backed-supply figure is read from the Don contract's own immutable cap. There is nothing to rug.")}</li>
        </ul>
        <Warn title="Redeeming is a one-way door">
          {md("The reserve pays you the floor and locks your Don inside it permanently. That Don's membership is over: no more staking, no more payouts. Its Vault, with everything in it, is locked away too. **Claim and empty your Vault before you redeem.** Redemption is the exit hatch that guarantees the floor; it is not a trade you reverse.")}
        </Warn>
        <P>{md("Because redemption is always open at the floor, a Don can never trade below it: anyone who saw a cheaper price would buy and redeem for instant profit until the price snapped back.")}</P>
      </Section>

      {/* ---- 4 · trade ---- */}
      <Section id="trade" kicker="04" title="Trade">
        <P>{md("The **DonExchange** is the broker desk: a vault holding Dons on one side and $ESSEY on the other, trading at one price. That price is pinned on every trade to **the live redemption floor** (never below the 300,000 $ESSEY deploy minimum), read fresh from the reserve, so the desk can never be arbitraged against a risen floor.")}</P>
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
          {md("**70% of every trade fee buys tokenized stock for staked Dons.** The remaining 30% goes to the protocol treasury. Every trade, yours or anyone's, pays the people seated at the table.")}
        </div>
        <P>{md("Every trade takes a slippage bound (max cost on buys, min proceeds on sells): because the floor can rise between your click and your transaction, the trade reverts rather than filling at a worse price than you approved.")}</P>
        <P>{md("The desk is adminless over funds. The only privileged role can *add* Dons to inventory; it can never withdraw the $ESSEY reserve or touch fees.")}</P>
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
        <P>{md("Fees are cumulative: upgrading later costs only the difference (Base → Tier 4 is 1,600,000 $ESSEY whether you climb rung by rung or jump).")}</P>
        <P>{md("The activation fee is a **sink, not a deposit**: **50% is burned forever, 50% goes to the treasury.** You don't get it back. What you get is your weight on every payout for as long as you hold the Don. There are no seasons, no vesting, no cooldowns. **Activate, and you earn from the next ring onward.**")}</P>
        <div className="hw-grid">
          <Card accent="var(--good)">
            <div className="hw-card-h">🔔 The Bell</div>
            {md("Every fee in the protocol (mint fees, trade fees) flows into one pot. When the pot fills, the Bell rings: the pot is split across all active Dons, pro-rata by weight, in a single on-chain operation. A protocol keeper rings it (there's no ringer tip to race for: the whole pot goes to holders), and anyone may ring it themselves once the pot passes the threshold.")}
          </Card>
          <Card accent="var(--r-preferred)">
            <div className="hw-card-h">📈 Paid in stock</div>
            {md("Payouts are delivered as **Robinhood tokenized stock**. Elect up to 3 stocks with your own weights (say, 60% AAPL / 40% NVDA), or elect nothing and receive the default BUNDLE basket. If a conversion can't settle (market closed, stale feed), that payout arrives as USDG instead: your money is never stuck behind a swap.")}
          </Card>
        </div>
        <P>{md("Everything lands in your Don's Vault. Claims are permissionless because they can only ever go one place: the Don's own Vault.")}</P>
        <Warn title="Two things clear when a Don changes hands">
          {md("Its tier and its stock elections. The buyer starts fresh and activates their own seat. Rewards already credited stay with the Don: they're in its Vault, and the Vault goes where the Don goes. So before you sell: **claim, and empty the Vault.** And remember: **activating locks your art.** The look you stake is the look forever.")}
        </Warn>
      </Section>

      {/* ---- 6 · borrow ---- */}
      <Section id="borrow" kicker="06" title="Borrow">
        <P>{md("Your Don is collateral you don't have to give up. Borrowing is a **fixed-term, fixed-draw** line against your Don's floor, a pawn-style loan with a due date, not a revolving margin balance.")}</P>
        <div className="hw-stats">
          <Stat big="150,015 $ESSEY" label="the full draw today, a fixed 50% of your Don's floor" />
          <Stat big="7 – 365 days" label="you choose the term; interest is prepaid in ETH at signing" />
          <Stat big="Flat, 1:1" label="the debt never grows: repay exactly what you drew, any time" />
        </div>
        <ul className="hw-list">
          <li>{md("**You draw exactly half your floor, no dial to set.** Open a loan and you receive the full **150,015 $ESSEY** (50% of the live floor), disbursed in one shot. The floor can only rise, so a fresh loan is always ~2× over-collateralized on day one.")}</li>
          <li>{md("**Interest is paid once, up front, in ETH, never in $ESSEY.** The fee scales with your Don's floor and the term you pick, and is split the moment you borrow: **70% buys stock for staked Dons, 30% to the treasury**, the same 70/30 shape the trade fees follow. The rate is a treasury-set coefficient, currently **0 (borrowing is free on this deployment)**, and is hard-capped so a full-term loan can never cost more than **1 ETH** up front.")}</li>
          <li>{md("**The debt is flat: it does not accrue.** You owe back exactly the $ESSEY you drew, 1:1, with nothing added over time. Repay any amount, any time; anyone may repay on your behalf. Full repayment releases the lien on the spot.")}</li>
          <li>{md("**The Don stays in your wallet, still staked, still earning.** A lien blocks it from being sold, swapped, or redeemed until the debt clears; nothing else changes. Your seat keeps collecting stock into its Vault the entire time you're borrowed against it.")}</li>
        </ul>
        <P>{md("**There is a due date.** Each loan expires at the end of its term. Miss it, and a **30-day grace period** starts; once that runs out, **anyone can liquidate**: the trigger is the calendar, not a price. Because the debt is a flat 50% of a floor that only rises, it can never climb to the 70%-of-floor ratio backstop, so the clock is the thing to watch. Repaying, or the floor being funded higher, never changes your due date. Only paying the loan off does.")}</P>
        <P>{md("**Liquidation.** Once you're past due plus grace, the facility seizes the Don and redeems it at the floor. The proceeds clear your debt, a **1% tip** pays whoever triggered it, and **any surplus is returned to you**. But the Don itself is consumed: locked in the reserve, seat gone.")}</P>
        <Warn title="Miss the due date and you lose the Don, and its Vault">
          {md("Liquidation (like redemption) takes the Don's Vault with it, including every unclaimed dividend inside. There is no partial or soft default: past due + 30 days, the whole Don can be redeemed out from under you. **Claim your Vault regularly, and repay before the grace clock runs out.**")}
        </Warn>
        <div className="hw-note">
          {md("Because debt and collateral are both in $ESSEY, there is **no price oracle to fail and no keeper to trust**, and every open loan emits a solvency statement that Essey's zero-knowledge prover verifies on-chain: `debt ≤ 50% of floor` at origination, proven cryptographically, not promised. A loan cannot go underwater: the floor never falls, and the draw is capped at half of it.")}
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
          <li>{md("**Trade fees (8% / 12%, $ESSEY):** 70% → the Bell → stock for staked Dons; 30% → treasury.")}</li>
          <li>{md("**Activation fees ($ESSEY):** 50% burned (supply shrinks), 50% treasury.")}</li>
          <li>{md("**Loan interest (ETH, prepaid at borrow):** 70% → stock for staked Dons / 30% → treasury. The same split as trade fees. Interest is an ETH fee, not $ESSEY, and it does **not** flow to the floor.")}</li>
          <li>{md("**Royalties (5% of secondary sales):** → the treasury.")}</li>
        </ul>
        <P>{md("More minting means more stock for seats. More trading means more stock for seats. More borrowing means more prepaid ETH buying stock for seats. And the floor rises whenever the protocol funds it from proceeds: a higher floor means a higher trade price, a bigger draw, and a stronger backstop under everything. There is no fee in the system that leaks out of it.")}</P>
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
    a: "This isn't a token AMM. It's an NFT broker desk trading whole Dons at a floor-pinned price. The fee is the anti-arbitrage margin: because any Don can always be redeemed for its floor, a fee-free desk at floor price would be drained by buy-then-redeem loops. The 8% buy/sell fee makes that loop strictly unprofitable, and the 12% snipe premium prices the privilege of picking an exact Don over taking the next one from inventory. Either way, 70% of every fee buys tokenized stock for staked Dons, so the same margin that protects the desk also pays the table.",
  },
  {
    q: "What happens if I sell a staked Don?",
    a: "Two things clear the instant it transfers: the tier (your activation fee is a sink; it isn't refunded) and your stock elections. What doesn't clear: rewards already credited to the Don, because they live in its Vault, and the Vault goes with the Don. Practical rule: claim and empty the Vault before selling, and price the Don knowing the buyer re-activates from scratch.",
  },
  {
    q: "Can the team rug the floor?",
    a: "No, and you can verify it in the contract, not a promise. The DonReserve has no owner, no admin functions, no upgrade path, and no setter on its accounting. The number of Dons it backs is read from the Don contract's own immutable 8,888 cap. Money goes in permissionlessly; the only way it comes out is a Don's owner redeeming that one Don for its exact pro-rata share, which by construction never lowers the floor for anyone else.",
  },
  {
    q: "What exactly is the floor and can it go down?",
    a: "Floor = reserve balance ÷ Dons still backed. It's funded with 2,666,666,666 $ESSEY against 8,888 Dons, 300,030 $ESSEY per Don today. It cannot go down: funding raises it (anyone may fund; the protocol routes proceeds here), and redemptions are pro-rata (neutral, with rounding dust left in the reserve). Note loan interest does NOT feed the floor: that's a prepaid ETH fee that buys stock and funds the treasury, not the reserve. The floor only rises.",
  },
  {
    q: "What's \"provable solvency\"?",
    a: "Every loan the protocol writes carries an on-chain solvency statement (borrower, debt, floor, LTV) that Essey's zero-knowledge prover (the dregg circuit) commits and proves under a Groth16 verifier: debt × 10,000 ≤ floor × 5,000. The rounding is deliberately conservative (debt rounds up, floor rounds down), so the proof can only overstate risk, never hide it. Most protocols ask you to trust their dashboard; Essey's book is checkable by anyone with the verifier.",
  },
  {
    q: "Why are loans in $ESSEY and not USDG?",
    a: "Because the Don's floor is denominated in $ESSEY. With debt and collateral in the same unit, LTV and liquidation need no price oracle, no keeper, and no trading session: none of the usual failure points. Solvency reduces to two on-chain facts: the floor never decreases, and every loan starts at ≤50% of it. Want dollars? Swap the borrowed $ESSEY yourself: that's one trade, not a protocol risk.",
  },
  {
    q: "What happens to my art when I stake?",
    a: "It locks, permanently. Until you stake, traits are fluid: reroll for ~$3 as often as you like. The moment you activate a tier, the reroll path closes and the traits freeze on-chain. The art you take your seat with is the art forever, even through future sales.",
  },
  {
    q: "I got a random Don. Can I convert it to custom traits?",
    a: "No. Random Dons stay on the reroll path: unlimited ~$3 re-rolls until you're happy or you stake. The ~$10 custom path mints a new Don with exactly the traits you build; it isn't an edit to an existing one.",
  },
  {
    q: "Can I unstake and get my activation fee back?",
    a: "No, there is nothing to unstake. The fee is a sink (50% burned, 50% treasury), and in exchange your Don earns at its weight for as long as you hold it. No seasons, no vesting, no cooldown, no exit paperwork. The tier only ends when the Don changes hands.",
  },
  {
    q: "Who rings the Bell, and do they get paid?",
    a: "Anyone can, once the pot passes the threshold; a protocol keeper does it routinely. The ringer's tip is set to 0%, so 100% of the pot goes to active Dons. Ringing is one division on-chain no matter how many Dons are seated; it never gets more expensive as the table fills.",
  },
  {
    q: "What if the Bell rings and nobody has activated?",
    a: "It can't: the ring reverts if no Don is active. The pot just waits and keeps growing until someone takes a seat. Early activators inherit everything accumulated before them.",
  },
  {
    q: "Do I have to claim, or do payouts arrive automatically?",
    a: "Rings credit your Don instantly; claiming moves the credited amount into its Vault, converted to your elected stocks. Anyone can trigger a claim (it can only pay the Vault), but do it yourself regularly: anything unclaimed rides with the Don if it's sold, redeemed, or liquidated.",
  },
  {
    q: "How do stock elections work?",
    a: "Per Don, choose up to 3 supported tokenized stocks with weights summing to 100%, your personal dividend basket. No election means the default BUNDLE basket. Every slice fails open: if a conversion can't settle (market closed, stale feed, thin pool), that slice is delivered as USDG instead. Elections are per-owner and clear on transfer.",
  },
  {
    q: "If I borrow, do I stop earning?",
    a: "No, that's the point. The loan is a lien, not an escrow: the Don never leaves your wallet, stays staked, and keeps collecting stock the whole time. The only restriction is that it can't be transferred (sold, swapped, or redeemed) until the debt clears.",
  },
  {
    q: "How close is liquidation, really, and what actually triggers it?",
    a: "It's a due date, not a ratio drift. Each loan runs for the term you picked (7–365 days); when it expires a 30-day grace period starts, and only after that does anyone become able to liquidate. There is no interest piling up to push you underwater: the debt is flat at exactly what you drew. The old 70%-of-floor ratio backstop still exists in the contract but can never actually fire: a flat 50%-of-floor debt against a floor that only rises can't reach 70%. So the one thing that matters is the calendar. Repay before grace ends and nothing happens; funding the floor higher does not change your due date.",
  },
  {
    q: "What do I lose if I do get liquidated?",
    a: "The Don is seized and redeemed at its floor; the proceeds pay a 1% caller tip, then clear your principal. Any surplus is returned to you. There's no interest leg in the waterfall because interest was prepaid in ETH at borrow. What's gone is the Don itself and its Vault, including unclaimed dividends. Claim often and repay before your grace period ends; anyone (a friend, a bot you run) may repay on your behalf.",
  },
  {
    q: "Where does each fee actually go?",
    a: "Mint and reroll fees (ETH): 100% converted and sent to the Bell, stock for staked Dons. Trade fees ($ESSEY): 70% to the Bell, 30% treasury. Activation fees ($ESSEY): 50% burned, 50% treasury. Loan interest (ETH, prepaid at borrow): 70% to the Bell for stock, 30% treasury, NOT to the floor. Secondary-sale royalties (5%): treasury. The floor is funded separately, from protocol proceeds and anyone who chooses to fund it. Nothing leaks out of the loop.",
  },
  {
    q: "How many Dons does the team keep?",
    a: "The admin mint is hard-capped on-chain at 2,722. Of those, 2,222 are the exchange's trading inventory, owned by the desk, not by people. Up to 500 cover partners and team. The cap is immutable, and the whitelist itself sits behind a 2-day public timelock before it can go live.",
  },
  {
    q: "Testnet vs mainnet: what am I looking at today?",
    a: "Today's deployment is the Robinhood Chain testnet: real contracts, rehearsed live (mint → trade → borrow → repay → sell, all on-chain), but with mock USDG, mock price feeds, and an interim fee route while the ETH-side plumbing gets its mocks. Mainnet ships the same audited bytecode with real assets, per the published go-live plan. Testnet balances do not carry over.",
  },
];

/* ------------------------------ inline diagrams -------------------------------
   Static, trusted SVGs authored in-repo (fee-flow diagram set, 2026-08-11). Fixed width/height
   were swapped for width="100%" so they scale with the viewBox inside their Scroller. */

const FEE_MAP_SVG = `<svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 1200 675" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
  <defs>
    <marker id="fmGold" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="var(--gold)"/></marker>
    <marker id="fmMut" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="var(--tx-faint)"/></marker>
    <marker id="fmOx" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="var(--ox)"/></marker>
  </defs>

  <rect width="1200" height="675" fill="var(--s1)"/>
  <rect x="6" y="6" width="1188" height="663" rx="12" fill="none" stroke="var(--line-2)" stroke-width="1"/>

  <text x="40" y="52" font-size="30" font-weight="700" fill="var(--gold-hi)">WHERE EVERY FEE GOES</text>
  <text x="40" y="78" font-size="15" fill="var(--tx-mut)">Every fee ends at the Bell (stock for staked Dons), the treasury, or the burn. Never the floor.</text>

  <!-- legend -->
  <circle cx="46" cy="99" r="6" fill="var(--gold)"/>
  <text x="58" y="104" font-size="14" fill="var(--tx-mut)">buys stock for staked Dons (via the Bell)</text>
  <circle cx="410" cy="99" r="6" fill="var(--tx-faint)"/>
  <text x="422" y="104" font-size="14" fill="var(--tx-mut)">to the treasury</text>
  <circle cx="600" cy="99" r="6" fill="var(--ox)"/>
  <text x="612" y="104" font-size="14" fill="var(--tx-mut)">burned forever</text>

  <text x="40" y="122" font-size="12" font-weight="700" letter-spacing="2" fill="var(--tx-faint)">FEE SOURCE</text>
  <text x="800" y="122" font-size="12" font-weight="700" letter-spacing="2" fill="var(--tx-faint)">WHERE IT GOES</text>

  <!-- fee sources (left) -->
  <g>
    <rect x="40" y="128" width="360" height="66" rx="9" fill="var(--s2)" stroke="var(--line-2)" stroke-width="1.5"/>
    <text x="60" y="156" font-size="18" font-weight="700" fill="var(--tx)">MINT &amp; REROLL <tspan font-size="14" font-weight="400" fill="var(--r-bluechip)">· ETH</tspan></text>
    <text x="60" y="178" font-size="14" fill="var(--tx-mut)">reroll ~$3 · custom mint ~$10</text>

    <rect x="40" y="206" width="360" height="66" rx="9" fill="var(--s2)" stroke="var(--line-2)" stroke-width="1.5"/>
    <text x="60" y="234" font-size="18" font-weight="700" fill="var(--tx)">TRADE / EXCHANGE <tspan font-size="14" font-weight="400" fill="var(--tx-mut)">· $ESSEY</tspan></text>
    <text x="60" y="256" font-size="14" fill="var(--tx-mut)">8% buy / sell · 12% snipe a specific Don</text>

    <rect x="40" y="284" width="360" height="66" rx="9" fill="var(--s2)" stroke="var(--line-2)" stroke-width="1.5"/>
    <text x="60" y="312" font-size="18" font-weight="700" fill="var(--tx)">LOAN INTEREST <tspan font-size="14" font-weight="400" fill="var(--r-bluechip)">· ETH, prepaid</tspan></text>
    <text x="60" y="334" font-size="14" fill="var(--tx-mut)">paid up front at borrow · never $ESSEY</text>

    <rect x="40" y="362" width="360" height="66" rx="9" fill="var(--s2)" stroke="var(--line-2)" stroke-width="1.5"/>
    <text x="60" y="390" font-size="18" font-weight="700" fill="var(--tx)">ACTIVATION <tspan font-size="14" font-weight="400" fill="var(--tx-mut)">· $ESSEY</tspan></text>
    <text x="60" y="412" font-size="14" fill="var(--tx-mut)">tier ladder 66,666 → 1,666,666</text>

    <rect x="40" y="440" width="360" height="66" rx="9" fill="var(--s2)" stroke="var(--line-2)" stroke-width="1.5"/>
    <text x="60" y="468" font-size="18" font-weight="700" fill="var(--tx)">ROYALTIES <tspan font-size="14" font-weight="400" fill="var(--tx-mut)">· 5% secondary</tspan></text>
    <text x="60" y="490" font-size="14" fill="var(--tx-mut)">on secondary-market resales</text>
  </g>

  <!-- destinations (right) -->
  <g>
    <rect x="800" y="128" width="360" height="146" rx="9" fill="var(--gold-dim)" stroke="var(--gold)" stroke-width="2.5"/>
    <text x="822" y="160" font-size="20" font-weight="700" fill="var(--gold-hi)">THE BELL <tspan font-size="14" font-weight="400" fill="var(--tx-mut)">· stock for staked Dons</tspan></text>
    <text x="822" y="188" font-size="14.5" fill="var(--tx)">fees → USDG → tokenized stock</text>
    <text x="822" y="212" font-size="14.5" fill="var(--tx)">split pro-rata by tier weight (1.00× → 3.33×)</text>
    <text x="822" y="236" font-size="14.5" fill="var(--tx)">lands in each Don's Vault (elect up to 3, or BUNDLE)</text>
    <text x="822" y="260" font-size="13.5" fill="var(--tx-mut)">rings at ≥ 10 USDG · ringer tip 0% · O(1) split</text>

    <rect x="800" y="296" width="360" height="78" rx="9" fill="var(--s2)" stroke="var(--line-2)" stroke-width="1.5"/>
    <text x="822" y="330" font-size="19" font-weight="700" fill="var(--tx)">TREASURY</text>
    <text x="822" y="356" font-size="14" fill="var(--tx-mut)">protocol operations &amp; development</text>

    <rect x="800" y="392" width="360" height="78" rx="9" fill="var(--s2)" stroke="var(--ox)" stroke-width="2"/>
    <text x="822" y="426" font-size="19" font-weight="700" fill="var(--tx)">BURNED FOREVER <tspan font-size="14" font-weight="400" fill="var(--ox)">· $ESSEY</tspan></text>
    <text x="822" y="452" font-size="14" fill="var(--tx-mut)">→ 0x…dEaD · supply only shrinks</text>
  </g>

  <!-- gold: buys stock via the Bell -->
  <path d="M400 161 C 560 161, 640 178, 800 178" fill="none" stroke="var(--gold)" stroke-width="3" marker-end="url(#fmGold)"/>
  <text x="590" y="166" font-size="15" font-weight="700" fill="var(--gold-hi)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">100%</text>
  <path d="M400 239 C 560 239, 650 200, 800 200" fill="none" stroke="var(--gold)" stroke-width="3" marker-end="url(#fmGold)"/>
  <text x="586" y="212" font-size="15" font-weight="700" fill="var(--gold-hi)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">70%</text>
  <path d="M400 317 C 560 317, 650 226, 800 226" fill="none" stroke="var(--gold)" stroke-width="3" marker-end="url(#fmGold)"/>
  <text x="600" y="268" font-size="15" font-weight="700" fill="var(--gold-hi)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">70%</text>

  <!-- muted: to treasury -->
  <path d="M400 239 C 580 252, 640 316, 800 322" fill="none" stroke="var(--tx-faint)" stroke-width="2" marker-end="url(#fmMut)"/>
  <text x="626" y="300" font-size="14" font-weight="700" fill="var(--tx-mut)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">30%</text>
  <path d="M400 317 C 570 322, 650 334, 800 336" fill="none" stroke="var(--tx-faint)" stroke-width="2" marker-end="url(#fmMut)"/>
  <text x="648" y="330" font-size="14" font-weight="700" fill="var(--tx-mut)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">30%</text>
  <path d="M400 395 C 570 395, 650 350, 800 352" fill="none" stroke="var(--tx-faint)" stroke-width="2" marker-end="url(#fmMut)"/>
  <text x="626" y="372" font-size="14" font-weight="700" fill="var(--tx-mut)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">50%</text>
  <path d="M400 473 C 580 473, 660 366, 800 366" fill="none" stroke="var(--tx-faint)" stroke-width="2" marker-end="url(#fmMut)"/>
  <text x="600" y="438" font-size="14" font-weight="700" fill="var(--tx-mut)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">100%</text>

  <!-- ox: burned -->
  <path d="M400 395 C 580 400, 660 428, 800 428" fill="none" stroke="var(--ox)" stroke-width="2.5" marker-end="url(#fmOx)"/>
  <text x="600" y="410" font-size="14" font-weight="700" fill="var(--ox)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">50% burned</text>

  <!-- the floor: funded separately, NOT from fees -->
  <line x1="40" y1="524" x2="1160" y2="524" stroke="var(--line-2)" stroke-width="1" stroke-dasharray="2 6"/>
  <rect x="40" y="536" width="1120" height="98" rx="12" fill="none" stroke="var(--gold-line)" stroke-width="1.5" stroke-dasharray="7 6"/>
  <text x="64" y="572" font-size="19" font-weight="700" fill="var(--gold-hi)">THE FLOOR · DonReserve <tspan font-size="14" font-weight="400" fill="var(--tx-mut)">(funded SEPARATELY)</tspan></text>
  <text x="64" y="598" font-size="14.5" fill="var(--tx-mut)">300,030 $ESSEY per Don · fed by protocol proceeds + anyone who chooses to fund it · redeemable any time · it only rises</text>
  <text x="1136" y="572" font-size="15" font-weight="700" fill="var(--ox)" text-anchor="end">✕ no fee routes here</text>
  <text x="1136" y="598" font-size="13.5" fill="var(--tx-faint)" text-anchor="end">interest &amp; fees never touch the floor</text>

  <text x="40" y="658" font-size="13" fill="var(--tx-faint)">numbers read from the deployed contracts</text>
  <text x="1160" y="658" font-size="15" font-weight="700" fill="var(--gold)" text-anchor="end">essey.xyz</text>
</svg>`;

const FLYWHEEL_SVG = `<svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 1200 675" font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
  <defs>
    <marker id="fwGold" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="var(--gold)"/></marker>
    <marker id="fwDim" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="var(--tx-faint)"/></marker>
  </defs>

  <rect width="1200" height="675" fill="var(--s1)"/>
  <rect x="6" y="6" width="1188" height="663" rx="12" fill="none" stroke="var(--line-2)" stroke-width="1"/>

  <!-- main loop arrows (drawn first, under the nodes) -->
  <path d="M726 150 C 862 158, 972 198, 1002 240" fill="none" stroke="var(--gold)" stroke-width="4" marker-end="url(#fwGold)"/>
  <text x="862" y="176" font-size="15" font-style="italic" fill="var(--tx-mut)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">every action pays a fee</text>

  <path d="M1006 320 C 1012 402, 968 468, 908 496" fill="none" stroke="var(--gold)" stroke-width="4" marker-end="url(#fwGold)"/>
  <text x="1010" y="410" font-size="15" font-style="italic" fill="var(--tx-mut)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">70% buys stock</text>
  <text x="1010" y="430" font-size="15" font-style="italic" fill="var(--tx-mut)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">30% → treasury</text>

  <path d="M724 536 C 620 588, 480 588, 476 540" fill="none" stroke="var(--gold)" stroke-width="4" marker-end="url(#fwGold)"/>
  <text x="600" y="600" font-size="15" font-style="italic" fill="var(--tx-mut)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">stock into each staked Don's Vault</text>

  <path d="M298 496 C 236 468, 192 402, 198 320" fill="none" stroke="var(--gold)" stroke-width="4" marker-end="url(#fwGold)"/>
  <text x="196" y="410" font-size="15" font-style="italic" fill="var(--tx-mut)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">a richer seat</text>

  <path d="M204 240 C 232 198, 342 158, 474 150" fill="none" stroke="var(--gold)" stroke-width="4" marker-end="url(#fwGold)"/>
  <text x="336" y="176" font-size="15" font-style="italic" fill="var(--tx-mut)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">more reason to hold &amp; stake</text>

  <!-- parallel reinforcing arc: proceeds → floor rises → borrow more -->
  <path d="M902 320 C 828 372, 782 400, 744 408" fill="none" stroke="var(--tx-faint)" stroke-width="2" stroke-dasharray="6 5" marker-end="url(#fwDim)"/>
  <text x="826" y="392" font-size="13" font-style="italic" fill="var(--tx-faint)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">some proceeds fund the floor</text>
  <path d="M572 392 C 468 344, 462 236, 546 168" fill="none" stroke="var(--tx-faint)" stroke-width="2" stroke-dasharray="6 5" marker-end="url(#fwDim)"/>
  <text x="452" y="300" font-size="13" font-style="italic" fill="var(--tx-faint)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">bigger draws,</text>
  <text x="452" y="318" font-size="13" font-style="italic" fill="var(--tx-faint)" text-anchor="middle" paint-order="stroke" stroke="var(--s1)" stroke-width="4">borrow more</text>

  <!-- center caption -->
  <text x="600" y="248" font-size="27" font-weight="700" fill="var(--gold-hi)" text-anchor="middle">THE DONS FLYWHEEL</text>
  <text x="600" y="276" font-size="15" fill="var(--tx-mut)" text-anchor="middle">activity → fees → stock → holders → more activity</text>
  <text x="600" y="300" font-size="15" font-style="italic" fill="var(--gold)" text-anchor="middle">a seat that pays you to sit in it</text>

  <!-- floor node (parallel arc) -->
  <rect x="460" y="388" width="280" height="56" rx="10" fill="var(--gold-dim)" stroke="var(--gold-line)" stroke-width="1.5" stroke-dasharray="7 6"/>
  <text x="600" y="412" font-size="15" font-weight="700" fill="var(--gold-hi)" text-anchor="middle">THE FLOOR ONLY RISES</text>
  <text x="600" y="432" font-size="13" fill="var(--tx-mut)" text-anchor="middle">a stronger backstop under every Don</text>

  <!-- ring nodes -->
  <rect x="475" y="90" width="250" height="74" rx="12" fill="var(--s2)" stroke="var(--line-2)" stroke-width="1.5"/>
  <text x="600" y="122" font-size="19" font-weight="700" fill="var(--tx)" text-anchor="middle">ACTIVITY</text>
  <text x="600" y="146" font-size="13.5" fill="var(--tx-mut)" text-anchor="middle">mint · reroll · trade · borrow · stake</text>

  <rect x="878" y="243" width="255" height="74" rx="12" fill="var(--s2)" stroke="var(--line-2)" stroke-width="1.5"/>
  <text x="1005" y="275" font-size="19" font-weight="700" fill="var(--tx)" text-anchor="middle">FEES COLLECTED</text>
  <text x="1005" y="299" font-size="13.5" fill="var(--tx-mut)" text-anchor="middle">on every action: ETH + $ESSEY</text>

  <rect x="726" y="495" width="255" height="74" rx="12" fill="var(--gold-dim)" stroke="var(--gold)" stroke-width="2.5"/>
  <text x="853" y="527" font-size="19" font-weight="700" fill="var(--gold-hi)" text-anchor="middle">70% BUYS STOCK</text>
  <text x="853" y="551" font-size="13.5" fill="var(--tx-mut)" text-anchor="middle">fees → USDG → the Bell</text>

  <rect x="220" y="495" width="255" height="74" rx="12" fill="var(--s2)" stroke="var(--line-2)" stroke-width="1.5"/>
  <text x="347" y="527" font-size="19" font-weight="700" fill="var(--tx)" text-anchor="middle">STAKED DONS PAID</text>
  <text x="347" y="551" font-size="13.5" fill="var(--tx-mut)" text-anchor="middle">real stock, pro-rata by weight</text>

  <rect x="67" y="243" width="255" height="74" rx="12" fill="var(--s2)" stroke="var(--line-2)" stroke-width="1.5"/>
  <text x="194" y="275" font-size="19" font-weight="700" fill="var(--tx)" text-anchor="middle">DONS WORTH MORE</text>
  <text x="194" y="299" font-size="13.5" fill="var(--tx-mut)" text-anchor="middle">more reason to hold &amp; stake</text>

  <text x="1160" y="658" font-size="15" font-weight="700" fill="var(--gold)" text-anchor="end">essey.xyz</text>
  <text x="40" y="658" font-size="13" fill="var(--tx-faint)">8,888 seats · every route on-chain · nothing leaks out of the loop</text>
</svg>`;
