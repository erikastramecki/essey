// The marketing surface — the game-first face of Essey. D.O.N. (the game) is the consumer skin;
// the provable RWA rails underneath are the foundation and live in the technical docs.
// Guardrail: no section may claim more than the contracts deliver. Honesty rule, verbatim: this
// season settles in Scrip (play points) marked to tickers; real-token settlement is the roadmap —
// never imply testers receive real stock now.
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";

const REPO = "https://github.com/erikastramecki/essey";

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

// ---------------------------------------------------------------- theme toggle
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

// ---------------------------------------------------------------- first-visit warning
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
    <div className="warn-modal" role="dialog" aria-modal="true" aria-label="Before you step into Solvency">
      <div className="warn-box">
        <div className="warn-mark"><EMonogram size={54} stamped={false} /></div>
        <h2>Before you step into Solvency</h2>
        <p className="warn-lede"><b>Essey is experimental software.</b> It's early, and it's built in the open, including
          the audits that made us look bad. Read this before you connect a wallet.</p>
        <ul className="warn-list">
          <li><b>Testnet, play money. You can't lose real money here.</b> The game runs on Robinhood Chain
            <b> testnet</b> with real contracts and real mechanics, but its tokens have <b>no real value</b>. The
            base layer — the $ESSEY token and its on-chain floor reserve — is live on Robinhood Chain
            <b> mainnet</b>; this game season is not. So explore freely. Then, the honest rest:</li>
          <li><b>This season settles in Scrip</b> — play points marked to real tickers. Real-token settlement is
            the roadmap, not this season: nothing you win in the game right now is real stock, and no one should
            tell you otherwise, including us.</li>
          <li><b>Nothing here is financial advice.</b> Not from us, not from the app, not from anyone.</li>
          <li><b>Every roll's odds are published on-chain before you pay</b>, and the house keeps an edge: across the
            city, roughly 10 of every 100 Scrip staked on a gamble stays with the house. Play because it's a good
            table, not to beat the math. You can't.</li>
          <li><b>Banked is sacred.</b> Nothing in the game — no mechanic, no robbery, no admin — can touch your
            Vault. What can be lost is exactly what you chose to expose: deployed Scrip, the hopper, provisions,
            and fees.</li>
          <li><b>Exits are free, forever.</b> Banking, claiming, withdrawing: no fee, no delay, no future knob.</li>
          <li><b>The assets are volatile.</b> $ESSEY is a pure access token; its price can go to zero. Tokenized
            stocks move with their markets and carry oracle and issuer risk.</li>
          <li><b>Provable ≠ risk-free.</b> We prove what we can prove (a published odds ladder, a solvent book)
            and hand you the button to check. Ordinary software has ordinary bugs. Proof removes one
            <em> class</em> of risk, not all of it.</li>
          <li><b>Your jurisdiction is your responsibility.</b> Some features are restricted in some places for good
            reason.</li>
        </ul>
        <button className="btn btn-gold warn-accept" onClick={accept}>I understand. Let me in</button>
        <Link className="warn-docs" to="/how-to-play" onClick={accept}>Or read how to play, start to finish →</Link>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- the hero: D.O.N.
// Left: the claim. Right: a sample of the Tape wearing the game's flavor — explicitly labeled a
// sample; no fake "live" state, per the design doc's honesty rule.
const SAMPLE_TAPE: [string, string, string][] = [
  ["▸", "DON №1204 DEPARTED · PAPER ROUTE · 3h window · House stands open", "tape"],
  ["✓", "JOB RESOLVED · clean · ◫ 36 Scrip to the hopper", "verify"],
  ["✉", "HIT ORDER FILED · target sealed · reveal in 10–40 min", "commit"],
  ["🔒", "BANKED · hopper → Vault · free, forever", "sacred"],
];

export function GameHero() {
  return (
    <section className="hero mkt-hero">
      <div className="wrap hero-grid">
        <div>
          <span className="eyebrow">D.O.N. · Developing On-chain Nation</span>
          <h1>Welcome to Solvency.<br /><em>Nothing bleeds but a balance sheet.</em></h1>
          <p className="lede">A city of <b className="num">8,888</b> founding families. Send your Don on timed
            jobs with the odds published on-chain, build up the House, mint a crew, and rob the neglectful —
            while everything you bank stays untouchable, forever. Season Zero is live on testnet: same rules,
            same odds, zero real stakes.</p>
          <div className="hero-cta">
            <Link className="btn btn-gold" to="/game">Enter Solvency</Link>
            <Link className="btn btn-ghost" to="/how-to-play">How to play</Link>
          </div>
          <div className="proof-strip num">♠ this season settles in <b>Scrip</b>, play points marked to real
            tickers · real-token settlement is the roadmap · <Link to="/faucet">get testnet funds →</Link></div>
        </div>
        <aside className="bell-plate">
          <div className="bell-head">
            <span className="bell-title">SEASON 0 · THE SKIRMISH</span>
            <span className="preview-chip" title="A sample of the Tape. The live one runs on the Tape page.">sample</span>
          </div>
          <div className="bell-pot">
            <span className="bell-emoji" aria-hidden>♠</span>
            <div className="bell-nums">
              <div className="bell-amt num">SEASON OF THE FIRST BELL</div>
              <div className="bell-sub">four briefs on the board · doors already getting kicked</div>
            </div>
          </div>
          <div className="tape-peek">
            <div className="tape-peek-h">THE TAPE <span className="preview-chip">sample</span></div>
            {SAMPLE_TAPE.map(([icon, text, tag], i) => (
              <div className="tape-row" key={i}>
                <span className="tr-icon">{icon}</span>
                <span className="tr-text num">{text}</span>
                <span className="tr-tag">{tag}</span>
              </div>
            ))}
            <div className="tape-note">sample rows. in the game, every line is a real tx you can verify</div>
          </div>
        </aside>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------- the loop, in four beats
export function GameLoop() {
  const BEATS: [string, string, string][] = [
    ["01", "Get a Don", "One of 8,888 founding families. Your Don is your character, your seat, and his own on-chain wallet in one — claim free on the whitelist, or build him trait by trait."],
    ["02", "Work a job", "Open a dossier, read the odds (the folder IS the disclosure), press the wax seal, and your Don departs. Longer jobs pay more — and leave your House standing open longer."],
    ["03", "Come home, bank it", "Pay lands in the House hopper. Banking it to the Vault is free, forever — and banked money is sacred: no mechanic, no robbery, no admin can touch it."],
    ["04", "Do the other thing", "Depart lines print on the Tape, so everyone knows whose House stands open. Mint a Hitter, file a sealed hit order, and rob the negligent. Or garrison up and be nobody's mark."],
  ];
  return (
    <section className="band club" id="loop">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The loop</span>
          <h2>Deploy · work · come home · bank</h2>
          <p>Exposure is always a choice. Money in the Vault earns nothing and can never be taken; money you
            deploy earns daily and can be robbed only while your Don is away. That choice is the whole game.</p>
        </div></div>
        <div className="flow">
          {BEATS.map(([no, h, p]) => (
            <div className="step" key={no}>
              <span className="no">{no}</span>
              <h3>{h}</h3><p>{p}</p>
            </div>
          ))}
        </div>
        <div className="learn-row" style={{ marginTop: 18 }}>
          <b>On the roadmap, honestly:</b> when the take goes real, the district you work pays its own asset —
          chip jobs pay the chip company, Ledger Row pays T-bills, the Refinery oil, the Mint silver — and you
          <em> win</em> it by playing, into a claim box no raid can touch. No dates, and nothing real this season.
        </div>
        <div className="learn-row" style={{ marginTop: 10 }}>
          The full walkthrough, with every number from the chain: <Link to="/how-to-play">How to play →</Link>
        </div>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------- the engine underneath
// The rails, compressed to their role in THIS narrative: the game is the consumer skin; a lending
// protocol for tokenized stocks is the foundation. The full specs live in the technical docs.
export function EngineSection() {
  const CARDS: [string, string][] = [
    ["Conservative by construction", "Collateral is priced by session-gated Chainlink feeds with fail-closed discipline: a stale feed, a holiday gap, or an off-hours equity price refuses rather than guesses. Nothing settles on an unverifiable price."],
    ["Positions are Notes", "Every loan is a bearer NFT: debt, collateral, and its solvency state travel together, sellable as one object. The engine's interest is a designed fee stream into the protocol's pot."],
    ["Audited in the open", "Every adversarial audit round is published, clean or not, including the ones that found real bugs the day before they'd have shipped. The audit trail is the product."],
  ];
  return (
    <section className="band engine" id="engine">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The engine underneath</span>
          <h2>The rails the game runs on</h2>
          <p>The game is the consumer skin. Underneath sits a lending protocol for tokenized stocks on
            Robinhood Chain — real assets, real oracles, real audits. That's why the roadmap can point at
            real-token settlement at all.</p>
        </div></div>
        <div className="flow">
          {CARDS.map(([h, p]) => (
            <div className="step" key={h}><h3>{h}</h3><p>{p}</p></div>
          ))}
        </div>
        <div className="twist-status" style={{ marginTop: 16 }}>Built and fork-tested against real Robinhood
          Chain state and live on Robinhood Chain testnet. The full specs (oracle discipline, risk framework, rate
          model, and everything still open) are in the technical docs, rendered from the repo's own files.</div>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------- the provable twist
export function ProvableTwist() {
  return (
    <section className="band twist" id="provable">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The part they can't copy</span>
          <h2>Provably fair <em>and</em> provably solvent</h2>
          <p>Plenty of games can prove a roll was fair. Only a game built on a real lending protocol can prove
            the books behind it are solvent, because ours publishes the proof either way.</p>
        </div></div>
        <div className="twist-grid">
          <div className="twist-card">
            <div className="twist-h">⬡ Provably fair</div>
            <p>Every odds ladder in the game is published on-chain before you pay, and never changes mid-season.
              Every roll commits its entropy before it resolves. The odds aren't a promise; they're arithmetic.</p>
          </div>
          <div className="twist-card">
            <div className="twist-h">⬡ Provably solvent</div>
            <p>The rails underneath are a lending engine whose solvency rule is machine-checked: every loan emits a
              solvency statement proven on-chain, and its audit rounds are published clean
              or not. The books aren't a promise either.</p>
          </div>
        </div>
        <div className="twist-status">Status, honestly: the contracts are <b>adversarially audited across
          published rounds and live on Robinhood Chain testnet</b>. You can play the whole thing with play money
          right now, and every event links a real transaction. The game season runs on testnet; the base
          layer — the $ESSEY token and its on-chain floor reserve — is live on Robinhood Chain
          mainnet. <a href={`${REPO}/tree/main/docs/audits`} target="_blank" rel="noreferrer">Read the audits ↗</a>
        </div>
      </div>
    </section>
  );
}
