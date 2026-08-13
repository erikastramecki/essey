// Portfolio — the returning tester's hub: what you hold, and one-click ways to do the things you do
// again and again (claim a Payout, buy/stake/open/supply). Actions that are cheap to do here happen
// here; heavier flows link out.
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { formatEther, type Address } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { usePortfolio, type PortfolioDon } from "./usePortfolio";
import { NET, ADDR, TIERS, flows, reads, fmt, niceError } from "./live";

const DAY = 86_400; // seconds
const GRACE_DAYS = 30; // Don loan default grace after the term's expiry (matches the deployed facility)
const fmtDate = (unixSec: number) =>
  new Date(unixSec * 1000).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });

export function PortfolioPage() {
  const w = useWallet();
  const { portfolio: p, connected, refresh } = usePortfolio();
  useEffect(() => { document.title = "Portfolio · Essey"; }, []);
  const a = w.address as Address | null;
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [floor, setFloor] = useState<{ floor: bigint; reserve: bigint; backed: bigint } | null>(null);
  const [facility, setFacility] = useState<{ maxDraw: bigint; lendable: bigint; ltvBps: number } | null>(null);
  useEffect(() => { reads.donFloor().then(setFloor).catch(() => {}); }, []);
  useEffect(() => { reads.donLoanFacility().then(setFacility).catch(() => {}); }, [p]);

  const run = async (label: string, fn: () => Promise<unknown>, ok: string) => {
    setBusy(label); setMsg(null);
    try { await fn(); setMsg(ok); refresh(); }
    catch (e) { setMsg(niceError(e)); }
    finally { setBusy(null); }
  };

  return (
    <section className="band" id="portfolio" style={{ paddingTop: 34 }}>
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">Portfolio</span>
          <h2>Your Essey</h2>
          <p>Everything you hold on testnet: balances, your Dons, the Payouts sitting in each
            Vault, and any stock in your wallet. Your Dons are your characters in the game.</p>
        </div>
        </div>

        {!connected ? (
          <div className="live-card"><div className="live-row">
            <span className="live-note">Connect on Robinhood Chain testnet to see your account.</span><ConnectButton />
          </div></div>
        ) : !p ? (
          <div className="live-card"><div className="live-note">Loading your account…</div></div>
        ) : (
          <>
            {/* balances */}
            <div className="pf-stats">
              <Stat label="Gas (ETH)" value={fmt(p.gas, 4)} />
              <Stat label="$ESSEY" value={fmt(p.essey)} sub="the access chip" />
              <Stat label="USDG" value={fmt(p.usdg)} sub="fees & payouts" />
              <Stat label="Dons" value={p.dons.length.toString()} sub="seats at the table" />
            </div>

            {/* Returning-user launchpad: the repeat actions, one hop each. */}
            <div className="pf-quick">
              <span className="pf-quick-h">Quick actions</span>
              <Link className="pf-quick-btn" to="/game">♠ Play D.O.N.</Link>
              <Link className="pf-quick-btn" to="/market">⬡ Buy a Don</Link>
              <Link className="pf-quick-btn" to="/builder">◇ Build a Don</Link>
              <Link className="pf-quick-btn" to="/tape">📈 The Tape</Link>
            </div>

            {msg && <div className="live-msg" style={{ marginBottom: 14 }}>{msg}</div>}

            {/* Dons */}
            <div className="pf-block">
              <div className="pf-block-h">Your Dons {p.dons.length > 0 && <Link className="pf-link" to="/bell">manage tiers →</Link>}</div>
              {p.dons.length === 0 ? (
                <div className="pf-empty">No Dons yet. <Link to="/market">Buy one on the Market →</Link></div>
              ) : (
                <>
                {floor && floor.floor > 0n && (
                  <div className="pf-note" style={{ marginBottom: 10 }}>🛡 <b>Every Don has a hard floor.</b> Redeem one for <b>≥ {fmt(floor.floor, 2)} $ESSEY</b> from the reserve, anytime. That's the reserve ({fmt(floor.reserve, 0)} $ESSEY) split across the {floor.backed.toString()} Dons it backs, and it only ever rises. Redeeming <b>locks the Don</b> and forfeits its membership and Vault.</div>
                )}
                <div className="pf-seats">
                  {p.dons.map((s) => (
                    <DonSeat key={s.id.toString()} s={s} a={a} floor={floor} facility={facility} busy={busy} run={run} />
                  ))}
                </div>
                </>
              )}
            </div>

            {/* Lending */}
            <div className="pf-block">
              <div className="pf-block-h">Lending {p.pool.mine > 0n || p.loans.length > 0 ? <Link className="pf-link" to="/lend">manage →</Link> : <Link className="pf-link" to="/lend">supply / borrow →</Link>}</div>
              <div className="pf-lend num">
                {p.pool.mine > 0n
                  ? <span className="pf-lend-item">supplied <b>{fmt(p.pool.mine, 2)}</b> USDG <i>@ {p.pool.supplyApy.toFixed(2)}% APY</i></span>
                  : <span className="pf-note">not supplying yet. Supply USDG to earn {p.pool.supplyApy.toFixed(2)}% APY →</span>}
                {p.loans.length === 0
                  ? <span className="pf-note">no open loans{p.wins.aapl > 0n || p.wins.nvda > 0n ? " (you hold stock; borrowing against it is coming to testnet)" : ""}.</span>
                  : p.loans.map((l) => <span className="pf-lend-item" key={l.id.toString()}>Loan #{l.id.toString()} · owe <b>{fmt(l.debt, 2)}</b> USDG</span>)}
              </div>
            </div>

            {/* Wallet-held stock */}
            <div className="pf-block">
              <div className="pf-block-h">Stock in your wallet</div>
              {p.wins.aapl === 0n && p.wins.nvda === 0n ? (
                <div className="pf-empty">No stock tokens in this wallet yet.</div>
              ) : (
                <div className="pf-wins num">
                  {p.wins.aapl > 0n && <span className="pf-win">AAPL <b>{fmt(p.wins.aapl, 2)}</b></span>}
                  {p.wins.nvda > 0n && <span className="pf-win">NVDA <b>{fmt(p.wins.nvda, 2)}</b></span>}
                  <span className="pf-note">real testnet stock tokens, held in your wallet; borrow against them on <Link to="/lend">Lend</Link>.</span>
                </div>
              )}
            </div>
          </>
        )}
      </div>
    </section>
  );
}

type RunFn = (label: string, fn: () => Promise<unknown>, ok: string) => Promise<void>;

/// One owned Don's card — status, Vault, and its actions, including the wired BORROW / REPAY loan flow.
/// Its own component so the borrow panel's local state (term slider, prepaid quote, open toggle) gets a
/// clean hook scope per seat.
function DonSeat({ s, a, floor, facility, busy, run }: {
  s: PortfolioDon; a: Address | null;
  floor: { floor: bigint; reserve: bigint; backed: bigint } | null;
  facility: { maxDraw: bigint; lendable: bigint; ltvBps: number } | null;
  busy: string | null; run: RunFn;
}) {
  const [openBorrow, setOpenBorrow] = useState(false);
  const [termDays, setTermDays] = useState(90);
  const [prepaid, setPrepaid] = useState<bigint | null>(null);
  const termSecs = BigInt(termDays * DAY);
  const nowSec = Math.floor(Date.now() / 1000);

  // Re-quote the prepaid ETH interest whenever the panel is open and the term moves. The launch rate is
  // 0 (free), but we always read it live and send it as msg.value — never assume free.
  useEffect(() => {
    if (!openBorrow) { setPrepaid(null); return; }
    let live = true;
    reads.donLoanPrepaid(termSecs).then((v) => { if (live) setPrepaid(v); }).catch(() => {});
    return () => { live = false; };
  }, [openBorrow, termSecs]);

  const draw = facility?.maxDraw ?? 0n;
  const potShort = !!facility && facility.lendable < draw; // the loan pot can't cover the fixed draw
  const canBorrow = !!a && !busy && !!facility && draw > 0n && !potShort;
  const dueSec = nowSec + termDays * DAY;

  const doBorrow = () => a && facility && run("borrow" + s.id,
    () => flows.borrowAgainstDon(a, s.id, termSecs),
    `✓ Borrowed ${fmt(draw, 2)} $ESSEY against Don #${s.id}. It's liened until you repay.`);
  const doRepay = () => a && run("repay" + s.id,
    () => flows.repayDonLoan(a, s.id, s.debt),
    `✓ Repaid Don #${s.id}'s loan. The lien is lifted.`);

  return (
    <div className="pf-seat">
      <div className="pf-seat-top">
        <span className="pf-seat-id num">Don #{s.id.toString()}</span>
        <span className={"pf-tier" + (s.tier > 0 ? " on" : "")}>{s.tier === 0 ? "Base" : (TIERS[s.tier - 1]?.name ?? `Tier ${s.tier}`)}</span>
        {s.locked && <span className="pf-tier on" title="This Don's traits are frozen forever; staking locks the art.">🔒 art locked</span>}
        {s.liened && <span className="pf-tier on" title="Borrowed against, locked until repaid. It stays in your wallet, staked and earning, but can't be sold, redeemed, or swapped until the debt clears.">📜 borrowed, locked until repaid</span>}
      </div>
      <div className="pf-seat-row num">
        <span>ready to claim: <b>{fmt(s.pending, 4)}</b> USDG</span>
        <span>Vault holds <b>{fmt(s.vaultUsdg, 4)}</b> USDG
          {(s.vaultAapl > 0n || s.vaultNvda > 0n) && (
            <> · <b>{s.vaultAapl > 0n && `${fmt(s.vaultAapl, 2)} AAPL`}{s.vaultAapl > 0n && s.vaultNvda > 0n ? " · " : ""}{s.vaultNvda > 0n && `${fmt(s.vaultNvda, 2)} NVDA`}</b> in stock</>
          )}
        </span>
        {s.liened && <span>loan debt: <b>{fmt(s.debt, 2)}</b> $ESSEY{s.expiry > 0n && <> · due <b>{fmtDate(Number(s.expiry))}</b> · liquidatable after <b>{fmtDate(Number(s.expiry) + GRACE_DAYS * DAY)}</b></>}</span>}
      </div>
      <div className="pf-seat-actions">
        <a className="pf-link" href={`${NET.explorer}/token/${ADDR.don}?a=${s.id}`} target="_blank" rel="noreferrer">Don ↗</a>
        <a className="pf-link" href={`${NET.explorer}/address/${s.vault}`} target="_blank" rel="noreferrer">Vault ↗</a>
        {s.pending > 0n
          ? <button className="pf-link gold pf-inline-btn" disabled={busy === "claim" + s.id} onClick={() => a && run("claim" + s.id, () => flows.claimPayout(a, s.id), `✓ Payout claimed into Don #${s.id}'s Vault`)}>{busy === "claim" + s.id ? "claiming…" : "claim now"}</button>
          : s.tier === 0 ? <Link className="pf-link gold" to="/bell">stake →</Link>
          : <Link className="pf-link" to="/bell">upgrade →</Link>}
        {s.liened ? (
          <button className="pf-link gold pf-inline-btn" disabled={!!busy} title="Repay the loan in $ESSEY (1:1, flat; interest was prepaid in ETH). Clears the debt and lifts the lien."
            onClick={doRepay}>{busy === "repay" + s.id ? "repaying…" : `repay ${fmt(s.debt, 2)} $ESSEY`}</button>
        ) : (
          <>
            {floor && floor.floor > 0n && (
              <button className="pf-link pf-inline-btn" disabled={!!busy} title="Redeem this Don for its $ESSEY floor. This locks the Don and forfeits its membership and Vault."
                onClick={() => a && run("redeem" + s.id, () => flows.redeemDonFloor(a, s.id), `✓ Don #${s.id} redeemed for ${fmt(floor.floor, 2)} $ESSEY. Membership forfeited.`)}>
                {busy === "redeem" + s.id ? "redeeming…" : `redeem ↓ ${fmt(floor.floor, 2)} $ESSEY`}
              </button>
            )}
            <button className="pf-link pf-inline-btn" aria-expanded={openBorrow} onClick={() => setOpenBorrow((o) => !o)}
              title="Borrow $ESSEY against this Don. It stays in your wallet, staked and earning, while liened.">
              ⚖ {openBorrow ? "close" : "borrow $ESSEY"}
            </button>
          </>
        )}
      </div>

      {openBorrow && !s.liened && (
        <div className="pf-borrow">
          <div className="pf-borrow-row num">
            <label htmlFor={`term-${s.id}`}>term: <b>{termDays} days</b></label>
            <input id={`term-${s.id}`} type="range" min={7} max={365} step={1} value={termDays}
              onChange={(e) => setTermDays(+e.target.value)} aria-label="Loan term in days" />
          </div>
          <div className="pf-borrow-stats num">
            <span>draw <b>{fmt(draw, 2)} $ESSEY</b> <i>(50% of the floor, flat debt, repay 1:1)</i></span>
            <span>interest: <b>{prepaid === null ? "…" : prepaid === 0n ? "free" : `${formatEther(prepaid)} ETH`}</b> <i>prepaid, once</i></span>
            <span>due <b>{fmtDate(dueSec)}</b> · liquidatable after <b>{fmtDate(dueSec + GRACE_DAYS * DAY)}</b></span>
          </div>
          {potShort && <div className="pf-note">The loan pot is short right now: only {fmt(facility!.lendable, 2)} $ESSEY lendable, less than the {fmt(draw, 2)} draw. Try again once it's refunded.</div>}
          <button className="btn btn-gold pf-borrow-go" disabled={!canBorrow}
            onClick={doBorrow}>
            {busy === "borrow" + s.id ? "borrowing…" : !a ? "connect a wallet to borrow" : `Borrow ${fmt(draw, 2)} $ESSEY`}
          </button>
          <div className="pf-note">The Don stays in your wallet (still staked, still earning stock) but can't be sold, redeemed, or swapped until you repay. Miss the due date (term + a {GRACE_DAYS}-day grace) and it can be liquidated: redeemed at the floor to clear the debt, surplus back to you, but the Don and its Vault are forfeited.</div>
        </div>
      )}
    </div>
  );
}

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="pf-stat">
      <div className="pf-stat-k">{label}</div>
      <div className="pf-stat-v num">{value}</div>
      {sub && <div className="pf-stat-sub">{sub}</div>}
    </div>
  );
}
