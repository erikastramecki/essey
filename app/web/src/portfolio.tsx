// Portfolio — the returning tester's hub: what you hold, and one-click ways to do the things you do
// again and again (claim a Payout, buy/stake/open/supply). Actions that are cheap to do here happen
// here; heavier flows link out.
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Address } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { usePortfolio } from "./usePortfolio";
import { NET, ADDR, TIERS, flows, reads, fmt, niceError } from "./live";

export function PortfolioPage() {
  const w = useWallet();
  const { portfolio: p, connected, refresh } = usePortfolio();
  useEffect(() => { document.title = "Portfolio · Essey"; }, []);
  const a = w.address as Address | null;
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [floor, setFloor] = useState<{ floor: bigint; reserve: bigint; backed: bigint } | null>(null);
  useEffect(() => { reads.donFloor().then(setFloor).catch(() => {}); }, []);

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
          <p>Everything you hold on testnet — balances, Dons and their Tiers, the Payouts sitting in each
            Vault, and the stock you've drawn from Cases. Come back here to do it all again.</p>
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
              <Link className="pf-quick-btn" to="/market">⬡ Buy a Don</Link>
              <Link className="pf-quick-btn" to="/bell">🔔 Stake / Ring</Link>
              <Link className="pf-quick-btn" to="/cases">🎁 Open a Case</Link>
              <Link className="pf-quick-btn" to="/lend">⚖ Supply</Link>
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
                  <div className="pf-note" style={{ marginBottom: 10 }}>🛡 <b>Every Don has a hard floor.</b> Redeem one for <b>≥ {fmt(floor.floor, 2)} $ESSEY</b> from the reserve, anytime — that's the reserve ({fmt(floor.reserve, 0)} $ESSEY) split across the {floor.backed.toString()} Dons it backs, and it only ever rises. Redeeming <b>locks the Don</b> and forfeits its membership and Vault.</div>
                )}
                <div className="pf-seats">
                  {p.dons.map((s) => (
                    <div className="pf-seat" key={s.id.toString()}>
                      <div className="pf-seat-top">
                        <span className="pf-seat-id num">Don #{s.id.toString()}</span>
                        <span className={"pf-tier" + (s.tier > 0 ? " on" : "")}>{s.tier === 0 ? "Base" : (TIERS[s.tier - 1]?.name ?? `Tier ${s.tier}`)}</span>
                        {s.locked && <span className="pf-tier on" title="This Don's traits are frozen forever — staking locks the art.">🔒 art locked</span>}
                        {s.liened && <span className="pf-tier on" title="Pledged as loan collateral — it stays in your wallet, staked and earning, but can't move until the debt clears.">📜 collateralized — still earning</span>}
                      </div>
                      <div className="pf-seat-row num">
                        <span>ready to claim: <b>{fmt(s.pending, 4)}</b> USDG</span>
                        <span>Vault holds <b>{fmt(s.vaultUsdg, 4)}</b> USDG
                          {(s.vaultAapl > 0n || s.vaultNvda > 0n) && (
                            <> · <b>{s.vaultAapl > 0n && `${fmt(s.vaultAapl, 2)} AAPL`}{s.vaultAapl > 0n && s.vaultNvda > 0n ? " · " : ""}{s.vaultNvda > 0n && `${fmt(s.vaultNvda, 2)} NVDA`}</b> in stock</>
                          )}
                        </span>
                        {s.liened && <span>loan debt: <b>{fmt(s.debt, 2)}</b> $ESSEY</span>}
                      </div>
                      <div className="pf-seat-actions">
                        <a className="pf-link" href={`${NET.explorer}/token/${ADDR.don}?a=${s.id}`} target="_blank" rel="noreferrer">Don ↗</a>
                        <a className="pf-link" href={`${NET.explorer}/address/${s.vault}`} target="_blank" rel="noreferrer">Vault ↗</a>
                        {s.pending > 0n
                          ? <button className="pf-link gold pf-inline-btn" disabled={busy === "claim" + s.id} onClick={() => a && run("claim" + s.id, () => flows.claimPayout(a, s.id), `✓ Payout claimed into Don #${s.id}'s Vault`)}>{busy === "claim" + s.id ? "claiming…" : "claim now"}</button>
                          : s.tier === 0 ? <Link className="pf-link gold" to="/bell">stake →</Link>
                          : <Link className="pf-link" to="/bell">upgrade →</Link>}
                        {floor && floor.floor > 0n && !s.liened && (
                          <button className="pf-link pf-inline-btn" disabled={!!busy} title="Redeem this Don for its $ESSEY floor. This locks the Don and forfeits its membership and Vault."
                            onClick={() => a && run("redeem" + s.id, () => flows.redeemDonFloor(a, s.id), `✓ Don #${s.id} redeemed for ${fmt(floor.floor, 2)} $ESSEY — membership forfeited.`)}>
                            {busy === "redeem" + s.id ? "redeeming…" : `redeem ↓ ${fmt(floor.floor, 2)} $ESSEY`}
                          </button>
                        )}
                      </div>
                    </div>
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
                  : <span className="pf-note">not supplying yet — supply USDG to earn {p.pool.supplyApy.toFixed(2)}% APY →</span>}
                {p.loans.length === 0
                  ? <span className="pf-note">no open loans{p.wins.aapl > 0n || p.wins.nvda > 0n ? " — you hold stock (borrowing against it is coming to testnet)" : ""}.</span>
                  : p.loans.map((l) => <span className="pf-lend-item" key={l.id.toString()}>Loan #{l.id.toString()} · owe <b>{fmt(l.debt, 2)}</b> USDG</span>)}
              </div>
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
                  <span className="pf-note">real testnet stock tokens — held in your wallet; borrow against them on <Link to="/lend">Lend</Link>.</span>
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
