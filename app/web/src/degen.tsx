// The Degen Case — a provably-fair + provably-solvent MULTIPLIER gacha. Roll 0.65x-50x; odds are
// on-chain and disclosed; the 50x "Gold Bell" is provably reserved before you open. A reel spins to
// the rolled multiplier; a jackpot gets a full-screen Gold-Bell burst. Winnings are pull-based (claim).
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import type { Address } from "viem";
import { EMonogram } from "./market";
import { useWallet, ConnectButton } from "./wallet";
import { ADDR, PRICE, reads, flows, fmt, niceError } from "./live";

const ZERO = "0x0000000000000000000000000000000000000000";
const DEGEN_LIVE = ADDR.degenCases.toLowerCase() !== ZERO;

const reducedMotion = () =>
  typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;

// Color + label for a multiplier (bps of 1x: 6500 = 0.65x, 500000 = 50x).
function mstyle(bps: number): { color: string; glow: string; label: string; jackpot: boolean } {
  const x = bps / 10000;
  const label = (Number.isInteger(x) ? x.toString() : x.toFixed(2)) + "×";
  if (bps >= 500000) return { color: "var(--r-goldleaf)", glow: "rgba(231,197,122,.6)", label: "50×", jackpot: true };
  if (bps >= 50000) return { color: "var(--r-alpha)", glow: "rgba(242,92,122,.5)", label, jackpot: false };
  if (bps >= 20000) return { color: "var(--r-preferred)", glow: "rgba(157,107,255,.5)", label, jackpot: false };
  if (bps >= 10000) return { color: "var(--r-bluechip)", glow: "rgba(79,142,247,.46)", label, jackpot: false };
  return { color: "var(--r-ticker)", glow: "rgba(143,160,184,.4)", label, jackpot: false };
}

type Ladder = { multBps: number; pct: number }[];
type Account = { ladder: Ladder; maxMultBps: number; free: bigint; reserved: bigint; fee: bigint; owed: bigint };
type Phase = "idle" | "spinning" | "revealed";

const CHIP_W = 132; // .cs-card width (120) + .spin-rail gap (12)
const WIN = 40; // winner index in the strip

export function DegenCase({ embedded }: { embedded?: boolean } = {}) {
  const w = useWallet();
  const a = w.address as Address | null;
  const ready = !!a && w.chainOk;
  const [acct, setAcct] = useState<Account | null>(null);
  const [phase, setPhase] = useState<Phase>("idle");
  const [strip, setStrip] = useState<number[]>([]);
  const [won, setWon] = useState<number | null>(null); // multBps
  const [payout, setPayout] = useState<bigint>(0n);
  const [stage, setStage] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const railRef = useRef<HTMLDivElement>(null);
  const gen = useRef(0);
  const offsetRef = useRef(0); // current translateX magnitude (px shifted left), shared across the two spin phases

  useEffect(() => { document.title = "Degen Case · Essey"; }, []);
  const load = useCallback(() => {
    if (!DEGEN_LIVE) return;
    reads.degen(a).then(setAcct).catch(() => {});
  }, [a]);
  useEffect(() => { load(); const t = setInterval(load, 20_000); return () => clearInterval(t); }, [load]);

  // A weighted-by-odds pool of multipliers for the reel's decorative fill.
  const pool = useMemo(() => {
    if (!acct) return [6500];
    const out: number[] = [];
    acct.ladder.forEach((t) => { for (let i = 0; i < Math.max(1, Math.round(t.pct)); i++) out.push(t.multBps); });
    return out.length ? out : [6500];
  }, [acct]);
  const drawFill = () => pool[Math.floor(Math.random() * pool.length)];

  const rtp = useMemo(() => {
    if (!acct) return 0;
    return acct.ladder.reduce((s, t) => s + (t.multBps / 10000) * (t.pct / 100), 0) * 100;
  }, [acct]);

  const open = async () => {
    if (!a || !acct || busy) return;
    setBusy(true); setMsg(null); setStage("buying"); setWon(null);
    const winnerSeed = drawFill();
    const s = Array.from({ length: 54 }, drawFill);
    s[WIN] = winnerSeed; // corrected to the real roll on reveal
    setStrip(s); setPhase("spinning");
    try {
      const { multBps, payoutShares } = await flows.degenOpen(a, setStage);
      // land the reel on the true rolled multiplier
      setStrip((prev) => { const c = [...prev]; c[WIN] = multBps; return c; });
      setWon(multBps); setPayout(payoutShares); setStage(null);
    } catch (e) {
      setMsg(niceError(e)); setPhase("idle"); setStage(null); setBusy(false); return;
    }
  };

  const period = strip.length * CHIP_W; // width of one strip copy (rail renders two copies for a seamless loop)

  // Phase 1 — free spin: a constant-velocity blur that runs the instant we start buying, so the reel is
  // visibly spinning while the buy + settle transactions confirm (not frozen waiting on the chain).
  useEffect(() => {
    if (phase !== "spinning" || won !== null) return;
    const rail = railRef.current;
    if (!rail || reducedMotion() || period === 0) return;
    const g = ++gen.current;
    const V = 2600; // px/s
    const t0 = performance.now();
    const step = (t: number) => {
      if (g !== gen.current) return;
      offsetRef.current = (V * (t - t0)) / 1000 % period;
      rail.style.transform = `translateX(${(-offsetRef.current).toFixed(2)}px)`;
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
    return () => { gen.current++; };
  }, [phase, won, period]);

  // Phase 2 — settle: once the true multiplier is known, decelerate from wherever the free spin is to
  // land the winner (index WIN, one loop forward so it always travels) under the marker.
  useEffect(() => {
    if (phase !== "spinning" || won === null) return;
    const finish = () => { setPhase("revealed"); setBusy(false); load(); };
    const g = ++gen.current;
    const rail = railRef.current;
    if (!rail || reducedMotion() || period === 0) { finish(); return; }
    const stageW = rail.parentElement?.clientWidth ?? 600;
    const jitter = (Math.random() - 0.5) * (CHIP_W * 0.4);
    const start = offsetRef.current % period; // snap into the first copy (invisible mid-blur)
    rail.style.transform = `translateX(${(-start).toFixed(2)}px)`;
    const target = WIN * CHIP_W + CHIP_W / 2 + jitter - stageW / 2 + period; // winner in the second copy → forward
    const D = 2600, t0 = performance.now();
    const step = (t: number) => {
      if (g !== gen.current) return;
      const k = Math.min(1, (t - t0) / D);
      const eased = 1 - Math.pow(1 - k, 4);
      offsetRef.current = start + (target - start) * eased;
      rail.style.transform = `translateX(${(-offsetRef.current).toFixed(2)}px)`;
      if (k < 1) { requestAnimationFrame(step); return; }
      finish();
    };
    requestAnimationFrame(step);
    const dog = setTimeout(() => { if (g === gen.current) { gen.current++; finish(); } }, D + 700);
    return () => { gen.current++; clearTimeout(dog); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase, won, period]);

  const claim = async () => {
    if (!a) return;
    setBusy(true); setMsg(null);
    try { await flows.degenWithdraw(a); setMsg("✓ winnings withdrawn to your wallet"); load(); }
    catch (e) { setMsg(niceError(e)); }
    finally { setBusy(false); }
  };

  const again = () => { setPhase("idle"); setWon(null); setStage(null); };
  const rWon = won !== null ? mstyle(won) : null;
  const stageLabel: Record<string, string> = { approving: "approving $ESSEY + USDG…", buying: "buying the case…", sealing: "sealing the roll on-chain…" };

  // Gold-Bell unlock: the 50x tier is only offered when the reserve can back one worst-case payout.
  const unlockPct = acct && acct.reserved + acct.free > 0n
    ? Math.min(100, Number((acct.free * 100n) / (acct.reserved + acct.free + 1n)))
    : 0;

  return (
    <section className="band cases-arcade" id="degen" style={{ paddingTop: embedded ? 0 : 34 }}>
      <div className="wrap">
        {!embedded && (
        <div className="band-head"><div>
          <span className="eyebrow">Degen Case</span>
          <h2>Roll the multiplier. Up to 50×.</h2>
          <p>A <b>provably-fair and provably-solvent</b> multiplier gacha — the odds are on-chain and
            disclosed, and the 50× <b>Gold Bell</b> is reserved in real stock <b>before</b> you open.
            Same rush as anyone's box; the only one you can actually verify.</p>
        </div>
          {DEGEN_LIVE
            ? <span className="preview-chip live" title="Live on Robinhood Chain testnet — a real on-chain roll with play money.">LIVE · testnet</span>
            : <span className="preview-chip">deploys soon</span>}
        </div>
        )}

        {!DEGEN_LIVE ? (
          <div className="live-card"><div className="live-note">The degen case goes live at its deploy — the reveal, the odds, and the reserve meter light up here. Meanwhile the fair-value <Link to="/cases">Cases</Link> are live.</div></div>
        ) : (
          <>
            {/* spin stage */}
            <div className="spin-shell">
              {phase !== "revealed" && (
                <div className="spin-stage" aria-label="multiplier reel">
                  {phase === "idle" ? (
                    <div className="spin-idle">
                      <EMonogram size={40} />
                      <p>{acct ? `${fmt(PRICE.casePrice)} $ESSEY per roll · ~${rtp.toFixed(0)}% avg payback · ${fmt(acct.free, 0)} AAPL in the prize vault` : "…"}</p>
                      {ready ? (
                        <>
                          <button className="btn btn-gold spin-cta" disabled={busy} onClick={open}>
                            {busy ? "opening…" : `OPEN A CASE · ${fmt(PRICE.casePrice)} $ESSEY`}
                          </button>
                          <i>a real on-chain roll · costs {fmt(PRICE.casePrice)} $ESSEY + a tiny gas fee in ETH</i>
                        </>
                      ) : (
                        <><span className="live-note">Connect on Robinhood Chain testnet to roll.</span><ConnectButton /></>
                      )}
                    </div>
                  ) : (
                    <>
                      <div className="spin-marker" />
                      <div className="spin-rail" ref={railRef}>
                        {[...strip, ...strip].map((m, i) => {
                          const s = mstyle(m);
                          return (
                            <div key={i} className="cs-card cs-reel dg-chip" style={{ "--rar": s.color, "--rarGlow": s.glow } as React.CSSProperties}>
                              <div className="dg-mult num">{s.label}</div>
                            </div>
                          );
                        })}
                      </div>
                      <div className="spin-fade left" /><div className="spin-fade right" />
                      {stage && <div className="spin-stage-label num">{stageLabel[stage] ?? stage}</div>}
                    </>
                  )}
                </div>
              )}

              {phase === "revealed" && won !== null && rWon && (
                <div className={"reveal" + (rWon.jackpot ? " dg-jackpot" : "")} style={{ "--rar": rWon.color, "--rarGlow": rWon.glow } as React.CSSProperties}>
                  <div className="reveal-card">
                    {rWon.jackpot && <div className="dg-bell">🔔</div>}
                    <span className="reveal-rarity" style={{ color: rWon.color }}>{rWon.jackpot ? "GOLD BELL" : won >= 20000 ? "GREEN" : won >= 10000 ? "EVEN" : "ROLL"}</span>
                    <div className="reveal-sym num dg-big" style={{ color: rWon.color }}>{rWon.label}</div>
                    <div className="reveal-unit num">won <b>{fmt(payout, 3)} AAPL</b></div>
                    <div className="reveal-stamp"><EMonogram size={30} /><span>roll verifiable ✓ · backed before you opened</span></div>
                  </div>
                  <div className="reveal-actions">
                    <button className="btn btn-gold" disabled={busy} onClick={open}>Roll again</button>
                    {acct && acct.owed > 0n && <button className="btn btn-ghost" disabled={busy} onClick={claim}>{busy ? "…" : `Withdraw ${fmt(acct.owed, 3)} AAPL`}</button>}
                    <button className="linklike" onClick={again}>done</button>
                  </div>
                </div>
              )}
            </div>
            {msg && <div className="live-msg" style={{ marginTop: 10 }}>{msg}</div>}

            {/* owed banner (outside a roll) */}
            {phase !== "revealed" && acct && acct.owed > 0n && (
              <div className="live-card" style={{ marginTop: 14 }}>
                <div className="live-row"><span className="live-note">You have <b>{fmt(acct.owed, 3)} AAPL</b> in winnings to collect.</span>
                  <button className="btn btn-gold" disabled={busy} onClick={claim}>Withdraw</button></div>
              </div>
            )}

            {/* reserve-unlock meter */}
            <div className="live-card" style={{ marginTop: 14 }}>
              <div className="live-h">GOLD BELL — PROVABLY BACKED <span className="preview-chip live">solvent</span></div>
              <div className="quest-bar" style={{ marginTop: 8 }}><div className="quest-bar-fill" style={{ width: `${unlockPct}%` }} /></div>
              <div className="live-note num" style={{ marginTop: 6 }}>
                {acct ? <>free reserve <b>{fmt(acct.free, 0)}</b> shares · reserved for open rolls <b>{fmt(acct.reserved, 0)}</b> · the 50× is only offered while the vault can cover it — verifiably.</> : "…"}
              </div>
            </div>

            {/* on-chain odds */}
            {acct && (
              <div className="case-contents">
                <div className="cc-head"><span>The odds (on-chain)</span><span className="cc-note">RTP {rtp.toFixed(1)}% · disclosed, not marketed</span></div>
                <div className="dg-ladder">
                  {[...acct.ladder].sort((x, y) => y.multBps - x.multBps).map((t) => {
                    const s = mstyle(t.multBps);
                    return (
                      <div key={t.multBps} className="dg-row" style={{ "--rar": s.color } as React.CSSProperties}>
                        <span className="dg-row-mult num" style={{ color: s.color }}>{s.label}</span>
                        <span className="dg-row-bar"><span style={{ width: `${Math.min(100, t.pct)}%`, background: s.color }} /></span>
                        <span className="dg-row-pct num">{t.pct < 1 ? t.pct.toFixed(2) : t.pct.toFixed(1)}%</span>
                      </div>
                    );
                  })}
                </div>
              </div>
            )}

            <div className="quest-fine">
              Provably fair: the roll is a Keccak256-verifiable commit-reveal (Dice Protocol) mapped onto the odds above — anyone
              can recompute it. Provably solvent: every open reserves its worst-case (50×) payout in real stock first. Rolls settle
              during US market hours (the reserve is priced then). Winnings are pull-based — withdraw when you like. Testnet, play money.
            </div>
          </>
        )}
      </div>
    </section>
  );
}
