// The lending layer: Supply liquidity (earn interest now) and Borrow against your Case winnings
// (opens after the 2-day market timelock). This is the "get paid in stock → borrow against it" half
// of the flywheel — and its interest routes to the same Bell the game feeds.
import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Address } from "viem";
import { parseUnits } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { ADDR, NET, BORROW_OPENS, flows, reads, fmt, niceError } from "./live";

type PoolState = Awaited<ReturnType<typeof reads.poolState>>;

export function LendPage() {
  const w = useWallet();
  const a = w.address as Address | null;
  const ready = !!a && w.chainOk;
  const [pool, setPool] = useState<PoolState | null>(null);

  const loadPool = useCallback(() => { reads.poolState(a).then(setPool).catch(() => {}); }, [a]);
  useEffect(() => { loadPool(); const t = setInterval(loadPool, 15_000); return () => clearInterval(t); }, [loadPool]);

  useEffect(() => { document.title = "Lend · Essey"; }, []);

  return (
    <section className="band" id="lend" style={{ paddingTop: 34 }}>
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">Lend</span>
          <h2>Supply liquidity, borrow against your stock</h2>
          <p>The engine under the game: lenders supply USDG and earn the interest borrowers pay; anyone
            holding stock (say, a Case you opened) can borrow USDG against it. A share of that interest
            routes to the Bell — so lending feeds the same pot the game does.</p>
        </div>
          <span className="preview-chip live">testnet</span>
        </div>

        <div className="lend-stats num">
          <span>pool TVL <b>{pool ? fmt(pool.tvl) : "…"}</b> USDG</span>
          <span>supply APY <b className="good">{pool ? pool.supplyApy.toFixed(2) : "…"}%</b></span>
          <span>borrow APR <b>{pool ? pool.borrowApr.toFixed(2) : "…"}%</b></span>
          <span>utilization <b>{pool ? pool.utilPct.toFixed(0) : "…"}%</b></span>
        </div>

        {!ready ? (
          <div className="live-card"><div className="live-row">
            <span className="live-note">Connect on Robinhood Chain testnet to supply or borrow.</span><ConnectButton />
          </div></div>
        ) : (
          <div className="lend-grid">
            <SupplyPanel a={a!} pool={pool} onDone={loadPool} />
            <BorrowPanel a={a!} onDone={loadPool} />
          </div>
        )}
      </div>
    </section>
  );
}

function SupplyPanel({ a, pool, onDone }: { a: Address; pool: PoolState | null; onDone: () => void }) {
  const [mode, setMode] = useState<"supply" | "withdraw">("supply");
  const [amt, setAmt] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const act = async () => {
    const n = parseFloat(amt); if (!(n > 0)) return;
    setBusy(true); setMsg(null);
    try {
      const wei = parseUnits(amt, 18);
      if (mode === "supply") await flows.supply(a, wei);
      else await flows.withdrawSupply(a, wei);
      setMsg(mode === "supply" ? `✓ supplied ${amt} USDG — now earning` : `✓ withdrew ${amt} USDG`);
      setAmt(""); onDone();
    } catch (e) { setMsg(niceError(e)); }
    finally { setBusy(false); }
  };

  return (
    <div className="live-card">
      <div className="live-h">SUPPLY — EARN <span className="preview-chip live">live now</span></div>
      <div className="live-bal num">your position: <b>{pool ? fmt(pool.mine, 2) : "…"}</b> USDG · earning {pool ? pool.supplyApy.toFixed(2) : "…"}% APY</div>
      <div className="seg" role="tablist" style={{ width: "fit-content" }}>
        <button aria-selected={mode === "supply"} onClick={() => setMode("supply")}>Supply</button>
        <button aria-selected={mode === "withdraw"} onClick={() => setMode("withdraw")}>Withdraw</button>
      </div>
      <div className="lend-input">
        <input className="num" type="number" min={0} placeholder="0" value={amt} onChange={(e) => setAmt(e.target.value)} aria-label="USDG amount" />
        <span className="lend-unit">USDG</span>
        <button className="btn btn-gold" disabled={busy || !(parseFloat(amt) > 0)} onClick={act}>
          {busy ? "confirming…" : mode === "supply" ? "Supply" : "Withdraw"}
        </button>
      </div>
      <div className="live-note">Interest accrues every second; withdraw whenever there's idle liquidity. A slice of
        borrower interest is skimmed to the Bell — lending literally funds the Payouts.</div>
      {msg && <div className="live-msg">{msg}</div>}
    </div>
  );
}

function BorrowPanel({ a, onDone }: { a: Address; onDone: () => void }) {
  const [wins, setWins] = useState<{ aapl: bigint; nvda: bigint } | null>(null);
  const [loans, setLoans] = useState<Awaited<ReturnType<typeof reads.myLoans>>>([]);
  const [open, setOpen] = useState(false);
  const [token, setToken] = useState<Address>(ADDR.aapl);
  const [coll, setColl] = useState("");
  const [debt, setDebt] = useState("");
  const [maxDebt, setMaxDebt] = useState<bigint | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  const now = new Date();
  const load = useCallback(() => {
    reads.stockWins(a).then(setWins).catch(() => {});
    reads.myLoans(a).then(setLoans).catch(() => {});
    reads.canBorrow(ADDR.aapl).then(setOpen).catch(() => {});
  }, [a]);
  useEffect(() => { load(); }, [load]);

  // Quote the max borrow whenever collateral changes.
  useEffect(() => {
    const n = parseFloat(coll);
    if (!(n > 0)) { setMaxDebt(null); return; }
    reads.maxBorrow(token, parseUnits(coll, 18)).then(setMaxDebt).catch(() => setMaxDebt(null));
  }, [coll, token]);

  const doBorrow = async () => {
    if (!(parseFloat(coll) > 0) || !(parseFloat(debt) > 0)) return;
    setBusy("borrow"); setMsg(null);
    try {
      await flows.borrow(a, token, parseUnits(coll, 18), parseUnits(debt, 18));
      setMsg(`✓ borrowed ${debt} USDG against ${coll} ${token === ADDR.aapl ? "AAPL" : "NVDA"} — your position is a Note you can repay anytime`);
      setColl(""); setDebt(""); load(); onDone();
    } catch (e) { setMsg(niceError(e)); }
    finally { setBusy(null); }
  };

  const repay = async (id: bigint, owed: bigint) => {
    setBusy("repay" + id); setMsg(null);
    try { await flows.repay(a, id, owed); setMsg(`✓ repaid loan #${id} — your collateral is back`); load(); onDone(); }
    catch (e) { setMsg(niceError(e)); }
    finally { setBusy(null); }
  };

  const haveStock = wins && (wins.aapl > 0n || wins.nvda > 0n);

  return (
    <div className="live-card">
      <div className="live-h">BORROW — AGAINST STOCK {open
        ? <span className="preview-chip live">live now</span>
        : <span className="preview-chip">opens {BORROW_OPENS.toUTCString().slice(5, 16)}</span>}
      </div>

      {loans.length > 0 && (
        <div className="lend-loans">
          {loans.map((l) => (
            <div className="lend-loan num" key={l.id.toString()}>
              <span>Loan #{l.id.toString()} · {fmt(l.collateralRaw, 2)} {l.token.toLowerCase() === ADDR.aapl.toLowerCase() ? "AAPL" : "NVDA"} collateral · owe <b>{fmt(l.debt, 2)}</b> USDG</span>
              <button className="btn btn-ghost" disabled={busy === "repay" + l.id} onClick={() => repay(l.id, l.debt)}>{busy === "repay" + l.id ? "repaying…" : "Repay"}</button>
            </div>
          ))}
        </div>
      )}

      {!open ? (
        <div className="live-note">Borrowing against stock opens {BORROW_OPENS.toUTCString()} — collateral markets sit
          behind a 2-day timelock for safety (a real feature, not a wait we chose). It also only accepts new loans
          during US market hours, when the price feed is live. {now < BORROW_OPENS ? "Check back then." : "The market may just be closed right now — try during US session hours."}</div>
      ) : !haveStock ? (
        <div className="live-note">You don't hold any stock to borrow against yet. <Link to="/cases">Open a Case →</Link> to draw some AAPL or NVDA, then come back.</div>
      ) : (
        <>
          <div className="live-bal num">you hold: {wins!.aapl > 0n && <>AAPL {fmt(wins!.aapl, 2)} </>}{wins!.nvda > 0n && <>NVDA {fmt(wins!.nvda, 2)}</>}</div>
          <div className="seg" role="tablist" style={{ width: "fit-content" }}>
            <button aria-selected={token === ADDR.aapl} onClick={() => setToken(ADDR.aapl)}>AAPL</button>
            <button aria-selected={token === ADDR.nvda} onClick={() => setToken(ADDR.nvda)}>NVDA</button>
          </div>
          <div className="lend-input">
            <input className="num" type="number" min={0} placeholder="collateral" value={coll} onChange={(e) => setColl(e.target.value)} aria-label="collateral amount" />
            <span className="lend-unit">{token === ADDR.aapl ? "AAPL" : "NVDA"}</span>
          </div>
          <div className="lend-input">
            <input className="num" type="number" min={0} placeholder="borrow" value={debt} onChange={(e) => setDebt(e.target.value)} aria-label="borrow amount" />
            <span className="lend-unit">USDG</span>
            <button className="btn btn-gold" disabled={!!busy || !(parseFloat(debt) > 0)} onClick={doBorrow}>{busy === "borrow" ? "borrowing…" : "Borrow"}</button>
          </div>
          {maxDebt !== null && <div className="live-note num">max borrow at 35% LTV: {fmt(maxDebt, 2)} USDG</div>}
        </>
      )}
      <div className="live-note">Your loan is a Note — a transferable position that carries its debt, its collateral, and
        its solvency with it. Repay anytime to get the collateral back. <a href={`${NET.explorer}/address/${ADDR.pool}`} target="_blank" rel="noreferrer">the pool ↗</a></div>
      {msg && <div className="live-msg">{msg}</div>}
    </div>
  );
}
