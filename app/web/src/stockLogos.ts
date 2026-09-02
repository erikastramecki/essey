// Brass-coin logo marks for the basket assets. ONE keyed source of truth so the holder UI, the Treasury
// page, and any standalone mockup render the SAME mark for a ticker — the founder rejected letter-monogram
// placeholders twice, so every basket name gets a real, embedded mark here. Paths are inline (no external
// URLs) on purpose: a self-contained mockup or a strict-CSP page cannot load a remote image, which is
// exactly how the monograms slipped in.
//
// SOURCES, per mark (honest labels — do not "upgrade" a thematic mark to imply an official brand asset):
//   - "brand" = the company's own logomark, taken verbatim from Simple Icons (CC0-1.0, simpleicons.org).
//   - "thematic" = an original iconographic mark we drew for an ETF/index/memecoin that has no clean
//     single-path brand SVG (GLD → gold bars, etc.). Recognizable by subject, not an official logo.
//
// TRADEMARK NOTE (flagged, not blocking): these are third-party word/figure marks shown in a nominative,
// factual listing context — naming which real equities back $ESSEY. Nominative use to identify the actual
// asset is generally defensible and carries no endorsement claim. Keep them descriptive (never implying the
// issuer sponsors Essey), monochrome to our gold so they read as a set, and swap any mark an issuer objects
// to. This is a note for the founder's awareness, not a legal opinion.
//
// The ticker set is grounded in the live on-chain basket (reserve.ts:43-56, RH mainnet 4663). MSFT/INTC are
// carried too — referenced in MODEL-equity-backed-floor.md:38 as basket candidates — so a later add renders
// a real mark with zero UI change.

export type LogoSource = "brand" | "thematic";

export interface StockLogo {
  /// SVG path data in a 0 0 24 24 viewBox. May contain multiple subpaths.
  d: string;
  source: LogoSource;
  /// Only set when the mark's subpaths need even-odd winding (donuts, cut-outs). Brand paths from Simple
  /// Icons are authored for nonzero winding — forcing even-odd there punches false holes (e.g. NVIDIA).
  evenodd?: boolean;
}

/// Verbatim Simple-Icons (CC0) brand paths, plus our thematic marks. Every entry is a real mark, never an
/// initial. Keyed by the exact ticker symbol the reserve reads on chain.
export const STOCK_LOGOS: Record<string, StockLogo> = {
  AAPL: {
    source: "brand",
    d: "M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701",
  },
  NVDA: {
    source: "brand",
    d: "M8.948 8.798v-1.43a6.7 6.7 0 0 1 .424-.018c3.922-.124 6.493 3.374 6.493 3.374s-2.774 3.851-5.75 3.851c-.398 0-.787-.062-1.158-.185v-4.346c1.528.185 1.837.857 2.747 2.385l2.04-1.714s-1.492-1.952-4-1.952a6.016 6.016 0 0 0-.796.035m0-4.735v2.138l.424-.027c5.45-.185 9.01 4.47 9.01 4.47s-4.08 4.964-8.33 4.964c-.37 0-.733-.035-1.095-.097v1.325c.3.035.61.062.91.062 3.957 0 6.82-2.023 9.593-4.408.459.371 2.34 1.263 2.73 1.652-2.633 2.208-8.772 3.984-12.253 3.984-.335 0-.653-.018-.971-.053v1.864H24V4.063zm0 10.326v1.131c-3.657-.654-4.673-4.46-4.673-4.46s1.758-1.944 4.673-2.262v1.237H8.94c-1.528-.186-2.73 1.245-2.73 1.245s.68 2.412 2.739 3.11M2.456 10.9s2.164-3.197 6.5-3.533V6.201C4.153 6.59 0 10.653 0 10.653s2.35 6.802 8.948 7.42v-1.237c-4.84-.6-6.492-5.936-6.492-5.936z",
  },
  GOOGL: {
    source: "brand",
    d: "M12.48 10.92v3.28h7.84c-.24 1.84-.853 3.187-1.787 4.133-1.147 1.147-2.933 2.4-6.053 2.4-4.827 0-8.6-3.893-8.6-8.72s3.773-8.72 8.6-8.72c2.6 0 4.507 1.027 5.907 2.347l2.307-2.307C18.747 1.44 16.133 0 12.48 0 5.867 0 .307 5.387.307 12s5.56 12 12.173 12c3.573 0 6.267-1.173 8.373-3.36 2.16-2.16 2.84-5.213 2.84-7.667 0-.76-.053-1.467-.173-2.053H12.48z",
  },
  TSLA: {
    source: "brand",
    d: "M12 5.362l2.475-3.026s4.245.09 8.471 2.054c-1.082 1.636-3.231 2.438-3.231 2.438-.146-1.439-1.154-1.79-4.354-1.79L12 24 8.619 5.034c-3.18 0-4.188.354-4.335 1.792 0 0-2.146-.795-3.229-2.43C5.28 2.431 9.525 2.34 9.525 2.34L12 5.362l-.004.002H12v-.002zm0-3.899c3.415-.03 7.326.528 11.328 2.28.535-.968.672-1.395.672-1.395C19.625.612 15.528.015 12 0 8.472.015 4.375.61 0 2.349c0 0 .195.525.672 1.396C4.674 1.989 8.585 1.435 12 1.46v.003z",
  },
  NFLX: {
    source: "brand",
    d: "m5.398 0 8.348 23.602c2.346.059 4.856.398 4.856.398L10.113 0H5.398zm8.489 0v9.172l4.715 13.33V0h-4.715zM5.398 1.5V24c1.873-.225 2.81-.312 4.715-.398V14.83L5.398 1.5z",
  },
  MSTR: {
    source: "brand",
    d: "M9.095 2.572h5.827v18.856H9.096zM0 2.572h5.825v18.856H.001zm18.174 0v18.854H24V8.33z",
  },

  // Thematic marks — no clean single-path brand SVG exists for these. Drawn to read by subject.
  GLD: {
    source: "thematic", // stacked gold ingots
    d: "M9 6h6l1 5H8zM4 12.5h7l1 5.5H3zM13 12.5h7l1 5.5h-9z",
  },
  SPY: {
    source: "thematic", // broad-market: three ascending bars
    d: "M3 20h3.2v-6H3zm7.4 0h3.2V10h-3.2zm7.4 0H21V6h-3.2z",
  },
  QQQ: {
    source: "thematic", // index fund: a ring (basket of many names)
    evenodd: true,
    d: "M12 3a9 9 0 100 18 9 9 0 000-18zm0 4.5a4.5 4.5 0 110 9 4.5 4.5 0 010-9z",
  },
  DJT: {
    source: "thematic", // media badge: a solid tile with a cut-out T
    evenodd: true,
    d: "M4 3h16a1 1 0 011 1v16a1 1 0 01-1 1H4a1 1 0 01-1-1V4a1 1 0 011-1zm3 4v3h3.5v8h3v-8H17V7z",
  },
  CASHCAT: {
    source: "thematic", // cat head with eyes cut out
    evenodd: true,
    d: "M5 4l4 4h6l4-4v11a7 7 0 01-14 0zm4.5 7a1.1 1.1 0 100 2.2 1.1 1.1 0 000-2.2zm5 0a1.1 1.1 0 100 2.2 1.1 1.1 0 000-2.2z",
  },
  PONS: {
    source: "thematic", // bridge with an arch opening
    evenodd: true,
    d: "M2 8h20v12h-4v-5a6 6 0 00-12 0v5H2z",
  },
  FLR: {
    source: "thematic", // FLOOR: a plinth that steps up, never down
    d: "M2 18h20v3H2zm4-5h12v3H6zm4-5h4v3h-4z",
  },
};

const GOLD = "#e2c177";
const RING = "#c9a24b";

/// The brass-coin frame every mark sits in — dark radial field, gold rim, faint inner ring. Matches the
/// holder mockup's coin exactly; the logo is scaled into a ~22px box centered in the 40-unit coin.
export function coinSVG(ticker: string, size = 38): string {
  const logo = STOCK_LOGOS[ticker];
  const gid = `coin-${ticker}`;
  const inner = logo
    ? `<g transform="translate(9 9) scale(0.9167)" fill="${GOLD}"` +
      (logo.evenodd ? ` fill-rule="evenodd"` : ``) +
      `><path d="${logo.d}"/></g>`
    : `<text x="20" y="20" text-anchor="middle" dominant-baseline="central" font-family="Didot,Georgia,serif" font-size="15" fill="${GOLD}">${ticker[0] ?? "?"}</text>`;
  return (
    `<svg class="coin" width="${size}" height="${size}" viewBox="0 0 40 40" aria-hidden="true">` +
    `<defs><radialGradient id="${gid}" cx="38%" cy="32%" r="80%">` +
    `<stop offset="0" stop-color="#2c2619"/><stop offset="1" stop-color="#17130d"/></radialGradient></defs>` +
    `<circle cx="20" cy="20" r="18.5" fill="url(#${gid})" stroke="${RING}" stroke-opacity=".55" stroke-width="1"/>` +
    `<circle cx="20" cy="20" r="15" fill="none" stroke="${RING}" stroke-opacity=".22" stroke-width=".8"/>` +
    inner +
    `</svg>`
  );
}
