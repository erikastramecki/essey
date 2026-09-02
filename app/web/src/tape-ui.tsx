// The Tape — the full /tape room. Reads live from the chain; when it's quiet it says so rather than
// faking motion (the brand's whole point).
import { useCallback, useEffect, useRef, useState } from "react";
import { fetchTape, txUrl, type TapeRow } from "./tape";
import { EMonogram } from "./market";

/// The room's chain poller.
function useTape(pollMs = 20_000) {
  const [rows, setRows] = useState<TapeRow[]>([]);
  const [loaded, setLoaded] = useState(false);
  const load = useCallback(() => { fetchTape().then(({ rows }) => { setRows(rows); setLoaded(true); }).catch(() => setLoaded(true)); }, []);
  useEffect(() => { load(); const t = setInterval(load, pollMs); return () => clearInterval(t); }, [load, pollMs]);
  return { rows, loaded };
}

/// The full room: reverse-chronological, filterable, every row a receipt.
const FILTERS: [string, (r: TapeRow) => boolean][] = [
  ["All", () => true],
  ["Bell & Payouts", (r) => r.kind === "bell_rung" || r.kind === "payout" || r.kind === "interest"],
  ["Trades", (r) => r.kind === "trade"],
  ["Dons & Tiers", (r) => r.kind === "don_minted" || r.kind === "don_move" || r.kind === "tier"],
  ["Loans", (r) => r.kind === "loan"],
  ["⬡ proven only", (r) => r.proven],
];

export function TapeRoom() {
  const { rows, loaded } = useTape(15_000);
  const [fi, setFi] = useState(0);
  const firstKey = useRef<string | null>(null);
  const [freshKey, setFreshKey] = useState<string | null>(null);
  useEffect(() => { document.title = "The Tape · Essey"; }, []);

  // Pulse the newest row once when a genuinely new event arrives.
  useEffect(() => {
    if (rows.length && rows[0].key !== firstKey.current) {
      if (firstKey.current !== null) setFreshKey(rows[0].key);
      firstKey.current = rows[0].key;
    }
  }, [rows]);

  const shown = rows.filter(FILTERS[fi][1]);

  return (
    <section className="band" id="tape" style={{ paddingTop: 34 }}>
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The Tape</span>
          <h2>Every receipt, live</h2>
          <p>Everything the club does, printed as it happens on-chain, and every line links
            the real transaction. The <b>⬡ proven only</b> filter shows just the events whose correctness is
            checkable on-chain: rings, payouts, fair draws, solvent loans.</p>
        </div>
          <span className="preview-chip live">live</span>
        </div>

        <div className="tape-filters">
          {FILTERS.map(([label], i) => (
            <button key={label} className={"tape-filter" + (i === fi ? " on" : "")} onClick={() => setFi(i)}>{label}</button>
          ))}
        </div>

        <div className="tape-list">
          {!loaded ? (
            <div className="tape-empty">Reading the chain…</div>
          ) : shown.length === 0 ? (
            <div className="tape-empty">{rows.length === 0
              ? "No events in the recent window. The club is quiet. Play a flow and watch it print here."
              : "Nothing in this filter yet."}</div>
          ) : (
            shown.map((r) => (
              <a key={r.key} className={"tape-room-row" + (r.key === freshKey ? " fresh" : "")} href={txUrl(r.tx)} target="_blank" rel="noreferrer">
                <span className="trr-icon">{r.proven ? <EMonogram size={18} /> : r.icon}</span>
                <span className="trr-text num">{r.text}</span>
                <span className="trr-tx num">{r.tx.slice(0, 8)}…{r.tx.slice(-4)} ↗</span>
              </a>
            ))
          )}
        </div>
      </div>
    </section>
  );
}
