// The guided tester journey. A new visitor should never wonder "where do I test staking?" — this
// is the map: numbered steps that auto-check from live chain state, each pointing at the one page
// where that flow lives. Shared by the Start page and a compact progress strip on the app pages.
import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Address } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { reads, flows, fmt, NET, type Portfolio } from "./live";

export type StepId = "connect" | "fund" | "seat" | "stake" | "payout" | "case";

export type Step = {
  id: StepId;
  n: number;
  title: string;
  what: string; // one line: what you're testing
  to: string; // where you do it
  cta: string;
  done: (p: Portfolio | null, connected: boolean) => boolean;
};

export const STEPS: Step[] = [
  { id: "connect", n: 1, title: "Connect", what: "Connect a wallet on Robinhood Chain testnet.", to: "/start", cta: "Connect",
    done: (_p, c) => c },
  { id: "fund", n: 2, title: "Get play money", what: "Grab testnet gas, then 5,000 $ESSEY + 1,000 USDG from the faucet.", to: "/start", cta: "Open the faucet",
    done: (p) => !!p && p.essey > 0n && p.usdg > 0n },
  { id: "seat", n: 3, title: "Buy a Seat", what: "Trade $ESSEY for a Seat on the Exchange — the fee feeds the Bell's pot.", to: "/market", cta: "Go to the Market",
    done: (p) => !!p && p.seats.length > 0 },
  { id: "stake", n: 4, title: "Stake a Tier", what: "Stake $ESSEY on your Seat to earn a bigger slice of every Payout.", to: "/bell", cta: "Go to Stake",
    done: (p) => !!p && p.seats.some((s) => s.tier > 0) },
  { id: "payout", n: 5, title: "Ring & claim", what: "Ring the Bell, then claim your Payout — it lands in your Seat's Vault.", to: "/bell", cta: "Ring the Bell",
    done: (p) => !!p && p.seats.some((s) => s.vaultUsdg > 0n) },
  { id: "case", n: 6, title: "Open a Case", what: "Open a Case for a real stock draw — AAPL or NVDA, fair value either way.", to: "/cases", cta: "Go to Cases",
    done: (p) => !!p && (p.wins.aapl > 0n || p.wins.nvda > 0n) },
];

/// Live progress, polled. Returns the portfolio, per-step done flags, and the next unfinished step.
export function useJourney() {
  const w = useWallet();
  const a = w.address as Address | null;
  const connected = !!a && w.chainOk;
  const [p, setP] = useState<Portfolio | null>(null);
  const [loading, setLoading] = useState(false);

  const refresh = useCallback(() => {
    if (!a) { setP(null); return; }
    setLoading(true);
    reads.portfolio(a).then(setP).catch(() => {}).finally(() => setLoading(false));
  }, [a]);

  useEffect(() => { refresh(); const t = setInterval(refresh, 20_000); return () => clearInterval(t); }, [refresh]);

  const steps = STEPS.map((s) => ({ ...s, complete: s.done(p, connected) }));
  const next = steps.find((s) => !s.complete) ?? steps[steps.length - 1];
  const doneCount = steps.filter((s) => s.complete).length;
  return { portfolio: p, steps, next, doneCount, connected, loading, refresh };
}

/// Compact strip for the top of app pages: "Step 3 of 6 · Buy a Seat →" with a dot tracker.
export function JourneyStrip({ here }: { here?: StepId }) {
  const { steps, next, doneCount } = useJourney();
  const cur = here ? steps.find((s) => s.id === here) ?? next : next;
  return (
    <div className="journey-strip">
      <div className="js-dots" aria-hidden>
        {steps.map((s) => <span key={s.id} className={"js-dot" + (s.complete ? " done" : s.id === cur.id ? " on" : "")} />)}
      </div>
      <span className="js-label">
        <b className="num">{doneCount}/{steps.length}</b> {cur.complete ? "all steps done — explore freely" : <>Next: <b>{cur.title}</b> — {cur.what}</>}
      </span>
      {!cur.complete && cur.to !== "/start" && <Link className="js-go" to={cur.to}>{cur.cta} →</Link>}
      <Link className="js-map" to="/start">Guide</Link>
    </div>
  );
}

/// The Start page: the funds panel + the full numbered checklist.
export function StartPage() {
  const w = useWallet();
  const a = w.address as Address | null;
  const { portfolio: p, steps, doneCount, connected, refresh } = useJourney();
  useEffect(() => { document.title = "Start here · Essey"; }, []);

  return (
    <>
      <section className="band" id="start" style={{ paddingTop: 34 }}>
        <div className="wrap">
          <div className="band-head"><div>
            <span className="eyebrow">Start here</span>
            <h2>Test the whole club in six steps</h2>
            <p>Everything below is live on Robinhood Chain testnet with play money — real contracts, real
              mechanics, nothing at risk. Do them in order the first time; each ticks itself off as you go.</p>
          </div>
            <span className="preview-chip live">{doneCount}/6 done</span>
          </div>

          <FundsPanel connected={connected} address={a} portfolio={p} onFund={refresh} />

          <ol className="journey-list">
            {steps.map((s) => (
              <li key={s.id} className={"journey-step" + (s.complete ? " complete" : "")}>
                <span className="jstep-n num">{s.complete ? "✓" : s.n}</span>
                <div className="jstep-body">
                  <div className="jstep-title">{s.title}</div>
                  <div className="jstep-what">{s.what}</div>
                </div>
                {s.complete
                  ? <span className="jstep-done">done</span>
                  : s.id === "connect"
                    ? <ConnectButton />
                    : s.id === "fund"
                      ? <a className="btn btn-ghost" href="#funds" onClick={(e) => { e.preventDefault(); document.getElementById("funds")?.scrollIntoView({ behavior: "smooth" }); }}>Faucet ↑</a>
                      : <Link className="btn btn-gold" to={s.to}>{s.cta} →</Link>}
              </li>
            ))}
          </ol>
        </div>
      </section>
    </>
  );
}

/// One place to get funds — no longer scattered across pages.
function FundsPanel({ connected, address, portfolio, onFund }: { connected: boolean; address: Address | null; portfolio: Portfolio | null; onFund: () => void }) {
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const drip = async () => {
    if (!address) return;
    setBusy(true); setMsg(null);
    try { await flows.drip(address); setMsg("✓ 5,000 $ESSEY + 1,000 USDG dripped"); onFund(); }
    catch (e) { const m = String((e as Error).message ?? e); setMsg(m.includes("TooSoon") ? "Faucet cooldown — 8h between drips" : m.slice(0, 120)); }
    finally { setBusy(false); }
  };
  return (
    <div className="live-card" id="funds" style={{ marginBottom: 22 }}>
      <div className="live-h">PLAY MONEY <span className="preview-chip live">testnet</span></div>
      {!connected ? (
        <div className="live-row"><span className="live-note">Connect on Robinhood Chain testnet to get funds.</span><ConnectButton /></div>
      ) : (
        <>
          <div className="live-bal num">
            {portfolio ? <>{fmt(portfolio.gas, 4)} ETH (gas) · {fmt(portfolio.essey)} $ESSEY · {fmt(portfolio.usdg)} USDG · {portfolio.seats.length} Seats</> : "…"}
          </div>
          <div className="live-row">
            <button className="btn btn-gold" disabled={busy} onClick={drip}>{busy ? "dripping…" : "Get 5,000 $ESSEY + 1,000 USDG"}</button>
            <a className="btn btn-ghost" href={NET.faucet} target="_blank" rel="noreferrer">Need gas ETH? ↗</a>
          </div>
          {portfolio && portfolio.gas === 0n && <div className="live-note">You have no gas ETH yet — grab some from the chain faucet (button above) before any transaction.</div>}
          {msg && <div className="live-msg">{msg}</div>}
        </>
      )}
    </div>
  );
}
