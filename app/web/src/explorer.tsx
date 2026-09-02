// ESSEY SCAN — the Solvency desk. Game-era explorer: THE WIRE (live game+protocol event feed,
// world-voice lines, stamps) leads; THE STREET (who is exposed right now), FAMILIES (per-Don
// dossiers), THE FLOOR (the economy dashboard) drill down; THE RAILS preserves the protocol
// explorer — pool, markets, open loans, firehose — intact.
//
// Honesty rules baked in: panels wired to on-chain reads show REAL data; anything not yet wired
// renders a visible "—" / in-voice empty state and never a fabricated number or mock row. Every
// event row links its tx.
// Motion discipline: one-shot fresh pulse + one-shot stamp thump only, both gated by
// prefers-reduced-motion; countdowns tick on setInterval (never rAF — hidden tabs throttle rAF).
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { parseAbiItem, type Address } from "viem";
import { pub, ADDR, poolAbi, marketsAbi, noteAbi, reads, fmt, NET } from "./live";
import { fetchTape, txUrl, type TapeRow } from "./tape";
import { gameConfigured } from "./game/gameChain";
import { DonImg, fmtAmt } from "./game/bits";
import { fmtHMS } from "./game/useGame";
import {
  fetchGameWire, mergeWire, fetchEconomy, fetchStreet, fetchDossier, blockTs, tsOf,
  missionDueMs, fmtScrip, type WireRow, type Economy, type Street, type Dossier,
} from "./game/wire";

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
.txp .brand .sub{display:block;color:var(--tx-faint);font-weight:400;letter-spacing:.06em;font-size:10px}
.txp .search{flex:1;display:flex;align-items:center;gap:8px;border:1px solid var(--line-2);background:var(--s2);padding:7px 10px}
.txp .search input{flex:1;min-width:0;background:transparent;border:0;color:var(--tx);font:inherit;outline:none}
.txp .clock{color:var(--tx-faint);white-space:nowrap}
.txp .ticker{display:flex;gap:18px;overflow-x:auto;border:1px solid var(--line);padding:6px 10px;margin-bottom:10px;white-space:nowrap}
.txp .ticker span b{color:var(--gold)}
.txp .tabs{display:flex;gap:8px;margin-bottom:8px;overflow-x:auto}
.txp .tab{background:transparent;border:1px solid var(--line-2);color:var(--tx-mut);font:inherit;font-weight:700;letter-spacing:.1em;padding:6px 13px;cursor:pointer;white-space:nowrap}
.txp .tab:hover{color:var(--tx)}
.txp .tab.on{border-color:var(--gold);color:var(--gold)}
.txp .season{border:1px solid var(--line-2);background:var(--s1);color:var(--gold);padding:5px 10px;margin-bottom:10px;font-size:11px;letter-spacing:.08em;white-space:nowrap;overflow-x:auto}
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
.txp .okg{color:#4E8A68}
.txp .pill{border:1px solid currentColor;padding:0 5px;font-size:10px}
.txp button.v{background:transparent;border:1px solid var(--line-2);color:var(--tx-mut);font:inherit;cursor:pointer;padding:1px 7px}
.txp button.v:hover{border-color:var(--gold);color:var(--gold)}
.txp .foot{color:var(--tx-faint);margin-top:12px;border-top:1px solid var(--line);padding-top:8px;display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px}
.txp .empty{color:var(--tx-faint);padding:8px 0}
/* THE WIRE — feed rows */
.txp .chips{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:8px}
.txp .chipf{background:transparent;border:1px solid var(--line-2);color:var(--tx-mut);font:inherit;font-size:10px;letter-spacing:.1em;padding:3px 9px;cursor:pointer}
.txp .chipf.on{border-color:var(--gold);color:var(--gold)}
.txp .wire{border:1px solid var(--line-2);background:var(--s1)}
.txp .wrow{display:flex;gap:10px;align-items:center;padding:6px 10px;border-bottom:1px solid var(--line);color:var(--tx-mut)}
.txp .wrow:last-child{border-bottom:0}
.txp .wrow b{color:var(--tx);font-weight:600}
.txp .wrow .wt{color:var(--tx-faint);white-space:nowrap;flex:none;width:150px}
.txp .wrow .wi{flex:none;width:16px;text-align:center}
.txp .wrow .wb{flex:1;min-width:0}
.txp .wrow .wb.mut, .txp .wrow .wb.mut b{color:var(--tx-faint);font-weight:400}
.txp .wrow .wx{margin-left:auto;flex:none;white-space:nowrap;font-size:11px}
.txp .wrow.fresh{animation:txp-pulse 1.4s ease-out 1}
@keyframes txp-pulse{0%{background:var(--gold-dim)}100%{background:transparent}}
/* rubber stamps — the dossier grammar's stamp recipe restated on ledger colors (never import
   game.css here: it is .game-root-scoped and carries phone-frame layout) */
.txp .stamp{display:inline-block;flex:none;font-weight:700;text-transform:uppercase;letter-spacing:.14em;
  border:2px solid currentColor;border-radius:4px;padding:1px 7px 0;transform:rotate(-8deg);font-size:9.5px;
  filter:blur(.24px);-webkit-mask-image:radial-gradient(circle at 30% 40%,black 60%,rgba(0,0,0,.72) 100%);
  mask-image:radial-gradient(circle at 30% 40%,black 60%,rgba(0,0,0,.72) 100%);opacity:.92;white-space:nowrap}
.txp .stamp.bigst{font-size:12px;padding:3px 10px 2px}
.txp .stamp.crit{color:var(--crit)} .txp .stamp.gold{color:var(--gold)} .txp .stamp.warn{color:var(--warn)}
.txp .stamp.ok{color:#4E8A68} .txp .stamp.mut{color:var(--tx-faint)} .txp .stamp.carbon{color:#4A5A78}
@keyframes txp-thump{0%{transform:scale(2.6) rotate(-18deg);opacity:0}60%{transform:scale(.92) rotate(-7deg);opacity:1}100%{transform:scale(1) rotate(-8deg);opacity:.92}}
.txp .stamp.thump{animation:txp-thump .38s cubic-bezier(.2,.9,.3,1.3) both}
@media (prefers-reduced-motion:reduce){.txp .stamp.thump,.txp .wrow.fresh{animation:none}}
/* countdown chips (plain text swap each second; no transitions) */
.txp .cdown{border:1px solid var(--line-2);padding:0 5px;color:var(--tx);font-size:10px;white-space:nowrap;margin-left:6px}
.txp .cdown.warn{color:var(--warn);border-color:var(--warn)}
/* street + dossier */
.txp .donth{width:24px;height:24px;object-fit:cover;border:1px solid var(--line-2);flex:none}
.txp span.donth{display:inline-flex;align-items:center;justify-content:center;font-size:8px;color:var(--tx-faint);background:var(--s2)}
.txp .dosimg{width:96px;height:96px;object-fit:cover;border:1px solid var(--line-2);flex:none}
.txp span.dosimg{display:inline-flex;align-items:center;justify-content:center;color:var(--tx-faint);background:var(--s2)}
.txp .srow{display:flex;gap:8px;align-items:flex-start;padding:6px 0;border-bottom:1px solid var(--line)}
.txp .srow:last-child{border-bottom:0}
.txp .cap{color:var(--tx-faint);margin-top:6px;font-size:10px}
.txp .arrives{color:var(--tx-faint);letter-spacing:.08em}
.txp .dosbody{display:flex;gap:12px;align-items:flex-start;flex-wrap:wrap}
.txp .doslines{flex:1;min-width:240px;display:flex;flex-direction:column;gap:4px}
.txp .doslines b{color:var(--tx);font-weight:600}
@media(max-width:820px){
  .txp .grid{grid-template-columns:1fr}
  /* wide, nowrap tables scroll inside their own panel instead of being clipped by the page */
  .txp table{display:block;overflow-x:auto;-webkit-overflow-scrolling:touch}
  /* ≥16px so iOS Safari doesn't auto-zoom when the search field is focused */
  .txp .search input{font-size:16px}
  .txp .wrow{flex-wrap:wrap}
  .txp .wrow .wt{width:auto}
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

type Tab = "wire" | "street" | "families" | "floor" | "rails";
const TABS: [Tab, string][] = [["wire", "THE WIRE"], ["street", "THE STREET"], ["families", "FAMILIES"], ["floor", "THE FLOOR"], ["rails", "THE RAILS"]];
const WIRE_FILTERS = ["JOBS", "RAIDS", "HOUSES", "CREW", "MONEY"] as const;

/// ⟦…⟧ segments → mono-white <b>; the rest stays muted.
const B = ({ t }: { t: string }) => <>{t.split(/[⟦⟧]/).map((s, i) => (i % 2 ? <b key={i}>{s}</b> : s))}</>;

/// hh "h" remainder, e.g. 31h — for the big-score lock line.
const fmtHrs = (ms: number) => `${Math.max(0, Math.ceil((ms - Date.now()) / 3600_000))}h`;
const fmtMS = (ms: number) => {
  const s = Math.max(0, Math.floor((ms - Date.now()) / 1000));
  const mmss = `${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
  // Hours-scale spans (heat is 8h) read as h:mm:ss — "347:28" total-minutes was misreadable (review fix).
  return s >= 3600 ? `${Math.floor(s / 3600)}:${mmss}` : mmss;
};

/// The mission countdown chip: live [T-hh:mm:ss], --warn under 10 min, then [WINDOW CLOSED].
function MissionChip({ dueMs, settled }: { dueMs: number | null; settled: boolean }) {
  if (dueMs === null) return settled ? <span className="cdown muted">[WINDOW CLOSED]</span> : null;
  const left = dueMs - Date.now();
  if (left <= 0) return <span className="cdown muted">[WINDOW CLOSED]</span>;
  return <span className={"cdown" + (left < 600_000 ? " warn" : "")}>[T-{fmtHMS(left / 1000)}]</span>;
}

/// The stock-peg record — the live season's four briefs, straight from the guide's master ledger,
/// with the main-network token + price-wire contracts on file where a brief has them. No prices:
/// the feed is not wired to the web layer.
const PEGS: { brief: string; ticker: string; token: string | null; wire: string | null }[] = [
  { brief: "PAPER ROUTE", ticker: "SGOV", token: null, wire: null },
  { brief: "GLASS HARVEST · RUSH", ticker: "NVDA", token: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", wire: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15" },
  { brief: "PROOF OF WORK", ticker: "CLSK", token: null, wire: null },
  { brief: "ABSOLUTE ZERO", ticker: "IONQ / RGTI", token: null, wire: null },
];

export function ExplorerPage() {
  const gameOn = gameConfigured();
  const [tab, setTab] = useState<Tab>(gameOn ? "wire" : "rails");
  // ---- THE RAILS state (the protocol explorer, preserved intact) ----
  const [pool, setPool] = useState<Pool | null>(null);
  const [loans, setLoans] = useState<Loan[] | null>(null);
  const [acts, setActs] = useState<Act[] | null>(null);
  const [markets, setMarkets] = useState<Market[] | null>(null);
  const [head, setHead] = useState<bigint>(0n);
  const [q, setQ] = useState("");
  const [clock, setClock] = useState("");
  const mounted = useRef(true);
  // ---- game-era state ----
  const [wireRows, setWireRows] = useState<WireRow[]>([]);
  const [wireLoaded, setWireLoaded] = useState(false);
  const [tapeRows, setTapeRows] = useState<TapeRow[]>([]);
  const [econ, setEcon] = useState<Economy | null>(null);
  const [street, setStreet] = useState<Street | null>(null);
  const [chips, setChips] = useState<Set<string>>(new Set());
  const [bigOnly, setBigOnly] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const [, setTsTick] = useState(0);
  const [dossier, setDossier] = useState<{ status: "idle" | "loading" | "none" | "ok"; id?: bigint; d?: Dossier }>({ status: "idle" });
  const [famQ, setFamQ] = useState("");
  const lastScanned = useRef<bigint | null>(null);
  const wireRef = useRef<WireRow[]>([]);
  const firstKey = useRef<string | null>(null);
  const [freshKey, setFreshKey] = useState<string | null>(null);
  const seenKeys = useRef<Set<string>>(new Set());
  const thumpKeys = useRef<Set<string>>(new Set());

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

  // ---- THE WIRE: 15s log poll (monotonic store — rows never removed on a scan miss) ----
  const loadWire = useCallback(async () => {
    try {
      const r = await fetchGameWire(lastScanned.current ?? undefined);
      lastScanned.current = r.scanned;
      if (!mounted.current) return;
      setWireRows((prev) => { const m = mergeWire(prev, r.rows); wireRef.current = m; return m; });
      setWireLoaded(true);
    } catch { /* leave last good */ }
  }, []);
  const loadTapeRows = useCallback(async () => {
    try { const t = await fetchTape(); if (mounted.current) setTapeRows(t.rows); } catch { /* leave last good */ }
  }, []);
  useEffect(() => {
    if (!gameOn) return;
    loadWire(); loadTapeRows();
    const t = setInterval(() => { loadWire(); loadTapeRows(); }, 15_000);
    return () => clearInterval(t);
  }, [gameOn, loadWire, loadTapeRows]);

  // ---- reads: economy + street, 20s ----
  const loadReads = useCallback(async () => {
    try { const e = await fetchEconomy(); if (mounted.current) setEcon(e); } catch { /* leave last good */ }
    try { const s = await fetchStreet(wireRef.current); if (mounted.current) setStreet(s); } catch { /* leave last good */ }
  }, []);
  useEffect(() => {
    if (!gameOn) return;
    const first = setTimeout(loadReads, 1200); // let the first wire scan land so the street has candidates
    const t = setInterval(loadReads, 20_000);
    return () => { clearTimeout(first); clearInterval(t); };
  }, [gameOn, loadReads]);

  const ql = q.trim().toLowerCase();
  const loansF = useMemo(() => (loans ?? []).filter((l) => !ql || l.owner.toLowerCase().includes(ql) || l.id.toString() === ql || tokenName(l.token).toLowerCase().includes(ql)), [loans, ql]);
  const actsF = useMemo(() => (acts ?? []).filter((a) => !ql || a.actor.toLowerCase().includes(ql) || a.tx.toLowerCase().includes(ql)), [acts, ql]);

  const expl = (path: string) => `${NET.explorer}/${path}`;

  // ---- merged feed: game rows + MONEY rows from the protocol tape (tape.ts row() output, verbatim) ----
  const merged = useMemo<WireRow[]>(() => {
    const money: WireRow[] = tapeRows.map((r) => ({
      key: r.key, block: r.block, logIndex: Number(r.key.split(":")[1] ?? 0), tx: r.tx,
      filter: "MONEY", kind: "tape", icon: r.icon, text: r.text,
    }));
    return mergeWire(wireRows, money, 400);
  }, [wireRows, tapeRows]);

  const settledMissions = useMemo(() => {
    const s = new Set<string>();
    for (const r of wireRows) if ((r.kind === "Resolved" || r.kind === "Reclaimed") && r.missionId !== undefined) s.add(r.missionId.toString());
    return s;
  }, [wireRows]);

  const wireF = useMemo(() => merged.filter((r) => {
    if (chips.size > 0 && !chips.has(r.filter)) return false;
    if (bigOnly && !r.stamp?.big) return false; // big MOMENTS only (review-gate fix: was any-stamp)
    if (ql && !(r.text.toLowerCase().includes(ql) || r.tx.toLowerCase().includes(ql) || r.donId?.toString() === ql || r.raidId?.toString() === ql)) return false;
    return true;
  }), [merged, chips, bigOnly, ql]);

  // Visible slice (24 + MORE up to the 80-row cap); >5 yield rows in view roll into one line.
  const visible = useMemo(() => {
    let vis = wireF.slice(0, expanded ? 80 : 24);
    const yields = vis.filter((r) => r.kind === "YieldAccrued");
    if (yields.length > 5) {
      const sum = yields.reduce((acc, r) => acc + (r.amt ?? 0n), 0n);
      const fams = new Set(yields.map((r) => r.donId?.toString() ?? "")).size;
      const first = yields[0];
      const synth: WireRow = { ...first, key: `yield-collapse:${first.key}`, text: `the Houses paid · ⟦${fmtScrip(sum)}⟧ yield across ⟦${fams}⟧ families`, stamp: undefined };
      vis = vis.flatMap((r) => (r.kind === "YieldAccrued" ? (r.key === first.key ? [synth] : []) : [r]));
    }
    return vis;
  }, [wireF, expanded]);

  // Freshness: pulse the newest genuinely-new row once; thump only rows that arrive after load.
  useEffect(() => {
    if (merged.length === 0) return;
    if (firstKey.current === null) {
      firstKey.current = merged[0].key;
      for (const r of merged) seenKeys.current.add(r.key);
      return;
    }
    if (merged[0].key !== firstKey.current) {
      setFreshKey(merged[0].key);
      firstKey.current = merged[0].key;
    }
    for (const r of merged) {
      if (!seenKeys.current.has(r.key)) {
        seenKeys.current.add(r.key);
        if (r.stamp?.thump) thumpKeys.current.add(r.key);
      }
    }
  }, [merged]);

  // Block timestamps for visible rows only — one cached getBlock per unique block.
  const visKeySig = visible.map((r) => r.key).join(",");
  useEffect(() => {
    const blocks = [...new Set(visible.filter((r) => tsOf(r.block) === null).map((r) => r.block))];
    if (blocks.length === 0) return;
    let live = true;
    Promise.all(blocks.slice(0, 40).map((bn) => blockTs(bn))).then(() => { if (live && mounted.current) setTsTick((t) => t + 1); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [visKeySig]);

  // ---- FAMILIES ----
  const openDossier = useCallback(async (id: bigint) => {
    setTab("families");
    setFamQ(id.toString());
    setDossier({ status: "loading", id });
    try {
      const d = await fetchDossier(id);
      if (mounted.current) setDossier(d ? { status: "ok", id, d } : { status: "none", id });
    } catch { if (mounted.current) setDossier({ status: "none", id }); }
  }, []);

  // search: a small-integer query offers the dossier jump (≤ 8888 families).
  const qNum = /^\d{1,4}$/.test(q.trim()) && Number(q.trim()) >= 1 && Number(q.trim()) <= 8888 ? BigInt(q.trim()) : null;

  const timeCell = (r: WireRow) => {
    const ts = tsOf(r.block);
    return ts !== null ? `${new Date(ts).toISOString().slice(11, 19)} · b${r.block.toString()}` : `b${r.block.toString()}`;
  };

  const wireRow = (r: WireRow) => (
    <div key={r.key} className={"wrow" + (r.key === freshKey ? " fresh" : "")}>
      <span className="wt">{timeCell(r)}</span>
      {r.stamp && (
        <span className={"stamp " + r.stamp.tone + (r.stamp.big ? " bigst" : "") + (r.stamp.thump && thumpKeys.current.has(r.key) ? " thump" : "")}>
          {r.stamp.text}
        </span>
      )}
      <span className="wi">{r.icon}</span>
      <span className={"wb" + (r.muted ? " mut" : "")}>
        <B t={r.text} />
        {r.countdown && r.missionId !== undefined && (
          <MissionChip dueMs={missionDueMs(r.missionId)} settled={settledMissions.has(r.missionId.toString())} />
        )}
      </span>
      <a className="wx" href={txUrl(r.tx)} target="_blank" rel="noreferrer">verify ↗</a>
    </div>
  );

  // per-tab search-hit counter (the rails count keeps its original meaning)
  const hits = tab === "rails" ? loansF.length + actsF.length : tab === "wire" ? wireF.length
    : tab === "street" ? (street ? street.jobs.length + street.raids.length + street.hospital.length + street.hits.length : 0)
    : tab === "families" ? (dossier.status === "ok" ? 1 : 0) : 0;

  const damagedCount = street ? new Set(street.hits.filter((h) => h.damaged).map((h) => h.donId.toString())).size : null;

  const notPosted = <div className="panel full"><div className="empty">this desk opens with the season posting</div></div>;

  return (
    <div className="txp">
      <style>{CSS}</style>

      <div className="top">
        <div className="brand"><b>ESSEY</b>&nbsp;SCAN<span className="sub">the Solvency desk</span></div>
        <div className="search">
          <span className="muted">&gt;</span>
          <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="SEARCH  ADDRESS / TX / DON № / MISSION / RAID / LOAN" spellCheck={false} />
          {qNum !== null && <button className="v" onClick={() => openDossier(qNum)}>open dossier №{qNum.toString()} →</button>}
          <span className="muted">{hits} hits</span>
        </div>
        <div className="clock">{clock || "—"}</div>
      </div>

      <div className="ticker">
        {gameOn && <>
          <span>SCRIP SUPPLY <b>{econ?.supply != null ? fmtScrip(econ.supply) : "—"}</b></span>
          <span>BURNED <b>{econ?.burned != null ? fmtScrip(econ.burned) : "—"}</b></span>
          <span>DONS AWAY <b>{street ? street.jobs.length : "—"}</b></span>
          <span>HOUSES DAMAGED <b>{damagedCount ?? "—"}</b></span>
          <span>MISSION BUDGET <b>{econ?.missionBudget != null ? fmtScrip(econ.missionBudget) : "—"}</b></span>
        </>}
        <span className="muted" style={{ marginLeft: "auto" }}>chain {NET.chainId} · block {head ? head.toString() : "—"}</span>
      </div>

      <div className="tabs">
        {TABS.map(([t, label]) => (
          <button key={t} className={"tab" + (tab === t ? " on" : "")} onClick={() => setTab(t)}>{label}</button>
        ))}
      </div>
      <div className="season">SEASON 0 · THE SKIRMISH · played in Scrip, the city&rsquo;s season money · play money · no real value at stake</div>

      {/* ═══════════════ THE WIRE ═══════════════ */}
      {tab === "wire" && (!gameOn ? <div className="grid">{notPosted}</div> : (
        <div>
          <div className="chips">
            <button className={"chipf" + (chips.size === 0 && !bigOnly ? " on" : "")} onClick={() => { setChips(new Set()); setBigOnly(false); }}>ALL</button>
            {WIRE_FILTERS.map((f) => (
              <button key={f} className={"chipf" + (chips.has(f) ? " on" : "")}
                onClick={() => setChips((prev) => { const n = new Set(prev); if (n.has(f)) n.delete(f); else n.add(f); return n; })}>{f}</button>
            ))}
            <button className={"chipf" + (bigOnly ? " on" : "")} onClick={() => setBigOnly((v) => !v)}>⬡ BIG ONLY</button>
          </div>
          <div className="wire">
            {!wireLoaded && visible.length === 0 && <div className="empty" style={{ padding: "10px" }}>reading the chain…</div>}
            {wireLoaded && visible.length === 0 && (
              <div className="empty" style={{ padding: "10px" }}>
                {merged.length === 0
                  ? "the Tape is quiet · nothing has printed in this window · fog is just news that hasn't happened yet"
                  : "nothing in this filter yet"}
              </div>
            )}
            {visible.map(wireRow)}
          </div>
          {wireF.length > visible.length && !expanded && (
            <button className="v" style={{ marginTop: 8 }} onClick={() => setExpanded(true)}>MORE ({Math.min(wireF.length, 80) - visible.length} older)</button>
          )}
        </div>
      ))}

      {/* ═══════════════ THE STREET ═══════════════ */}
      {tab === "street" && (!gameOn ? <div className="grid">{notPosted}</div> : (
        <div className="grid">
          <div className="panel">
            <div className="ph"><span className="t">OUT ON JOBS</span><span className="s">exposed while away · chain truth</span></div>
            {!street && <div className="empty">casing the street…</div>}
            {street && street.jobs.length === 0 && <div className="empty">every Don in Solvency is home · no windows open, no houses exposed</div>}
            {street?.jobs.map((jb) => (
              <div key={jb.donId.toString()} className="srow">
                <DonImg id={jb.donId} className="donth" />
                <div style={{ minWidth: 0 }}>
                  <div><b style={{ color: "var(--tx)" }}>№{jb.donId.toString()}</b> <span className="good">{jb.codename}</span> <MissionChip dueMs={jb.dueMs} settled={false} /></div>
                  <div className="muted">hopper {fmtScrip(jb.hopper)} exposed · safe band {fmtScrip(jb.deployed * 15n / 100n)}–{fmtScrip(jb.deployed * 30n / 100n)} (15–30% of {fmtScrip(jb.deployed)})</div>
                  <div className="muted">heat: {jb.heatMs > Date.now() ? fmtMS(jb.heatMs) : "none"} · big-score lock: {jb.bigLockMs > Date.now() ? fmtHrs(jb.bigLockMs) : "none"}</div>
                </div>
              </div>
            ))}
            <div className="cap">band per the posted big-score curve</div>
          </div>

          <div>
            <div className="panel" style={{ marginBottom: 10 }}>
              <div className="ph"><span className="t">OPEN HIT ORDERS</span><span className="s">commit → reveal → settle</span></div>
              {!street && <div className="empty">reading the docket…</div>}
              {street && street.raids.length === 0 && <div className="empty">no hit orders on file · the incinerator waits</div>}
              {street?.raids.map((r) => (
                <div key={r.raidId.toString()} className="srow">
                  <div style={{ minWidth: 0 }}>
                    {r.state === 0 ? (
                      <div>raid #{r.raidId.toString()} · <b style={{ color: "var(--tx)" }}>sealed</b> · a crew working for №{r.attacker.toString()} · target undisclosed</div>
                    ) : (
                      <>
                        <div>raid #{r.raidId.toString()} · door kicked → <b style={{ color: "var(--tx)" }}>№{r.target.toString()}</b>{!r.garrisonRevealed && <> · garrison fog</>}</div>
                        <div className="muted">{r.garrisonRevealed
                          ? "garrison out · the word is with the Keeper"
                          : `floor settle opens in ${fmtMS(r.revealedAt + 3600_000)}`}</div>
                      </>
                    )}
                  </div>
                </div>
              ))}
            </div>
            <div className="panel">
              <div className="ph"><span className="t">THE HOSPITAL</span><span className="s">48h beds</span></div>
              {!street && <div className="empty">checking the ward…</div>}
              {street && street.hospital.length === 0 && <div className="empty">every bed is empty · the crews are healthy or lucky</div>}
              {street?.hospital.map((h) => (
                <div key={h.hitterId.toString()} className="srow"><div>H-{h.hitterId.toString()} <span className="muted">out in {fmtHMS((h.untilMs - Date.now()) / 1000)}</span></div></div>
              ))}
            </div>
          </div>

          <div className="panel full">
            <div className="ph"><span className="t">HOUSES HIT THIS WEEK</span><span className="s">RaidSettled · last 7 days</span></div>
            {!street && <div className="empty">pulling the blotter…</div>}
            {street && street.hits.length === 0 && <div className="empty">no house lost a coin this week · the doors held or nobody knocked</div>}
            {street?.hits.map((h) => (
              <div key={`${h.donId}-${h.raidId}`} className="srow">
                <div>
                  <b style={{ color: "var(--tx)" }}>№{h.donId.toString()}</b>{" "}
                  {h.big ? <span className="bad">BIG SCORE</span> : <span className="muted">common hit</span>}{" "}
                  <span className="bad">-{fmtScrip(h.taken)}</span>{" "}
                  {h.damaged ? <span className="stamp warn">SCARRED</span> : <span className="muted">· repaired</span>}{" "}
                  <a href={txUrl(h.tx)} target="_blank" rel="noreferrer">verify ↗</a>
                </div>
              </div>
            ))}
          </div>
        </div>
      ))}

      {/* ═══════════════ FAMILIES ═══════════════ */}
      {tab === "families" && (!gameOn ? <div className="grid">{notPosted}</div> : (
        <div className="grid">
          <div className="panel full">
            <div className="ph"><span className="t">FAMILIES</span><span className="s">one dossier at a time</span></div>
            <div style={{ display: "flex", gap: 8, marginBottom: 10 }}>
              <div className="search" style={{ flex: "0 1 260px" }}>
                <span className="muted">№</span>
                <input value={famQ} onChange={(e) => setFamQ(e.target.value)} placeholder="DON NUMBER" spellCheck={false}
                  onKeyDown={(e) => { if (e.key === "Enter" && /^\d+$/.test(famQ.trim())) openDossier(BigInt(famQ.trim())); }} />
              </div>
              <button className="v" disabled={!/^\d+$/.test(famQ.trim())} onClick={() => openDossier(BigInt(famQ.trim()))}>PULL THE FILE</button>
            </div>
            {dossier.status === "idle" && <div className="empty">pull a file · enter a Don&rsquo;s number · everything printed here is chain truth</div>}
            {dossier.status === "loading" && <div className="empty">pulling file №{dossier.id?.toString()}…</div>}
            {dossier.status === "none" && <div className="empty">no file under that number · 8,888 families, none of them this one</div>}
            {dossier.status === "ok" && dossier.d && (() => {
              const d = dossier.d;
              const famRows = wireRows.filter((r) => r.donId !== undefined && r.donId === d.donId).slice(0, 20);
              return (
                <div>
                  <div className="ph"><span className="t">DOSSIER №{d.donId.toString()}</span><span className="s">owner <a href={expl(`address/${d.owner}`)} target="_blank" rel="noreferrer">{short(d.owner)}</a></span></div>
                  <div className="dosbody">
                    <DonImg id={d.donId} className="dosimg" />
                    <div className="doslines">
                      <div>№{d.donId.toString()} · kit: {d.kitClaimed ? <b>class {d.kitClass} · on the record</b> : <b>unclaimed</b>} <span className="arrives">· kit mint · ARRIVES WITH A LATER POSTING ·</span></div>
                      <div>status: {d.away
                        ? <><b>AWAY — {d.codename ?? `mission #${d.missionId.toString()}`}</b> <MissionChip dueMs={d.dueMs} settled={false} /></>
                        : <b>HOME</b>}</div>
                      <div>VAULT <b>{d.vaultScrip != null ? fmtScrip(d.vaultScrip) : "—"}</b>&nbsp;&nbsp;DEPLOYED <b>{fmtScrip(d.deployed)}</b>&nbsp;&nbsp;HOPPER <b>{fmtScrip(d.hopper)}</b></div>
                      <div className="muted">vault is forever · deployed can be taken · hopper is the till</div>
                      <div>house: {d.deedId === 0n ? <span className="muted">no deed yet · claimed at first depart</span> : <>tier <b>{d.tier}</b> · defense <b>{d.defense}</b> · garrison <b>{d.slots}</b> slots · deploy cap <b>{fmtScrip(d.deployCap)}</b></>}</div>
                      <div>condition: {d.damageBps > 0
                        ? <><span className="stamp warn">SCARRED</span> <span className="muted">(-40% until repaired · bill {fmtScrip(d.repairFee)})</span></>
                        : <b>intact</b>}</div>
                      <div>pending yield <b>{fmtScrip(d.pendingYield)}</b> · heat {d.heatMs > Date.now() ? <b>{fmtMS(d.heatMs)}</b> : "none"} · big-score lock {d.bigLockMs > Date.now() ? <b>{fmtHrs(d.bigLockMs)}</b> : "none"}</div>
                      <div>crew: {d.crew.length === 0 ? <span className="muted">no soldiers on this payroll</span> : d.crew.map((c, i) => (
                        <span key={c.id.toString()}>{i > 0 && " · "}H-{c.id.toString()} ({c.hospitalMs > Date.now() ? `hospital ${fmtHrs(c.hospitalMs)}` : "fit"}) · envelope: {c.sealed ? "sealed" : ["empty", "a small favor", "a real favor", "the Don owes him"][c.favor] ?? "opened"}</span>
                      ))}</div>
                    </div>
                  </div>
                  <div className="ph" style={{ marginTop: 12 }}><span className="t" style={{ fontSize: 11 }}>── RECENT, THIS FAMILY ──</span><span className="s">last {famRows.length} printed</span></div>
                  <div className="wire">
                    {famRows.length === 0 && <div className="empty" style={{ padding: 10 }}>nothing printed for this family in the scanned window</div>}
                    {famRows.map(wireRow)}
                  </div>
                </div>
              );
            })()}
          </div>
        </div>
      ))}

      {/* ═══════════════ THE FLOOR ═══════════════ */}
      {tab === "floor" && (!gameOn ? <div className="grid">{notPosted}</div> : (() => {
        const sum = (pred: (r: WireRow) => boolean, pick: (r: WireRow) => bigint | undefined) =>
          wireRows.filter(pred).reduce((acc, r) => acc + (pick(r) ?? 0n), 0n);
        const doorFees = sum((r) => r.kind === "Departed", (r) => r.amt);
        const raidTax = sum((r) => r.kind === "RaidSettled", (r) => r.amt2);
        const repairFees = sum((r) => r.kind === "Repaired", (r) => r.amt);
        const forfeits = wireRows.filter((r) => r.kind === "RaidForfeited").length;
        const forfeitBurn = BigInt(forfeits) * 50n * 10n ** 18n;
        const drawdown = sum((r) => r.kind === "Resolved" || r.kind === "Reclaimed", (r) => r.amt);
        const refills = sum((r) => r.kind === "BudgetFunded", (r) => r.amt);
        const yieldPaid = sum((r) => r.kind === "YieldAccrued", (r) => r.amt);
        const totalBurn = doorFees + raidTax + repairFees + forfeitBurn;
        return (
          <div className="grid">
            <div className="panel">
              <div className="ph"><span className="t">SCRIP</span><span className="s">the season money</span></div>
              <div className="big">{econ?.supply != null ? fmtScrip(econ.supply) : "…"} <span className="muted" style={{ fontSize: 13 }}>supply</span></div>
              <div className="kv">
                <div><span className="k">BURNED, ALL-TIME</span><span className="v">{econ?.burned != null ? fmtScrip(econ.burned) : "—"}</span></div>
                <div><span className="k">SEASON</span><span className="v">Season 0 · the Skirmish <span className="muted">(scrip.seasonId {econ?.seasonId ?? "—"})</span></span></div>
                <div><span className="k">CUSTODY</span><span className="v">{econ?.custodyOk == null ? <span className="muted">—</span> : econ.custodyOk
                  ? <span className="okg">✓ escrow holds deployed + hopper, exactly</span>
                  : <span className="bad">✗ custody mismatch — read the chain</span>}</span></div>
                {econ?.custodyOk != null && (
                  <div><span className="k">THE CHECK</span><span className="v muted">{econ.escrowBal != null ? fmtScrip(econ.escrowBal) : "—"} = {econ.totalDeployed != null ? fmtScrip(econ.totalDeployed) : "—"} + {econ.totalHopper != null ? fmtScrip(econ.totalHopper) : "—"}</span></div>
                )}
              </div>
            </div>

            <div className="panel">
              <div className="ph"><span className="t">MISSION BUDGET</span><span className="s">funded, never printed</span></div>
              <div className="big">{econ?.missionBudget != null ? fmtScrip(econ.missionBudget) : "…"}</div>
              <div className="kv">
                <div><span className="k">RESERVED (WORST-CASE)</span><span className="v">{econ?.outstandingReserved != null ? fmtScrip(econ.outstandingReserved) : "—"}</span></div>
                <div><span className="k">PAID OUT, WINDOW</span><span className="v">{fmtScrip(drawdown)}</span></div>
                <div><span className="k">REFILLS, WINDOW</span><span className="v">{fmtScrip(refills)}</span></div>
              </div>
              <div className="cap">the Keeper pays from a funded budget · it cannot print</div>
            </div>

            <div className="panel">
              <div className="ph"><span className="t">YIELD</span><span className="s">the House pays</span></div>
              <div className="big">{fmtScrip(yieldPaid)} <span className="muted" style={{ fontSize: 13 }}>paid in window</span></div>
              <div className="kv">
                <div><span className="k">RATE</span><span className="v">0.15%/day · fixed this season · posted on-chain</span></div>
                <div><span className="k">YIELD BUDGET LEFT</span><span className="v">{econ?.yieldBudget != null ? fmtScrip(econ.yieldBudget) : "—"}</span></div>
                <div><span className="k">STIPEND BUDGET LEFT</span><span className="v">{econ?.stipendBudget != null ? fmtScrip(econ.stipendBudget) : "—"}</span></div>
              </div>
            </div>

            <div className="panel">
              <div className="ph"><span className="t">THE BELL &amp; THE POOL</span><span className="s">the rails&rsquo; figures, same reads</span></div>
              <div className="kv">
                <div><span className="k">BELL POT</span><span className="v">{pool ? fmt(pool.pot, 0) : "—"} USDG</span></div>
                <div><span className="k">POOL TVL</span><span className="v">{pool ? fmt(pool.tvl, 0) : "—"} USDG</span></div>
                <div><span className="k">SUPPLY APY</span><span className="v good">{pool ? pool.supplyApy.toFixed(2) + "%" : "—"}</span></div>
              </div>
              <div className="cap"><a onClick={() => setTab("rails")} style={{ cursor: "pointer" }}>→ THE RAILS</a> · the provable rails under the city</div>
            </div>

            <div className="panel full">
              <div className="ph"><span className="t">THE INCINERATOR</span><span className="s">window: since the season posting (block 100489472)</span></div>
              <table>
                <thead><tr><th>WHAT BURNED</th><th className="r">COUNT</th><th className="r">AMOUNT</th></tr></thead>
                <tbody>
                  <tr><td>door fees (dispatch)</td><td className="r muted">{wireRows.filter((r) => r.kind === "Departed").length}</td><td className="r">{fmtScrip(doorFees)}</td></tr>
                  <tr><td>raid tax to the Floor</td><td className="r muted">{wireRows.filter((r) => r.kind === "RaidSettled").length}</td><td className="r">{fmtScrip(raidTax)}</td></tr>
                  <tr><td>forfeited hit orders (50 each)</td><td className="r muted">{forfeits}</td><td className="r">{fmtScrip(forfeitBurn)}</td></tr>
                  <tr><td>repair bills</td><td className="r muted">{wireRows.filter((r) => r.kind === "Repaired").length}</td><td className="r">{fmtScrip(repairFees)}</td></tr>
                  <tr><td className="good">TOTAL, WINDOW</td><td className="r" /><td className="r good">{fmtScrip(totalBurn)}</td></tr>
                </tbody>
              </table>
              <div className="cap">everything the city takes, it burns or banks in public · window sums are added up from chain events, not a separate ledger</div>
            </div>

            <div className="panel full">
              <div className="ph"><span className="t">STOCK PEGS</span><span className="s">the briefs&rsquo; tickers · main-network contracts on file</span></div>
              <table>
                <thead><tr><th>BRIEF</th><th>TICKER</th><th>TOKEN</th><th>PRICE WIRE</th></tr></thead>
                <tbody>
                  {PEGS.map((p) => (
                    <tr key={p.brief}>
                      <td className="good">{p.brief}</td>
                      <td>{p.ticker}</td>
                      <td>{p.token ? <a href={`https://robinhoodchain.blockscout.com/address/${p.token}`} target="_blank" rel="noreferrer">{short(p.token)}</a> : <span className="muted">—</span>}</td>
                      <td>{p.wire ? <a href={`https://robinhoodchain.blockscout.com/address/${p.wire}`} target="_blank" rel="noreferrer">{short(p.wire)}</a> : <span className="muted">—</span>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <div className="cap">this season settles in Scrip, marked to the peg · the seasons that settle in the tokens themselves are the roadmap · no price feed is wired to the web layer yet</div>
            </div>
          </div>
        );
      })())}

      {/* ═══════════════ THE RAILS — the protocol explorer, preserved intact ═══════════════ */}
      {tab === "rails" && (
        <div>
          <div className="cap" style={{ margin: "0 0 8px" }}>the provable rails under the city</div>
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

            {/* MARKETS — real borrow-open status */}
            <div className="panel">
              <div className="ph"><span className="t">MARKETS</span><span className="s">collateral</span></div>
              <table>
                <thead><tr><th>ASSET</th><th className="r">BORROW</th></tr></thead>
                <tbody>
                  {(markets ?? []).map((m) => (
                    <tr key={m.sym}>
                      <td className="good">{m.sym}</td>
                      <td className="r">{m.canBorrow === null ? <span className="muted">—</span> : m.canBorrow ? <span className="pill good">OPEN</span> : <span className="pill warn">CLOSED</span>}</td>
                    </tr>
                  ))}
                  {!markets && <tr><td colSpan={2} className="empty">loading…</td></tr>}
                </tbody>
              </table>
            </div>

            {/* LOANS — real positions; health computed from live maxBorrow reads */}
            <div className="panel full">
              <div className="ph"><span className="t">OPEN LOANS</span><span className="s">live positions · health read from the chain</span></div>
              <div style={{ overflowX: "auto" }}>
                <table>
                  <thead><tr><th>ID</th><th>BORROWER</th><th>COLLATERAL</th><th className="r">DEBT</th><th className="r">LTV / MAX</th><th>HEALTH</th></tr></thead>
                  <tbody>
                    {loansF.map((l) => {
                      const util = l.maxDebt > 0n ? Number(l.debt) / Number(l.maxDebt) : null;
                      const hp = util === null ? null : util <= 0.85 ? "good" : util <= 1 ? "warn" : "bad";
                      return (
                        <tr key={l.id.toString()}>
                          <td className="muted">#{l.id.toString()}</td>
                          <td><a href={expl(`address/${l.owner}`)} target="_blank" rel="noreferrer">{short(l.owner)}</a></td>
                          <td>{fmt(l.collateralRaw, 2)} <span className="good">{tokenName(l.token)}</span></td>
                          <td className="r">{fmt(l.debt, 2)} USDG</td>
                          <td className="r">{util === null ? <span className="muted">—</span> : <span className={hp!}>{(util * 100).toFixed(0)}%</span>}</td>
                          <td>{hp === null ? <span className="muted">—</span> : hp === "good" ? <span className="good">HEALTHY</span> : hp === "warn" ? <span className="warn">TIGHT</span> : <span className="bad">UNDERWATER</span>}</td>
                        </tr>
                      );
                    })}
                    {loans && loansF.length === 0 && <tr><td colSpan={6} className="empty">{loans.length === 0 ? "no open loans in the scanned window" : "no matches"}</td></tr>}
                    {!loans && <tr><td colSpan={6} className="empty">scanning positions…</td></tr>}
                  </tbody>
                </table>
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
        </div>
      )}

      <div className="foot">
        <span>ESSEY SCAN · v2 · Robinhood Chain {NET.chainId} · <a href={NET.explorer} target="_blank" rel="noreferrer">raw explorer ↗</a></span>
        <span>every line links its receipt · read the chain yourself</span>
      </div>
    </div>
  );
}
