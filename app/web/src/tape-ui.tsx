// The Tape — the full /tape room. Reads the MAINNET reserve (4663) live; when it is quiet it says so
// rather than faking motion, and the `live` chip only appears once a real read has come back.
import { useCallback, useEffect, useRef, useState } from "react";
import { fetchMainnetTape, mainnetLive, mainnetTxUrl, type MainnetTapeRow } from "./tape-mainnet";
import { RESERVE } from "./reserve";
import { EMonogram } from "./market";

type Feed = { rows: MainnetTapeRow[]; head: bigint | null; loaded: boolean; ok: boolean };

/// A failed read keeps the last good rows but drops `ok`, so the chip never claims live off a stale render.
function useTape(pollMs = 20_000): Feed {
  const [feed, setFeed] = useState<Feed>({ rows: [], head: null, loaded: false, ok: false });
  const load = useCallback(() => {
    fetchMainnetTape()
      .then(({ rows, head }) => setFeed({ rows, head, loaded: true, ok: true }))
      .catch(() => setFeed((f) => ({ ...f, loaded: true, ok: false })));
  }, []);
  useEffect(() => { load(); const t = setInterval(load, pollMs); return () => clearInterval(t); }, [load, pollMs]);
  return feed;
}

const FILTERS: [string, string, (r: MainnetTapeRow) => boolean][] = [
  ["All", "Nothing has moved through the reserve yet.", () => true],
  ["Deposits", "No deposits yet — the reserve is empty.", (r) => r.kind === "deposit"],
  ["Redemptions", "No redemptions yet. No $ESSEY has been burned against the reserve.", (r) => r.kind === "redeem" || r.kind === "claim"],
];

const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

export function TapeRoom() {
  const { rows, head, loaded, ok } = useTape(15_000);
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

  const shown = rows.filter(FILTERS[fi][2]);

  return (
    <section className="band" id="tape" style={{ paddingTop: 34 }}>
      <div className="wrap">
        <div className="band-head"><div>
          <span className="eyebrow">The Tape</span>
          <h2>Every event, with its receipt</h2>
          <p>Every token that has gone into the $ESSEY reserve and every redemption that has come back
            out, read straight from Robinhood Chain mainnet. The reserve is <b>adminless</b> — no owner,
            no withdraw, no pause — so this is the whole story: a deposit raises the floor under every
            $ESSEY, and a redemption burns $ESSEY for its pro-rata slice, minus a 5% exit fee that stays
            behind as over-collateralisation.</p>
        </div>
          {mainnetLive() && ok ? <span className="preview-chip live">live</span> : null}
        </div>

        <div className="tape-filters">
          {FILTERS.map(([label], i) => (
            <button key={label} className={"tape-filter" + (i === fi ? " on" : "")} onClick={() => setFi(i)}>{label}</button>
          ))}
        </div>

        <div className="tape-list">
          {!loaded ? (
            <div className="tape-empty">Reading the chain…</div>
          ) : !ok && rows.length === 0 ? (
            <div className="tape-empty">Could not reach Robinhood Chain mainnet. Nothing is shown rather than something stale.</div>
          ) : shown.length === 0 ? (
            <div className="tape-empty">{FILTERS[fi][1]}</div>
          ) : (
            shown.map((r) => (
              <a key={r.key} className={"tape-room-row" + (r.key === freshKey ? " fresh" : "")} href={mainnetTxUrl(r.tx)} target="_blank" rel="noreferrer">
                <span className="trr-icon">{r.mark ? <EMonogram size={18} /> : r.icon}</span>
                <span className="trr-text num">{r.text}</span>
                <span className="trr-tx num">{r.tx.slice(0, 8)}…{r.tx.slice(-4)} ↗</span>
              </a>
            ))
          )}
        </div>

        <p className="disclaim num" style={{ marginTop: 14 }}>
          Robinhood Chain mainnet · chain 4663 · reserve {short(RESERVE.reserve)} · $ESSEY {short(RESERVE.essey)}
          {head !== null ? ` · read at block ${head.toLocaleString("en-US")}` : ""} · every event since deployment, newest first.
        </p>
      </div>
    </section>
  );
}
