// Live testnet UI: the live Exchange and the Bell. Everything here talks to the REAL deployed
// Dons contracts on 46630 — labeled TESTNET throughout, play money only.
import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Address } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { ADDR, BUNDLE, MAX_DONS, NET, TIERS, flows, reads, fmt, niceError } from "./live";
import { EMonogram } from "./market";

const ZERO = "0x0000000000000000000000000000000000000000";
// Stock payouts light up once the converter is wired at the redeploy; until then claims pay USDG and
// the payout selector stays hidden (no half-working UI pointing at a converter that isn't there).
const CONVERTER_LIVE = ADDR.converter.toLowerCase() !== ZERO;

// Which payout bucket a Don's first elected stock maps to (unset / BUNDLE both mean the default basket).
function prefKey(pref: Address | null): "Bundle" | "AAPL" | "NVDA" {
  const p = (pref ?? ZERO).toLowerCase();
  if (p === ADDR.aapl.toLowerCase()) return "AAPL";
  if (p === ADDR.nvda.toLowerCase()) return "NVDA";
  return "Bundle";
}

export function TestnetBanner() {
  return (
    <div className="testnet-banner num">
      TESTNET · live contracts on Robinhood Chain testnet · play money, real mechanics ·{" "}
      <a href={`${NET.explorer}/address/${ADDR.don}`} target="_blank" rel="noreferrer">verify ↗</a>
    </div>
  );
}

function useBalances() {
  const w = useWallet();
  const [bal, setBal] = useState<{ essey: bigint; usdg: bigint; dons: bigint } | null>(null);
  const refresh = useCallback(() => {
    if (!w.address) return;
    reads.balances(w.address as Address).then(setBal).catch(() => {});
  }, [w.address]);
  useEffect(() => { refresh(); }, [refresh]);
  return { bal, refresh };
}

type Quote = Awaited<ReturnType<typeof reads.quote>>;
type OwnedDon = { id: bigint; liened: boolean; locked: boolean };

/// One Don's face for the AMM grids. The branded hexagon placeholder sits BEHIND the image, so an
/// art-less pool Don (or the dev server, which doesn't run /api) degrades to an intentional plate —
/// never a broken-image glyph. The image endpoint itself already serves a branded SVG for unrevealed
/// Dons, so both the missing-endpoint and the unrevealed cases read as deliberate.
function DonThumb({ id }: { id: bigint }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => { setFailed(false); }, [id]);
  return (
    <div className="amm-thumb">
      <div className="amm-ph" aria-hidden><EMonogram size={40} /><span className="num">#{id.toString()}</span></div>
      {!failed && (
        <img className="amm-img" src={`/api/don-img/${id}`} alt={`Don #${id}`} loading="lazy" decoding="async"
          onError={() => setFailed(true)} />
      )}
    </div>
  );
}

/// The live Exchange, sudoswap-style: SEE the Dons in the pool (Buy) or in your wallet (Sell), click one,
/// confirm. Real float, real fees feeding the real pot. The two buy paths are made explicit — buy the next
/// Don at 8%, or snipe an exact one at the 12% premium — so the trade-off is never hidden behind a click.
export function LiveExchange() {
  const w = useWallet();
  const { bal, refresh } = useBalances();
  const [tab, setTab] = useState<"buy" | "sell">("buy");
  const [float_, setFloat] = useState<bigint | null>(null);
  const [poolIds, setPoolIds] = useState<bigint[] | null>(null);
  const [owned, setOwned] = useState<OwnedDon[] | null>(null);
  const [quote, setQuote] = useState<Quote | null>(null);
  const [pick, setPick] = useState<bigint | null>(null);   // selected pool Don → snipe confirm
  const [sellPick, setSellPick] = useState<bigint | null>(null); // selected owned Don → sell confirm
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  const a = w.address as Address | null;
  const ready = !!a && w.chainOk;

  const loadPool = useCallback(() => {
    reads.floatCount().then(setFloat).catch(() => {});
    reads.quote().then(setQuote).catch(() => {});
    reads.poolIds().then(setPoolIds).catch(() => setPoolIds([]));
  }, []);
  const loadOwned = useCallback(() => {
    if (!a) { setOwned(null); return; }
    reads.ownedDonsFlagged(a).then(setOwned).catch(() => setOwned([]));
  }, [a]);

  useEffect(() => { loadPool(); const t = setInterval(loadPool, 15_000); return () => clearInterval(t); }, [loadPool]);
  useEffect(() => { loadOwned(); }, [loadOwned]);

  const act = async (label: string, fn: () => Promise<unknown>, ok: string) => {
    setBusy(label); setMsg(null);
    try { await fn(); setMsg(ok); loadPool(); loadOwned(); refresh(); }
    catch (e) { setMsg(niceError(e)); }
    finally { setBusy(null); }
  };

  const shortBuy = !!bal && !!quote && bal.essey < quote.buyTotal;
  const shortSnipe = !!bal && !!quote && bal.essey < quote.snipeTotal;
  const sellDon = owned?.find((d) => d.id === sellPick) ?? null;

  return (
    <section className="band" id="trade" style={{ paddingTop: 0 }}>
      <div className="wrap">
        {/* A real, titled section header so the visual swap announces itself as THE Exchange — the live
            trading desk, not a widget. (The cards further down the page are no-wallet SANDBOXES; this is
            the real thing, and the heading makes that unmistakable on load.) */}
        <div className="band-head amm-head"><div>
          <span className="eyebrow">The Exchange · live</span>
          <h2>Trade Dons: see them, click one, done</h2>
          <p>The live Don AMM, on-chain right now. Buy the next Don off the shelf at 8%, snipe an exact # at
            12%, or sell one back. Every price is the reserve floor, read fresh. No wallet needed to browse
            the pool below.</p>
        </div></div>
        <div className="live-card amm">
          <div className="live-h">TRADE DONS <span className="preview-chip">testnet</span></div>

          {/* live desk header — pool size + floor price + your position */}
          <div className="ex-stats num amm-stats">
            <span><b>{float_ !== null ? float_.toString() : "…"}</b> in the pool</span>
            <span className="ex-price"><b>{quote ? fmt(quote.price) : "…"}</b> $ESSEY <i>live floor</i></span>
            <span>next at 8% <b>{quote ? fmt(quote.buyTotal) : "…"}</b> · snipe at 12% <b>{quote ? fmt(quote.snipeTotal) : "…"}</b></span>
            {bal && <span>you own <b>{bal.dons.toString()}</b></span>}
          </div>

          {/* buy / sell toggle */}
          <div className="seg amm-toggle" role="tablist">
            <button role="tab" aria-selected={tab === "buy"} onClick={() => { setTab("buy"); setSellPick(null); }}>Buy from pool</button>
            <button role="tab" aria-selected={tab === "sell"} onClick={() => { setTab("sell"); setPick(null); }}>Sell yours</button>
          </div>

          {tab === "buy" && (
            <>
              {/* the low-fee path, always visible and distinct from a snipe */}
              <div className="amm-next">
                <div className="amm-next-copy">
                  <b>Buy the next Don</b>
                  <span className="live-note">Takes whichever Don is next off the shelf, the cheapest way in at the <b>8%</b> fee. Don't care which #? Use this.</span>
                </div>
                {!ready ? <ConnectButton />
                  : shortBuy ? (
                    /* Short on $ESSEY: send them to the Faucet instead of a dead disabled button. A
                       "Need more $ESSEY" button that does nothing on click reads as broken (it was). */
                    <Link className="btn btn-gold amm-next-btn" to="/faucet">Get $ESSEY on the Faucet →</Link>
                  ) : (
                    <button className="btn btn-gold amm-next-btn" disabled={!!busy || float_ === 0n || !quote}
                      onClick={() => act("buy", () => flows.buyDon(a!).then(({ id }) => setMsg(`✓ Don #${id} is yours. Next: take him to the Game — the desk is waiting.`)), "✓ Don purchased")}>
                      {busy === "buy" ? "buying…"
                        : float_ === 0n ? "Pool is empty"
                        : quote ? `Buy next · ${fmt(quote.buyTotal)} $ESSEY` : "quoting…"}
                    </button>
                  )}
              </div>

              {/* snipe-confirm for the clicked Don */}
              {pick !== null && (
                <div className="amm-confirm">
                  <DonThumb id={pick} />
                  <div className="amm-confirm-body">
                    <div className="amm-confirm-h">Snipe Don #{pick.toString()} <span className="amm-fee-pill">12% premium</span></div>
                    <div className="amm-confirm-sub num">{quote ? fmt(quote.price) : "…"} + 12% fee ({quote ? fmt(quote.snipeFee) : "…"}) = <b>{quote ? fmt(quote.snipeTotal) : "…"} $ESSEY</b></div>
                    <div className="live-note">Picking an <b>exact</b> Don pays the 12% snipe fee, {quote ? fmt(quote.snipeFee - quote.buyFee) : "…"} $ESSEY more than buying the next one at 8%. Same live floor either way.</div>
                  </div>
                  <div className="amm-confirm-act">
                    {!ready ? <ConnectButton />
                      : shortSnipe ? (
                        <Link className="btn btn-gold" to="/faucet">Get $ESSEY on the Faucet →</Link>
                      ) : (
                        <button className="btn btn-gold" disabled={!!busy || !quote}
                          onClick={() => act("snipe", () => flows.snipeDon(a!, pick).then(() => { setMsg(`✓ Don #${pick} is yours. Take him to the Game — the desk is waiting.`); setPick(null); }), "✓ sniped")}>
                          {busy === "snipe" ? "sniping…" : `Confirm snipe · ${quote ? fmt(quote.snipeTotal) : "…"}`}
                        </button>
                      )}
                    <button className="btn btn-ghost" onClick={() => setPick(null)}>Cancel</button>
                  </div>
                </div>
              )}

              {/* the pool, as faces */}
              {poolIds === null ? (
                <div className="amm-empty live-note">Reading the pool…</div>
              ) : poolIds.length === 0 ? (
                <div className="amm-empty live-note">Every Don is held right now. Nothing on the shelf. Watch the <Link to="/tape">Tape</Link> for one returning (holders can sell back anytime).</div>
              ) : (
                <>
                  <div className="amm-grid-h live-note">Tap a Don to snipe that exact # (12%){float_ !== null && poolIds.length < Number(float_) ? ` · showing ${poolIds.length} of ${float_.toString()}` : ""}</div>
                  <div className="amm-grid">
                    {poolIds.map((id) => (
                      <button key={id.toString()} className={"amm-card" + (pick === id ? " on" : "")}
                        onClick={() => { setPick(id); setMsg(null); }} aria-pressed={pick === id}>
                        <DonThumb id={id} />
                        <span className="amm-id num">#{id.toString()}</span>
                        <span className="amm-price num">{quote ? fmt(quote.snipeTotal) : "…"}</span>
                      </button>
                    ))}
                  </div>
                </>
              )}

              <div className="live-note ex-help">🛡 Every Don carries a hard <b>$ESSEY floor</b>: redeem it for its share of the reserve anytime (see <Link to="/portfolio">Portfolio</Link>). The floor only ever rises. Totals carry ~1% slippage headroom; you're only charged the on-chain quote. Need funds? <Link to="/faucet">Faucet →</Link></div>
            </>
          )}

          {tab === "sell" && (
            !ready ? (
              <div className="amm-empty">
                <div className="live-note" style={{ marginBottom: 10 }}>Connect on Robinhood Chain testnet to see your Dons and sell one back.</div>
                <ConnectButton />
              </div>
            ) : owned === null ? (
              <div className="amm-empty live-note">Reading your Dons…</div>
            ) : owned.length === 0 ? (
              <div className="amm-empty live-note">You don't own a Don yet. <button className="linklike" onClick={() => setTab("buy")}>Buy one from the pool →</button></div>
            ) : (
              <>
                {sellPick !== null && sellDon && (
                  <div className="amm-confirm">
                    <DonThumb id={sellPick} />
                    <div className="amm-confirm-body">
                      <div className="amm-confirm-h">Sell Don #{sellPick.toString()} <span className="amm-fee-pill">−8% fee</span></div>
                      <div className="amm-confirm-sub num">receive <b>{quote ? fmt(quote.sellNet) : "…"} $ESSEY</b> <i>({quote ? fmt(quote.price) : "…"} floor − 8%)</i></div>
                      <div className="live-note">Returns the Don to the pool at the live floor minus the 8% fee. Its Vault contents travel with it, so <b>claim and empty the Vault first</b> (see <Link to="/portfolio">Portfolio</Link>).</div>
                    </div>
                    <div className="amm-confirm-act">
                      <button className="btn btn-gold" disabled={!!busy || !quote}
                        onClick={() => act("sell", () => flows.sellDon(a!, sellPick).then(() => { setMsg(`✓ sold Don #${sellPick} back for ~${quote ? fmt(quote.sellNet) : ""} $ESSEY`); setSellPick(null); }), "✓ sold")}>
                        {busy === "sell" ? "selling…" : `Confirm sell · get ~${quote ? fmt(quote.sellNet) : "…"}`}
                      </button>
                      <button className="btn btn-ghost" onClick={() => setSellPick(null)}>Cancel</button>
                    </div>
                  </div>
                )}
                <div className="amm-grid-h live-note">Tap one of your Dons to sell it back at the live floor −8%.</div>
                <div className="amm-grid">
                  {owned.map((d) => (
                    <button key={d.id.toString()} className={"amm-card" + (sellPick === d.id ? " on" : "") + (d.liened ? " amm-card-off" : "")}
                      disabled={d.liened} aria-pressed={sellPick === d.id}
                      title={d.liened ? "Loan collateral: repay the loan to unlock" : undefined}
                      onClick={() => { if (!d.liened) { setSellPick(d.id); setMsg(null); } }}>
                      <DonThumb id={d.id} />
                      <span className="amm-id num">#{d.id.toString()}</span>
                      {d.liened
                        ? <span className="amm-badge amm-badge-lien">📜 liened</span>
                        : d.locked
                          ? <span className="amm-badge">🔒 staked</span>
                          : <span className="amm-price num">{quote ? fmt(quote.sellNet) : "…"}</span>}
                    </button>
                  ))}
                </div>
                <div className="live-note ex-help">A <b>liened</b> Don is loan collateral. Repay the loan (Portfolio) to unlock it before selling. A <b>staked</b> Don sells fine; its Bell tier just clears on transfer.</div>
              </>
            )
          )}

          {busy && <div className="live-note ex-help">This can take a couple of wallet confirmations. Your wallet will walk you through each one.</div>}
          {msg && <div className="live-msg">{msg}</div>}
        </div>
      </div>
    </section>
  );
}

// The payout-mix editor's three electable targets (all converter-supported, incl. the BUNDLE sentinel).
const MIX_TOKENS: { key: string; addr: Address }[] = [
  { key: "Bundle", addr: BUNDLE }, { key: "AAPL", addr: ADDR.aapl }, { key: "NVDA", addr: ADDR.nvda },
];

// The Bell — the full loop: stake a Tier on a Don you own, ring when the pot's ready, claim the
// Payout into that Don's Vault. All live on testnet.
export function LiveBell() {
  const w = useWallet();
  const a = w.address as Address | null;
  const ready = !!a && w.chainOk;
  const [pot, setPot] = useState<bigint | null>(null);
  const [dons, setDons] = useState<bigint[]>([]);
  const [sel, setSel] = useState<bigint | null>(null);
  const [state, setState] = useState<{ tier: number; pending: bigint; vault: Address; locked: boolean; liened: boolean } | null>(null);
  const [vaultBal, setVaultBal] = useState<bigint | null>(null);
  const [vaultStock, setVaultStock] = useState<{ aapl: bigint; nvda: bigint } | null>(null);
  const [pref, setPref] = useState<Address | null>(null);
  const [mixOpen, setMixOpen] = useState(false);
  const [mixPct, setMixPct] = useState<Record<string, string>>({}); // token key -> whole-percent string
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  const loadPot = useCallback(() => { reads.pot().then(setPot).catch(() => {}); }, []);
  const loadDons = useCallback(() => {
    if (!a) return;
    reads.ownedDons(a).then((ids) => { setDons(ids); setSel((s) => s ?? ids[0] ?? null); }).catch(() => {});
  }, [a]);
  const loadSel = useCallback(() => {
    if (sel === null) { setState(null); return; }
    reads.donState(sel).then(async (st) => {
      setState(st);
      setVaultBal(await reads.vaultBalance(st.vault));
      setVaultStock(await reads.vaultStocks(st.vault));
    }).catch(() => {});
    if (CONVERTER_LIVE) reads.payoutPref(sel).then(setPref).catch(() => {});
  }, [sel]);

  useEffect(() => { loadPot(); const t = setInterval(loadPot, 15_000); return () => clearInterval(t); }, [loadPot]);
  useEffect(() => { loadDons(); }, [loadDons]);
  useEffect(() => { loadSel(); }, [loadSel]);

  const act = async (label: string, fn: () => Promise<unknown>, ok: string) => {
    setBusy(label); setMsg(null);
    try { await fn(); setMsg(ok); loadPot(); loadSel(); loadDons(); }
    catch (e) { setMsg(niceError(e)); }
    finally { setBusy(null); }
  };

  const applyMix = () => {
    const picked = MIX_TOKENS
      .map((t) => ({ token: t.addr, key: t.key, pct: Number(mixPct[t.key] || "0") }))
      .filter((t) => t.pct > 0);
    return act("pref", () => flows.setPayoutMix(a!, sel!, picked.map((t) => ({ token: t.token, bps: t.pct * 100 }))),
      `✓ Payouts now split ${picked.map((t) => `${t.pct}% ${t.key}`).join(" · ")}`);
  };

  return (
    <section className="band" id="bell">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The Bell</span>
          <h2>How you get paid</h2>
          <p>Three steps: <b>1.</b> stake your Don to join the payout · <b>2.</b> when the pot fills, anyone
            rings the Bell and it splits across staked Dons · <b>3.</b> claim your share, and it lands in your
            Don's Vault as real stock.</p>
        </div>
          <span className="preview-chip live">testnet</span>
        </div>

        {!ready ? (
          <div className="live-card"><div className="live-row"><span className="live-note">Connect on Robinhood Chain testnet to stake and get paid.</span><ConnectButton /></div></div>
        ) : dons.length === 0 ? (
          <div className="live-card"><div className="live-note">You need a Don first. <Link to="/market">Buy one on the Exchange →</Link> then come back to stake it and start earning.</div></div>
        ) : (
          <>
            {dons.length > 1 && (
              <div className="bell-seat-pick">
                <span className="live-note">Choose your Don:</span>
                {dons.map((id) => (
                  <button key={id.toString()} className={"seat-pill num" + (sel === id ? " on" : "")} onClick={() => setSel(id)}>#{id.toString()}</button>
                ))}
              </div>
            )}

            {state && (
              <>
                {/* Step 1 — stake */}
                <div className="live-card bell-step">
                  <div className="bell-step-h"><span className="bell-step-n">1</span> Stake your Don
                    <span className="bell-step-cur">{state.tier === 0 ? "not staked yet" : `staked · ${TIERS[state.tier - 1]?.name ?? `Tier ${state.tier}`}`}</span></div>
                  <div className="live-note">Stake $ESSEY on Don #{sel?.toString()} to start earning from every payout. Higher tier = a bigger share. Half of every stake burns, half funds the treasury. Pick a level:</div>
                  <div className="tier-buttons">
                    {TIERS.map((t) => {
                      const owned = state.tier;
                      const disabled = !!busy || t.tier <= owned;
                      const label = t.tier === owned ? "current" : t.tier < owned ? "n/a" : owned === 0 ? "Stake" : "Upgrade";
                      return (
                        <button key={t.tier} className={"tier-btn" + (t.tier === owned ? " on" : "")} disabled={disabled}
                          onClick={() => act("tier", () => flows.setTier(a!, sel!, t.tier), `✓ Don #${sel} is now ${t.name}`)}>
                          <b>{t.name}</b>
                          <i className="num">{(t.weight / 100).toFixed(2)}× share · {fmt(t.fee)} $ESSEY</i>
                          <span>{busy === "tier" ? "…" : label}</span>
                        </button>
                      );
                    })}
                  </div>
                  <div className="live-note">{state.locked
                    ? <>🔒 This Don's art is <b>locked</b>. Its look is permanent.</>
                    : <>Heads up: activating a Don <b>locks its art permanently</b>. Reroll or customize it on the <Link to="/builder">Builder</Link> first if you want a different look.</>}
                    {state.liened && <> · 📜 <b>collateralized</b> on a loan. Still staked, still earning; it just can't move until the debt clears.</>}</div>
                </div>

                {/* Step 2 — ring */}
                <div className="live-card bell-step">
                  <div className="bell-step-h"><span className="bell-step-n">2</span> Ring the Bell
                    <span className="bell-step-cur num">pot: {pot !== null ? fmt(pot, 2) : "…"} USDG</span></div>
                  <div className="live-note">When the pot's worth it, <b>anyone</b> can ring it. Ringing costs only gas and pays the ringer nothing; the whole pot splits across all staked Dons (by tier). The pot grows from protocol fees: trades and loan interest.</div>
                  <button className="btn btn-gold" disabled={!!busy || (pot ?? 0n) === 0n}
                    onClick={() => act("ring", () => flows.ringBell(a!), "✓ rung. The pot split across staked Dons")}>
                    {busy === "ring" ? "ringing…" : (pot ?? 0n) === 0n ? "Pot is empty, grow it first" : "Ring the Bell"}
                  </button>
                  {(pot ?? 0n) === 0n && <div className="live-note"><Link to="/market">→ Trade on the Exchange</Link> to grow the pot, then come back to ring.</div>}
                </div>

                {/* Step 3 — claim */}
                <div className="live-card bell-step">
                  <div className="bell-step-h"><span className="bell-step-n">3</span> Claim your payout
                    <span className="bell-step-cur num">yours: {fmt(state.pending, 4)} {CONVERTER_LIVE ? "→ stock" : "USDG"}</span></div>
                  {CONVERTER_LIVE && (
                    <div className="payout-pref">
                      <span className="pp-label">Get paid in</span>
                      {(["Bundle", "AAPL", "NVDA"] as const).map((k) => (
                        <button key={k} className={"pp-btn" + (!mixOpen && prefKey(pref) === k ? " on" : "")} disabled={!!busy}
                          onClick={() => act("pref", () => flows.setPayoutToken(a!, sel!, k === "Bundle" ? BUNDLE : k === "AAPL" ? ADDR.aapl : ADDR.nvda), `✓ Payouts now delivered in ${k}`)}>
                          {busy === "pref" ? "…" : k}
                        </button>
                      ))}
                      <button className={"pp-btn" + (mixOpen ? " on" : "")} disabled={!!busy} onClick={() => setMixOpen((v) => !v)}>Mix…</button>
                      <span className="live-note pp-note">the AAPL+NVDA basket by default · lands as real stock in your Vault · USDG if the market's closed</span>
                    </div>
                  )}
                  {CONVERTER_LIVE && mixOpen && (
                    <div className="payout-pref">
                      <span className="pp-label">Split across up to 3 (must total 100%)</span>
                      {MIX_TOKENS.map((t) => (
                        <label key={t.key} className="live-note num" style={{ display: "inline-flex", alignItems: "center", gap: 4 }}>
                          {t.key}
                          <input className="num ex-input" style={{ width: 56 }} type="text" inputMode="numeric" placeholder="0"
                            value={mixPct[t.key] ?? ""} aria-label={`${t.key} percent`}
                            onChange={(e) => setMixPct((m) => ({ ...m, [t.key]: e.target.value.replace(/\D/g, "") }))} />%
                        </label>
                      ))}
                      <button className="btn btn-ghost" disabled={!!busy} onClick={applyMix}>
                        {busy === "pref" ? "…" : "Apply split"}
                      </button>
                    </div>
                  )}
                  <div className="live-row">
                    <button className="btn btn-gold" disabled={!!busy || state.pending === 0n}
                      onClick={() => act("claim", () => flows.claimPayout(a!, sel!), `✓ Payout claimed into Don #${sel}'s Vault`)}>
                      {busy === "claim" ? "claiming…" : state.pending === 0n ? "nothing to claim yet"
                        : CONVERTER_LIVE ? `Claim ${fmt(state.pending, 4)} as ${prefKey(pref)}`
                        : `Claim ${fmt(state.pending, 4)} USDG`}
                    </button>
                    <a className="btn btn-ghost" href={`${NET.explorer}/address/${state.vault}`} target="_blank" rel="noreferrer">view your Vault ↗</a>
                  </div>
                  <div className="live-note num">Your Vault holds {vaultBal !== null ? fmt(vaultBal, 2) : "…"} USDG
                    {vaultStock && (vaultStock.aapl > 0n || vaultStock.nvda > 0n) && (
                      <> · <b>{vaultStock.aapl > 0n && `${fmt(vaultStock.aapl, 2)} AAPL`}{vaultStock.aapl > 0n && vaultStock.nvda > 0n ? " · " : ""}{vaultStock.nvda > 0n && `${fmt(vaultStock.nvda, 2)} NVDA`}</b></>
                    )} and it travels with the Don if you ever sell it.</div>
                </div>
              </>
            )}
            {msg && <div className="live-msg">{msg}</div>}
          </>
        )}
      </div>
    </section>
  );
}
