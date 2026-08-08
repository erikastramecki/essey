// The guided tester journey. A new visitor should never wonder "where do I test staking?" — this
// is the map: numbered steps that auto-check from live chain state, each pointing at the one page
// where that flow lives. Shared by the Start page and a compact progress strip on the app pages.
import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Address } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { reads, flows, fmt, NET, WHITELIST_SPOTS, type Portfolio, niceError } from "./live";

export type StepId = "connect" | "fund" | "join" | "seat" | "stake" | "payout" | "case" | "supply" | "borrow" | "invite";

// Referral capture: a ?ref=0x… link stashes the referrer so a later on-chain register credits them.
const REF_KEY = "essey-ref";
export function captureRef() {
  try {
    const r = new URLSearchParams(location.search).get("ref");
    if (r && /^0x[a-fA-F0-9]{40}$/.test(r)) localStorage.setItem(REF_KEY, r);
  } catch { /* ignore */ }
}
export function storedRef(self?: Address | null): Address {
  const ZERO = "0x0000000000000000000000000000000000000000" as Address;
  try {
    const r = localStorage.getItem(REF_KEY);
    if (r && /^0x[a-fA-F0-9]{40}$/.test(r) && r.toLowerCase() !== self?.toLowerCase()) return r as Address;
  } catch { /* ignore */ }
  return ZERO;
}

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
  { id: "join", n: 3, title: "Join the quest", what: "Register on-chain to enter the whitelist raffle (one tx; credits your referrer if you came from a link).", to: "/start", cta: "Join",
    done: (p) => !!p && p.quest.registered },
  { id: "seat", n: 4, title: "Buy a Seat", what: "Trade $ESSEY for a Seat on the Exchange — the fee feeds the Bell's pot.", to: "/market", cta: "Go to the Exchange",
    done: (p) => !!p && p.seats.length > 0 },
  { id: "stake", n: 5, title: "Stake a Tier", what: "Boost a Seat you own — stake $ESSEY so it earns a bigger share of every payout. (Bonus — boosts your odds.)", to: "/bell", cta: "Go to the Bell", bonus: true,
    done: (p) => !!p && p.seats.some((s) => s.tier > 0) },
  { id: "payout", n: 6, title: "Ring & claim", what: "When the fee pot is full, ring the Bell — then claim your payout as stock into your Seat's Vault. (Bonus — the pot fills from others' activity, so it's not always ringable solo.)", to: "/bell", cta: "Ring the Bell", bonus: true,
    // The Bell now pays real stock into the Vault (AAPL/NVDA); it fails open to USDG only if conversion can't settle.
    done: (p) => !!p && p.seats.some((s) => s.vaultUsdg > 0n || s.vaultAapl > 0n || s.vaultNvda > 0n) },
  { id: "case", n: 7, title: "Open a Case", what: "Open a Case — roll a multiplier (0.65×–50×) that pays out in real AAPL stock. Then withdraw your winnings to your wallet.", to: "/cases", cta: "Go to Cases",
    done: (p) => !!p && (p.wins.aapl > 0n || p.wins.nvda > 0n) },
  { id: "supply", n: 8, title: "Supply liquidity", what: "Supply USDG to the lending pool and earn the interest borrowers pay.", to: "/lend", cta: "Go to Lend",
    done: (p) => !!p && p.pool.mine > 0n },
  { id: "invite", n: 9, title: "Invite a friend", what: "Share your referral link — every friend who joins the quest boosts your odds.", to: "/start", cta: "Get your link", bonus: true,
    done: (p) => !!p && p.quest.referrals > 0n },
  { id: "borrow", n: 10, title: "Borrow against your stock", what: `Borrow USDG against the stock you drew — the full loop. (Not live on testnet yet — coming soon.)`, to: "/lend", cta: "Go to Lend", bonus: true,
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
  const required = steps.filter((s) => !s.bonus); // the core quest — completing all = whitelist-eligible
  // "next" prefers an unfinished required step; only points at a bonus if all required are done.
  const next = required.find((s) => !s.complete) ?? steps.find((s) => !s.complete) ?? steps[steps.length - 1];
  const doneCount = steps.filter((s) => s.complete).length;
  const coreDone = required.filter((s) => s.complete).length;
  const allRequiredDone = required.every((s) => s.complete);
  return { portfolio: p, steps, required, coreDone, coreTotal: required.length, next, doneCount, allRequiredDone, connected, loading, refresh };
}

/// Compact strip for the top of app pages: "Next: Buy a Seat →" with a dot tracker, and — crucially —
/// a working action inline when the next step is connect/switch/fund (the strip must never point at
/// something with no button here).
export function JourneyStrip({ here }: { here?: StepId }) {
  const w = useWallet();
  const { steps, next, doneCount, allRequiredDone } = useJourney();
  // Pin to this page's step ONLY once the user has actually reached it (their true next step is at or beyond it);
  // otherwise guide them to their real next step — so a disconnected visitor on /market isn't told "Buy a Seat"
  // (a step they can't do yet) but is pointed at Connect.
  const hereStep = here ? steps.find((s) => s.id === here) : undefined;
  const nextIdx = steps.findIndex((s) => s.id === next.id);
  const hereIdx = hereStep ? steps.findIndex((s) => s.id === hereStep.id) : -1;
  const cur = hereStep && nextIdx >= hereIdx ? hereStep : next;
  const onboarding = cur.id === "connect" || cur.id === "fund" || cur.id === "join" || cur.id === "invite"; // all handled at /start
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

/// The Quest — complete the tasks to earn a whitelist spot for the mainnet mint. Progress bar,
/// on-chain tasks, a referral link, and an honest raffle explainer.
export function StartPage() {
  const w = useWallet();
  const a = w.address as Address | null;
  const { portfolio: p, steps, coreDone, coreTotal, allRequiredDone, connected, refresh } = useJourney();
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  useEffect(() => { document.title = "The Quest · Essey"; captureRef(); }, []);

  const join = async () => {
    if (!a) return;
    setBusy("join"); setMsg(null);
    try { await flows.registerQuest(a, storedRef(a)); setMsg("✓ You're in the quest — complete the tasks to enter the raffle."); refresh(); }
    catch (e) { setMsg(niceError(e)); }
    finally { setBusy(null); }
  };

  const pct = Math.round((coreDone / coreTotal) * 100);

  return (
    <section className="band" id="start" style={{ paddingTop: 34 }}>
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The Quest</span>
          <h2>Earn an early-access pass</h2>
          <p>Play through the whole club on testnet — real contracts, play money — and you're entered to win one of
            <b> {WHITELIST_SPOTS.toLocaleString()}</b> early-access passes for the real (mainnet) launch. Every task is
            a real on-chain action; your activity is what qualifies you. <i>("Mint" just means minting your Seat NFT
            at launch.)</i></p>
        </div>
        </div>

        {/* progress bar */}
        <div className="quest-bar-wrap">
          <div className="quest-bar"><div className="quest-bar-fill" style={{ width: `${pct}%` }} /></div>
          <div className="quest-bar-label num">
            {allRequiredDone
              ? <><b className="good">✓ Quest complete</b> — you're in the raffle{p && p.quest.referrals > 0n ? <> · {p.quest.referrals.toString()} friend{p.quest.referrals > 1n ? "s" : ""} invited</> : null}</>
              : <><b>{coreDone}/{coreTotal}</b> core tasks · {pct}% to a whitelist spot</>}
          </div>
        </div>

        {allRequiredDone && (
          <div className="quest-done">
            🎉 <b>You've completed the quest.</b> Your wallet is on-chain-qualified for one of {WHITELIST_SPOTS.toLocaleString()} whitelist
            spots (register + a Seat + stock + a supply — all verifiable on-chain). Boost your odds with the bonus
            tasks below — stake a Tier, ring the Bell, and invite friends (borrowing against stock is coming to testnet soon).
          </div>
        )}

        <FundsPanel connected={connected} address={a} portfolio={p} onFund={refresh} />

        {connected && <ReferralCard address={a!} quest={p?.quest} />}

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
                : s.id === "connect" ? <ConnectButton />
                : s.id === "fund" ? <a className="btn btn-ghost" href="#funds" onClick={(e) => { e.preventDefault(); document.getElementById("funds")?.scrollIntoView({ behavior: "smooth" }); }}>Faucet ↑</a>
                : s.id === "join" ? (connected ? <button className="btn btn-gold" disabled={busy === "join"} onClick={join}>{busy === "join" ? "joining…" : "Join the quest"}</button> : <ConnectButton />)
                : s.id === "invite" ? <a className="btn btn-ghost" href="#refer" onClick={(e) => { e.preventDefault(); document.getElementById("refer")?.scrollIntoView({ behavior: "smooth" }); }}>Your link ↑</a>
                : <Link className="btn btn-gold" to={s.to}>{s.cta} →</Link>}
            </li>
          ))}
        </ol>
        {msg && <div className="live-msg" style={{ marginTop: 12 }}>{msg}</div>}

        <div className="quest-fine">
          How selection works, honestly: completing the core quest enters your wallet into the pool. At mint,
          up to {WHITELIST_SPOTS.toLocaleString()} wallets are chosen — weighted toward earlier and more active
          testers and those who brought others, and reviewed for sybil farming (many wallets, one person). Your
          on-chain activity is the record; this is an early-tester reward, not a purchase or a guarantee.
        </div>
      </div>
    </section>
  );
}

/// Your referral link + how many friends have joined. The link carries ?ref=<you>; when a friend
/// registers, the on-chain graph credits you.
export function ReferralCard({ address, quest }: { address: Address; quest?: { referrals: bigint; total: bigint } }) {
  const [copied, setCopied] = useState(false);
  const link = `${location.origin}/start?ref=${address}`;
  const copy = async () => {
    try { await navigator.clipboard.writeText(link); setCopied(true); setTimeout(() => setCopied(false), 2000); } catch { /* ignore */ }
  };
  return (
    <div className="live-card" id="refer" style={{ marginBottom: 22 }}>
      <div className="live-h">INVITE FRIENDS — BOOST YOUR ODDS <span className="preview-chip live">{quest ? `${quest.referrals} joined` : "…"}</span></div>
      <div className="refer-row">
        <input className="refer-link num" readOnly value={link} onFocus={(e) => e.target.select()} aria-label="your referral link" />
        <button className="btn btn-gold" onClick={copy}>{copied ? "✓ copied" : "Copy link"}</button>
      </div>
      <div className="live-note">Share it. Every friend who connects, gets set up, and joins the quest is credited to you
        on-chain{quest && quest.total > 0n ? <> · {quest.total.toString()} testers in the quest so far</> : null} — more invites, better odds.</div>
    </div>
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
      <div className="live-note" style={{ marginBottom: 8 }}><b>$ESSEY</b> is the token you spend to play (buy Seats, open Cases).
        <b> USDG</b> is a play-money stablecoin for fees and payouts. Both are free here — no real value.</div>
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
