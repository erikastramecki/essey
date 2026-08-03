// The Market layer surface — the gamified face of Essey per docs/DESIGN-website-rebrand.md.
// Everything here is STATIC (P0): the toys are client-side sandboxes, the Bell/Tape are labeled
// previews. Guardrail from the design doc: no section may claim more than the contracts deliver —
// the market contracts are audited and live on testnet; the toys here are still client-side sandboxes
// surface says so on the surface itself, not in a footnote.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Link } from "react-router-dom";

const REPO = "https://github.com/erikastramecki/essey";

const reducedMotion = () =>
  typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;

// ---------------------------------------------------------------- the hallmark (E-monogram)
// The real brand mark from brand/logo-final.html — the hexagon "provable stamp." `stamped`
// renders it pressed (filled); un-stamped is the hollow outline used by the warning modal.
export function EMonogram({ size = 26, stamped = true }: { size?: number; stamped?: boolean }) {
  return (
    <svg width={size} height={size} viewBox="0 0 100 100" aria-hidden className="emono">
      <path d="M50 7.81 L89.06 28.13 L89.06 71.88 L50 92.19 L10.94 71.88 L10.94 28.13 Z"
        fill={stamped ? "var(--gold-dim)" : "none"} stroke="var(--gold)" strokeWidth="3.4" strokeLinejoin="round" />
      <path d="M50 16.4 L81.4 32.7 L81.4 67.3 L50 83.6 L18.6 67.3 L18.6 32.7 Z"
        stroke="var(--gold-line)" strokeWidth="1.1" strokeLinejoin="round" fill="none" />
      <text x="50" y="51.5" textAnchor="middle" dominantBaseline="central"
        fontFamily="Didot,'Bodoni 72','Hoefler Text',Georgia,serif" fontSize="50" fill="var(--gold)">E</text>
    </svg>
  );
}

// ---------------------------------------------------------------- theme toggle (§8)
export function ThemeToggle() {
  const [theme, setTheme] = useState<string>(() => document.documentElement.dataset.theme || "dark");
  const flip = () => {
    const next = theme === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    localStorage.setItem("essey-theme", next);
    setTheme(next);
  };
  return (
    <button className="theme-btn" onClick={flip} aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`} title="Theme">
      {theme === "dark" ? "☀" : "☾"}
    </button>
  );
}

// ---------------------------------------------------------------- first-visit warning (§6)
// Honest disclosure as part of the pitch, not a legal wall. Shows once (localStorage),
// re-openable from the footer. The hallmark starts hollow — you read first, then it stamps.
const WARN_KEY = "essey-warning-accepted";
export function WarningModal() {
  const [open, setOpen] = useState(() => !localStorage.getItem(WARN_KEY));
  useEffect(() => {
    const reopen = () => setOpen(true);
    window.addEventListener("essey:reopen-warning", reopen);
    return () => window.removeEventListener("essey:reopen-warning", reopen);
  }, []);
  useEffect(() => {
    if (!open) return;
    document.body.style.overflow = "hidden";
    return () => { document.body.style.overflow = ""; };
  }, [open]);
  if (!open) return null;
  const accept = () => { localStorage.setItem(WARN_KEY, "1"); setOpen(false); };
  return (
    <div className="warn-modal" role="dialog" aria-modal="true" aria-label="Before you step onto the Exchange">
      <div className="warn-box">
        <div className="warn-mark"><EMonogram size={54} stamped={false} /></div>
        <h2>Before you step onto the Exchange</h2>
        <p className="warn-lede"><b>Essey is experimental software.</b> It's early, it's built in the open — including
          the audits that made us look bad. Read this before you connect a wallet.</p>
        <ul className="warn-list">
          <li><b>Nothing here is financial advice.</b> Not from us, not from the app, not from anyone.</li>
          <li><b>The assets are volatile.</b> $ESSEY is a pure access token — you spend it to get in; you never earn
            it back as a reward. Its price can go to zero. Tokenized stocks move with their markets and carry
            oracle and issuer risk.</li>
          <li><b>"Payouts" are protocol fees, not dividends.</b> When the Bell rings, it distributes accrued fees to
            Seat holders as stock — a mechanical fee-share, <b>not a dividend, not a yield promise.</b> Some days
            the pot is thin. Some days nobody rings it.</li>
          <li><b>No payout is guaranteed.</b> Ever. If the Exchange is quiet, it's quiet — and the Tape will show you
            that honestly.</li>
          <li><b>Provable ≠ risk-free.</b> We prove what we can prove — a distribution split, a loan's solvency —
            and hand you the button to check. Oracles can be wrong within their band; liquidation isn't instant;
            ordinary software has ordinary bugs. Proof removes one <em>class</em> of risk, not all of it.</li>
          <li><b>Your jurisdiction is your responsibility.</b> Some features are restricted in some places for good
            reason.</li>
          <li><b>Testnet, play money.</b> Everything here is live on Robinhood Chain <b>testnet</b> — real
            contracts, real mechanics, but the tokens have <b>no real value</b>. This is not on mainnet.</li>
        </ul>
        <button className="btn btn-gold warn-accept" onClick={accept}>I understand — let me in</button>
        <Link className="warn-docs" to="/start" onClick={accept}>Or start the guided tour →</Link>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- the hero (§2): "The Exchange"
// Left: the claim. Right: the Bell + Tape peek — both explicitly labeled PREVIEW because the
// contracts are audited but undeployed; no fake "live" state, per the design doc's honesty rule.
const SAMPLE_TAPE: [string, string, string][] = [
  ["🔔", "BELL RUNG · 0.44 ETH → 1,662 Vaults", "proof ✓"],
  ["✓", "LOAN PROVEN SOLVENT · Note #418 · HF 1.72", "verify"],
  ["◆", "SEAT #1204 MINTED · Vault created", "6551"],
  ["⬡", "EXCHANGE · Seat #0197 sniped · fee → the Bell", "verify"],
];

export function ExchangeHero() {
  const [pot, setPot] = useState(0.63);
  const [rung, setRung] = useState(false);
  // Generation counter: rAF pauses while the tab is hidden, so a drain loop can outlive the 3.2s
  // reset and overwrite the refilled pot with 0. Bumping the generation on reset orphans any
  // still-running loop.
  const gen = useRef(0);
  const ring = () => {
    if (rung) return;
    setRung(true);
    if (reducedMotion()) { setPot(0); return; }
    // the Bell moment, contained: pot drains, brass pulse, then calm (~900ms once)
    const g = ++gen.current;
    const t0 = performance.now();
    const step = (t: number) => {
      if (g !== gen.current) return; // reset happened while we were paused — stand down
      const k = Math.min(1, (t - t0) / 700);
      setPot(0.63 * (1 - k));
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  };
  useEffect(() => {
    if (!rung) return;
    const id = setTimeout(() => { gen.current++; setPot(0.63); setRung(false); }, 3200);
    return () => clearTimeout(id);
  }, [rung]);

  return (
    <section className="hero mkt-hero">
      <div className="wrap hero-grid">
        <div>
          <span className="eyebrow">Provably fair · provably solvent</span>
          <h1>A stock-market club where the odds and the books are both <em>provable</em>.</h1>
          <p className="lede">Buy a Seat. Earn Payouts in real stock. Borrow against them. Every ring, every draw,
            every loan — verifiable on-chain.</p>
          <div className="hero-cta">
            <Link className="btn btn-gold" to="/start">Start the quest — earn a mint spot</Link>
            <Link className="btn btn-ghost" to="/portfolio">Your portfolio</Link>
          </div>
          <div className="proof-strip num">⬡ 2,222 Seats · fees pay out as stock · every claim links a real tx</div>
        </div>
        <aside className={"bell-plate" + (rung ? " rung" : "")}>
          <div className="bell-head">
            <span className="bell-title">THE BELL</span>
            <span className="preview-chip live" title="Live on Robinhood Chain testnet — connect to ring the real Bell.">testnet</span>
          </div>
          <div className="bell-pot">
            <span className="bell-emoji" aria-hidden>🔔</span>
            <div className="bell-nums">
              <div className="bell-amt num">{pot.toFixed(2)} ETH</div>
              <div className="bell-sub">the pot — trade fees, royalties, loan interest</div>
            </div>
          </div>
          <div className="bell-gauge"><div className="bell-fill" style={{ width: `${(pot / 0.63) * 100}%` }} /></div>
          <button className="btn btn-gold bell-ring" onClick={ring} disabled={rung}>
            {rung ? "✓ rung — payout split by Tier" : "RING THE BELL"}
          </button>
          <div className="bell-tip">anyone can ring it · the ringer earns a tip for the gas</div>
          <div className="tape-peek">
            <div className="tape-peek-h">THE TAPE <span className="preview-chip">sample</span></div>
            {SAMPLE_TAPE.map(([icon, text, tag], i) => (
              <div className="tape-row" key={i}>
                <span className="tr-icon">{icon}</span>
                <span className="tr-text num">{text}</span>
                <span className="tr-tag">{tag}</span>
              </div>
            ))}
            <div className="tape-note">sample rows — at open, every line is a real tx you can verify</div>
          </div>
        </aside>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------- the claim strip + club flow (§4)
export function ClubFlow() {
  const BEATS: [string, string, string][] = [
    ["01", "Get a Seat", "2,222 membership NFTs. Each carries its own on-chain wallet — the Vault."],
    ["02", "Raise its Tier", "Stake $ESSEY to grow your Seat's share of every Payout. Half the fee burns."],
    ["03", "Someone rings the Bell", "When the fee pot fills, anyone can ring it — and earns a tip for doing so."],
    ["04", "Stock lands in your Vault", "The pot splits across every active Seat, by Tier, paid in real stock."],
  ];
  return (
    <section className="band club" id="club">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">How the club works</span>
          <h2>Seat → Tier → the Bell → Payout</h2>
          <p>The whole loop in four beats. Fees from real activity — trading, royalties, loan interest — pool up,
            and the Bell distributes them to Seat holders as stock. No emissions, no promises: a fee-share you can audit.</p>
        </div></div>
        <div className="flow">
          {BEATS.map(([no, h, p]) => (
            <div className="step" key={no}>
              <span className="no">{no}</span>
              <h3>{h}</h3><p>{p}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------- mechanic cards + toys (§5)
// Each card: one-liner + an expand-in-place toy — a safe, no-wallet sandbox. Every card carries a
// status chip that tells the truth about build state (built+audited vs scoped).
type CardDef = {
  id: string; icon: string; name: string; sub: string; oneLiner: string;
  status: "audited" | "scoped"; toy: () => ReactNode;
};

function TierToy() {
  const TIERS = [["Base", 100], ["Tier I", 160], ["Tier II", 200], ["Tier III", 333]] as const;
  const [t, setT] = useState(0);
  const w = TIERS[t][1];
  return (
    <div className="toy">
      <input type="range" min={0} max={3} step={1} value={t} onChange={(e) => setT(+e.target.value)} aria-label="Tier" />
      <div className="tier-row">
        {TIERS.map(([nm, wt], i) => (
          <div key={nm} className={"tier-cell" + (i === t ? " on" : "")}>
            <div className="tier-nm">{nm}</div>
            <div className="tier-bar"><div style={{ height: `${(wt / 333) * 100}%` }} /></div>
            <div className="tier-wt num">×{(wt / 100).toFixed(2)}</div>
          </div>
        ))}
      </div>
      <div className="toy-note">Your slice of every Payout scales <b className="num">×{(w / 100).toFixed(2)}</b> vs a
        Base Seat. Honest costs: <b>50% of the activation fee is burned</b>, and Tier clears when the Seat changes
        hands — it's a recurring choice, not a one-time flex.</div>
    </div>
  );
}

function ExchangeToy() {
  const [inv, setInv] = useState(5);
  const [pot, setPot] = useState(0);
  const [snipeN, setSnipeN] = useState("");
  const buy = (fee: number) => { if (inv > 0) { setInv(inv - 1); setPot(+(pot + fee).toFixed(1)); } };
  return (
    <div className="toy">
      <div className="ex-row">
        <button className="btn btn-gold" onClick={() => buy(10)} disabled={inv === 0}>Buy next · fee 10</button>
        <span className="ex-snipe">
          <input className="num" placeholder="#" value={snipeN} onChange={(e) => setSnipeN(e.target.value.replace(/\D/g, "").slice(0, 4))} aria-label="Seat number" />
          <button className="btn btn-ghost" onClick={() => buy(15)} disabled={inv === 0}>Snipe · fee 15</button>
        </span>
      </div>
      <div className="ex-stats num">
        <span>float: {inv} Seats</span>
        <span className="ex-pot">→ the Bell pot: +{pot}</span>
        {inv === 0 && <button className="linklike" onClick={() => { setInv(5); setPot(0); }}>reset</button>}
      </div>
      <div className="toy-note">Flat price, two-sided: buy the next Seat, snipe an exact #, or sell one back to the
        float. <b>Every trade's fee drops into the Bell pot</b> — trading literally funds the Payouts.</div>
    </div>
  );
}

function VaultToy() {
  const [flip, setFlip] = useState(false);
  return (
    <div className="toy">
      <button className={"vault-card" + (flip ? " flipped" : "")} onClick={() => setFlip(!flip)} aria-label="Flip the Seat to see its Vault">
        <span className="vc-face vc-front"><EMonogram size={30} /> SEAT #0891<i>tap to flip</i></span>
        <span className="vc-face vc-back num">VAULT · 0.8 AAPL · 1.2 NVDA · 140 USDG</span>
      </button>
      <div className="toy-note">The Seat <b>is</b> a wallet (ERC-6551). Sell the Seat and the Vault — and everything
        in it — travels with it.</div>
    </div>
  );
}

function PayoutToy() {
  const [pref, setPref] = useState<"base" | "stock">("stock");
  const SLICES = [["Tier III", 333], ["Tier II", 200], ["Base", 100]] as const;
  const total = SLICES.reduce((a, [, w]) => a + w, 0);
  return (
    <div className="toy">
      <div className="pay-bar">
        {SLICES.map(([nm, w]) => (
          <div key={nm} className="pay-slice" style={{ flex: w }} title={`${nm} — weight ${w}`}>
            <span>{nm}</span><i className="num">{Math.round((w / total) * 100)}%</i>
          </div>
        ))}
      </div>
      <div className="pay-pref">
        <span>receive as</span>
        <div className="seg" role="tablist">
          <button aria-selected={pref === "base"} onClick={() => setPref("base")}>ETH</button>
          <button aria-selected={pref === "stock"} onClick={() => setPref("stock")}>AAPL</button>
        </div>
      </div>
      <div className="toy-note">One pot → every active Vault, sliced by Tier weight. Set a payout preference and the
        claim converts at the edge — if conversion can't fill safely, it <b>fails open to base</b>. Always "Payout,"
        never "dividend": these are protocol fees, mechanically LP-style.</div>
    </div>
  );
}

function SeatMapToy() {
  // 1 cell = 10 Seats; a representative map, not a live one (no indexer yet — labeled).
  const CELLS = 222;
  const lit = new Set<number>();
  for (let i = 0; i < CELLS; i++) { if ((i * 7919) % 100 < 44) lit.add(i); } // deterministic scatter
  return (
    <div className="toy">
      <div className="seat-map" aria-hidden>
        {Array.from({ length: CELLS }, (_, i) => <span key={i} className={lit.has(i) ? "lit" : ""} />)}
      </div>
      <div className="toy-note num">2,222 Seats · one cell = 10 · <span className="lit-dot" /> held by members ·
        dim = Exchange float. The float is the design, not a failure — it's the scarcity dial.</div>
    </div>
  );
}

function AfterHoursToy() {
  const [night, setNight] = useState(false);
  return (
    <div className="toy">
      <div className="seg" role="tablist" style={{ width: "fit-content" }}>
        <button aria-selected={!night} onClick={() => setNight(false)}>Regular Hours</button>
        <button aria-selected={night} onClick={() => setNight(true)}>After Hours</button>
      </div>
      <div className="toy-note">{night
        ? <><b>After Hours:</b> the second engine, designed — 6% royalties on Seat resales plus the protocol's share
          of loan interest, both routed to the Bell. The streams that outlast launch hype.</>
        : <><b>Regular Hours:</b> the first engine, built — Exchange trade fees route straight into the Bell pot.</>}
      </div>
    </div>
  );
}

function NoteToy() {
  const [gone, setGone] = useState(false);
  return (
    <div className="toy">
      <div className={"note-cert" + (gone ? " transferred" : "")}>
        <div className="nc-h"><span>NOTE Nº 418</span><EMonogram size={22} /></div>
        <div className="nc-b num">debt 1,240 USDG · collateral 8 AAPL · HF 1.72</div>
        <div className="nc-f">⬡ proven solvent · bearer instrument</div>
      </div>
      <button className="linklike" onClick={() => setGone(!gone)}>{gone ? "↩ take it back" : "transfer the whole position →"}</button>
      <div className="toy-note">Your loan is a certificate you can sell. Debt, collateral, and the solvency proof all
        travel with it — a portable, provably-solvent credit object.</div>
    </div>
  );
}

function EsseyToy() {
  return (
    <div className="toy">
      <div className="sink-diagram num">
        <div className="sink-in">Seats · Tiers · Cases<span>$ESSEY in</span></div>
        <div className="sink-mid"><EMonogram size={34} /></div>
        <div className="sink-out">AAPL · NVDA · USDG<span>stock out</span></div>
      </div>
      <div className="toy-note">You spend the volatile token to earn the stable asset — <b>rewards are never paid in
        $ESSEY</b>, so there's no emissions death-spiral to run from. Fixed supply, no minting, no admin.</div>
    </div>
  );
}

function CasesToy() {
  return (
    <div className="toy">
      <div className="case-teaser">🎁 → <span className="num">1× NVDA</span> sealed in a Vault-NFT</div>
      <div className="toy-note">Open a Case, get real stock sealed in a Vault — keep it, borrow against it, or sell it
        back. The twist: <b>the prize is reserved in real inventory before you open</b>, provably. The fair-value
        "401k pack" ships first; anything spicier waits on legal review. <i>In design — not built.</i></div>
    </div>
  );
}

function TapeToy() {
  return (
    <div className="toy">
      {SAMPLE_TAPE.slice(0, 3).map(([icon, text, tag], i) => (
        <div className="tape-row" key={i}><span className="tr-icon">{icon}</span><span className="tr-text num">{text}</span><span className="tr-tag">{tag}</span></div>
      ))}
      <div className="toy-note">Everything the Exchange does, printed live — and every line is a real receipt. A
        <b> ⬡ proven-only</b> filter lets a skeptic watch only the verifiable events. That toggle is the whole pitch.</div>
    </div>
  );
}

const CARDS: CardDef[] = [
  { id: "seat", icon: "⬡", name: "Seat", sub: "membership NFT", status: "audited",
    oneLiner: "A seat on the exchange. Own one, and you get a cut of everything the Exchange earns.", toy: SeatMapToy },
  { id: "vault", icon: "▣", name: "Vault", sub: "the Seat's own wallet", status: "audited",
    oneLiner: "Every Seat carries its own wallet. Sell the Seat, and everything in it goes with it.", toy: VaultToy },
  { id: "tier", icon: "▲", name: "Tier", sub: "staking level", status: "audited",
    oneLiner: "Stake $ESSEY to level up your Seat. Higher Tier = a bigger slice of every Payout.", toy: TierToy },
  { id: "exchange", icon: "⇄", name: "the Exchange", sub: "the Seat AMM", status: "audited",
    oneLiner: "Swap $ESSEY for a Seat instantly — take the next one, or snipe the exact number you want.", toy: ExchangeToy },
  { id: "bell", icon: "🔔", name: "the Bell", sub: "permissionless payout", status: "audited",
    oneLiner: "When the fee pot is full, anyone can ring the Bell — and whoever does earns a tip.", toy: () => (
      <div className="toy"><div className="toy-note">The hero's centerpiece — scroll up and ring it. O(1) accumulator
        math, no bot, no admin: the ringer pays the gas, the contract pays the tip.</div></div>) },
  { id: "payout", icon: "◆", name: "Payout", sub: "the fee-share (not a dividend)", status: "audited",
    oneLiner: "The Bell splits the pot into every active Seat's Vault — paid in real stock, by Tier.", toy: PayoutToy },
  { id: "afterhours", icon: "🌙", name: "After Hours", sub: "the second engine", status: "scoped",
    oneLiner: "A second stream — royalties and loan interest keep paying after the launch buzz fades.", toy: AfterHoursToy },
  { id: "note", icon: "📜", name: "Note", sub: "loans as bearer NFTs", status: "audited",
    oneLiner: "Your loan is a certificate you can sell. Debt, collateral, and its proof travel with it.", toy: NoteToy },
  { id: "cases", icon: "🎁", name: "Cases", sub: "stock gacha — scoped", status: "scoped",
    oneLiner: "Open a Case, get real stock sealed in a Vault. Keep it, borrow against it, or sell it back.", toy: CasesToy },
  { id: "essey", icon: "◈", name: "$ESSEY", sub: "the access token", status: "audited",
    oneLiner: "The chip you spend to get in. You never earn $ESSEY — you earn stock.", toy: EsseyToy },
  { id: "tape", icon: "📈", name: "the Tape", sub: "the live proof feed", status: "scoped",
    oneLiner: "Everything the Exchange does, printed live — and every line is a real receipt.", toy: TapeToy },
];

export function Mechanics() {
  const [open, setOpen] = useState<string | null>("tier");
  return (
    <section className="band mechanics" id="market">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The Market</span>
          <h2>Every mechanic, playable before it costs anything</h2>
          <p>Tap a card to play with the mechanic in a no-wallet sandbox — then do it for real on its own page.
            Each maps to a live, audited contract on testnet.</p>
        </div></div>
        <div className="mech-grid">
          {CARDS.map((c) => {
            const isOpen = open === c.id;
            return (
              <article key={c.id} className={"mech-card" + (isOpen ? " open" : "")}>
                <button className="mech-hit" onClick={() => setOpen(isOpen ? null : c.id)} aria-expanded={isOpen}>
                  <span className="mech-icon" aria-hidden>{c.icon}</span>
                  <span className="mech-nm">{c.name}<i>{c.sub}</i></span>
                  <span className={"mech-status " + c.status}>{c.status === "audited" ? "built · audited" : "scoped"}</span>
                </button>
                <p className="mech-line">{c.oneLiner}</p>
                {isOpen && c.toy()}
              </article>
            );
          })}
        </div>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------- the engine underneath
// The lending engine, compressed to its role in THIS narrative: it is why the Payouts are real.
// (The old site's full lending surface — live markets, borrow/earn panels, chain comparisons —
// belonged to a previous iteration and was removed; the docs room keeps the specs.)
export function EngineSection() {
  const CARDS: [string, string][] = [
    ["Conservative by construction", "Collateral is priced by session-gated Chainlink feeds with fail-closed discipline: a stale feed, a holiday gap, or an off-hours equity price refuses rather than guesses. No loan and no Case buyback ever settles on an unverifiable price."],
    ["Positions are Notes", "Every loan is a bearer NFT — debt, collateral, and its solvency state travel together, sellable as one object. The same engine's interest is a designed Bell stream, so borrowing literally funds the Payouts."],
    ["Audited in the open", "Every adversarial audit round is published, clean or not — including the ones that found real bugs the day before they'd have shipped. The audit trail is the product."],
  ];
  return (
    <section className="band engine" id="engine">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The engine underneath</span>
          <h2>Why the Payouts are real</h2>
          <p>The game sits on a lending protocol for tokenized stocks on Robinhood Chain. Fees from real
            loans, real trades, and real royalties fill the pot — not emissions, not promises.</p>
        </div></div>
        <div className="flow">
          {CARDS.map(([h, p]) => (
            <div className="step" key={h}><h3>{h}</h3><p>{p}</p></div>
          ))}
        </div>
        <div className="twist-status" style={{ marginTop: 16 }}>Built and fork-tested against real Robinhood
          Chain state and live on Robinhood Chain testnet. The full specs — oracle discipline, risk framework, rate
          model, and everything still open — are in the docs room, rendered from the repo's own files.</div>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------- the provable twist (§4.5)
export function ProvableTwist() {
  return (
    <section className="band twist" id="provable">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The part they can't copy</span>
          <h2>Provably fair <em>and</em> provably solvent</h2>
          <p>Plenty of games can prove a draw was fair. Only a game built on a real lending protocol can prove the
            books behind the payouts are solvent — because ours publishes the proof either way.</p>
        </div></div>
        <div className="twist-grid">
          <div className="twist-card">
            <div className="twist-h">⬡ Provably fair</div>
            <p>Every Bell split is deterministic accumulator math anyone can re-run. Every Case draw commits its entropy before you open. The odds aren't a promise — they're arithmetic.</p>
          </div>
          <div className="twist-card">
            <div className="twist-h">⬡ Provably solvent</div>
            <p>The Payouts come from a lending engine whose solvency rule is machine-checked and whose audit rounds are
              published clean or not. The books aren't a promise either.</p>
          </div>
        </div>
        <div className="twist-status">Status, honestly: the Market contracts (Seat, Vault, Bell, the Exchange, Notes,
          $ESSEY, the mint distributor, the lending pool) are <b>adversarially audited across six published rounds
          and live on Robinhood Chain testnet</b> — you can play the whole thing with play money right now, and
          every event links a real transaction. Not on mainnet yet. <a href={`${REPO}/tree/main/docs/audits`} target="_blank" rel="noreferrer">Read the audits ↗</a>
        </div>
      </div>
    </section>
  );
}
