// ESSEY SCAN — the protocol explorer, on Robinhood Chain MAINNET (4663). Everything on this page is
// the EsseyReserve's own state and its own history: the tokens it holds, the claim they back, and
// every event since it deployed. The game-era explorer that used to sit here read TESTNET 46630 and
// printed a play-money banner over it; it now lives in the game wing (game/explorer.tsx).
//
// Honesty rules: the page reads the chain and shows exactly what it read. `deployed()` gates it, a
// failed read keeps the last good rows but drops the `live` chip, and a figure with no price source
// is excluded from the total rather than counted as zero. Redemptions are printed from
// receiptCount() — an empty ledger says so, it never falls back to another chain.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { parseAbi } from "viem";
import { unpricedReason } from "./prices";
import {
  deployed,
  fmt as fmtUnits,
  MAINNET as RH,
  mainnetPub,
  reads as reserveReads,
  RESERVE,
  usd,
  type TreasuryState,
} from "./reserve";
import {
  fetchMainnetTape,
  mainnetTxUrl,
  type MainnetTapeRow,
} from "./tape-mainnet";

// ---- the scan terminal, on the shared design tokens (styles.css) ----
// The ledger-floor palette the game-era desk established, trimmed to the rules this page uses: brass
// accent, hairline rules, squared corners, mono throughout. The whole terminal is tabular-nums at the
// root, so figures inside it need no per-cell class.
const CSS = `
.txp{background:var(--ink);color:var(--tx);font-family:var(--mono);font-size:12px;
  min-height:100dvh;padding:14px;padding-left:max(14px,env(safe-area-inset-left));
  padding-right:max(14px,env(safe-area-inset-right));letter-spacing:.02em;font-variant-numeric:tabular-nums;}
.txp *{box-sizing:border-box}
.txp a{color:var(--gold)}
.txp a:hover{color:var(--gold-hi)}
.txp .top{display:flex;align-items:center;gap:12px;margin-bottom:10px}
.txp .brand{color:var(--gold);font-weight:700;letter-spacing:.14em;white-space:nowrap}
.txp .brand b{background:var(--gold);color:var(--ink);padding:0 5px}
.txp .brand .sub{display:block;color:var(--tx-faint);font-weight:400;letter-spacing:.06em;font-size:10px}
.txp .search{flex:1;display:flex;align-items:center;gap:8px;border:1px solid var(--line-2);background:var(--s2);padding:7px 10px}
.txp .search input{flex:1;min-width:0;background:transparent;border:0;color:var(--tx);font:inherit;outline:none}
.txp .clock{color:var(--tx-faint);white-space:nowrap}
.txp .ticker{display:flex;gap:18px;overflow-x:auto;border:1px solid var(--line);padding:6px 10px;margin-bottom:10px;white-space:nowrap;align-items:center}
.txp .ticker span b{color:var(--gold)}
.txp .grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.txp .full{grid-column:1/-1}
.txp .panel{border:1px solid var(--line-2);background:var(--s1);padding:10px 12px;min-width:0}
.txp .ph{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:8px;gap:10px}
.txp .ph .t{color:var(--gold);letter-spacing:.12em;font-weight:700}
.txp .ph .s{color:var(--tx-faint);font-size:11px;text-align:right}
.txp .big{font-size:26px;color:var(--tx);line-height:1.1}
.txp .kv{display:flex;flex-wrap:wrap;gap:6px 22px;margin-top:8px}
.txp .kv div{display:flex;flex-direction:column}
.txp .kv .k{color:var(--tx-faint);font-size:10px;letter-spacing:.08em}
.txp .kv .v{color:var(--tx)}
.txp table{width:100%;border-collapse:collapse;font-size:11px}
.txp th{text-align:left;color:var(--tx-faint);font-weight:400;border-bottom:1px solid var(--line-2);padding:4px 8px 4px 0;letter-spacing:.06em}
.txp td{padding:5px 8px 5px 0;border-bottom:1px solid var(--line);white-space:nowrap}
.txp td.r,.txp th.r{text-align:right}
.txp .good{color:var(--gold)} .txp .muted{color:var(--tx-faint)}
.txp .pill{border:1px solid currentColor;padding:0 5px;font-size:10px}
.txp button.v{background:transparent;border:1px solid var(--line-2);color:var(--tx-mut);font:inherit;cursor:pointer;padding:1px 7px}
.txp button.v:hover{border-color:var(--gold);color:var(--gold)}
.txp .foot{color:var(--tx-faint);margin-top:12px;border-top:1px solid var(--line);padding-top:8px;display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px}
.txp .empty{color:var(--tx-faint);padding:8px 0}
.txp .chips{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:8px}
.txp .chipf{background:transparent;border:1px solid var(--line-2);color:var(--tx-mut);font:inherit;font-size:10px;letter-spacing:.1em;padding:3px 9px;cursor:pointer}
.txp .chipf.on{border-color:var(--gold);color:var(--gold)}
.txp .wire{border:1px solid var(--line-2);background:var(--s1)}
.txp .wrow{display:flex;gap:10px;align-items:center;padding:6px 10px;border-bottom:1px solid var(--line);color:var(--tx-mut)}
.txp .wrow:last-child{border-bottom:0}
.txp .wrow .wt{color:var(--tx-faint);white-space:nowrap;flex:none;width:112px}
.txp .wrow .wi{flex:none;width:16px;text-align:center;color:var(--gold)}
.txp .wrow .wb{flex:1;min-width:0;color:var(--tx)}
.txp .wrow .wx{margin-left:auto;flex:none;white-space:nowrap;font-size:11px}
.txp .wrow.fresh{animation:txp-pulse 1.4s ease-out 1}
@keyframes txp-pulse{0%{background:var(--gold-dim)}100%{background:transparent}}
@media (prefers-reduced-motion:reduce){.txp .wrow.fresh{animation:none}}
@media(max-width:820px){
  .txp .grid{grid-template-columns:1fr}
  .txp table{display:block;overflow-x:auto;-webkit-overflow-scrolling:touch}
  /* ≥16px so iOS Safari doesn't auto-zoom when the search field is focused */
  .txp .search input{font-size:16px}
  .txp .wrow{flex-wrap:wrap}
  .txp .wrow .wt{width:auto}
}
`;

const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const addrUrl = (a: string) => `${RH.explorer}/address/${a}`;

/// reserve.ts's abi carries the backing views; receiptCount is the redemption counter and is read
/// only here, so it stays local rather than widening a shared surface.
const receiptAbi = parseAbi(["function receiptCount() view returns (uint256)"]);

const LEDGER_FILTERS: [string, string, (r: MainnetTapeRow) => boolean][] = [
  ["ALL", "Nothing has moved through the reserve yet.", () => true],
  [
    "DEPOSITS",
    "No deposits yet — the reserve is empty.",
    (r) => r.kind === "deposit",
  ],
  [
    "REDEMPTIONS",
    "No redemptions yet. No $ESSEY has been burned against the reserve.",
    (r) => r.kind !== "deposit",
  ],
];

/// The backing bar. The figure is a MARK, not the claim, and a holding we cannot price is left OUT of
/// the total rather than summed in as zero. The MARK column carries each line's price source per row,
/// so the footer states the caveat once and sends the method to /treasury rather than restating it.
function TreasuryBar({ st }: { st: TreasuryState | null }) {
  const held = st?.tokens.filter((t) => t.reserve > 0n) ?? [];
  return (
    <div className="panel" style={{ marginBottom: 10 }}>
      <div className="ph">
        <span className="t">TREASURY BALANCE</span>
        <span className="s">
          RH MAINNET {RH.chainId} · INDICATIVE · DISPLAY ONLY
        </span>
      </div>
      <div className="big">{st ? usd(st.pricedUsd8) : "—"}</div>
      <div className="kv">
        <div>
          <span className="k">COVERS</span>
          <span className="v">
            {st
              ? `${st.pricedHeld} of ${st.pricedHeld + st.unpricedHeld} funded lines`
              : "—"}
          </span>
        </div>
        <div>
          <span className="k">EQUITIES · FEED</span>
          <span className="v">{st ? usd(st.equityUsd8) : "—"}</span>
        </div>
        <div>
          <span className="k">CRYPTO · POOL</span>
          <span className="v">{st ? usd(st.upsideUsd8) : "—"}</span>
        </div>
        <div>
          <span className="k">EXCLUDED</span>
          <span className="v">
            {st
              ? st.unpricedHeld === 0
                ? "none"
                : `${st.unpricedSymbols.join(" ")} — no price source`
              : "—"}
          </span>
        </div>
        <div>
          <span className="k">RESERVE</span>
          <span className="v">
            <a href={addrUrl(RESERVE.reserve)} target="_blank" rel="noreferrer">
              {short(RESERVE.reserve)} ↗
            </a>
          </span>
        </div>
      </div>
      <table style={{ marginTop: 8 }}>
        <thead>
          <tr>
            <th>HOLDING</th>
            <th className="r">UNITS</th>
            <th className="r">VALUE · USD</th>
            <th>MARK</th>
          </tr>
        </thead>
        <tbody>
          {held.length === 0 && (
            <tr>
              <td colSpan={4} className="empty">
                {st ? "the reserve holds nothing yet" : "reading the reserve…"}
              </td>
            </tr>
          )}
          {held.map((t) => (
            <tr key={t.address}>
              <td>
                {t.symbol}{" "}
                {t.kind === "crypto" && (
                  <span className="pill muted">UPSIDE</span>
                )}
              </td>
              <td className="r">{fmtUnits(t.reserve, t.decimals, 4)}</td>
              <td className="r">
                {t.valueUsd8 === null ? (
                  <span className="muted">{unpricedReason(t.price)}</span>
                ) : (
                  usd(t.valueUsd8)
                )}
              </td>
              <td className="muted">
                {t.price.ok
                  ? t.price.src === "pool"
                    ? "thin-pool median"
                    : "chainlink"
                  : "—"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="muted" style={{ marginTop: 6, fontSize: 10 }}>
        indicative · redemption pays UNITS, not dollars · unpriced lines
        excluded, not zeroed · <Link to="/treasury">how this is marked ↗</Link>
      </div>
    </div>
  );
}

export function ExplorerPage() {
  const [st, setSt] = useState<TreasuryState | null>(null);
  const [rows, setRows] = useState<MainnetTapeRow[]>([]);
  const [head, setHead] = useState<bigint | null>(null);
  const [receipts, setReceipts] = useState<bigint | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [ok, setOk] = useState(false);
  const [fi, setFi] = useState(0);
  const [q, setQ] = useState("");
  const [clock, setClock] = useState("");
  const mounted = useRef(true);
  const firstKey = useRef<string | null>(null);
  const [freshKey, setFreshKey] = useState<string | null>(null);

  useEffect(() => {
    document.title = "Explorer · Essey";
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  useEffect(() => {
    const t = setInterval(
      () => setClock(new Date().toISOString().slice(11, 19) + " UTC"),
      1000,
    );
    return () => clearInterval(t);
  }, []);

  // A failed read keeps the last good rows but drops `ok`, so the chip never claims live off a stale render.
  const load = useCallback(async () => {
    try {
      const [tape, count] = await Promise.all([
        fetchMainnetTape(),
        mainnetPub.readContract({
          address: RESERVE.reserve,
          abi: receiptAbi,
          functionName: "receiptCount",
        }),
      ]);
      if (!mounted.current) return;
      setRows(tape.rows);
      setHead(tape.head);
      setReceipts(count as bigint);
      setLoaded(true);
      setOk(true);
    } catch {
      if (mounted.current) {
        setLoaded(true);
        setOk(false);
      }
    }
    try {
      const t = await reserveReads.treasury();
      if (mounted.current) setSt(t);
    } catch {
      /* leave last good */
    }
  }, []);

  useEffect(() => {
    if (!deployed()) {
      setLoaded(true);
      return;
    }
    load();
    const t = setInterval(load, 20_000);
    return () => clearInterval(t);
  }, [load]);

  useEffect(() => {
    if (rows.length && rows[0].key !== firstKey.current) {
      if (firstKey.current !== null) setFreshKey(rows[0].key);
      firstKey.current = rows[0].key;
    }
  }, [rows]);

  const ql = q.trim().toLowerCase();
  const shown = useMemo(
    () =>
      rows
        .filter(LEDGER_FILTERS[fi][2])
        .filter(
          (r) =>
            !ql ||
            r.text.toLowerCase().includes(ql) ||
            r.tx.toLowerCase().includes(ql) ||
            r.block.toString() === ql,
        ),
    [rows, fi, ql],
  );

  const deposits = rows.filter((r) => r.kind === "deposit").length;
  const holdings = st ? st.pricedHeld + st.unpricedHeld : null;

  if (!deployed())
    return (
      <div className="txp">
        <style>{CSS}</style>
        <div className="top">
          <div className="brand">
            <b>ESSEY</b>&nbsp;SCAN
            <span className="sub">the protocol ledger</span>
          </div>
        </div>
        <div className="panel">
          <div className="empty">
            no reserve address is set in this build · nothing is read, so
            nothing is shown
          </div>
        </div>
      </div>
    );

  return (
    <div className="txp">
      <style>{CSS}</style>

      <div className="top">
        <div className="brand">
          <b>ESSEY</b>&nbsp;SCAN<span className="sub">the protocol ledger</span>
        </div>
        <div className="search">
          <span className="muted">&gt;</span>
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="SEARCH  TX / TICKER / BLOCK"
            spellCheck={false}
          />
          <span className="muted">{shown.length} hits</span>
        </div>
        <div className="clock">{clock || "—"}</div>
      </div>

      <div className="ticker">
        <span>
          $ESSEY CIRCULATING <b>{st ? fmtUnits(st.circulating, 18, 2) : "—"}</b>
        </span>
        <span>
          HOLDINGS <b>{holdings ?? "—"}</b>
        </span>
        <span>
          DEPOSITS <b>{loaded ? deposits : "—"}</b>
        </span>
        <span>
          REDEMPTIONS <b>{receipts === null ? "—" : receipts.toString()}</b>
        </span>
        <span className="muted" style={{ marginLeft: "auto" }}>
          chain {RH.chainId} · block {head !== null ? head.toString() : "—"}
        </span>
        {ok && <span className="preview-chip live">live</span>}
      </div>

      <TreasuryBar st={st} />

      <div className="grid">
        <div className="panel">
          <div className="ph">
            <span className="t">THE CLAIM</span>
            <span className="s">EsseyReserve.sol · read live</span>
          </div>
          <div className="big">
            {st ? `${Number(st.exitFeeBps) / 100}%` : "—"}{" "}
            <span className="muted" style={{ fontSize: 13 }}>
              exit fee, kept by the floor
            </span>
          </div>
          <div className="kv">
            <div>
              <span className="k">$ESSEY TOTAL SUPPLY</span>
              <span className="v">
                {st ? fmtUnits(st.esseyTotal, 18, 2) : "—"}
              </span>
            </div>
            <div>
              <span className="k">CIRCULATING</span>
              <span className="v">
                {st ? fmtUnits(st.circulating, 18, 2) : "—"}
              </span>
            </div>
            <div>
              <span className="k">CLAIM BASE</span>
              <span className="v">
                {st ? fmtUnits(st.claimBase, 18, 2) : "—"}
              </span>
            </div>
            <div>
              <span className="k">RECEIPTS OPENED</span>
              <span className="v">
                {receipts === null ? "—" : receipts.toString()}
              </span>
            </div>
          </div>
          <div className="empty" style={{ fontSize: 10 }}>
            redemption burns $ESSEY and opens a receipt that claims a pro-rata
            slice in UNITS of each token · the per-token floor is on{" "}
            <Link to="/treasury">the Floor</Link>
          </div>
        </div>

        <div className="panel">
          <div className="ph">
            <span className="t">THE CONTRACTS</span>
            <span className="s">no owner · no withdraw · no pause</span>
          </div>
          <table>
            <thead>
              <tr>
                <th>CONTRACT</th>
                <th>ADDRESS</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td className="good">EsseyReserve</td>
                <td>
                  <a
                    href={addrUrl(RESERVE.reserve)}
                    target="_blank"
                    rel="noreferrer"
                  >
                    {short(RESERVE.reserve)} ↗
                  </a>
                </td>
              </tr>
              <tr>
                <td className="good">$ESSEY</td>
                <td>
                  <a
                    href={addrUrl(RESERVE.essey)}
                    target="_blank"
                    rel="noreferrer"
                  >
                    {short(RESERVE.essey)} ↗
                  </a>
                </td>
              </tr>
            </tbody>
          </table>
          <div className="empty" style={{ fontSize: 10 }}>
            both are adminless: EsseyReserve.sol:21 declares no owner, no
            registrar, no roles, no setters, no withdraw, no upgrade, no pause ·
            check it on the explorer, not here
          </div>
        </div>
      </div>

      <div className="panel full" style={{ marginTop: 10 }}>
        <div className="ph">
          <span className="t">THE LEDGER</span>
          <span className="s">every event since deployment · newest first</span>
        </div>
        <div className="chips">
          {LEDGER_FILTERS.map(([label], i) => (
            <button
              key={label}
              className={"chipf" + (i === fi ? " on" : "")}
              onClick={() => setFi(i)}
            >
              {label}
            </button>
          ))}
        </div>
        <div className="wire">
          {!loaded ? (
            <div className="empty" style={{ padding: 10 }}>
              reading the chain…
            </div>
          ) : !ok && rows.length === 0 ? (
            <div className="empty" style={{ padding: 10 }}>
              could not reach Robinhood Chain mainnet · nothing is shown rather
              than something stale
            </div>
          ) : shown.length === 0 ? (
            <div className="empty" style={{ padding: 10 }}>
              {ql ? "no matches" : LEDGER_FILTERS[fi][1]}
            </div>
          ) : (
            shown.map((r) => (
              <div
                key={r.key}
                className={"wrow" + (r.key === freshKey ? " fresh" : "")}
              >
                <span className="wt">b{r.block.toString()}</span>
                <span className="wi">{r.icon}</span>
                <span className="wb">{r.text}</span>
                <a
                  className="wx"
                  href={mainnetTxUrl(r.tx)}
                  target="_blank"
                  rel="noreferrer"
                >
                  verify ↗
                </a>
              </div>
            ))
          )}
        </div>
      </div>

      <div className="foot">
        <span>
          ESSEY SCAN · Robinhood Chain {RH.chainId} ·{" "}
          <a href={RH.explorer} target="_blank" rel="noreferrer">
            raw explorer ↗
          </a>
        </span>
        <span>every line links its receipt · read the chain yourself</span>
      </div>
    </div>
  );
}
