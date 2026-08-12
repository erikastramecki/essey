// The lending layer: Supply liquidity (earn interest now) and Borrow against your Case winnings
// (opens after the 2-day market timelock). This is the "get paid in stock → borrow against it" half
// of the flywheel — and its interest routes to the same Bell the game feeds.
import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import type { Address } from "viem";
import { parseUnits } from "viem";
import { useWallet, ConnectButton } from "./wallet";
import { ADDR, NET, flows, reads, fmt, niceError } from "./live";

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
            routes to the Bell, so lending feeds the same pot the game does.</p>
        </div>
          <span className="preview-chip live">testnet</span>
        </div>

        <div className="lend-stats num">
          <span title="total USDG lenders have supplied to the pool">in the pool <b>{pool ? fmt(pool.tvl) : "…"}</b> USDG</span>
          <span title="what lenders earn per year">lenders earn <b className="good">{pool ? pool.supplyApy.toFixed(2) : "…"}%</b>/yr</span>
          <span title="what borrowers pay per year">borrowers pay <b>{pool ? pool.borrowApr.toFixed(2) : "…"}%</b>/yr</span>
          <span title="how much of the pool is currently lent out">lent out <b>{pool ? pool.utilPct.toFixed(0) : "…"}%</b></span>
        </div>

        {!ready ? (
          <div className="live-card"><div className="live-row">
            <span className="live-note">Connect on Robinhood Chain testnet to supply or borrow.</span><ConnectButton />
          </div></div>
        ) : (
          <>
            <div className="lend-grid">
              <SupplyPanel a={a!} pool={pool} onDone={loadPool} />
              <BorrowPanel a={a!} onDone={loadPool} />
            </div>
            <DcaPanel a={a!} />
          </>
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
      setMsg(mode === "supply" ? `✓ supplied ${amt} USDG, now earning` : `✓ withdrew ${amt} USDG`);
      setAmt(""); onDone();
    } catch (e) { setMsg(niceError(e)); }
    finally { setBusy(false); }
  };

  return (
    <div className="live-card">
      <div className="live-h">SUPPLY &amp; EARN <span className="preview-chip live">live now</span></div>
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
        borrower interest is skimmed to the Bell. Lending literally funds the Payouts.</div>
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
      setMsg(`✓ borrowed ${debt} USDG against ${coll} ${token === ADDR.aapl ? "AAPL" : "NVDA"}. Your position is a Note you can repay anytime`);
      setColl(""); setDebt(""); load(); onDone();
    } catch (e) { setMsg(niceError(e)); }
    finally { setBusy(null); }
  };

  const repay = async (id: bigint, owed: bigint) => {
    setBusy("repay" + id); setMsg(null);
    try { await flows.repay(a, id, owed); setMsg(`✓ repaid loan #${id}. Your collateral is back`); load(); onDone(); }
    catch (e) { setMsg(niceError(e)); }
    finally { setBusy(null); }
  };

  const haveStock = wins && (wins.aapl > 0n || wins.nvda > 0n);

  return (
    <div className="live-card">
      <div className="live-h">BORROW AGAINST STOCK {open
        ? <span className="preview-chip live">live now</span>
        : <span className="preview-chip">testnet: coming soon</span>}
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
        <div className="live-note">Borrowing against stock isn't live on testnet yet. The testnet stock tokens are
          simple mocks that don't expose the price data the collateral market needs to size a loan safely, so we've
          kept borrowing closed rather than open a position we can't price honestly. It's on the roadmap; supplying
          USDG to earn (above) works today.</div>
      ) : !haveStock ? (
        <div className="live-note">You don't hold any stock to borrow against yet. <Link to="/cases">Open a Case →</Link> to draw some AAPL or NVDA, then come back.</div>
      ) : (
        <>
          <div className="live-note">Lock stock you won as collateral, borrow USDG against it, and repay anytime to get the stock back.</div>
          <div className="live-bal num">you hold: {wins!.aapl > 0n && <>AAPL {fmt(wins!.aapl, 2)} </>}{wins!.nvda > 0n && <>NVDA {fmt(wins!.nvda, 2)}</>}</div>
          <div className="seg" role="tablist" style={{ width: "fit-content" }}>
            <button aria-selected={token === ADDR.aapl} onClick={() => setToken(ADDR.aapl)}>AAPL</button>
            <button aria-selected={token === ADDR.nvda} onClick={() => setToken(ADDR.nvda)}>NVDA</button>
          </div>
          <label className="lend-field-h">Stock to lock as collateral</label>
          <div className="lend-input">
            <input className="num" type="number" min={0} placeholder="0" value={coll} onChange={(e) => setColl(e.target.value)} aria-label="collateral amount" />
            <span className="lend-unit">{token === ADDR.aapl ? "AAPL" : "NVDA"}</span>
          </div>
          <label className="lend-field-h">USDG to borrow</label>
          <div className="lend-input">
            <input className="num" type="number" min={0} placeholder="0" value={debt} onChange={(e) => setDebt(e.target.value)} aria-label="borrow amount" />
            <span className="lend-unit">USDG</span>
            <button className="btn btn-gold" disabled={!!busy || !(parseFloat(debt) > 0)} onClick={doBorrow}>{busy === "borrow" ? "borrowing…" : "Borrow"}</button>
          </div>
          {maxDebt !== null && <div className="live-note num">You can borrow up to <b>{fmt(maxDebt, 2)} USDG</b> against this: a conservative 35% of the stock's value, which leaves a wide buffer. It's still a loan: if the stock falls far enough, your collateral can be <b>liquidated</b> to cover the debt. Repay anytime to get it back.</div>}
        </>
      )}
      <div className="live-note">Your loan is a Note, a transferable position that carries its debt, its collateral, and
        its solvency with it. Repay anytime to get the collateral back. <a href={`${NET.explorer}/address/${ADDR.pool}`} target="_blank" rel="noreferrer">the pool ↗</a></div>
      {msg && <div className="live-msg">{msg}</div>}
    </div>
  );
}

const dcaInput = { padding: "10px 12px", borderRadius: 8, border: "1px solid var(--line, #333)", background: "var(--bg-2, #111)", color: "inherit", fontSize: 14, fontFamily: "inherit" } as const;

/// Auto-stack into stock — a non-custodial recurring USDG→stock buy (DCA), settled through the oracle-floored,
/// session-gated converter and run by Essey's keeper.
function DcaPanel({ a }: { a: Address }) {
  const [stock, setStock] = useState<Address>(ADDR.aapl);
  const [perFill, setPerFill] = useState("");
  const [freq, setFreq] = useState<number>(86400);
  const [count, setCount] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [list, setList] = useState<Awaited<ReturnType<typeof reads.dcaSchedules>>>([]);

  const load = useCallback(() => { reads.dcaSchedules(a).then(setList).catch(() => {}); }, [a]);
  useEffect(() => { load(); }, [load]);

  const create = async () => {
    const amt = parseFloat(perFill), n = parseInt(count || "0", 10);
    if (!(amt > 0)) { setMsg("Enter a USDG amount per buy."); return; }
    if (!(n > 0 && n <= 1000)) { setMsg("Enter a number of buys (1–1000)."); return; }
    setBusy("create"); setMsg(null);
    try {
      await flows.createDca(a, stock, parseUnits(perFill, 18), BigInt(freq), n);
      setMsg("✓ Auto-stack started. Fills run automatically during US market hours."); setPerFill(""); setCount(""); load();
    } catch (e) { setMsg(niceError(e)); } finally { setBusy(null); }
  };

  const cancel = async (id: bigint) => {
    setBusy("cancel" + id); setMsg(null);
    try { await flows.cancelDca(a, id); setMsg("✓ Auto-stack cancelled."); load(); }
    catch (e) { setMsg(niceError(e)); } finally { setBusy(null); }
  };

  const active = list.filter((s) => !s.cancelled && s.filled < s.totalFills);
  const total = parseFloat(perFill || "0") * parseInt(count || "0", 10);
  const freqLabel = (sec: number) => sec % 86400 === 0 ? `${sec / 86400}d` : `${sec / 3600}h`;

  return (
    <div className="live-card" style={{ marginTop: 16 }}>
      <div className="live-h">AUTO-STACK INTO STOCK <span className="preview-chip">DCA</span></div>
      <div className="live-note" style={{ marginBottom: 12 }}>Dollar-cost-average into stock: a recurring USDG→stock buy that runs on its own. <b>Your funds stay in your wallet</b>: each buy pulls only that buy's USDG (cancel or revoke the allowance anytime). Fills settle at an oracle-fair price within a ≤5% floor, <b>during US market hours</b>, executed by Essey's keeper. Testnet, play money.</div>
      <div className="live-row" style={{ gap: 10, flexWrap: "wrap" }}>
        <select value={stock} onChange={(e) => setStock(e.target.value as Address)} style={{ ...dcaInput, flex: "0 0 90px" }} aria-label="stock">
          <option value={ADDR.aapl}>AAPL</option><option value={ADDR.nvda}>NVDA</option>
        </select>
        <input className="live-input" placeholder="USDG / buy" inputMode="decimal" value={perFill} onChange={(e) => setPerFill(e.target.value)} style={{ ...dcaInput, flex: "1 1 110px" }} />
        <select value={freq} onChange={(e) => setFreq(+e.target.value)} style={{ ...dcaInput, flex: "0 0 100px" }} aria-label="frequency">
          <option value={3600}>hourly</option><option value={86400}>daily</option><option value={604800}>weekly</option>
        </select>
        <input className="live-input" placeholder="# buys" inputMode="numeric" value={count} onChange={(e) => setCount(e.target.value)} style={{ ...dcaInput, flex: "0 0 90px" }} />
        <button className="btn btn-gold" disabled={busy === "create"} onClick={create}>{busy === "create" ? "starting…" : "Start Auto-stack →"}</button>
      </div>
      {total > 0 && <div className="live-note num" style={{ marginTop: 8 }}>Total committed: <b>{total.toLocaleString()}</b> USDG over {count} buys (the allowance you approve, with funds staying in your wallet until each fill).</div>}
      {active.length > 0 && (
        <div style={{ marginTop: 14, display: "flex", flexDirection: "column", gap: 8 }}>
          <div className="live-note">Your active Auto-stacks:</div>
          {active.map((s) => (
            <div key={s.id.toString()} className="lend-loan num">
              <span>{fmt(s.amountPerFill, 2)} USDG → {s.stock.toLowerCase() === ADDR.aapl.toLowerCase() ? "AAPL" : "NVDA"} · every {freqLabel(Number(s.everySec))} · <b>{s.filled}/{s.totalFills}</b> filled</span>
              <button className="btn btn-ghost" disabled={busy === "cancel" + s.id} onClick={() => cancel(s.id)}>{busy === "cancel" + s.id ? "cancelling…" : "Cancel"}</button>
            </div>
          ))}
        </div>
      )}
      {msg && <div className="live-msg">{msg}</div>}
    </div>
  );
}
