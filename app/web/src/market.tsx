// The Market layer surface — the gamified face of Essey, Dons v3 (docs/TOKENOMICS-v3.md).
// Everything here is STATIC: the toys are client-side sandboxes with the deployed numbers baked in.
// Guardrail: no section may claim more than the contracts deliver — the Don contracts are audited
// and live on Robinhood Chain testnet; the toys here are sandboxes and say so on the surface itself,
// not in a footnote. Numbers mirror the deployed config (floor 300,030 $ESSEY; AMM 8%/12%; the
// 666 tier ladder; loan 50% LTV / 15% APR / 70% liquidation).
import { createElement, useEffect, useRef, useState, type ReactNode } from "react";
import { Link } from "react-router-dom";

const REPO = "https://github.com/erikastramecki/essey";

const reducedMotion = () =>
  typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;

// The deployed economics, in one place so every toy tells the same story.
const DON_SUPPLY = 8_888;
const FLOOR = 300_030; // $ESSEY per Don, today — the reserve share; it can only rise

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
          <li><b>Testnet, play money — you can't lose real money here.</b> Everything is live on Robinhood Chain
            <b> testnet</b> with real contracts and real mechanics, but the tokens have <b>no real value</b> and this
            is not on mainnet. So explore freely. Then, the honest rest:</li>
          <li><b>Nothing here is financial advice.</b> Not from us, not from the app, not from anyone.</li>
          <li><b>The assets are volatile.</b> $ESSEY is a pure access token — you spend it to get in; you never earn
            it back as a reward. Its price can go to zero. Tokenized stocks move with their markets and carry
            oracle and issuer risk.</li>
          <li><b>"Payouts" are protocol fees, not dividends.</b> When the Bell rings, it distributes accrued fees to
            Don holders as stock — a mechanical fee-share, <b>not a dividend, not a yield promise.</b> Some days
            the pot is thin.</li>
          <li><b>No payout is guaranteed.</b> Ever. If the Exchange is quiet, it's quiet — and the Tape will show you
            that honestly.</li>
          <li><b>Redemption is a one-way door.</b> Redeeming a Don pays its full $ESSEY floor and locks the Don in
            the reserve forever — membership over, and its Vault, with everything still in it, is locked away too.
            Claim and empty the Vault first.</li>
          <li><b>Liquidation consumes the Don.</b> Borrow against a Don and let the debt cross 70% of its floor, and
            anyone can liquidate it: the Don is redeemed to settle the debt, the surplus comes back to you — but the
            Don is gone, and every unclaimed dividend in its Vault is forfeited with it.</li>
          <li><b>Provable ≠ risk-free.</b> We prove what we can prove — a distribution split, a loan's solvency —
            and hand you the button to check. Oracles can be wrong within their band; liquidation isn't instant;
            ordinary software has ordinary bugs. Proof removes one <em>class</em> of risk, not all of it.</li>
          <li><b>Your jurisdiction is your responsibility.</b> Some features are restricted in some places for good
            reason.</li>
        </ul>
        <button className="btn btn-gold warn-accept" onClick={accept}>I understand — let me in</button>
        <Link className="warn-docs" to="/how-it-works" onClick={accept}>Or read how it works, start to finish →</Link>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- the hero (§2): the Dons
// Left: the claim. Right: the Bell + Tape peek — both explicitly labeled as demos; no fake "live"
// state, per the design doc's honesty rule.
const SAMPLE_TAPE: [string, string, string][] = [
  ["🔔", "BELL RUNG · 96 USDG → every staked Don, by tier", "proof ✓"],
  ["✓", "LOAN PROVEN SOLVENT · Don #0418 · debt ≤ 50% of floor", "verify"],
  ["◆", "DON #1204 MINTED · Vault created", "6551"],
  ["⬡", "EXCHANGE · Don #0197 sniped · 70% of the fee → stock", "verify"],
];

export function ExchangeHero() {
  // The pot accrues in USDG (fees); at claim each Don's share converts to stock at the edge.
  const POT0 = 128.40;
  const [pot, setPot] = useState(POT0);
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
      setPot(POT0 * (1 - k));
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  };
  useEffect(() => {
    if (!rung) return;
    const id = setTimeout(() => { gen.current++; setPot(POT0); setRung(false); }, 3200);
    return () => clearTimeout(id);
  }, [rung]);

  return (
    <section className="hero mkt-hero">
      <div className="wrap hero-grid">
        <div>
          <span className="eyebrow">Provably fair · provably solvent</span>
          <h1>8,888 Dons.<br />Each one <em>a seat at the table.</em></h1>
          <p className="lede">A Don is three instruments in one NFT: a seat that earns a cut of every protocol
            fee, paid in tokenized Robinhood stock; a <b className="num">300,030 $ESSEY</b> floor you can redeem
            at any time; and a margin account that borrows against that floor while the seat keeps earning.
            Every ring, trade, and loan is verifiable on-chain.</p>
          <div className="hero-cta">
            <Link className="btn btn-gold" to="/builder">Build your Don</Link>
            <Link className="btn btn-ghost" to="/how-it-works">How it works</Link>
          </div>
          <div className="proof-strip num">⬡ 8,888 Dons · 300,030 $ESSEY floor under each · fees pay out
            as stock · <Link to="/faucet">get testnet funds →</Link></div>
        </div>
        <aside className={"bell-plate" + (rung ? " rung" : "")}>
          <div className="bell-head">
            <span className="bell-title">THE BELL</span>
            <span className="preview-chip" title="A demo of the Bell — the real pot lives on the Bell page.">demo</span>
          </div>
          <div className="bell-pot">
            <span className="bell-emoji" aria-hidden>🔔</span>
            <div className="bell-nums">
              <div className="bell-amt num">{pot.toFixed(2)} USDG</div>
              <div className="bell-sub">the pot — mint fees, trade fees, loan interest → paid out as stock</div>
            </div>
          </div>
          <div className="bell-gauge"><div className="bell-fill" style={{ width: `${(pot / POT0) * 100}%` }} /></div>
          <button className="btn btn-gold bell-ring" onClick={ring} disabled={rung}>
            {rung ? "✓ rung — split across staked Dons, by tier" : "RING THE BELL"}
          </button>
          <div className="bell-tip">a protocol keeper rings it — no tip to race for, the whole pot goes to holders</div>
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
    ["01", "Mint a Don", "8,888 NFTs, three ways in: free on the whitelist, ~$3 to reroll the traits, ~$10 to build them exactly. 100% of every mint fee buys stock for staked holders."],
    ["02", "Stake it — take your seat", "Activate a tier on the 666 ladder (66,666 → 1,666,666 $ESSEY buys ×1 → ×3.33 payout weight). Half the fee burns forever. Staking locks your art."],
    ["03", "The Bell rings", "Every protocol fee pools into one pot. When it fills, a keeper rings the Bell — no tip to race for, the whole pot goes to holders. Anyone may ring it too."],
    ["04", "Stock lands in your Vault", "The pot splits across every staked Don, pro-rata by tier weight, delivered as the tokenized stocks you elect — or the default BUNDLE."],
  ];
  return (
    <section className="band club" id="club">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">How the club works</span>
          <h2>Don → Tier → the Bell → Payout</h2>
          <p>The whole loop in four beats. The dons have a seat at the table: fees from real activity — minting,
            trading, borrowing — pool up, and the Bell pays the people seated, in stock. No emissions, no promises:
            a fee-share you can audit.</p>
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
// Each card: one-liner + an expand-in-place toy — a safe, no-wallet sandbox with the deployed
// numbers baked in. Every card carries a status chip that tells the truth about build state.
type CardDef = {
  id: string; icon: string; name: string; sub: string; oneLiner: string;
  status: "audited" | "scoped"; toy: () => ReactNode;
};

// The 666 ladder, exactly as deployed: cumulative activation fee ($ESSEY) → payout weight.
const LADDER = [
  ["Base", 66_666, 1.0],
  ["Tier 1", 166_666, 1.25],
  ["Tier 2", 366_666, 1.6],
  ["Tier 3", 666_666, 2.0],
  ["Tier 4", 1_666_666, 3.33],
] as const;

function TierToy() {
  const [t, setT] = useState(0);
  const [nm, fee, w] = LADDER[t];
  return (
    <div className="toy">
      <input type="range" min={0} max={4} step={1} value={t} onChange={(e) => setT(+e.target.value)} aria-label="Tier" />
      <div className="tier-row">
        {LADDER.map(([name, , wt], i) => (
          <div key={name} className={"tier-cell" + (i === t ? " on" : "")}>
            <div className="tier-nm">{name}</div>
            <div className="tier-bar"><div style={{ height: `${(wt / 3.33) * 100}%` }} /></div>
            <div className="tier-wt num">×{wt.toFixed(2)}</div>
          </div>
        ))}
      </div>
      <div className="toy-note"><b>{nm}</b>: a one-time <b className="num">{fee.toLocaleString()} $ESSEY</b> activation
        fee puts this Don on the payout roll at <b className="num">×{w.toFixed(2)}</b> weight, from the very next ring.
        Fees are cumulative — upgrading later costs only the difference. The fee is a sink, not a deposit:
        <b> 50% is burned forever</b>, 50% goes to treasury. The tier clears if the Don ever changes hands, and
        <b> activating locks the art permanently</b>.</div>
    </div>
  );
}

function MintToy() {
  const PATHS = [
    ["Whitelist", "free — gas only", "Hold an allocation and claim your Dons for gas. Traits roll random; reroll as much as you like before you stake. The whitelist is a Merkle root committed on-chain behind a 2-day public timelock — no one can swap it in quietly."],
    ["Reroll", "0.00075 ETH · ~$3", "Re-randomize any Don you own, unlimited, until it's staked. Your old trait combo is released back to the pool and your new one is locked in."],
    ["Custom", "0.0025 ETH · ~$10", "Open the builder, choose every trait, mint exactly that Don. Combos are unique by contract — the uniqueness ledger lives on-chain, so no two Dons can ever share a look."],
  ] as const;
  const [p, setP] = useState(2);
  return (
    <div className="toy">
      <div className="seg" role="tablist" style={{ width: "fit-content" }}>
        {PATHS.map(([nm], i) => (
          <button key={nm} aria-selected={p === i} onClick={() => setP(i)}>{nm}</button>
        ))}
      </div>
      <div className="toy-note"><b>{PATHS[p][0]} · {PATHS[p][1]}.</b> {PATHS[p][2]}</div>
      <div className="toy-note">All fees are paid in ETH and <b>100% of every fee buys stock for staked
        holders</b> — the team cut on mints is set to 0, on-chain. <Link to="/builder">Open the builder →</Link></div>
    </div>
  );
}

function VaultToy() {
  const [flip, setFlip] = useState(false);
  return (
    <div className="toy">
      <button className={"vault-card" + (flip ? " flipped" : "")} onClick={() => setFlip(!flip)} aria-label="Flip the Don to see its Vault">
        <span className="vc-face vc-front"><EMonogram size={30} /> DON #0891<i>tap to flip</i></span>
        <span className="vc-face vc-back num">VAULT · 0.8 AAPL · 1.2 NVDA · 140 USDG</span>
      </button>
      <div className="toy-note">The Don <b>is</b> a wallet (ERC-6551), created at mint. Everything it earns lands in
        its Vault, and the Vault travels with the Don — sell it, and everything inside goes with it. <b>Claim and
        empty the Vault before you sell, redeem, or run a loan hot.</b></div>
    </div>
  );
}

function FloorToy() {
  // The reserve math, playable: funding raises the floor; a redemption pays exactly one pro-rata
  // share, so the floor for everyone else never drops.
  const POOL0 = 2_666_666_666, BACKED0 = DON_SUPPLY;
  const [pool, setPool] = useState(POOL0);
  const [backed, setBacked] = useState(BACKED0);
  const floor = pool / backed;
  return (
    <div className="toy">
      <div className="ex-stats num" style={{ marginBottom: 8 }}>
        <span>reserve: {Math.round(pool).toLocaleString()} $ESSEY</span>
        <span>backing {backed.toLocaleString()} Dons</span>
        <span className="ex-pot">floor: {Math.floor(floor).toLocaleString()} $ESSEY each</span>
      </div>
      <div className="ex-row">
        <button className="btn btn-gold" onClick={() => setPool(pool + 888_800)}>Fund +888,800 (anyone can)</button>
        <button className="btn btn-ghost" onClick={() => { if (backed > 1) { setPool(pool - floor); setBacked(backed - 1); } }}>Redeem one Don</button>
        {(pool !== POOL0 || backed !== BACKED0) && <button className="linklike" onClick={() => { setPool(POOL0); setBacked(BACKED0); }}>reset</button>}
      </div>
      <div className="toy-note">Behind every Don sits a reserve seeded with <b className="num">2,666,666,666
        $ESSEY</b> — 30% of the supply. <b>Redemption is always open</b>: any owner can cash a Don in for its full
        floor share, no permission, no window, no admin — which is why a Don can never trade below the floor.
        Funding is open to anyone (all loan interest goes here), and the only way out is a redemption at exactly one
        share — so the floor for everyone else <b>can only rise</b>. But redeeming is a one-way door: the Don is
        locked in the reserve forever, membership over, and its Vault is locked away with it. Claim first.</div>
    </div>
  );
}

function ExchangeToy() {
  // Floor-pinned AMM: price = the live redemption floor; buy +8%, snipe +12%, sell −8%;
  // 70% of every fee buys stock for staked Dons, 30% treasury.
  const [stock, setStock] = useState(0);
  const [treasury, setTreasury] = useState(0);
  const [snipeN, setSnipeN] = useState("");
  const trade = (feePct: number) => {
    const fee = FLOOR * feePct;
    setStock((s) => s + fee * 0.7);
    setTreasury((t) => t + fee * 0.3);
  };
  return (
    <div className="toy">
      <div className="ex-row">
        <button className="btn btn-gold" onClick={() => trade(0.08)}>Buy · ~{Math.round(FLOOR * 1.08).toLocaleString()} all-in</button>
        <span className="ex-snipe">
          <input className="num" placeholder="#" value={snipeN} onChange={(e) => setSnipeN(e.target.value.replace(/\D/g, "").slice(0, 4))} aria-label="Don number" />
          <button className="btn btn-ghost" onClick={() => trade(0.12)}>Snipe · ~{Math.round(FLOOR * 1.12).toLocaleString()}</button>
        </span>
        <button className="btn btn-ghost" onClick={() => trade(0.08)}>Sell · net ~{Math.round(FLOOR * 0.92).toLocaleString()}</button>
      </div>
      <div className="ex-stats num">
        <span>price = the live floor: {FLOOR.toLocaleString()} $ESSEY</span>
        <span className="ex-pot">fees → stock for staked Dons: +{Math.round(stock).toLocaleString()} · treasury: +{Math.round(treasury).toLocaleString()}</span>
        {stock > 0 && <button className="linklike" onClick={() => { setStock(0); setTreasury(0); }}>reset</button>}
      </div>
      <div className="toy-note">The desk trades at the <b>live redemption floor</b>, read fresh from the reserve on
        every trade — it can never be arbitraged against a risen floor. Buy the next Don (+8%), snipe the exact #
        you want (+12%), or sell one back (−8%). <b>70% of every fee buys tokenized stock for staked Dons</b>;
        30% goes to treasury. Every trade takes a slippage bound: if the floor rises before your transaction lands,
        it reverts rather than filling worse than you approved.</div>
    </div>
  );
}

function PayoutToy() {
  // Elect up to 3 stocks; empty election = the default BUNDLE basket.
  const OPTIONS = ["AAPL", "NVDA", "MSFT"] as const;
  const [picks, setPicks] = useState<string[]>([]);
  const toggle = (s: string) =>
    setPicks((p) => (p.includes(s) ? p.filter((x) => x !== s) : p.length < 3 ? [...p, s] : p));
  return (
    <div className="toy">
      <div className="seg" role="tablist" style={{ width: "fit-content" }}>
        {OPTIONS.map((s) => (
          <button key={s} aria-selected={picks.includes(s)} onClick={() => toggle(s)}>{s}</button>
        ))}
      </div>
      <div className="ex-stats num" style={{ marginTop: 8 }}>
        <span>receiving: {picks.length === 0 ? "BUNDLE (the default basket)" : picks.map((s) => `${Math.round(100 / picks.length)}% ${s}`).join(" · ")}</span>
      </div>
      <div className="toy-note">Elect <b>up to 3 tokenized stocks</b> with your own split — or elect nothing and
        receive the default BUNDLE basket. If a conversion can't settle (market closed, stale feed), that slice
        arrives as USDG instead — your money is never stuck behind a swap. Elections clear when the Don changes
        hands. Always "Payout," never "dividend": these are protocol fees, mechanically LP-style.</div>
    </div>
  );
}

function BorrowToy() {
  // The loan meter: 50% LTV, 15% APR simple, liquidation at 70% of the live floor.
  const MAX = Math.floor(FLOOR * 0.5); // 150,015
  const LIQ = Math.floor(FLOOR * 0.7); // 210,021
  const [debt, setDebt] = useState(MAX);
  const years = debt > 0 ? (LIQ - debt) / (debt * 0.15) : Infinity;
  return (
    <div className="toy">
      <input type="range" min={0} max={MAX} step={5_001} value={debt} onChange={(e) => setDebt(+e.target.value)} aria-label="Borrowed $ESSEY" />
      <div className="ex-stats num">
        <span>debt: {debt.toLocaleString()} $ESSEY</span>
        <span>liquidation at {LIQ.toLocaleString()} (70% of the floor)</span>
      </div>
      <div className="bell-gauge" style={{ margin: "8px 0" }}><div className="bell-fill" style={{ width: `${(debt / LIQ) * 100}%` }} /></div>
      <div className="toy-note">Borrow <b className="num">up to {MAX.toLocaleString()} $ESSEY</b> — 50% of the floor —
        at <b>15% APR, simple interest</b>. The Don stays in your wallet, <b>still staked, still earning stock</b>;
        a lien just blocks selling, swapping, or redeeming it until the debt clears. Repay any amount, any time.
        {debt > 0 && <> At this debt, interest alone takes <b className="num">~{years.toFixed(1)} years</b> to reach
        the line — and that assumes the floor never rises, which it does every time anyone pays interest.</>}</div>
      <div className="toy-note"><b>Say it plainly: cross the line and the Don is gone.</b> Past 70% of the live
        floor, anyone can liquidate: the Don is redeemed at the floor to settle the debt, a 1% tip pays the caller,
        and the surplus comes back to you — but the Don is consumed, and <b>every unclaimed dividend in its Vault is
        forfeited with it</b>. Claim regularly, and service your loan.</div>
    </div>
  );
}

function DonMapToy() {
  // 1 cell ≈ 40 Dons; a representative map, not a live one (no indexer yet — labeled).
  const CELLS = 222;
  const lit = new Set<number>();
  for (let i = 0; i < CELLS; i++) { if ((i * 7919) % 100 < 69) lit.add(i); } // deterministic scatter
  return (
    <div className="toy">
      <div className="seat-map" aria-hidden>
        {Array.from({ length: CELLS }, (_, i) => <span key={i} className={lit.has(i) ? "lit" : ""} />)}
      </div>
      <div className="toy-note num">8,888 Dons · one cell ≈ 40 · <span className="lit-dot" /> held by members ·
        dim = the Exchange's inventory. 2,222 protocol-owned Dons seed the AMM as trading float — the scarcity
        dial, by design — and the team reserve is hard-capped on-chain at 2,722 total. The cap is immutable.</div>
    </div>
  );
}

function EsseyToy() {
  return (
    <div className="toy">
      <div className="sink-diagram num">
        <div className="sink-in">Mints · Trades · Tiers · Loans<span>fees in</span></div>
        <div className="sink-mid"><EMonogram size={34} /></div>
        <div className="sink-out">stock for staked Dons · the Floor<span>value out</span></div>
      </div>
      <div className="toy-note">You spend the volatile token to earn the stable asset — <b>rewards are never paid in
        $ESSEY</b>, so there's no emissions death-spiral to run from. Every fee ends in one of two places: stock for
        holders, or the floor under every Don. Activation fees burn 50% of themselves; <b>loan interest goes 100%
        into the reserve, raising every Don's floor</b>. No fee in the system leaks out of it.</div>
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
  { id: "don", icon: "⬡", name: "the Don", sub: "1 of 8,888", status: "audited",
    oneLiner: "A seat, a hard floor, and a margin account in one NFT. The dons have a seat at the table.", toy: DonMapToy },
  { id: "mint", icon: "◇", name: "the Mint", sub: "three ways in", status: "audited",
    oneLiner: "Free on the whitelist, ~$3 to reroll, ~$10 to build exact traits — 100% of fees buy stock.", toy: MintToy },
  { id: "vault", icon: "▣", name: "Vault", sub: "the Don's own wallet", status: "audited",
    oneLiner: "Every Don carries its own wallet. Sell the Don, and everything in it goes with it.", toy: VaultToy },
  { id: "floor", icon: "⏚", name: "the Floor", sub: "300,030 $ESSEY per Don", status: "audited",
    oneLiner: "Redemption is always open: cash any Don in for its full floor share. The floor only rises.", toy: FloorToy },
  { id: "tier", icon: "▲", name: "Tier", sub: "the 666 ladder", status: "audited",
    oneLiner: "Stake $ESSEY to take your seat: 66,666 → 1,666,666 buys ×1 → ×3.33 of every payout.", toy: TierToy },
  { id: "exchange", icon: "⇄", name: "the Exchange", sub: "the Don AMM", status: "audited",
    oneLiner: "Buy, snipe, or sell at the floor-pinned price — 70% of every fee buys stock for staked Dons.", toy: ExchangeToy },
  { id: "bell", icon: "🔔", name: "the Bell", sub: "the payout moment", status: "audited",
    oneLiner: "Every fee flows into one pot. When it fills, the Bell rings and every staked Don gets its cut.", toy: () => (
      <div className="toy"><div className="toy-note">The hero's centerpiece — scroll up and ring it. When the pot
        passes the threshold, a protocol keeper rings the Bell and the pot splits across all staked Dons, pro-rata
        by tier weight, in a single on-chain operation. <b>There's no ringer tip to race for — the whole pot goes to
        holders</b> — and anyone may ring it themselves once it's due. O(1) accumulator math, no admin.</div></div>) },
  { id: "payout", icon: "◆", name: "Payout", sub: "the fee-share (not a dividend)", status: "audited",
    oneLiner: "Paid in real stock: elect up to 3 tickers with your own split, or take the default BUNDLE.", toy: PayoutToy },
  { id: "borrow", icon: "⚖", name: "Borrow", sub: "the Don as collateral", status: "audited",
    oneLiner: "Borrow $ESSEY at 50% of the floor while the Don sits in your wallet — still staked, still earning.", toy: BorrowToy },
  { id: "essey", icon: "◈", name: "$ESSEY", sub: "the access token", status: "audited",
    oneLiner: "The chip you spend to get in. You never earn $ESSEY — you earn stock, and interest raises the floor.", toy: EsseyToy },
  { id: "tape", icon: "📈", name: "the Tape", sub: "the live proof feed", status: "audited",
    oneLiner: "Everything the Exchange does, printed live — and every line is a real receipt.", toy: TapeToy },
];

export function Mechanics() {
  const [open, setOpen] = useState<string | null>("don");
  return (
    <section className="band mechanics" id="market">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The Market</span>
          <h2>Every mechanic, playable before it costs anything</h2>
          <p>Tap a card to play with the mechanic in a no-wallet sandbox — the deployed numbers, no hand-waving —
            then do it for real on its own page. Each maps to a live, audited contract on Robinhood Chain testnet.</p>
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
                {/* render as an element (not an inline call) so each toy's hooks get their own
                    component scope — calling c.toy() inline inlined them into Mechanics and
                    crashed on expand (hook-count changes between which card is open). */}
                {isOpen && createElement(c.toy)}
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
            <p>The Payouts come from a lending engine whose solvency rule is machine-checked — every Don loan emits a
              solvency statement (debt ≤ 50% of floor) proven on-chain — and whose audit rounds are published clean
              or not. The books aren't a promise either.</p>
          </div>
        </div>
        <div className="twist-status">Status, honestly: the Market contracts (the Don, its Vault, the DonReserve
          floor, the Bell, the Exchange, the loan facility, the mint distributor, $ESSEY, the lending pool) are
          <b> adversarially audited across published rounds and live on Robinhood Chain testnet</b> — you can play
          the whole thing with play money right now, and every event links a real transaction. Not on mainnet
          yet. <a href={`${REPO}/tree/main/docs/audits`} target="_blank" rel="noreferrer">Read the audits ↗</a>
        </div>
      </div>
    </section>
  );
}
