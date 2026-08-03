// The guided tester journey. A new visitor should never wonder "where do I test staking?" — this
// is the map: numbered steps that auto-check from live chain state, each pointing at the one page
// where that flow lives. Shared by the Start page and a compact progress strip on the app pages.
import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Address } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { reads, flows, fmt, NET, BORROW_OPENS, type Portfolio, niceError } from "./live";

export type StepId = "connect" | "fund" | "seat" | "stake" | "payout" | "case" | "supply" | "borrow";

export type Step = {
  id: StepId;
  n: number;
  title: string;
  what: string; // one line: what you're testing
  to: string; // where you do it
  cta: string;
  bonus?: boolean; // optional step — doesn't block the "all done" completion payoff
  done: (p: Portfolio | null, connected: boolean) => boolean;
};

export const STEPS: Step[] = [
  { id: "connect", n: 1, title: "Connect", what: "Connect a wallet on Robinhood Chain testnet.", to: "/start", cta: "Connect",
    done: (_p, c) => c },
  { id: "fund", n: 2, title: "Get play money", what: "Grab gas ETH from the chain faucet FIRST, then 5,000 $ESSEY + 1,000 USDG from ours.", to: "/start", cta: "Open the faucet",
    done: (p) => !!p && p.gas > 0n && p.essey > 0n && p.usdg > 0n },
  { id: "seat", n: 3, title: "Buy a Seat", what: "Trade $ESSEY for a Seat on the Exchange — the fee feeds the Bell's pot.", to: "/market", cta: "Go to the Market",
    done: (p) => !!p && p.seats.length > 0 },
  { id: "stake", n: 4, title: "Stake a Tier", what: "Stake $ESSEY on your Seat to earn a bigger slice of every Payout.", to: "/bell", cta: "Go to Stake",
    done: (p) => !!p && p.seats.some((s) => s.tier > 0) },
  { id: "payout", n: 5, title: "Ring & claim", what: "Ring the Bell, then claim your Payout — it lands in your Seat's Vault.", to: "/bell", cta: "Ring the Bell",
    done: (p) => !!p && p.seats.some((s) => s.vaultUsdg > 0n) },
  { id: "case", n: 6, title: "Open a Case", what: "Open a Case for a real stock draw — AAPL or NVDA, fair value either way.", to: "/cases", cta: "Go to Cases",
    done: (p) => !!p && (p.wins.aapl > 0n || p.wins.nvda > 0n) },
  { id: "supply", n: 7, title: "Supply liquidity", what: "Supply USDG to the lending pool and earn the interest borrowers pay.", to: "/lend", cta: "Go to Lend",
    done: (p) => !!p && p.pool.mine > 0n },
  { id: "borrow", n: 8, title: "Borrow against your stock", what: `Borrow USDG against the stock you drew — the full loop. (Opens ${BORROW_OPENS.toUTCString().slice(5, 11)}.)`, to: "/lend", cta: "Go to Lend", bonus: true,
    done: (p) => !!p && p.loans.length > 0 },
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
  const required = steps.filter((s) => !s.bonus);
  // "next" prefers an unfinished required step; only points at a bonus if all required are done.
  const next = required.find((s) => !s.complete) ?? steps.find((s) => !s.complete) ?? steps[steps.length - 1];
  const doneCount = steps.filter((s) => s.complete).length;
  const allRequiredDone = required.every((s) => s.complete);
  return { portfolio: p, steps, required, next, doneCount, allRequiredDone, connected, loading, refresh };
}

/// Compact strip for the top of app pages: "Next: Buy a Seat →" with a dot tracker, and — crucially —
/// a working action inline when the next step is connect/switch/fund (the strip must never point at
/// something with no button here).
export function JourneyStrip({ here }: { here?: StepId }) {
  const w = useWallet();
  const { steps, next, doneCount, allRequiredDone } = useJourney();
  const cur = here ? steps.find((s) => s.id === here) ?? next : next;
  const onboarding = cur.id === "connect" || cur.id === "fund"; // handled at /start (funds live there)
  return (
    <div className="journey-strip">
      <div className="js-dots" aria-hidden>
        {steps.map((s) => <span key={s.id} className={"js-dot" + (s.complete ? " done" : s.id === cur.id ? " on" : "")} />)}
      </div>
      <span className="js-label">
        <b className="num">{doneCount}/{steps.length}</b> {allRequiredDone ? "core loop done — explore freely, or try the bonus" : <>Next: <b>{cur.title}</b> — {cur.what}</>}
      </span>
      {!allRequiredDone && (
        cur.id === "connect" && !w.address ? <span className="js-go"><ConnectButton /></span>
        : cur.id === "connect" && w.address && !w.chainOk ? <button className="js-go js-btn" onClick={w.switchChain}>Switch network →</button>
        : onboarding ? <Link className="js-go" to="/start">Set up →</Link>
        : <Link className="js-go" to={cur.to}>{cur.cta} →</Link>
      )}
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
            <h2>Test the whole club, step by step</h2>
            <p>Everything below is live on Robinhood Chain testnet with play money — real contracts, real
              mechanics, nothing at risk. Do them in order the first time; each ticks itself off as you go.</p>
          </div>
            <span className="preview-chip live">{doneCount}/{steps.length} done</span>
          </div>

          <FundsPanel connected={connected} address={a} portfolio={p} onFund={refresh} />

          <ol className="journey-list">
            {steps.map((s) => (
              <li key={s.id} className={"journey-step" + (s.complete ? " complete" : "")}>
                <span className="jstep-n num">{s.complete ? "✓" : s.n}</span>
                <div className="jstep-body">
                  <div className="jstep-title">{s.title}{s.bonus && <span className="jstep-bonus">bonus</span>}</div>
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
    catch (e) { setMsg(niceError(e)); }
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
          {/* Gas FIRST: every transaction needs it, and it comes from the chain's own faucet (a
              separate step from our token drip). Emphasize it until they actually have some. */}
          {portfolio && portfolio.gas === 0n && (
            <div className="fund-gas">
              <span className="fund-step num">1</span>
              <span>You have <b>no gas ETH</b> — nothing will send without it. Get some from the chain faucet first (it's free, opens in a new tab).</span>
              <a className="btn btn-gold" href={NET.faucet} target="_blank" rel="noreferrer">Get gas ETH ↗</a>
            </div>
          )}
          <div className="live-row">
            {portfolio && portfolio.gas > 0n && <a className="btn btn-ghost" href={NET.faucet} target="_blank" rel="noreferrer">More gas ↗</a>}
            <button className="btn btn-gold" disabled={busy} onClick={drip}>
              {busy ? "dripping…" : portfolio && portfolio.gas === 0n ? "2 · Then get 5,000 $ESSEY + 1,000 USDG" : "Get 5,000 $ESSEY + 1,000 USDG"}
            </button>
          </div>
          {msg && <div className="live-msg">{msg}</div>}
        </>
      )}
    </div>
  );
}
