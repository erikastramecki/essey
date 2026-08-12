// Essey Explorer — a terminal-style, "verify don't trust" explorer. Public data (no wallet needed):
// pool stats, live supply/withdraw activity, and every open loan — each with a PROOF cell that verifies
// its solvency proof IN YOUR BROWSER via snarkjs. Terminal aesthetic modeled on a broker-tools terminal.
//
// Honesty rules baked in: panels wired to on-chain reads show REAL data; anything not yet wired renders a
// visible "—" / TODO and never a fabricated number or mock row. The VERIFY button reports only what
// snarkjs.groth16.verify actually returns.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { parseAbiItem, type Address } from "viem";
import { pub, ADDR, poolAbi, marketsAbi, noteAbi, reads, fmt, NET } from "./live";

// ---- the scan terminal, re-skinned onto the "ledger floor" palette ----
// Instead of a hardcoded neon-phosphor look, the terminal draws straight from the shared
// design tokens (styles.css), so the page inherits the gold/ink identity AND flips with
// the site's light/dark theme. Green is gone: the all-purpose accent is now brass (--gold),
// rules are solid hairlines, corners stay squared — a ledger read of a block explorer.
const CSS = `
.txp{background:var(--ink);color:var(--tx);font-family:var(--mono);font-size:12px;
  min-height:100dvh;padding:14px;padding-left:max(14px,env(safe-area-inset-left));
  padding-right:max(14px,env(safe-area-inset-right));letter-spacing:.02em;font-variant-numeric:tabular-nums;}
.txp *{box-sizing:border-box}
.txp a{color:var(--gold)}
.txp a:hover{color:var(--gold-hi)}
.txp .top{display:flex;align-items:center;gap:12px;margin-bottom:10px}
.txp .brand{color:var(--gold);font-weight:700;letter-spacing:.14em;white-space:nowrap}
.txp .brand b{background:var(--gold);color:#14100A;padding:0 5px}
.txp .search{flex:1;display:flex;align-items:center;gap:8px;border:1px solid var(--line-2);background:var(--s2);padding:7px 10px}
.txp .search input{flex:1;min-width:0;background:transparent;border:0;color:var(--tx);font:inherit;outline:none}
.txp .clock{color:var(--tx-faint);white-space:nowrap}
.txp .ticker{display:flex;gap:18px;overflow-x:auto;border:1px solid var(--line);padding:6px 10px;margin-bottom:10px;white-space:nowrap}
.txp .ticker span b{color:var(--gold)}
.txp .ticker .na{color:var(--tx-faint)}
.txp .grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.txp .full{grid-column:1/-1}
.txp .panel{border:1px solid var(--line-2);background:var(--s1);padding:10px 12px;min-width:0}
.txp .ph{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:8px}
.txp .ph .t{color:var(--gold);letter-spacing:.12em;font-weight:700}
.txp .ph .s{color:var(--tx-faint);font-size:11px}
.txp .big{font-size:26px;color:var(--tx);line-height:1.1}
.txp .kv{display:flex;flex-wrap:wrap;gap:6px 22px;margin-top:8px}
.txp .kv div{display:flex;flex-direction:column}
.txp .kv .k{color:var(--tx-faint);font-size:10px;letter-spacing:.08em}
.txp .kv .v{color:var(--tx)}
.txp table{width:100%;border-collapse:collapse;font-size:11px}
.txp th{text-align:left;color:var(--tx-faint);font-weight:400;border-bottom:1px solid var(--line-2);padding:4px 8px 4px 0;letter-spacing:.06em}
.txp td{padding:5px 8px 5px 0;border-bottom:1px solid var(--line);white-space:nowrap}
.txp td.r,.txp th.r{text-align:right}
.txp .good{color:var(--gold)} .txp .warn{color:var(--warn)} .txp .bad{color:var(--crit)} .txp .muted{color:var(--tx-faint)}
.txp .pill{border:1px solid currentColor;padding:0 5px;font-size:10px}
.txp button.v{background:transparent;border:1px solid var(--line-2);color:var(--tx-mut);font:inherit;cursor:pointer;padding:1px 7px}
.txp button.v:hover{border-color:var(--gold);color:var(--gold)}
.txp .foot{color:var(--tx-faint);margin-top:12px;border-top:1px solid var(--line);padding-top:8px;display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px}
.txp .empty{color:var(--tx-faint);padding:8px 0}
@media(max-width:820px){
  .txp .grid{grid-template-columns:1fr}
  /* wide, nowrap tables scroll inside their own panel instead of being clipped by the page */
  .txp table{display:block;overflow-x:auto;-webkit-overflow-scrolling:touch}
  /* ≥16px so iOS Safari doesn't auto-zoom when the search field is focused */
  .txp .search input{font-size:16px}
}
`;

const ZERO = "0x0000000000000000000000000000000000000000";
const short = (a?: string) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "—");
const tokenName = (t: string) =>
  t.toLowerCase() === ADDR.aapl.toLowerCase() ? "AAPL" : t.toLowerCase() === ADDR.nvda.toLowerCase() ? "NVDA" : short(t);

type Pool = Awaited<ReturnType<typeof reads.poolState>> & { pot: bigint };
type Loan = { id: bigint; owner: Address; token: Address; collateralRaw: bigint; debt: bigint; maxDebt: bigint };
type Act = { kind: "SUPPLY" | "WITHDRAW"; actor: string; assets: bigint; tx: string; block: bigint };
type Market = { sym: string; addr: Address; canBorrow: boolean | null };

// ERC-4626 events the pool emits (standard) — used for the live activity firehose.
const evDeposit = parseAbiItem("event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)");
const evWithdraw = parseAbiItem("event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)");

export function ExplorerPage() {
  const [pool, setPool] = useState<Pool | null>(null);
  const [loans, setLoans] = useState<Loan[] | null>(null);
  const [acts, setActs] = useState<Act[] | null>(null);
  const [markets, setMarkets] = useState<Market[] | null>(null);
  const [head, setHead] = useState<bigint>(0n);
  const [q, setQ] = useState("");
  const [clock, setClock] = useState("");
  const [proof, setProof] = useState<Record<string, "idle" | "checking" | "verified" | "failed" | "notwired">>({});
  const mounted = useRef(true);

  useEffect(() => { document.title = "Explorer · Essey"; mounted.current = true; return () => { mounted.current = false; }; }, []);
  useEffect(() => { const t = setInterval(() => setClock(new Date().toISOString().slice(11, 19) + " UTC"), 1000); return () => clearInterval(t); }, []);

  const loadPool = useCallback(async () => {
    try {
      const [ps, pot, h] = await Promise.all([reads.poolState(null), reads.pot(), pub.getBlockNumber()]);
      if (mounted.current) { setPool({ ...ps, pot }); setHead(h); }
    } catch { /* leave last good */ }
  }, []);

  const loadMarkets = useCallback(async () => {
    const defs: { sym: string; addr: Address }[] = [{ sym: "AAPL", addr: ADDR.aapl }, { sym: "NVDA", addr: ADDR.nvda }];
    const out = await Promise.all(defs.map(async (d) => ({
      ...d, canBorrow: await reads.canBorrow(d.addr).catch(() => null) as boolean | null,
    })));
    if (mounted.current) setMarkets(out);
  }, []);

  const loadLoans = useCallback(async () => {
    try {
      const [next, note] = await Promise.all([
        pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "nextPositionId" }) as Promise<bigint>,
        pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "note" }) as Promise<Address>,
      ]);
      const CAP = 60n; // most recent 60 positions (bounded RPC)
      const start = next > CAP ? next - CAP : 1n;
      const out: Loan[] = [];
      for (let id = start; id < next; id++) {
        const owner = await pub.readContract({ address: note, abi: noteAbi, functionName: "ownerOf", args: [id] }).catch(() => null) as Address | null;
        if (!owner) continue; // closed / burned
        const pos = await pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "positions", args: [id] }) as readonly [Address, bigint, bigint, bigint];
        const debt = await pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "debtOf", args: [id] }) as bigint;
        if (debt === 0n) continue;
        const maxDebt = await pub.readContract({ address: ADDR.markets, abi: marketsAbi, functionName: "maxBorrow", args: [pos[0], pos[1]] }).catch(() => 0n) as bigint;
        out.push({ id, owner, token: pos[0], collateralRaw: pos[1], debt, maxDebt });
      }
      if (mounted.current) setLoans(out.reverse());
    } catch { if (mounted.current) setLoans([]); }
  }, []);

  const loadActivity = useCallback(async () => {
    try {
      const h = await pub.getBlockNumber();
      const from = h > 300_000n ? h - 300_000n : 0n;
      const [dep, wd] = await Promise.all([
        pub.getLogs({ address: ADDR.pool, event: evDeposit, fromBlock: from, toBlock: h }).catch(() => []),
        pub.getLogs({ address: ADDR.pool, event: evWithdraw, fromBlock: from, toBlock: h }).catch(() => []),
      ]);
      const rows: Act[] = [
        ...dep.map((l) => ({ kind: "SUPPLY" as const, actor: (l.args as { owner?: string }).owner ?? ZERO, assets: (l.args as { assets?: bigint }).assets ?? 0n, tx: l.transactionHash!, block: l.blockNumber! })),
        ...wd.map((l) => ({ kind: "WITHDRAW" as const, actor: (l.args as { owner?: string }).owner ?? ZERO, assets: (l.args as { assets?: bigint }).assets ?? 0n, tx: l.transactionHash!, block: l.blockNumber! })),
      ].sort((a, b) => Number(b.block - a.block)).slice(0, 24);
      if (mounted.current) setActs(rows);
    } catch { if (mounted.current) setActs([]); }
  }, []);

  useEffect(() => {
    loadPool(); loadMarkets(); loadLoans(); loadActivity();
    const t = setInterval(() => { loadPool(); loadActivity(); }, 20_000);
    return () => clearInterval(t);
  }, [loadPool, loadMarkets, loadLoans, loadActivity]);

  // In-browser Groth16 verification of a loan's solvency proof. Reports ONLY what snarkjs returns.
  const verify = useCallback(async (id: bigint) => {
    const key = id.toString();
    setProof((p) => ({ ...p, [key]: "checking" }));
    try {
      const [vkRes, pfRes] = await Promise.all([fetch("/proof/solvency_vk.json"), fetch(`/proof/loan_${key}.json`)]);
      if (!vkRes.ok || !pfRes.ok) { setProof((p) => ({ ...p, [key]: "notwired" })); return; }
      const vk = await vkRes.json();
      const { proof, publicSignals } = await pfRes.json();
      const snarkjs = await import("snarkjs");
      const ok = await snarkjs.groth16.verify(vk, publicSignals, proof);
      setProof((p) => ({ ...p, [key]: ok ? "verified" : "failed" }));
    } catch { setProof((p) => ({ ...p, [key]: "notwired" })); }
  }, []);

  const ql = q.trim().toLowerCase();
  const loansF = useMemo(() => (loans ?? []).filter((l) => !ql || l.owner.toLowerCase().includes(ql) || l.id.toString() === ql || tokenName(l.token).toLowerCase().includes(ql)), [loans, ql]);
  const actsF = useMemo(() => (acts ?? []).filter((a) => !ql || a.actor.toLowerCase().includes(ql) || a.tx.toLowerCase().includes(ql)), [acts, ql]);

  const expl = (path: string) => `${NET.explorer}/${path}`;

  return (
    <div className="txp">
      <style>{CSS}</style>

      <div className="top">
        <div className="brand"><b>ESSEY</b>&nbsp;SCAN</div>
        <div className="search">
          <span className="muted">&gt;</span>
          <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="SEARCH  ADDRESS / TX / LOAN / PROOF" spellCheck={false} />
          <span className="muted">{loansF.length + actsF.length} hits</span>
        </div>
        <div className="clock">{clock || "—"}</div>
      </div>

      <div className="ticker">
        {/* No price oracle wired into the web layer yet -> honest placeholders (TODO: wire feeds). */}
        {["USDG", "ESSEY", "AAPL", "NVDA"].map((s) => (
          <span key={s}>{s} <span className="na">—</span></span>
        ))}
        <span className="muted" style={{ marginLeft: "auto" }}>chain {NET.chainId} · block {head ? head.toString() : "—"} · testnet</span>
      </div>

      <div className="grid">
        {/* POOL — real */}
        <div className="panel">
          <div className="ph"><span className="t">LENDING POOL</span><span className="s">live · USDG</span></div>
          <div className="big">{pool ? fmt(pool.tvl, 0) : "…"} <span className="muted" style={{ fontSize: 13 }}>USDG TVL</span></div>
          <div className="kv">
            <div><span className="k">SUPPLY APY</span><span className="v good">{pool ? pool.supplyApy.toFixed(2) : "…"}%</span></div>
            <div><span className="k">BORROW APR</span><span className="v">{pool ? pool.borrowApr.toFixed(2) : "…"}%</span></div>
            <div><span className="k">UTILIZATION</span><span className="v">{pool ? pool.utilPct.toFixed(1) : "…"}%</span></div>
            <div><span className="k">BELL POT</span><span className="v">{pool ? fmt(pool.pot, 0) : "…"} USDG</span></div>
          </div>
        </div>

        {/* MARKETS — real borrow-open status; price is TODO */}
        <div className="panel">
          <div className="ph"><span className="t">MARKETS</span><span className="s">collateral</span></div>
          <table>
            <thead><tr><th>ASSET</th><th className="r">PRICE</th><th className="r">BORROW</th></tr></thead>
            <tbody>
              {(markets ?? []).map((m) => (
                <tr key={m.sym}>
                  <td className="good">{m.sym}</td>
                  <td className="r na muted">—</td>
                  <td className="r">{m.canBorrow === null ? <span className="muted">—</span> : m.canBorrow ? <span className="pill good">OPEN</span> : <span className="pill warn">CLOSED</span>}</td>
                </tr>
              ))}
              {!markets && <tr><td colSpan={3} className="empty">loading…</td></tr>}
            </tbody>
          </table>
          <div className="muted" style={{ marginTop: 6, fontSize: 10 }}>PRICE feed not wired to the web layer yet — TODO.</div>
        </div>

        {/* LOANS — real; PROOF = in-browser verify */}
        <div className="panel full">
          <div className="ph"><span className="t">OPEN LOANS</span><span className="s">provably-solvent · verify in your browser</span></div>
          <div style={{ overflowX: "auto" }}>
            <table>
              <thead><tr><th>ID</th><th>BORROWER</th><th>COLLATERAL</th><th className="r">DEBT</th><th className="r">LTV / MAX</th><th>HEALTH</th><th>PROOF</th></tr></thead>
              <tbody>
                {loansF.map((l) => {
                  const util = l.maxDebt > 0n ? Number(l.debt) / Number(l.maxDebt) : null;
                  const hp = util === null ? null : util <= 0.85 ? "good" : util <= 1 ? "warn" : "bad";
                  const st = proof[l.id.toString()] ?? "idle";
                  return (
                    <tr key={l.id.toString()}>
                      <td className="muted">#{l.id.toString()}</td>
                      <td><a href={expl(`address/${l.owner}`)} target="_blank" rel="noreferrer">{short(l.owner)}</a></td>
                      <td>{fmt(l.collateralRaw, 2)} <span className="good">{tokenName(l.token)}</span></td>
                      <td className="r">{fmt(l.debt, 2)} USDG</td>
                      <td className="r">{util === null ? <span className="muted">—</span> : <span className={hp!}>{(util * 100).toFixed(0)}%</span>}</td>
                      <td>{hp === null ? <span className="muted">—</span> : hp === "good" ? <span className="good">HEALTHY</span> : hp === "warn" ? <span className="warn">TIGHT</span> : <span className="bad">UNDERWATER</span>}</td>
                      <td>
                        {st === "verified" ? <span className="good" title="debt ≤ collateral×price×LTV — verified in your browser">✓ SOLVENT</span>
                          : st === "checking" ? <span className="muted">verifying…</span>
                          : st === "failed" ? <span className="bad">✗ INVALID</span>
                          : st === "notwired" ? <span className="muted" title="Drop solvency_vk.json + loan_<id>.json in public/proof/ (needs gnark→snarkjs vk conversion)">proof not wired</span>
                          : <button className="v" onClick={() => verify(l.id)}>VERIFY</button>}
                      </td>
                    </tr>
                  );
                })}
                {loans && loansF.length === 0 && <tr><td colSpan={7} className="empty">{loans.length === 0 ? "no open loans in the scanned window" : "no matches"}</td></tr>}
                {!loans && <tr><td colSpan={7} className="empty">scanning positions…</td></tr>}
              </tbody>
            </table>
          </div>
          <div className="muted" style={{ marginTop: 6, fontSize: 10 }}>
            VERIFY runs snarkjs.groth16.verify in-browser against <span className="good">public/proof/solvency_vk.json</span> + <span className="good">loan_&lt;id&gt;.json</span>.
            Real solvency proofs need the gnark→snarkjs vk conversion (TODO) — until then it honestly reports “proof not wired”.
          </div>
        </div>

        {/* FIREHOSE — real ERC-4626 supply/withdraw */}
        <div className="panel full">
          <div className="ph"><span className="t">FIREHOSE</span><span className="s">live activity · supply/withdraw (borrow/case/ring = TODO)</span></div>
          <div style={{ overflowX: "auto" }}>
            <table>
              <thead><tr><th>TYPE</th><th>ACTOR</th><th className="r">AMOUNT</th><th>ASSET</th><th>TX</th><th className="r">BLOCK</th></tr></thead>
              <tbody>
                {actsF.map((a, i) => (
                  <tr key={a.tx + i}>
                    <td className={a.kind === "SUPPLY" ? "good" : "warn"}>{a.kind}</td>
                    <td><a href={expl(`address/${a.actor}`)} target="_blank" rel="noreferrer">{short(a.actor)}</a></td>
                    <td className="r">{fmt(a.assets, 2)}</td>
                    <td className="muted">USDG</td>
                    <td><a href={expl(`tx/${a.tx}`)} target="_blank" rel="noreferrer">{short(a.tx)}</a></td>
                    <td className="r muted">{a.block.toString()}</td>
                  </tr>
                ))}
                {acts && actsF.length === 0 && <tr><td colSpan={6} className="empty">{acts.length === 0 ? "no supply/withdraw activity in the scanned window" : "no matches"}</td></tr>}
                {!acts && <tr><td colSpan={6} className="empty">streaming…</td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div className="foot">
        <span>ESSEY SCAN · v1 · Robinhood Chain {NET.chainId} testnet · <a href={NET.explorer} target="_blank" rel="noreferrer">raw explorer ↗</a></span>
        <span>proof, not attestation — verify solvency yourself</span>
      </div>
    </div>
  );
}
