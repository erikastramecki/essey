// D.O.N. game — the shared grammar components: the CaseFile slide-over (one component, every
// screen), the wax-seal single-click tx affordance, rubber stamps, the odds ladder, the
// paperclip/mugshot/chair SVGs, and the real-Don photo with an intentional fallback plate.
import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";

// ---------------------------------------------------------------------------------------------
// The CaseFile slide-over — folder tab + sheet + punch holes + CONFIDENTIAL watermark + filehead.
// Always mounted (the slide transition needs a persistent element); contents render while the
// file is open or stacked-under.
// ---------------------------------------------------------------------------------------------
export function CaseFile({ open, under, stack2, jacket, tab, head, onClose, children }: {
  open: boolean;
  under?: boolean;          // a second file is stacked over this one (2-deep max)
  stack2?: boolean;         // this IS the second file of the stack
  jacket?: "carbon" | "grey";
  tab: string;              // the folder-tab label
  head: string;             // the filehead letterhead
  onClose: () => void;
  children: ReactNode;
}) {
  const cls = "g-file" + (open ? " open" : "") + (under ? " under" : "") + (stack2 ? " stack2" : "")
    + (jacket ? ` jacket-${jacket}` : "");
  return (
    <section className={cls} aria-label={tab} aria-hidden={!open}>
      <div className="g-foldertab">{tab}</div>
      <div className="g-sheet">
        <div className="g-wm" aria-hidden /><div className="g-punch p1" aria-hidden /><div className="g-punch p2" aria-hidden />
        <div className="g-filehead">
          <span>{head}</span><span className="g-rule" />
          <button className="g-xbtn" onClick={onClose} aria-label="close file">✕</button>
        </div>
        {(open || under) && children}
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------------------------
// The wax seal — single click, the universal tx affordance. One click fires onCommit immediately
// (the wallet's signature prompt is the real confirmation step; a hold gesture confused live
// testers). The stamp-down is a one-shot visual: pressed state for STAMP_MS, then the parent's
// `sealed` prop holds the stamped result.
// ---------------------------------------------------------------------------------------------
const STAMP_MS = 220;

export function WaxSeal({ disabled, sealed, hint, onCommit }: {
  disabled?: boolean;
  sealed?: boolean;         // the action is committed — die pressed, seal inert
  hint: string;             // the line under the seal (parent owns status copy)
  onCommit: () => void;     // fired exactly once, immediately on click
}) {
  const stampT = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [pressing, setPressing] = useState(false);

  const click = () => {
    if (disabled || sealed) return;
    setPressing(true);
    if (stampT.current) clearTimeout(stampT.current);
    stampT.current = setTimeout(() => { stampT.current = null; setPressing(false); }, STAMP_MS);
    onCommit();
  };
  useEffect(() => () => { if (stampT.current) clearTimeout(stampT.current); }, []);

  return (
    <div className="g-sealwrap">
      <button
        className={"g-seal" + (pressing ? " pressing" : "") + (sealed ? " done" : "")}
        disabled={disabled || sealed}
        aria-label="Click to sign"
        onClick={click}
      >
        <span className="g-ring" aria-hidden />
      </button>
      <div className="g-sealhint">{hint}</div>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------
// Rubber stamp + actuarial rating stamp
// ---------------------------------------------------------------------------------------------
export function Stamp({ ok, carbon, corner, big, thump, style, children }: {
  ok?: boolean; carbon?: boolean; corner?: boolean; big?: boolean; thump?: boolean;
  style?: CSSProperties; children: ReactNode;
}) {
  const cls = "g-stamp" + (ok ? " ok" : "") + (carbon ? " carbon" : "") + (corner ? " corner" : "")
    + (big ? " big" : "") + (thump ? " thump" : "");
  return <span className={cls} style={style}>{children}</span>;
}

export function RatingStamp({ rating, children }: { rating: "low" | "std" | "steep" | "unins"; children: ReactNode }) {
  return <span className={`g-ratestamp ${rating}`}>{children}</span>;
}

// ---------------------------------------------------------------------------------------------
// The real Don render (the existing /api/don-img pipeline; live-ui's DonThumb pattern). Fallback
// is an intentional dark plate with the number — never a broken-image glyph (dev server runs no
// /api, unrevealed Dons get the endpoint's branded SVG).
// ---------------------------------------------------------------------------------------------
export function DonImg({ id, className, alt }: { id: bigint; className?: string; alt?: string }) {
  const [ok, setOk] = useState(true);
  useEffect(() => { setOk(true); }, [id]);
  if (!ok) return <span className={(className ? className + " " : "") + "g-imgph"} aria-hidden>№{id.toString()}</span>;
  return (
    <img
      className={className} src={`/api/don-img/${id.toString()}`} alt={alt ?? `Don №${id.toString()}`}
      loading="lazy" decoding="async" onError={() => setOk(false)}
    />
  );
}

// ---------------------------------------------------------------------------------------------
// The odds ladder — Material A island. 10 blocks per row, filled per pct.
// ---------------------------------------------------------------------------------------------
function Blocks({ pct }: { pct: number }) {
  const n = Math.round(pct / 10);
  return (
    <span className="blocks">
      <b>{"▮".repeat(Math.min(10, n))}</b>{"░".repeat(Math.max(0, 10 - n))}
    </span>
  );
}

export function OddsLadder({ odds, payout, capRight }: {
  odds: [number, number, number]; payout: string; capRight?: string;
}) {
  // Contract semantics (MissionBoard cumPpm bands): success / partial ("sideways") / fail.
  const rows: [string, "suc" | "set" | "amb", number][] = [
    ["success", "suc", odds[0]], ["sideways", "set", odds[1]], ["bust", "amb", odds[2]],
  ];
  return (
    <div className="g-island">
      <div className="g-cap"><span>RISK ASSESSMENT</span><span>{capRight ?? "published on-chain · the ladder IS the disclosure"}</span></div>
      {rows.map(([k, cls, pct]) => (
        <div key={k} className={`g-odds-row ${cls}`}>
          <span className="k">{k}</span><Blocks pct={pct} /><span className="pct">{pct}%</span>
        </div>
      ))}
      <div className="g-payline"><span>payout, marked</span><b>{payout}</b></div>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------
// Small SVGs: paperclip, redacted mugshot, garrison chair + silhouette, sealed envelope
// ---------------------------------------------------------------------------------------------
export const PaperClip = () => (
  <svg className="g-pclip" viewBox="0 0 22 44" aria-hidden>
    <path d="M11 3 c4 0 6.5 2.5 6.5 6 v24 c0 5-3 8-6.5 8 s-6.5-3-6.5-8 V12 c0-3 2-5 4.5-5 s4.5 2 4.5 5 v20" fill="none" stroke="#8f8a7c" strokeWidth="2.2" strokeLinecap="round" />
  </svg>
);

/// The zero-budget Hitter portrait: height ruler + head-and-shoulders silhouette + REDACTED bar.
export function RedactedMug() {
  return (
    <div className="g-mug">
      <div className="g-ruler">6′<br /><br />5′<br /><br />4′</div>
      <svg viewBox="0 0 100 100" aria-hidden>
        <path d="M50 10 c10 0 16 7 16 17 0 6-3 11-7 14 13 4 22 13 24 32 l1 27 H16 l1-27 c2-19 11-28 24-32 -4-3-7-8-7-14 0-10 6-17 16-17z" fill="#17140E" />
      </svg>
      <div className="g-censor">REDACTED</div>
    </div>
  );
}

export function ChairSlot({ label, empty }: { label: string; empty?: boolean }) {
  return (
    <div className="g-chairslot">
      <div className="g-occ">
        <svg viewBox="0 0 44 52" aria-hidden>
          <path d="M8 2 h4 v26 h20 V2 h4 v34 h-4 v-4 H12 v4 H8z M10 36 l-3 14 h3 l3-12 M34 36 l3 14 h-3 l-3-12"
            fill={empty ? "none" : "#6b5b3d"} stroke={empty ? "#6b5b3d" : undefined}
            strokeWidth={empty ? 2 : undefined} strokeDasharray={empty ? "3 3" : undefined} />
        </svg>
        {!empty && (
          <svg className="g-sil" viewBox="0 0 100 100" aria-hidden>
            <path d="M50 12 c9 0 14 7 14 15 0 6-2 10-6 13 12 3 20 12 22 28 l1 20 H19 l1-20 c2-16 10-25 22-28 -4-3-6-7-6-13 0-8 5-15 14-15z" fill="#17140E" />
          </svg>
        )}
      </div>
      {label}
    </div>
  );
}

export const SealedEnvelopeIcon = ({ size = 14 }: { size?: number }) => (
  <svg width={size} height={size * 10 / 14} viewBox="0 0 14 10" aria-hidden>
    <rect x=".5" y=".5" width="13" height="9" fill="none" stroke="#4A5A78" />
    <path d="M.5.5 L7 5.5 L13.5.5" fill="none" stroke="#4A5A78" />
    <circle cx="7" cy="5.5" r="1.6" fill="#A8352A" />
  </svg>
);

export const BigEnvelope = () => (
  <svg width="150" height="104" viewBox="0 0 150 104" aria-hidden>
    <rect x="2" y="2" width="146" height="100" rx="3" fill="#F3EDDD" stroke="#b9b096" strokeWidth="1.5" />
    <path d="M2 4 L75 58 L148 4" fill="none" stroke="#b9b096" strokeWidth="1.5" />
    <circle cx="75" cy="58" r="13" fill="#a34a3e" />
    <circle cx="75" cy="58" r="9" fill="none" stroke="rgba(60,12,6,.4)" strokeWidth="1.6" />
    <text x="75" y="63" textAnchor="middle" fontFamily="Georgia,serif" fontSize="13" fill="rgba(60,12,6,.6)">D</text>
  </svg>
);

/// 18-decimal token amount → short display string.
export const fmtAmt = (n: bigint, dp = 0): string => {
  const neg = n < 0n ? "-" : "";
  const abs = n < 0n ? -n : n;
  const whole = abs / 10n ** 18n;
  if (dp === 0) return neg + whole.toLocaleString("en-US");
  const frac = abs % 10n ** 18n;
  const fs = (Number(frac) / 1e18).toFixed(dp).slice(2);
  return `${neg}${whole.toLocaleString("en-US")}.${fs}`;
};
