// Live testnet UI: the faucet, the live Exchange, and the shared banner. Everything here talks to
// the REAL deployed contracts on 46630 — labeled TESTNET throughout, play money only.
import { useCallback, useEffect, useState } from "react";
import type { Address } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { ADDR, BUNDLE, NET, PRICE, TIERS, flows, reads, fmt, niceError } from "./live";

const ZERO = "0x0000000000000000000000000000000000000000";
// Stock payouts light up once the converter is wired at the redeploy; until then claims pay USDG and
// the payout selector stays hidden (no half-working UI pointing at a converter that isn't there).
const CONVERTER_LIVE = ADDR.converter.toLowerCase() !== ZERO;

// Which payout bucket a Seat's stored preference maps to (unset / BUNDLE both mean the default basket).
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
      <a href={`${NET.explorer}/address/${ADDR.seat}`} target="_blank" rel="noreferrer">verify ↗</a>
    </div>
  );
}

function useBalances() {
  const w = useWallet();
  const [bal, setBal] = useState<{ essey: bigint; usdg: bigint; seats: bigint } | null>(null);
  const refresh = useCallback(() => {
    if (!w.address) return;
    reads.balances(w.address as Address).then(setBal).catch(() => {});
  }, [w.address]);
  useEffect(() => { refresh(); }, [refresh]);
  return { bal, refresh };
}

/// The live Exchange: real float, real fees feeding the real pot.
export function LiveExchange() {
  const w = useWallet();
  const { bal, refresh } = useBalances();
  const [float_, setFloat] = useState<bigint | null>(null);
  const [ids, setIds] = useState<bigint[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [snipeId, setSnipeId] = useState("");
  const [sellId, setSellId] = useState("");
  const [adv, setAdv] = useState(false); // "More options" (snipe / sell) collapsed by default

  const load = useCallback(() => {
    reads.floatCount().then(setFloat).catch(() => {});
    reads.floatIds().then(setIds).catch(() => {});
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

  return (
    <section className="band" style={{ paddingTop: 0 }}>
      <div className="wrap">
        <div className="live-card">
          <div className="live-h">BUY A SEAT <span className="preview-chip">testnet</span></div>
          <p className="ex-intro">A <b>Seat</b> is your membership pass. Own one and you earn a cut of every fee the
            club collects — trades, Cases, loan interest. There are only 2,222.</p>
          <div className="ex-stats num">
            <span><b>{float_ !== null ? float_.toString() : "…"}</b> Seats available</span>
            <span className="ex-price"><b>{fmt(PRICE.seat)}</b> $ESSEY <i>+ {fmt(PRICE.swapFee)} USDG fee</i></span>
            {bal && <span>you own <b>{bal.seats.toString()}</b></span>}
          </div>

          {!ready ? (
            <div className="live-row"><span className="live-note">Connect on Robinhood Chain testnet to buy a Seat.</span><ConnectButton /></div>
          ) : (
            <>
              {/* the one obvious action */}
              <button className="btn btn-gold ex-buy" disabled={!!busy}
                onClick={() => act("buy", () => flows.buySeat(a!).then(({ id }) => setMsg(`✓ Seat #${id} is yours! Your fee just fed the Bell's pot.`)), "✓ Seat purchased")}>
                {busy === "buy" ? "buying your Seat…" : `Buy a Seat  ·  ${fmt(PRICE.seat)} $ESSEY + ${fmt(PRICE.swapFee)} USDG`}
              </button>
              <div className="live-note ex-help">You'll get the next available Seat. The first time, your wallet asks to approve
                $ESSEY and USDG — that's normal; just confirm each popup. Need funds? Grab them on the <a href="/start">Quest</a> page.</div>

              {/* advanced, hidden by default */}
              <button className="ex-more" onClick={() => setAdv((v) => !v)}>
                {adv ? "▾  Hide options" : "▸  More options — pick an exact Seat, or sell one"}
              </button>
              {adv && (
                <div className="ex-adv">
                  <div className="ex-adv-block">
                    <div className="ex-adv-h">Pick an exact Seat number</div>
                    <div className="ex-adv-row">
                      <input className="num ex-input" type="text" inputMode="numeric" placeholder="Seat #" value={snipeId}
                        onChange={(e) => setSnipeId(e.target.value.replace(/\D/g, ""))} aria-label="Seat number to buy" />
                      <button className="btn btn-ghost" disabled={!!busy || !snipeId}
                        onClick={() => act("snipe", () => flows.snipeSeat(a!, BigInt(snipeId)), `✓ Seat #${snipeId} is yours`)}>
                        {busy === "snipe" ? "buying…" : `Buy #${snipeId || "?"} · ${fmt(PRICE.snipeFee)} USDG fee`}
                      </button>
                    </div>
                    {ids.length > 0 && <div className="live-note num">available now: {ids.map((i) => `#${i}`).join(", ")}{float_ !== null && float_ > 12n ? ", …" : ""}</div>}
                  </div>
                  <div className="ex-adv-block">
                    <div className="ex-adv-h">Sell a Seat you own</div>
                    <div className="ex-adv-row">
                      <input className="num ex-input" type="text" inputMode="numeric" placeholder="your Seat #" value={sellId}
                        onChange={(e) => setSellId(e.target.value.replace(/\D/g, ""))} aria-label="Seat number to sell" />
                      <button className="btn btn-ghost" disabled={!!busy || !sellId}
                        onClick={() => act("sell", () => flows.sellSeat(a!, BigInt(sellId)), `✓ sold #${sellId} back for ${fmt(PRICE.seat)} $ESSEY`)}>
                        {busy === "sell" ? "selling…" : `Sell back · get ${fmt(PRICE.seat)} $ESSEY`}
                      </button>
                    </div>
                    <div className="live-note">Returns a Seat to the Exchange for {fmt(PRICE.seat)} $ESSEY back. Your Seat numbers are on the Portfolio tab.</div>
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

// The Bell — the full loop: stake a Tier on a Seat you own, ring when the pot's ready, claim the
// Payout into that Seat's Vault. All live on testnet.
export function LiveBell() {
  const w = useWallet();
  const a = w.address as Address | null;
  const ready = !!a && w.chainOk;
  const [pot, setPot] = useState<bigint | null>(null);
  const [seats, setSeats] = useState<bigint[]>([]);
  const [sel, setSel] = useState<bigint | null>(null);
  const [state, setState] = useState<{ tier: number; pending: bigint; vault: Address } | null>(null);
  const [vaultBal, setVaultBal] = useState<bigint | null>(null);
  const [vaultStock, setVaultStock] = useState<{ aapl: bigint; nvda: bigint } | null>(null);
  const [pref, setPref] = useState<Address | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  const loadPot = useCallback(() => { reads.pot().then(setPot).catch(() => {}); }, []);
  const loadSeats = useCallback(() => {
    if (!a) return;
    reads.ownedSeats(a).then((ids) => { setSeats(ids); setSel((s) => s ?? ids[0] ?? null); }).catch(() => {});
  }, [a]);
  const loadSel = useCallback(() => {
    if (sel === null) { setState(null); return; }
    reads.seatState(sel).then(async (st) => {
      setState(st);
      setVaultBal(await reads.vaultBalance(st.vault));
      setVaultStock(await reads.vaultStocks(st.vault));
    }).catch(() => {});
    if (CONVERTER_LIVE) reads.payoutPref(sel).then(setPref).catch(() => {});
  }, [sel]);

  useEffect(() => { loadPot(); const t = setInterval(loadPot, 15_000); return () => clearInterval(t); }, [loadPot]);
  useEffect(() => { loadSeats(); }, [loadSeats]);
  useEffect(() => { loadSel(); }, [loadSel]);

  const act = async (label: string, fn: () => Promise<unknown>, ok: string) => {
    setBusy(label); setMsg(null);
    try { await fn(); setMsg(ok); loadPot(); loadSel(); loadSeats(); }
    catch (e) { setMsg(niceError(e)); }
    finally { setBusy(null); }
  };

  return (
    <section className="band" id="bell">
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The Bell</span>
          <h2>How you get paid</h2>
          <p>Three steps: <b>1.</b> stake your Seat to join the payout · <b>2.</b> when the pot fills, anyone
            rings the Bell and it splits across staked Seats · <b>3.</b> claim your share — it lands in your
            Seat's Vault as real stock.</p>
        </div>
          <span className="preview-chip live">testnet</span>
        </div>

        {!ready ? (
          <div className="live-card"><div className="live-row"><span className="live-note">Connect on Robinhood Chain testnet to stake and get paid.</span><ConnectButton /></div></div>
        ) : seats.length === 0 ? (
          <div className="live-card"><div className="live-note">You need a Seat first. <a href="/market">Buy one on the Exchange →</a> then come back to stake it and start earning.</div></div>
        ) : (
          <>
            {seats.length > 1 && (
              <div className="bell-seat-pick">
                <span className="live-note">Choose your Seat:</span>
                {seats.map((id) => (
                  <button key={id.toString()} className={"seat-pill num" + (sel === id ? " on" : "")} onClick={() => setSel(id)}>#{id.toString()}</button>
                ))}
              </div>
            )}

            {state && (
              <>
                {/* Step 1 — stake */}
                <div className="live-card bell-step">
                  <div className="bell-step-h"><span className="bell-step-n">1</span> Stake your Seat
                    <span className="bell-step-cur">{state.tier === 0 ? "not staked yet" : `staked · ${TIERS[state.tier - 1]?.name ?? `Tier ${state.tier}`}`}</span></div>
                  <div className="live-note">Stake $ESSEY on Seat #{sel?.toString()} to start earning from every payout. Higher tier = a bigger share. Pick a level:</div>
                  <div className="tier-buttons">
                    {TIERS.map((t) => {
                      const owned = state.tier;
                      const disabled = !!busy || t.tier <= owned;
                      const label = t.tier === owned ? "current" : t.tier < owned ? "—" : owned === 0 ? "Stake" : "Upgrade";
                      return (
                        <button key={t.tier} className={"tier-btn" + (t.tier === owned ? " on" : "")} disabled={disabled}
                          onClick={() => act("tier", () => flows.setTier(a!, sel!, t.tier), `✓ Seat #${sel} is now ${t.name}`)}>
                          <b>{t.name}</b>
                          <i className="num">{(t.weight / 100).toFixed(2)}× share · {fmt(t.fee)} $ESSEY</i>
                          <span>{busy === "tier" ? "…" : label}</span>
                        </button>
                      );
                    })}
                  </div>
                </div>

                {/* Step 2 — ring */}
                <div className="live-card bell-step">
                  <div className="bell-step-h"><span className="bell-step-n">2</span> Ring the Bell
                    <span className="bell-step-cur num">pot: {pot !== null ? fmt(pot, 2) : "…"} USDG</span></div>
                  <div className="live-note">When the pot's worth it, <b>anyone</b> can ring it — the pot splits across all staked Seats (by tier), and whoever rings earns a small tip. The pot grows from trades, Cases, and loan interest, so buy a few Seats on the Exchange to fill it.</div>
                  <button className="btn btn-gold" disabled={!!busy || (pot ?? 0n) === 0n}
                    onClick={() => act("ring", () => flows.ringBell(a!), "✓ rung — the pot split across staked Seats, and your tip is in")}>
                    {busy === "ring" ? "ringing…" : (pot ?? 0n) === 0n ? "Pot is empty — grow it first" : "Ring the Bell"}
                  </button>
                </div>

                {/* Step 3 — claim */}
                <div className="live-card bell-step">
                  <div className="bell-step-h"><span className="bell-step-n">3</span> Claim your payout
                    <span className="bell-step-cur num">yours: {fmt(state.pending, 4)} {CONVERTER_LIVE ? "→ stock" : "USDG"}</span></div>
                  {CONVERTER_LIVE && (
                    <div className="payout-pref">
                      <span className="pp-label">Get paid in</span>
                      {(["Bundle", "AAPL", "NVDA"] as const).map((k) => (
                        <button key={k} className={"pp-btn" + (prefKey(pref) === k ? " on" : "")} disabled={!!busy}
                          onClick={() => act("pref", () => flows.setPayoutToken(a!, sel!, k === "Bundle" ? BUNDLE : k === "AAPL" ? ADDR.aapl : ADDR.nvda), `✓ Payouts now delivered in ${k}`)}>
                          {busy === "pref" ? "…" : k}
                        </button>
                      ))}
                      <span className="live-note pp-note">the AAPL+NVDA basket by default · lands as real stock in your Vault · USDG if the market's closed</span>
                    </div>
                  )}
                  <div className="live-row">
                    <button className="btn btn-gold" disabled={!!busy || state.pending === 0n}
                      onClick={() => act("claim", () => flows.claimPayout(a!, sel!), `✓ Payout claimed into Seat #${sel}'s Vault`)}>
                      {busy === "claim" ? "claiming…" : state.pending === 0n ? "nothing to claim yet"
                        : CONVERTER_LIVE ? `Claim ${fmt(state.pending, 4)} as ${prefKey(pref)}`
                        : `Claim ${fmt(state.pending, 4)} USDG`}
                    </button>
                    <a className="btn btn-ghost" href={`${NET.explorer}/address/${state.vault}`} target="_blank" rel="noreferrer">view your Vault ↗</a>
                  </div>
                  <div className="live-note num">Your Vault holds {vaultBal !== null ? fmt(vaultBal, 2) : "…"} USDG
                    {vaultStock && (vaultStock.aapl > 0n || vaultStock.nvda > 0n) && (
                      <> · <b>{vaultStock.aapl > 0n && `${fmt(vaultStock.aapl, 2)} AAPL`}{vaultStock.aapl > 0n && vaultStock.nvda > 0n ? " · " : ""}{vaultStock.nvda > 0n && `${fmt(vaultStock.nvda, 2)} NVDA`}</b></>
                    )} — it travels with the Seat if you ever sell it.</div>
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
