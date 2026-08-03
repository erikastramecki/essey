// Portfolio — the account view: what you hold, what your Seats are worth, what you've won. Read-only
// and honest; the actions live on their own pages (linked from here) so this stays a clean dashboard.
import { useEffect } from "react";
import { Link } from "react-router-dom";
import { useWallet, ConnectButton } from "./wallet";
import { useJourney } from "./journey";
import { NET, ADDR, TIERS, fmt } from "./live";

export function PortfolioPage() {
  const w = useWallet();
  const { portfolio: p, connected, doneCount, steps } = useJourney();
  useEffect(() => { document.title = "Portfolio · Essey"; }, []);
  const next = steps.find((s) => !s.complete);

  return (
    <section className="band" id="portfolio" style={{ paddingTop: 34 }}>
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">Portfolio</span>
          <h2>Your Essey</h2>
          <p>Everything you hold on testnet — balances, Seats and their Tiers, the Payouts sitting in each
            Vault, and the stock you've drawn from Cases.</p>
        </div>
          {connected && <span className="preview-chip live">{doneCount}/6 tested</span>}
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
              <Stat label="Seats" value={p.seats.length.toString()} sub="membership" />
            </div>

            {next && (
              <div className="pf-next">
                <span>Next step in the tour: <b>{next.title}</b> — {next.what}</span>
                <Link className="btn btn-gold" to={next.to}>{next.cta} →</Link>
              </div>
            )}

            {/* Seats */}
            <div className="pf-block">
              <div className="pf-block-h">Your Seats {p.seats.length > 0 && <Link className="pf-link" to="/bell">manage tiers →</Link>}</div>
              {p.seats.length === 0 ? (
                <div className="pf-empty">No Seats yet. <Link to="/market">Buy one on the Market →</Link></div>
              ) : (
                <div className="pf-seats">
                  {p.seats.map((s) => (
                    <div className="pf-seat" key={s.id.toString()}>
                      <div className="pf-seat-top">
                        <span className="pf-seat-id num">Seat #{s.id.toString()}</span>
                        <span className={"pf-tier" + (s.tier > 0 ? " on" : "")}>{s.tier === 0 ? "Base" : (TIERS[s.tier - 1]?.name ?? `Tier ${s.tier}`)}</span>
                      </div>
                      <div className="pf-seat-row num">
                        <span>claimable <b>{fmt(s.pending, 4)}</b> USDG</span>
                        <span>Vault holds <b>{fmt(s.vaultUsdg, 4)}</b> USDG</span>
                      </div>
                      <div className="pf-seat-actions">
                        <a className="pf-link" href={`${NET.explorer}/token/${ADDR.seat}?a=${s.id}`} target="_blank" rel="noreferrer">Seat ↗</a>
                        <a className="pf-link" href={`${NET.explorer}/address/${s.vault}`} target="_blank" rel="noreferrer">Vault ↗</a>
                        {s.tier === 0 ? <Link className="pf-link gold" to="/bell">stake →</Link>
                          : s.pending > 0n ? <Link className="pf-link gold" to="/bell">claim →</Link>
                          : <Link className="pf-link" to="/bell">upgrade →</Link>}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Case winnings */}
            <div className="pf-block">
              <div className="pf-block-h">Stock from Cases {(p.wins.aapl > 0n || p.wins.nvda > 0n) && <Link className="pf-link" to="/cases">open another →</Link>}</div>
              {p.wins.aapl === 0n && p.wins.nvda === 0n ? (
                <div className="pf-empty">No stock drawn yet. <Link to="/cases">Open a Case →</Link></div>
              ) : (
                <div className="pf-wins num">
                  {p.wins.aapl > 0n && <span className="pf-win">AAPL <b>{fmt(p.wins.aapl, 2)}</b></span>}
                  {p.wins.nvda > 0n && <span className="pf-win">NVDA <b>{fmt(p.wins.nvda, 2)}</b></span>}
                  <span className="pf-note">real testnet stock tokens — held in your wallet, borrowable once the pool is wired.</span>
                </div>
              )}
            </div>
          </>
        )}
      </div>
    </section>
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
