// The Cases arcade — the CS:GO-grade opening experience for the fair-value "401(k) pack".
// Reference bar (founder): CS:GO crate reel physics + Rainbet case-page structure. Everything here is
// a SANDBOX (the contract is audited, not deployed): the draw is simulated client-side and labeled.
//
// Design law of the fair-value variant: every unit in a case is ~the same USD value, so RARITY IS
// SCARCITY OF THE NAME, never payout size. The color system ranks how rare a pull is; the value
// column stays flat on purpose — that flatness IS the product ("always ~fair value; the draw decides
// which stock"). No multipliers exist here, and the UI must never imply them.
import { useEffect, useMemo, useRef, useState } from "react";
import { EMonogram } from "./market";

const reducedMotion = () =>
  typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;

// ---------------------------------------------------------------- rarity system
// Five tiers keyed to pull odds (scarcity), styled on Essey ink+gold. Gold Leaf is the hallmark tier.
export type RarityKey = "ticker" | "bluechip" | "preferred" | "alpha" | "goldleaf";
export const RARITY: Record<RarityKey, { label: string; color: string; glow: string }> = {
  ticker: { label: "Ticker", color: "var(--r-ticker)", glow: "rgba(143,160,184,.36)" },
  bluechip: { label: "Blue Chip", color: "var(--r-bluechip)", glow: "rgba(79,142,247,.42)" },
  preferred: { label: "Preferred", color: "var(--r-preferred)", glow: "rgba(157,107,255,.44)" },
  alpha: { label: "Alpha", color: "var(--r-alpha)", glow: "rgba(242,92,122,.46)" },
  goldleaf: { label: "Gold Leaf", color: "var(--r-goldleaf)", glow: "rgba(231,197,122,.55)" },
};

type Item = { sym: string; name: string; unit: string; value: number; rarity: RarityKey; odds: number };
type CaseDef = { id: string; name: string; price: number; accent: RarityKey; items: Item[] };

// Sample lineups (labeled as such in the UI — live inventory feeds this at open). Odds sum to 100.
// Values hover at the case price — fair value, varying only by seeding drift.
const CASES: CaseDef[] = [
  {
    id: "k401", name: "The 401(k) Pack", price: 100, accent: "goldleaf",
    items: [
      { sym: "F", name: "Ford", unit: "9 shares", value: 99, rarity: "ticker", odds: 24 },
      { sym: "T", name: "AT&T", unit: "5 shares", value: 101, rarity: "ticker", odds: 20 },
      { sym: "PFE", name: "Pfizer", unit: "4 shares", value: 98, rarity: "ticker", odds: 16 },
      { sym: "KO", name: "Coca-Cola", unit: "1.6 shares", value: 100, rarity: "bluechip", odds: 12 },
      { sym: "DIS", name: "Disney", unit: "1.1 shares", value: 102, rarity: "bluechip", odds: 10 },
      { sym: "AAPL", name: "Apple", unit: "0.5 shares", value: 100, rarity: "preferred", odds: 8 },
      { sym: "MSFT", name: "Microsoft", unit: "0.25 shares", value: 103, rarity: "preferred", odds: 5 },
      { sym: "NVDA", name: "NVIDIA", unit: "0.8 shares", value: 101, rarity: "alpha", odds: 3 },
      { sym: "TSLA", name: "Tesla", unit: "0.4 shares", value: 99, rarity: "alpha", odds: 1.4 },
      { sym: "BRK.B", name: "Berkshire B", unit: "0.2 shares", value: 104, rarity: "goldleaf", odds: 0.6 },
    ],
  },
  {
    id: "bluechip", name: "Blue Chip Case", price: 250, accent: "bluechip",
    items: [
      { sym: "KO", name: "Coca-Cola", unit: "4 shares", value: 249, rarity: "ticker", odds: 26 },
      { sym: "JPM", name: "JPMorgan", unit: "1 share", value: 252, rarity: "ticker", odds: 20 },
      { sym: "DIS", name: "Disney", unit: "2.7 shares", value: 251, rarity: "bluechip", odds: 16 },
      { sym: "V", name: "Visa", unit: "0.9 shares", value: 250, rarity: "bluechip", odds: 13 },
      { sym: "AAPL", name: "Apple", unit: "1.25 shares", value: 250, rarity: "preferred", odds: 10 },
      { sym: "COST", name: "Costco", unit: "0.27 shares", value: 253, rarity: "preferred", odds: 7 },
      { sym: "MSFT", name: "Microsoft", unit: "0.6 shares", value: 248, rarity: "alpha", odds: 4.5 },
      { sym: "NVDA", name: "NVIDIA", unit: "2 shares", value: 252, rarity: "alpha", odds: 2.5 },
      { sym: "META", name: "Meta", unit: "0.35 shares", value: 251, rarity: "goldleaf", odds: 1 },
    ],
  },
  {
    id: "founders", name: "Founders Case", price: 1000, accent: "alpha",
    items: [
      { sym: "JPM", name: "JPMorgan", unit: "4 shares", value: 1008, rarity: "ticker", odds: 28 },
      { sym: "V", name: "Visa", unit: "3.6 shares", value: 1000, rarity: "bluechip", odds: 22 },
      { sym: "AAPL", name: "Apple", unit: "5 shares", value: 1000, rarity: "bluechip", odds: 16 },
      { sym: "COST", name: "Costco", unit: "1.1 shares", value: 1012, rarity: "preferred", odds: 12 },
      { sym: "MSFT", name: "Microsoft", unit: "2.4 shares", value: 992, rarity: "preferred", odds: 9 },
      { sym: "NVDA", name: "NVIDIA", unit: "8 shares", value: 1008, rarity: "alpha", odds: 6 },
      { sym: "META", name: "Meta", unit: "1.4 shares", value: 1004, rarity: "alpha", odds: 4 },
      { sym: "TSLA", name: "Tesla", unit: "4 shares", value: 990, rarity: "goldleaf", odds: 2 },
      { sym: "BRK.B", name: "Berkshire B", unit: "2 shares", value: 1040, rarity: "goldleaf", odds: 1 },
    ],
  },
];

const usd = (n: number) => "$" + n.toLocaleString();

function weightedDraw(items: Item[]): Item {
  let r = Math.random() * items.reduce((a, i) => a + i.odds, 0);
  for (const it of items) { r -= it.odds; if (r <= 0) return it; }
  return items[items.length - 1];
}

// ---------------------------------------------------------------- item card (reel + grids)
function ItemCard({ it, size = "reel" }: { it: Item; size?: "reel" | "grid" }) {
  const r = RARITY[it.rarity];
  return (
    <div className={`cs-card cs-${size}`} style={{ "--rar": r.color, "--rarGlow": r.glow } as React.CSSProperties}>
      <div className="cs-card-sym num">{it.sym}</div>
      <div className="cs-card-name">{it.name}</div>
      <div className="cs-card-unit num">{it.unit}</div>
      <div className="cs-card-val num">{usd(it.value)}</div>
      <div className="cs-card-rail" />
    </div>
  );
}

// ---------------------------------------------------------------- the case (CSS art)
function CaseBox({ c, active, onPick }: { c: CaseDef; active: boolean; onPick: () => void }) {
  const r = RARITY[c.accent];
  return (
    <button className={"case-box" + (active ? " on" : "")} onClick={onPick}
      style={{ "--rar": r.color, "--rarGlow": r.glow } as React.CSSProperties}>
      <span className="case-lid" />
      <span className="case-face">
        <EMonogram size={44} />
        <b>{c.name}</b>
        <i className="num">{usd(c.price)} · in $ESSEY</i>
      </span>
      <span className="case-base" />
    </button>
  );
}

// ---------------------------------------------------------------- the arcade
type Phase = "idle" | "spinning" | "revealed";
const CARD_W = 132; // card width + gap, must match CSS
const WIN = 46; // winner index in the reel strip

export function CasesArcade() {
  const [caseIdx, setCaseIdx] = useState(0);
  const [phase, setPhase] = useState<Phase>("idle");
  const [strip, setStrip] = useState<Item[]>([]);
  const [won, setWon] = useState<Item | null>(null);
  const [pulls, setPulls] = useState<Item[]>([]);
  const [sold, setSold] = useState(false);
  const railRef = useRef<HTMLDivElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const gen = useRef(0);
  const c = CASES[caseIdx];

  const byOdds = useMemo(() => [...c.items].sort((a, b) => b.odds - a.odds), [c]);

  const pickCase = (i: number) => {
    if (phase === "spinning") return;
    setCaseIdx(i); setPhase("idle"); setWon(null); setSold(false);
  };

  const spin = () => {
    if (phase === "spinning") return;
    const winner = weightedDraw(c.items);
    const cards: Item[] = Array.from({ length: 54 }, () => weightedDraw(c.items));
    cards[WIN] = winner;
    // The classic near-miss: sometimes a gold-leaf gleams one slot past where you stop.
    if (winner.rarity !== "goldleaf" && Math.random() < 0.35) {
      const gold = c.items.filter((i) => i.rarity === "goldleaf" || i.rarity === "alpha");
      if (gold.length) cards[WIN + 1] = gold[Math.floor(Math.random() * gold.length)];
    }
    setStrip(cards); setWon(winner); setSold(false); setPhase("spinning");
  };

  // The animation must start AFTER the spinning phase has rendered the rail — reading railRef in
  // spin() itself races React's commit and silently skips the whole reel (found in self-audit: the
  // ref was always null in that tick, so every open jumped straight to the reveal).
  useEffect(() => {
    if (phase !== "spinning" || !won) return;
    const finish = () => { setPhase("revealed"); setPulls((p) => [won, ...p].slice(0, 8)); };
    const g = ++gen.current;
    const rail = railRef.current, stage = stageRef.current;
    if (!rail || !stage || reducedMotion()) { finish(); return; } // reduced motion: no reel
    const stageW = stage.clientWidth;
    // Land the marker inside the winner card, deliberately off-center (CS:GO realism), never on the edge.
    const jitter = (Math.random() - 0.5) * (CARD_W * 0.55);
    const finalX = WIN * CARD_W + CARD_W / 2 + jitter - stageW / 2;
    const D = 6400; // ms — long enough to build tension, short enough to not bore
    const t0 = performance.now();
    rail.style.transform = "translateX(0px)";
    const step = (t: number) => {
      if (g !== gen.current) return;
      const k = Math.min(1, (t - t0) / D);
      const eased = 1 - Math.pow(1 - k, 5); // quintic ease-out: fast blur -> aching crawl
      rail.style.transform = `translateX(${(-finalX * eased).toFixed(2)}px)`;
      if (k < 1) { requestAnimationFrame(step); return; }
      finish();
    };
    requestAnimationFrame(step);
    // Watchdog: rAF is throttled to zero in hidden/occluded tabs, which would strand the spin
    // forever. If the reel hasn't finished shortly after its duration, resolve it — a user who tabs
    // away mid-spin gets their reveal the moment they're back.
    const dog = setTimeout(() => { if (g === gen.current) { gen.current++; finish(); } }, D + 600);
    return () => { gen.current++; clearTimeout(dog); }; // orphan the loop if we unmount mid-spin
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase]);

  const again = () => { setPhase("idle"); setWon(null); setSold(false); };
  const rWon = won ? RARITY[won.rarity] : null;

  return (
    <section className="band cases-arcade" id="cases">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">Cases</span>
          <h2>Open a Case. Get real stock.</h2>
          <p>Every pull lands ~the case's value in real stock — <b>the draw only ever decides which name</b>,
            never how much. Rarity is scarcity, not size: chasing the gold leaf costs you nothing but the
            spin. Keep it, borrow against it, or sell it back at a 5% spread.</p>
        </div>
          <span className="preview-chip" title="The Case contract is audited but not deployed; this arcade simulates the draw client-side.">sandbox — simulated draw</span>
        </div>

        {/* case picker */}
        <div className="case-row">
          {CASES.map((cd, i) => <CaseBox key={cd.id} c={cd} active={i === caseIdx} onPick={() => pickCase(i)} />)}
        </div>

        {/* spin stage */}
        <div className="spin-shell">
          {phase !== "revealed" && (
            <div className="spin-stage" ref={stageRef} aria-label="case opening reel">
              {phase === "idle" ? (
                <div className="spin-idle">
                  <EMonogram size={40} />
                  <p>{c.name} · {usd(c.price)} in $ESSEY</p>
                  <button className="btn btn-gold spin-cta" onClick={spin}>OPEN {c.name.toUpperCase()}</button>
                  <i>simulated — no wallet, no cost</i>
                </div>
              ) : (
                <>
                  <div className="spin-marker" />
                  <div className="spin-rail" ref={railRef}>
                    {strip.map((it, i) => <ItemCard key={i} it={it} />)}
                  </div>
                  <div className="spin-fade left" /><div className="spin-fade right" />
                </>
              )}
            </div>
          )}

          {/* reveal */}
          {phase === "revealed" && won && rWon && (
            <div className="reveal" style={{ "--rar": rWon.color, "--rarGlow": rWon.glow } as React.CSSProperties}>
              <div className="reveal-card">
                <span className="reveal-rarity" style={{ color: rWon.color }}>{rWon.label}</span>
                <div className="reveal-sym num">{won.sym}</div>
                <div className="reveal-name">{won.name}</div>
                <div className="reveal-unit num">{won.unit} · {usd(won.value)}</div>
                <div className="reveal-stamp"><EMonogram size={34} /><span>draw fair ✓ · sealed to your wallet</span></div>
              </div>
              <div className="reveal-actions">
                {sold
                  ? <div className="reveal-sold num">sold back · {usd(Math.round(won.value * 0.95))} · 5% spread → the Bell</div>
                  : <>
                    <button className="btn btn-gold" onClick={again}>Keep it · open another</button>
                    <button className="btn btn-ghost" onClick={() => setSold(true)}>Sell back · {usd(Math.round(won.value * 0.95))}</button>
                  </>}
                {sold && <button className="linklike" onClick={again}>open another →</button>}
              </div>
              <div className="reveal-verify num">draw = keccak(blockhash(commit), caseId) % inventory · at launch this line is a real tx ↗</div>
            </div>
          )}
        </div>

        {/* contents + odds */}
        <div className="case-contents">
          <div className="cc-head">
            <span>What's inside {c.name}</span>
            <span className="cc-note">sample lineup · live inventory (and exact odds) are on-chain at launch</span>
          </div>
          <div className="cc-grid">
            {byOdds.map((it) => (
              <div className="cc-row" key={it.sym} style={{ "--rar": RARITY[it.rarity].color } as React.CSSProperties}>
                <ItemCard it={it} size="grid" />
                <div className="cc-odds num">{it.odds}%</div>
              </div>
            ))}
          </div>
          <div className="cc-legend">
            {(Object.keys(RARITY) as RarityKey[]).map((k) => (
              <span key={k} className="cc-key" style={{ "--rar": RARITY[k].color } as React.CSSProperties}>{RARITY[k].label}</span>
            ))}
            <span className="cc-legend-note">rarity = how rare the name is to pull — every tier is ~equal value</span>
          </div>
        </div>

        {/* recent pulls (this session's sandbox pulls) */}
        {pulls.length > 0 && (
          <div className="recent-pulls">
            <span className="rp-h">YOUR PULLS</span>
            {pulls.map((it, i) => (
              <span key={i} className="rp-chip num" style={{ "--rar": RARITY[it.rarity].color } as React.CSSProperties}>{it.sym}</span>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}
