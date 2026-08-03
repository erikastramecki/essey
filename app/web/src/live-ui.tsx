// Live testnet UI: the faucet, the live Exchange, and the shared banner. Everything here talks to
// the REAL deployed contracts on 46630 — labeled TESTNET throughout, play money only.
import { useCallback, useEffect, useState } from "react";
import type { Address } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { ADDR, NET, PRICE, flows, reads, fmt } from "./live";

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

/// Get play money: testnet ETH from the chain faucet (external), then $ESSEY + mock USDG from ours.
export function FaucetCard() {
  const w = useWallet();
  const { bal, refresh } = useBalances();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const drip = async () => {
    if (!w.address) return;
    setBusy(true); setMsg(null);
    try {
      await flows.drip(w.address as Address);
      setMsg("✓ 5,000 $ESSEY + 1,000 USDG dripped");
      refresh();
    } catch (e) {
      const m = String((e as Error).message ?? e);
      setMsg(m.includes("TooSoon") ? "Faucet cooldown — 8h between drips" : m.slice(0, 120));
    } finally { setBusy(false); }
  };

  return (
    <div className="live-card">
      <div className="live-h">PLAY MONEY <span className="preview-chip">testnet</span></div>
      {w.address ? (
        <>
          <div className="live-bal num">
            {bal ? <>{fmt(bal.essey)} $ESSEY · {fmt(bal.usdg)} USDG · {bal.seats.toString()} Seats</> : "…"}
          </div>
          <div className="live-row">
            <button className="btn btn-gold" disabled={busy} onClick={drip}>{busy ? "dripping…" : "Get 5,000 $ESSEY + 1,000 USDG"}</button>
            <a className="btn btn-ghost" href={NET.faucet} target="_blank" rel="noreferrer">Need gas ETH? ↗</a>
          </div>
          {msg && <div className="live-msg">{msg}</div>}
        </>
      ) : (
        <div className="live-row"><span className="live-note">Connect a wallet to get test funds and play for real.</span><ConnectButton /></div>
      )}
    </div>
  );
}

/// The live Exchange: real float, real fees feeding the real pot.
export function LiveExchange() {
  const w = useWallet();
  const { refresh } = useBalances();
  const [float_, setFloat] = useState<bigint | null>(null);
  const [pot, setPot] = useState<bigint | null>(null);
  const [ids, setIds] = useState<bigint[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [snipeId, setSnipeId] = useState("");
  const [sellId, setSellId] = useState("");

  const load = useCallback(() => {
    reads.floatCount().then(setFloat).catch(() => {});
    reads.pot().then(setPot).catch(() => {});
    reads.floatIds().then(setIds).catch(() => {});
  }, []);
  useEffect(() => { load(); const t = setInterval(load, 15_000); return () => clearInterval(t); }, [load]);

  const act = async (label: string, fn: () => Promise<unknown>, ok: string) => {
    setBusy(label); setMsg(null);
    try { await fn(); setMsg(ok); load(); refresh(); }
    catch (e) { setMsg(String((e as Error).message ?? e).slice(0, 140)); }
    finally { setBusy(null); }
  };

  const a = w.address as Address | null;
  const ready = !!a && w.chainOk;

  return (
    <section className="band" style={{ paddingTop: 0 }}>
      <div className="wrap">
        <div className="live-card">
          <div className="live-h">THE EXCHANGE — LIVE <span className="preview-chip">testnet</span></div>
          <div className="live-bal num">
            float: {float_ !== null ? float_.toString() : "…"} Seats · price {fmt(PRICE.seat)} $ESSEY ·
            the pot: {pot !== null ? fmt(pot) : "…"} USDG
          </div>
          {ids.length > 0 && (
            <div className="live-note num">on the floor: {ids.map((i) => `#${i}`).join(" · ")}{float_ !== null && float_ > 12n ? " · …" : ""}</div>
          )}
          {ready ? (
            <>
              <div className="live-row">
                <button className="btn btn-gold" disabled={!!busy}
                  onClick={() => act("buy", () => flows.buySeat(a!).then(({ id }) => setMsg(`✓ Seat #${id} is yours — fee just fed the pot`)), "✓ bought")}>
                  {busy === "buy" ? "buying…" : `Buy next · ${fmt(PRICE.swapFee)} USDG fee`}
                </button>
                <span className="ex-snipe">
                  <input className="num" placeholder="#" value={snipeId} onChange={(e) => setSnipeId(e.target.value.replace(/\D/g, ""))} aria-label="Seat number to snipe" />
                  <button className="btn btn-ghost" disabled={!!busy || !snipeId}
                    onClick={() => act("snipe", () => flows.snipeSeat(a!, BigInt(snipeId)), `✓ sniped #${snipeId}`)}>
                    {busy === "snipe" ? "sniping…" : `Snipe · ${fmt(PRICE.snipeFee)} fee`}
                  </button>
                </span>
                <span className="ex-snipe">
                  <input className="num" placeholder="#" value={sellId} onChange={(e) => setSellId(e.target.value.replace(/\D/g, ""))} aria-label="Seat number to sell" />
                  <button className="btn btn-ghost" disabled={!!busy || !sellId}
                    onClick={() => act("sell", () => flows.sellSeat(a!, BigInt(sellId)), `✓ sold #${sellId} back for ${fmt(PRICE.seat)} $ESSEY`)}>
                    {busy === "sell" ? "selling…" : "Sell back"}
                  </button>
                </span>
              </div>
              {busy && <div className="live-note">Approvals may add a transaction or two the first time — your wallet will walk you through.</div>}
              {msg && <div className="live-msg">{msg}</div>}
            </>
          ) : (
            <div className="live-row"><span className="live-note">Connect on Robinhood Chain testnet to trade the float for real.</span><ConnectButton /></div>
          )}
        </div>
      </div>
    </section>
  );
}
