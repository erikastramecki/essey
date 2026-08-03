// The referral leaderboard — ranked by QUALIFIED invites (friends who actually tested), not raw
// count, so it rewards bringing real testers rather than spawning wallets. Everyone sees their own
// rank, not just the podium. Badges reward depth the whitelist scorer already weights.
import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Address } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { reads, type Portfolio } from "./live";
import { useJourney } from "./journey";

type Row = { addr: Address; qualified: number; total: number };

// Badges are data-driven so new ones drop in without touching the render — each is a predicate over
// the connected wallet's portfolio + its leaderboard row.
type Badge = { id: string; label: string; icon: string; earned: (p: Portfolio | null, row?: Row) => boolean; hint: string };
const BADGES: Badge[] = [
  { id: "quester", label: "Quester", icon: "◆", hint: "Joined the quest", earned: (p) => !!p?.quest.registered },
  { id: "seated", label: "Seated", icon: "⬡", hint: "Own a Seat", earned: (p) => !!p && p.seats.length > 0 },
  { id: "staker", label: "Staker", icon: "▲", hint: "Staked a Tier", earned: (p) => !!p && p.seats.some((s) => s.tier > 0) },
  { id: "lender", label: "Lender", icon: "⚖", hint: "Supplied liquidity", earned: (p) => !!p && p.pool.mine > 0n },
  { id: "opener", label: "Case Opener", icon: "🎁", hint: "Opened a Case", earned: (p) => !!p && (p.wins.aapl > 0n || p.wins.nvda > 0n) },
  { id: "recruiter", label: "Recruiter", icon: "🤝", hint: "3+ qualified invites", earned: (_p, row) => (row?.qualified ?? 0) >= 3 },
  { id: "ringleader", label: "Ringleader", icon: "🔔", hint: "10+ qualified invites", earned: (_p, row) => (row?.qualified ?? 0) >= 10 },
];

const short = (a: string) => a.slice(0, 6) + "…" + a.slice(-4);

export function LeaderboardPage() {
  const w = useWallet();
  const me = (w.address as Address | null)?.toLowerCase();
  const { portfolio: p } = useJourney();
  const [board, setBoard] = useState<Row[]>([]);
  const [total, setTotal] = useState(0);
  const [loaded, setLoaded] = useState(false);
  useEffect(() => { document.title = "Leaderboard · Essey"; }, []);

  const load = useCallback(() => {
    reads.leaderboard().then(({ board, totalQuesters }) => { setBoard(board); setTotal(totalQuesters); setLoaded(true); }).catch(() => setLoaded(true));
  }, []);
  useEffect(() => { load(); const t = setInterval(load, 30_000); return () => clearInterval(t); }, [load]);

  const myIdx = me ? board.findIndex((r) => r.addr.toLowerCase() === me) : -1;
  const myRow = myIdx >= 0 ? board[myIdx] : undefined;

  return (
    <section className="band" id="leaderboard" style={{ paddingTop: 34 }}>
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">Leaderboard</span>
          <h2>Top recruiters</h2>
          <p>Ranked by <b>qualified invites</b> — friends who actually tested the club (joined, bought a Seat,
            supplied liquidity), not just anyone who clicked. Bringing real testers is what moves you up, and
            it's what the whitelist selection weights.</p>
        </div>
          <span className="preview-chip live">{total} in the quest</span>
        </div>

        {/* your standing — shown to everyone, not just the top */}
        <div className="lb-you">
          {!w.address ? (
            <div className="live-row"><span className="live-note">Connect to see your rank and earn badges.</span><ConnectButton /></div>
          ) : (
            <>
              <div className="lb-you-rank">
                <span className="lb-rank-num num">{myIdx >= 0 ? `#${myIdx + 1}` : "—"}</span>
                <div>
                  <div className="lb-you-h">Your standing</div>
                  <div className="lb-you-sub num">{myRow ? <>{myRow.qualified} qualified · {myRow.total} invited</> : "No qualified invites yet — share your link to climb."}</div>
                </div>
                <Link className="btn btn-gold" to="/start#refer">Get your link →</Link>
              </div>
              <div className="lb-badges">
                {BADGES.map((b) => {
                  const on = b.earned(p, myRow);
                  return <span key={b.id} className={"lb-badge" + (on ? " on" : "")} title={b.hint}>{b.icon} {b.label}</span>;
                })}
              </div>
            </>
          )}
        </div>

        {/* the board */}
        <div className="lb-list">
          {!loaded ? <div className="tape-empty">Scoring the chain…</div>
            : board.length === 0 ? <div className="tape-empty">No qualified invites yet — be the first. <Link to="/start#refer">Grab your referral link →</Link></div>
            : board.slice(0, 25).map((r, i) => (
              <div key={r.addr} className={"lb-row" + (r.addr.toLowerCase() === me ? " me" : "")}>
                <span className="lb-pos num">{i === 0 ? "🥇" : i === 1 ? "🥈" : i === 2 ? "🥉" : `#${i + 1}`}</span>
                <span className="lb-addr num">{short(r.addr)}{r.addr.toLowerCase() === me && " · you"}</span>
                <span className="lb-qual num"><b>{r.qualified}</b> qualified</span>
                <span className="lb-tot num">{r.total} invited</span>
              </div>
            ))}
        </div>

        <div className="quest-fine">
          "Qualified" means a referred wallet did real, faucet-gated work — registered, bought a Seat, and
          supplied to the pool — so the board can't be farmed with empty wallets. Rank feeds your whitelist
          priority and is sybil-reviewed; it isn't a purchase or a guaranteed slot.
        </div>
      </div>
    </section>
  );
}
