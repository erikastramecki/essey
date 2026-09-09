// Throwaway operator console: burn the ops wallet's entire $ESSEY and claim the underlying basket.
//
// Founder, 2026-09-09, deliberately and after being told twice what it costs: burn ALL, claim the 95%.
// The 5% exit fee stays in the reserve backing a token that will then have zero supply — that is the
// designed ratchet working, not a bug, and it becomes seed backing for the relaunched token.
//
// receiptCount() is 0: this is the first exercise of the redeem path on mainnet. DELETE THIS FILE and
// its route once the burn is done.
import { useEffect, useState } from "react";

import {
  ESSEY_DECIMALS,
  exitFeeOn,
  previewRedeem,
  reads,
  redeemAbi,
  type Position,
  type Quote,
  type RedeemState,
} from "./redeem";
import { RESERVE } from "./reserve";
import { txUrl, useMainnetTx, useMainnetWallet } from "./mainnet-tx";

const fmt = (v: bigint, dec: number, sig = 6): string => {
  const neg = v < 0n;
  const s = (neg ? -v : v).toString().padStart(dec + 1, "0");
  const whole = s
    .slice(0, s.length - dec)
    .replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const frac = s
    .slice(s.length - dec)
    .replace(/0+$/, "")
    .slice(0, sig);
  return `${neg ? "-" : ""}${whole}${frac ? "." + frac : ""}`;
};

export function BurnAllPage() {
  const w = useMainnetWallet();
  const burnTx = useMainnetTx();
  const claimTx = useMainnetTx();
  const [st, setSt] = useState<RedeemState | null>(null);
  const [pos, setPos] = useState<Position | null>(null);
  const [receiptId, setReceiptId] = useState<bigint | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    reads
      .state()
      .then(setSt)
      .catch((e) => setErr(String(e)));
  }, []);

  useEffect(() => {
    if (!w.address) return setPos(null);
    reads
      .position(w.address)
      .then(setPos)
      .catch((e) => setErr(String(e)));
  }, [w.address]);

  const balance = pos?.essey ?? 0n;
  const quotes: Quote[] =
    st && balance > 0n ? previewRedeem(balance, st.tokens, st.params) : [];
  const fee = st && balance > 0n ? exitFeeOn(balance, st.params) : 0n;
  const nonZero = quotes.filter((q) => q.units > 0n);

  const burn = async () => {
    if (!st || balance === 0n) return;
    setErr(null);
    const rcpt = await burnTx.run({
      address: RESERVE.reserve,
      abi: redeemAbi,
      functionName: "redeem",
      args: [balance],
    });
    if (!rcpt) return;
    const id = await reads
      .state()
      .then((s) => (s.receiptCount > 0n ? s.receiptCount - 1n : null))
      .catch(() => null);
    setReceiptId(id);
    if (w.address)
      reads
        .position(w.address)
        .then(setPos)
        .catch(() => {});
  };

  const claimAll = async () => {
    if (receiptId === null || !st) return;
    setErr(null);
    await claimTx.run({
      address: RESERVE.reserve,
      abi: redeemAbi,
      functionName: "claimMany",
      args: [receiptId, st.tokens.map((t) => t.address)],
    });
  };

  return (
    <div className="hw-wrap" style={{ maxWidth: 820 }}>
      <h1>Burn &amp; claim — operator console</h1>
      <p className="hw-sub">
        Burns the connected wallet&rsquo;s entire $ESSEY balance and claims the
        underlying basket. One-time tool. Delete after use.
      </p>

      {err && <div className="hw-warn">{err}</div>}
      {!w.address ? (
        <button className="hw-btn" onClick={w.connect}>
          Connect operations wallet
        </button>
      ) : (
        <div className="hw-card">
          <div className="hw-card-k">Connected</div>
          <code>{w.address}</code>
        </div>
      )}

      {w.address && !w.chainOk && (
        <div className="hw-warn">
          Wrong network.{" "}
          <button className="hw-btn" onClick={w.switchChain}>
            Switch to RH mainnet
          </button>
        </div>
      )}

      {w.address && w.chainOk && st && (
        <>
          <div className="hw-card">
            <div className="hw-card-k">You will burn</div>
            <div className="hw-card-big">
              {fmt(balance, ESSEY_DECIMALS, 0)} $ESSEY
            </div>
            <p>
              Exit fee {Number(st.params.exitFeeBps) / 100}% ={" "}
              <b>{fmt(fee, ESSEY_DECIMALS, 0)} $ESSEY</b> of weight forfeited.
              That value stays in the reserve. After this burn the token&rsquo;s
              supply is zero, so nothing can claim it — it becomes seed backing
              for whatever is launched against this reserve next.
            </p>
          </div>

          <div className="hw-card">
            <div className="hw-card-k">
              You will receive — {nonZero.length} tokens
            </div>
            <table className="hw-table">
              <tbody>
                {nonZero.map((q) => (
                  <tr key={q.token.address}>
                    <td>{q.token.symbol}</td>
                    <td style={{ textAlign: "right" }}>
                      {fmt(q.units, q.token.decimals)}
                    </td>
                    <td>
                      <code>{q.token.address}</code>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            <p>
              Quoted from the reserve&rsquo;s own claim math at this block.
              Amounts move with the reserve&rsquo;s balances until the burn
              lands.
            </p>
          </div>

          <div className="hw-card">
            <div className="hw-card-k">Step 1 — burn</div>
            <button
              className="hw-btn"
              disabled={balance === 0n || burnTx.state.phase === "pending"}
              onClick={burn}
            >
              {burnTx.state.phase === "pending"
                ? "confirm in wallet…"
                : `Burn all ${fmt(balance, ESSEY_DECIMALS, 0)} $ESSEY`}
            </button>
            {burnTx.state.hash && (
              <p>
                <a
                  href={txUrl(burnTx.state.hash)}
                  target="_blank"
                  rel="noreferrer"
                >
                  burn tx
                </a>
                {receiptId !== null && <> · receipt #{receiptId.toString()}</>}
              </p>
            )}
            {burnTx.state.error && (
              <div className="hw-warn">{burnTx.state.error}</div>
            )}
          </div>

          <div className="hw-card">
            <div className="hw-card-k">Step 2 — claim the basket</div>
            <button
              className="hw-btn"
              disabled={receiptId === null || claimTx.state.phase === "pending"}
              onClick={claimAll}
            >
              {receiptId === null
                ? "burn first"
                : claimTx.state.phase === "pending"
                  ? "confirm in wallet…"
                  : `Claim all ${st.tokens.length} tokens`}
            </button>
            {claimTx.state.hash && (
              <p>
                <a
                  href={txUrl(claimTx.state.hash)}
                  target="_blank"
                  rel="noreferrer"
                >
                  claim tx
                </a>
              </p>
            )}
            {claimTx.state.error && (
              <div className="hw-warn">{claimTx.state.error}</div>
            )}
            <p>
              Separate transaction by design: the burn mints a receipt that
              stays claimable, so a paused token cannot strand the rest. If this
              leg fails the receipt survives and can be claimed later.
            </p>
          </div>
        </>
      )}
    </div>
  );
}
