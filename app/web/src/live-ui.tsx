// Live testnet UI: the live Exchange and the Bell. Everything here talks to the REAL deployed
// Dons contracts on 46630 — labeled TESTNET throughout, play money only.
import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Address } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { ADDR, BUNDLE, MAX_DONS, NET, TIERS, flows, reads, fmt, niceError } from "./live";

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

/// The live Exchange: real float, real fees feeding the real pot.
export function LiveExchange() {
  const w = useWallet();
  const { bal, refresh } = useBalances();
  const [float_, setFloat] = useState<bigint | null>(null);
  const [ids, setIds] = useState<bigint[]>([]);
  const [quote, setQuote] = useState<Quote | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [snipeId, setSnipeId] = useState("");
  const [sellId, setSellId] = useState("");
  const [adv, setAdv] = useState(false); // "More options" (snipe / sell) collapsed by default

  const load = useCallback(() => {
    reads.floatCount().then(setFloat).catch(() => {});
    reads.floatIds().then(setIds).catch(() => {});
    reads.quote().then(setQuote).catch(() => {});
  }, []);
  useEffect(() => { load(); const t = setInterval(load, 15_000); return () => clearInterval(t); }, [load]);

  const act = async (label: string, fn: () => Promise<unknown>, ok: string) => {
    setBusy(label); setMsg(null);
    try { await fn(); setMsg(ok); load(); refresh(); }
    catch (e) { setMsg(niceError(e)); }
    finally { setBusy(null); }
  };

  const a = w.address as Address | null;
  const ready = !!a && w.chainOk;
  const short = !!bal && !!quote && bal.essey < quote.buyTotal;

  return (
    <section className="band" style={{ paddingTop: 0 }}>
      <div className="wrap">
        <div className="live-card">
          <div className="live-h">BUY A DON <span className="preview-chip">testnet</span></div>
          <p className="ex-intro">A <b>Don</b> is your seat at the table — 1 of only {MAX_DONS.toLocaleString()}. Own one and <b>stake a Tier
            at the Bell</b> to earn a cut of every fee the club collects — trades, Cases, loan interest. (Owning holds
            your spot; staking is what earns.)</p>
          <div className="ex-stats num">
            <span><b>{float_ !== null ? float_.toString() : "…"}</b> Dons available</span>
            <span className="ex-price"><b>{quote ? fmt(quote.price) : "…"}</b> $ESSEY <i>+ {quote ? fmt(quote.buyFee) : "…"} $ESSEY fee (8%)</i></span>
            {bal && <span>you own <b>{bal.dons.toString()}</b></span>}
          </div>

          {!ready ? (
            <div className="live-row"><span className="live-note">Connect on Robinhood Chain testnet to buy a Don.</span><ConnectButton /></div>
          ) : (
            <>
              {/* the one obvious action */}
              <button className="btn btn-gold ex-buy"
                disabled={!!busy || float_ === 0n || !quote || short}
                onClick={() => act("buy", () => flows.buyDon(a!).then(({ id }) => setMsg(`✓ Don #${id} is yours! Your fee just fed the club. Next: stake a Tier at the Bell to start earning.`)), "✓ Don purchased")}>
                {busy === "buy" ? "buying your Don…"
                  : float_ === 0n ? "No Dons for sale right now"
                  : short ? "Need more $ESSEY — top up on the Faucet"
                  : quote ? `Buy a Don  ·  ${fmt(quote.buyTotal)} $ESSEY all-in` : "quoting…"}
              </button>
              {float_ === 0n && <div className="live-note ex-help">Every Don is held right now — check back, or watch the <Link to="/tape">Tape</Link> for one returning to the Exchange (holders can sell back anytime).</div>}
              <div className="live-note ex-help">You'll get the next available Don. The price is the <b>live floor</b> (never below 300,000 $ESSEY) plus the 8% fee — the total above includes ~1% headroom in case the floor rises mid-trade; you're only ever charged the on-chain quote. Need funds? Grab them on the <Link to="/faucet">Faucet</Link> page.</div>
              <div className="live-note ex-help">🛡 Every Don has a hard <b>$ESSEY floor</b> — redeem it for its share of the reserve anytime (see <Link to="/portfolio">Portfolio</Link>). The floor only ever rises.</div>

              {/* advanced, hidden by default */}
              <button className="ex-more" onClick={() => setAdv((v) => !v)}>
                {adv ? "▾  Hide options" : "▸  More options — pick an exact Don, or sell one"}
              </button>
              {adv && (
                <div className="ex-adv">
                  <div className="ex-adv-block">
                    <div className="ex-adv-h">Pick an exact Don number</div>
                    <div className="ex-adv-row">
                      <input className="num ex-input" type="text" inputMode="numeric" placeholder="Don #" value={snipeId}
                        onChange={(e) => setSnipeId(e.target.value.replace(/\D/g, ""))} aria-label="Don number to buy" />
                      <button className="btn btn-ghost" disabled={!!busy || !snipeId || !quote}
                        onClick={() => act("snipe", () => flows.snipeDon(a!, BigInt(snipeId)), `✓ Don #${snipeId} is yours`)}>
                        {busy === "snipe" ? "buying…" : `Buy #${snipeId || "?"} · ${quote ? fmt(quote.snipeTotal) : "…"} $ESSEY (12% fee)`}
                      </button>
                    </div>
                    {ids.length > 0 && <div className="live-note num">available now: {ids.map((i) => `#${i}`).join(", ")}{float_ !== null && float_ > 12n ? ", …" : ""}</div>}
                  </div>
                  <div className="ex-adv-block">
                    <div className="ex-adv-h">Sell a Don you own</div>
                    <div className="ex-adv-row">
                      <input className="num ex-input" type="text" inputMode="numeric" placeholder="your Don #" value={sellId}
                        onChange={(e) => setSellId(e.target.value.replace(/\D/g, ""))} aria-label="Don number to sell" />
                      <button className="btn btn-ghost" disabled={!!busy || !sellId || !quote}
                        onClick={() => act("sell", () => flows.sellDon(a!, BigInt(sellId)), `✓ sold #${sellId} back for ~${quote ? fmt(quote.sellNet) : "…"} $ESSEY`)}>
                        {busy === "sell" ? "selling…" : `Sell back · get ~${quote ? fmt(quote.sellNet) : "…"} $ESSEY`}
                      </button>
                    </div>
                    <div className="live-note">Returns a Don to the Exchange at the live price minus the 8% fee. Your Don numbers are on the Portfolio tab.</div>
                  </div>
                </div>
              )}
              {busy && <div className="live-note ex-help">This can take a couple of wallet confirmations — your wallet will walk you through each one.</div>}
              {msg && <div className="live-msg">{msg}</div>}
            </>
          )}
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
            rings the Bell and it splits across staked Dons · <b>3.</b> claim your share — it lands in your
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
                      const label = t.tier === owned ? "current" : t.tier < owned ? "—" : owned === 0 ? "Stake" : "Upgrade";
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
                    ? <>🔒 This Don's art is <b>locked</b> — its look is permanent.</>
                    : <>Heads up: activating a Don <b>locks its art permanently</b> — reroll or customize it on the <Link to="/builder">Builder</Link> first if you want a different look.</>}
                    {state.liened && <> · 📜 <b>collateralized</b> on a loan — still staked, still earning; it just can't move until the debt clears.</>}</div>
                </div>

                {/* Step 2 — ring */}
                <div className="live-card bell-step">
                  <div className="bell-step-h"><span className="bell-step-n">2</span> Ring the Bell
                    <span className="bell-step-cur num">pot: {pot !== null ? fmt(pot, 2) : "…"} USDG</span></div>
                  <div className="live-note">When the pot's worth it, <b>anyone</b> can ring it — ringing costs only gas and pays the ringer nothing; the whole pot splits across all staked Dons (by tier). The pot grows from trades, Cases, and loan interest.</div>
                  <button className="btn btn-gold" disabled={!!busy || (pot ?? 0n) === 0n}
                    onClick={() => act("ring", () => flows.ringBell(a!), "✓ rung — the pot split across staked Dons")}>
                    {busy === "ring" ? "ringing…" : (pot ?? 0n) === 0n ? "Pot is empty — grow it first" : "Ring the Bell"}
                  </button>
                  {(pot ?? 0n) === 0n && <div className="live-note"><Link to="/market">→ Trade on the Exchange</Link> or open a <Link to="/cases">Case</Link> to grow the pot, then come back to ring.</div>}
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
                    )} — it travels with the Don if you ever sell it.</div>
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
