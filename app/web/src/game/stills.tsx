// The LOCATION STILLS — code-drawn "exhibit photography" for the dossier interface. One
// component (ExhibitStill) renders an inline-SVG noir location portrait per scene: duotone
// ink-on-paper (the game's --g palette), one dramatic light source, film grain + scanlines.
// Chrome (CAM label, EXHIBIT tag) stays HTML — no text lives inside the SVG art.
// FUTURE RASTER SLOT: pass `src` and the component swaps the SVG for the real AI-gen image
// under the identical surveillance treatment (frame, grain, scanlines, chrome).
import { useId, useState, type ReactNode } from "react";

export type SceneKey =
  | "armored-run" | "fab-dock" | "rig-hall" | "cryo-annex" | "milk-corner" | "open-window"
  | "safehouse" | "row-house" | "brownstone" | "estate" | "compound";

/// House deed tier (0..4) → its exterior-still scene.
export const HOUSE_TIER_SCENES: readonly SceneKey[] =
  ["safehouse", "row-house", "brownstone", "estate", "compound"];

const SCENE_LABELS: Record<SceneKey, string> = {
  "armored-run": "surveillance still — the armored run under a streetlamp",
  "fab-dock": "surveillance still — dock 4, roller door half-open",
  "rig-hall": "surveillance still — the rig hall through the fence",
  "cryo-annex": "surveillance still — annex K, cryo tanks venting",
  "milk-corner": "surveillance still — the corner store at dawn",
  "open-window": "surveillance still — a row house at night, one window lit",
  "safehouse": "exterior still — a narrow walk-up over a shuttered shop",
  "row-house": "exterior still — a brick row house with a stoop",
  "brownstone": "exterior still — a brownstone with lit bay windows",
  "estate": "exterior still — a gated estate behind trees",
  "compound": "exterior still — a walled compound, gate lit",
};

// The house palette — duotone ink-on-paper, matched to game.css tokens.
const NIGHT = "#0b0a07";      // deep sky
const INK = "#0d0a06";        // darkest silhouette
const SHADE = "#14100a";      // building shadow mass
const WALL = "#1b1610";       // primary facade
const WALL2 = "#241d12";      // warmer mid surface
const TRIM = "#2e2718";       // catch-light trim / iron
const GOLD = "#c9a24b";
const GOLDHI = "#f0c46a";
const LAMP = "#e2c177";
const PAPER = "#e8dfc9";
const PAPERHI = "#f3eddd";

const SQUARE: readonly SceneKey[] = HOUSE_TIER_SCENES;

// The raster stills — photographic noir location plates (locally generated, vision-QA'd),
// served from /public/stills. Used as the default `src`; if a file 404s the component
// falls back to the code-drawn SVG scene, so the raster layer is purely additive.
export const RASTER_STILLS: Record<SceneKey, string> = {
  "armored-run": "/stills/armored-run.webp",
  "fab-dock": "/stills/fab-dock.webp",
  "rig-hall": "/stills/rig-hall.webp",
  "cryo-annex": "/stills/cryo-annex.webp",
  "milk-corner": "/stills/milk-corner.webp",
  "open-window": "/stills/open-window.webp",
  "safehouse": "/stills/safehouse.webp",
  "row-house": "/stills/row-house.webp",
  "brownstone": "/stills/brownstone.webp",
  "estate": "/stills/estate.webp",
  "compound": "/stills/compound.webp",
};

// ---------------------------------------------------------------------------------------------
// The component. `ts`/`tag` are the HTML chrome (kept out of the SVG); `square` picks the 1:1
// exterior-portrait framing (house file); `damaged` etches a cracked-glass line over the still.
// ---------------------------------------------------------------------------------------------
export function ExhibitStill({ scene, ts, tag, square, damaged, src, className }: {
  scene: SceneKey;
  ts?: string;              // timestamp chrome, top-right ("CAM 4 · 02:41")
  tag?: string;             // exhibit tag chrome, bottom-left ("EXHIBIT 1-A · …")
  square?: boolean;         // 1:1 exterior portrait (default 4:3 surveillance frame)
  damaged?: boolean;        // the House took a hit — cracked-glass overlay
  src?: string;             // explicit raster override (default: RASTER_STILLS[scene])
  className?: string;
}) {
  const [broken, setBroken] = useState<string | null>(null);
  const raster = src ?? RASTER_STILLS[scene];
  const showRaster = !!raster && raster !== broken;
  return (
    <div className={"g-still" + (square ? " sq" : "") + (className ? ` ${className}` : "")}>
      {showRaster
        ? <img className="g-still-img" src={raster} alt={SCENE_LABELS[scene]} loading="lazy" decoding="async"
            onError={() => setBroken(raster)} />
        : <SceneSvg scene={scene} damaged={damaged} />}
      {showRaster && damaged && (
        <svg className="g-still-crack" viewBox="0 0 400 400" preserveAspectRatio="none" aria-hidden>
          <path d={CRACK} fill="none" stroke={PAPER} strokeWidth="1.4" opacity="0.4" />
        </svg>
      )}
      {ts && <span className="g-ts">{ts}</span>}
      {tag && <span className="g-extag">{tag}</span>}
    </div>
  );
}

// One cracked-glass line — a single path (with short branch subpaths), not gore.
const CRACK = "M352 0 L296 64 L262 92 L238 132 L216 176 M296 64 L246 50 M296 64 L330 118 M262 92 L286 122";

function SceneSvg({ scene, damaged }: { scene: SceneKey; damaged?: boolean }) {
  const u = useId().replace(/[^a-zA-Z0-9]/g, "");
  const H = SQUARE.includes(scene) ? 400 : 300;
  return (
    <svg className="g-still-svg" viewBox={`0 0 400 ${H}`} preserveAspectRatio="xMidYMid slice"
      role="img" aria-label={SCENE_LABELS[scene]}>
      <defs>
        <filter id={`${u}grain`} x="-10%" y="-10%" width="120%" height="120%">
          <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" stitchTiles="stitch" />
          <feColorMatrix type="saturate" values="0" />
        </filter>
        <filter id={`${u}soft`}><feGaussianBlur stdDeviation="3" /></filter>
      </defs>
      {SCENES[scene](u)}
      <rect width="400" height={H} filter={`url(#${u}grain)`} opacity="0.14" style={{ mixBlendMode: "overlay" }} />
      {damaged && <path d={CRACK} transform={H === 300 ? "scale(1 .75)" : undefined}
        fill="none" stroke={PAPER} strokeWidth="1.4" opacity="0.4" />}
    </svg>
  );
}

// ---------------------------------------------------------------------------------------------
// The scenes. Each is a pure fragment keyed on a unique id prefix (gradient ids must not
// collide across instances). Compositions are built to read at ~110px (house frame) and up.
// ---------------------------------------------------------------------------------------------
const SCENES: Record<SceneKey, (u: string) => ReactNode> = {

  // PAPER ROUTE — the armored car under a streetlamp, long shadow across the street.
  "armored-run": (u) => (
    <g>
      <defs>
        <linearGradient id={`${u}sky`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={NIGHT} /><stop offset="1" stopColor="#241c0f" />
        </linearGradient>
        <linearGradient id={`${u}cone`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={GOLDHI} stopOpacity=".5" /><stop offset="1" stopColor={GOLDHI} stopOpacity=".06" />
        </linearGradient>
      </defs>
      <rect width="400" height="206" fill={`url(#${u}sky)`} />
      {/* the skyline, asleep */}
      <path fill="#131009" d="M0 206 V146 h34 v-16 h26 v26 h38 v-38 h28 v20 h46 v-28 h36 v36 h32 v-18 h44 v22 h38 v-30 h34 v30 h44 V206 Z" />
      <g fill={GOLD} opacity=".3">
        <rect x="70" y="140" width="3" height="4" /><rect x="132" y="126" width="3" height="4" />
        <rect x="246" y="132" width="3" height="4" /><rect x="352" y="144" width="3" height="4" />
      </g>
      {/* street */}
      <rect y="206" width="400" height="94" fill="#0c0a06" />
      <line x1="0" y1="206" x2="400" y2="206" stroke="#2b261c" strokeWidth="1.5" />
      <path d="M20 262 h44 M110 262 h44 M200 262 h44 M290 262 h44" stroke="#221c12" strokeWidth="3" />
      {/* the lamp and its cone */}
      <polygon points="298,66 234,236 386,236" fill={`url(#${u}cone)`} />
      <ellipse cx="310" cy="236" rx="86" ry="13" fill={GOLDHI} opacity=".16" />
      <rect x="316" y="70" width="4" height="166" fill="#050403" />
      <path d="M318 72 q-2 -14 -14 -14 h-6" fill="none" stroke="#050403" strokeWidth="4" />
      <rect x="290" y="54" width="16" height="7" rx="2" fill="#050403" />
      <circle cx="298" cy="64" r="4" fill={PAPERHI} />
      <circle cx="298" cy="64" r="12" fill={GOLDHI} opacity=".45" filter={`url(#${u}soft)`} />
      {/* the long shadow, then the truck on top of it */}
      <polygon points="140,224 16,258 116,268 292,230" fill="#050302" opacity=".7" />
      <g>
        <path fill="#0a0805" d="M138 192 l18 -22 h36 v-6 h96 v54 H138 Z" />
        <path d="M158 168 h128 M156 170 l-16 20" fill="none" stroke={GOLDHI} strokeWidth="1.6" opacity=".75" />
        <rect x="160" y="178" width="26" height="10" fill="#d9b366" opacity=".85" />
        <path d="M168 178 v10 M177 178 v10" stroke={INK} strokeWidth="2" />
        <path d="M200 178 h80 M200 196 h80" stroke="#161009" strokeWidth="1.5" />
        <circle cx="172" cy="220" r="13" fill="#050403" /><circle cx="172" cy="220" r="5" fill="#171208" />
        <circle cx="266" cy="220" r="13" fill="#050403" /><circle cx="266" cy="220" r="5" fill="#171208" />
      </g>
    </g>
  ),

  // GLASS HARVEST — dock 4, roller door half-open, a forklift backlit in the spill.
  "fab-dock": (u) => (
    <g>
      <defs>
        <linearGradient id={`${u}glow`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={PAPERHI} /><stop offset=".55" stopColor={LAMP} /><stop offset="1" stopColor="#8a6a2a" />
        </linearGradient>
        <linearGradient id={`${u}spill`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={GOLDHI} stopOpacity=".4" /><stop offset="1" stopColor={GOLDHI} stopOpacity=".03" />
        </linearGradient>
        <pattern id={`${u}cor`} width="14" height="10" patternUnits="userSpaceOnUse">
          <rect width="14" height="10" fill="#16120b" /><rect width="2" height="10" fill="#0e0b06" />
        </pattern>
      </defs>
      <rect width="400" height="234" fill={`url(#${u}cor)`} />
      <rect y="234" width="400" height="66" fill="#0a0805" />
      {/* stacked pallets, rim-lit */}
      <g>
        <rect x="26" y="212" width="70" height="10" fill={INK} /><rect x="30" y="200" width="62" height="10" fill={INK} />
        <rect x="34" y="188" width="54" height="10" fill={INK} />
        <path d="M26 212 h70 M30 200 h62 M34 188 h54" stroke="#3a3223" strokeWidth="1.4" opacity=".8" />
      </g>
      {/* the door: frame, rolled slats above, glow beneath */}
      <rect x="106" y="40" width="200" height="194" fill="#0b0906" />
      <rect x="106" y="40" width="200" height="194" fill="none" stroke="#241d12" strokeWidth="3" />
      <rect x="114" y="150" width="184" height="84" fill={`url(#${u}glow)`} />
      <rect x="114" y="48" width="184" height="102" fill="#1d1811" />
      <path d="M114 58 h184 M114 70 h184 M114 82 h184 M114 94 h184 M114 106 h184 M114 118 h184 M114 130 h184 M114 142 h184" stroke="#0e0b07" strokeWidth="2.5" />
      <rect x="114" y="146" width="184" height="4" fill={GOLDHI} opacity=".55" />
      {/* light spilling onto the apron */}
      <polygon points="114,234 298,234 358,300 54,300" fill={`url(#${u}spill)`} />
      {/* the forklift, black against the glow */}
      <g fill="#060503">
        <rect x="152" y="154" width="6" height="76" />
        <rect x="134" y="224" width="26" height="4" />
        <rect x="158" y="216" width="10" height="14" />
        <path d="M168 196 h50 c9 0 14 6 14 13 v21 h-70 v-28 c0 -4 3 -6 6 -6z" />
        <path d="M176 196 v-34 h34 l10 34" fill="none" stroke="#060503" strokeWidth="5" />
        <circle cx="182" cy="230" r="10" /><circle cx="222" cy="230" r="8" />
      </g>
      {/* caged lamp over the door */}
      <circle cx="206" cy="34" r="18" fill={GOLDHI} opacity=".35" filter={`url(#${u}soft)`} />
      <path d="M198 34 a8 8 0 0 1 16 0 z" fill={LAMP} />
      <path d="M198 34 h16 M202 28 v6 M210 28 v6" stroke="#0b0906" strokeWidth="1" />
      {/* dock bumpers */}
      <rect x="98" y="216" width="8" height="18" fill="#050403" /><rect x="306" y="216" width="8" height="18" fill="#050403" />
    </g>
  ),

  // PROOF OF WORK — the rig hall: racks receding to a lit aisle, seen through the fence.
  "rig-hall": (u) => (
    <g>
      <defs>
        <linearGradient id={`${u}aisle`} x1="0" y1="1" x2="0" y2="0">
          <stop offset="0" stopColor={GOLDHI} stopOpacity=".34" /><stop offset="1" stopColor={GOLDHI} stopOpacity=".08" />
        </linearGradient>
        <pattern id={`${u}link`} width="18" height="18" patternUnits="userSpaceOnUse">
          <path d="M0 9 L9 0 M9 18 L18 9 M0 9 L9 18 M9 0 L18 9" stroke={PAPER} strokeOpacity=".09" strokeWidth="1.2" fill="none" />
        </pattern>
      </defs>
      <rect width="400" height="300" fill="#0b0906" />
      {/* ceiling / floor planes */}
      <polygon points="0,0 400,0 232,120 168,120" fill="#0f0c08" />
      <polygon points="0,300 400,300 232,178 168,178" fill="#0e0b07" />
      {/* far end of the aisle */}
      <rect x="168" y="120" width="64" height="58" fill="#060503" />
      <rect x="188" y="134" width="24" height="44" fill={GOLD} opacity=".38" />
      <rect x="199" y="134" width="2.5" height="44" fill="#060503" />
      {/* rack rows, inner faces */}
      <polygon points="0,14 168,120 168,178 0,300" fill="#14100a" />
      <polygon points="400,14 232,120 232,178 400,300" fill="#110e09" />
      <path d="M34 36 V276 M66 56 V254 M96 75 V234 M122 91 V217 M144 105 V203" stroke="#060503" strokeWidth="2.5" />
      <path d="M366 36 V276 M334 56 V254 M304 75 V234 M278 91 V217 M256 105 V203" stroke="#060503" strokeWidth="2.5" />
      {/* LED shelf rows — dashed perspective lines */}
      <g stroke={GOLDHI} strokeWidth="2" strokeDasharray="2 9" opacity=".55">
        <path d="M4 88 L164 140" /><path d="M4 160 L164 152" /><path d="M4 236 L164 166" />
      </g>
      <g stroke={GOLD} strokeWidth="2" strokeDasharray="2 11" opacity=".4">
        <path d="M396 88 L236 140" /><path d="M396 160 L236 152" /><path d="M396 236 L236 166" />
      </g>
      {/* overhead lights down the aisle + the lit floor strip */}
      <polygon points="168,178 232,178 322,300 78,300" fill={`url(#${u}aisle)`} />
      <g fill={GOLDHI}>
        <rect x="188" y="58" width="24" height="6" /><rect x="192" y="88" width="16" height="5" />
        <rect x="195" y="108" width="10" height="4" /><rect x="197" y="120" width="6" height="3" />
      </g>
      <ellipse cx="200" cy="70" rx="30" ry="8" fill={GOLDHI} opacity=".14" filter={`url(#${u}soft)`} />
      {/* the fence you're watching through */}
      <rect width="400" height="300" fill={`url(#${u}link)`} />
      <path d="M0 22 H400" stroke={PAPER} strokeOpacity=".14" strokeWidth="2" />
      <path d="M56 0 V300 M348 0 V300" stroke="#050403" strokeWidth="4" opacity=".8" />
    </g>
  ),

  // ABSOLUTE ZERO — annex K: cryo tanks, vapor at the base, one small barred window.
  "cryo-annex": (u) => (
    <g>
      <defs>
        <linearGradient id={`${u}wall`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#191510" /><stop offset="1" stopColor="#0d0a06" />
        </linearGradient>
        <linearGradient id={`${u}tank`} x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="#15100a" /><stop offset=".3" stopColor="#4a3e28" /><stop offset=".55" stopColor="#2b2417" /><stop offset="1" stopColor="#0f0c07" />
        </linearGradient>
        <linearGradient id={`${u}shaft`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={PAPER} stopOpacity=".2" /><stop offset="1" stopColor={PAPER} stopOpacity=".02" />
        </linearGradient>
      </defs>
      <rect width="400" height="300" fill={`url(#${u}wall)`} />
      <rect y="240" width="400" height="60" fill="#0a0805" />
      <line x1="0" y1="240" x2="400" y2="240" stroke="#241d12" strokeWidth="1.5" />
      {/* overhead pipe run */}
      <rect y="18" width="400" height="8" fill="#241d12" />
      <path d="M0 22 H400" stroke="#0d0a06" strokeWidth="1.5" />
      {/* the barred window + its shaft */}
      <polygon points="314,90 370,90 300,240 206,240" fill={`url(#${u}shaft)`} />
      <rect x="314" y="44" width="54" height="46" fill={PAPERHI} opacity=".92" />
      <rect x="326" y="44" width="5" height="46" fill={INK} /><rect x="342" y="44" width="5" height="46" fill={INK} />
      <rect x="358" y="44" width="5" height="46" fill={INK} />
      <rect x="311" y="41" width="60" height="52" fill="none" stroke="#241d12" strokeWidth="4" />
      <circle cx="341" cy="66" r="34" fill={PAPER} opacity=".14" filter={`url(#${u}soft)`} />
      {/* three tanks, staggered heights */}
      {([[40, 66], [140, 90], [236, 104]] as const).map(([x, y], i) => (
        <g key={i}>
          <rect x={x + 26} y={y - 46} width="7" height="46" fill="#241d12" />
          <path d={`M${x + 29} ${y - 44} h${i === 2 ? -20 : 24} `} stroke="#241d12" strokeWidth="7" fill="none" />
          <rect x={x} y={y} width="62" height={246 - y} fill={`url(#${u}tank)`} />
          <ellipse cx={x + 31} cy={y} rx="31" ry="11" fill="#2b2417" stroke="#4a3e28" strokeWidth="1.4" />
          <path d={`M${x} ${y + 60} a31 11 0 0 0 62 0 M${x} ${y + 120} a31 11 0 0 0 62 0`} fill="none" stroke="#0d0a06" strokeWidth="2.5" />
          <circle cx={x + 46} cy={y + 88} r="6" fill="#0d0a06" stroke="#4a3e28" strokeWidth="1.4" />
          <path d={`M${x + 46} ${y + 84} v4`} stroke={GOLDHI} strokeWidth="1.4" />
        </g>
      ))}
      {/* vapor along the floor */}
      <g fill="none" stroke={PAPER} strokeLinecap="round" filter={`url(#${u}soft)`}>
        <path d="M46 248 q26 -18 54 -8 q26 9 46 -6" strokeWidth="9" opacity=".12" />
        <path d="M150 252 q30 -14 62 -4 q24 7 42 -8" strokeWidth="7" opacity=".09" />
        <path d="M258 240 q10 -22 4 -40" strokeWidth="6" opacity=".08" />
      </g>
      <path d="M60 268 h48 M220 272 h60" stroke="#14100a" strokeWidth="2" />
    </g>
  ),

  // MILK RUN — the corner store at dawn, crates on the sidewalk, lamp still burning.
  "milk-corner": (u) => (
    <g>
      <defs>
        <linearGradient id={`${u}dawn`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#0e0c08" /><stop offset=".55" stopColor="#2e2415" /><stop offset="1" stopColor="#a8894a" />
        </linearGradient>
        <linearGradient id={`${u}shopwin`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={LAMP} /><stop offset="1" stopColor="#a87c2e" />
        </linearGradient>
        <pattern id={`${u}aw`} width="24" height="24" patternUnits="userSpaceOnUse">
          <rect width="24" height="24" fill="#201a10" /><rect width="12" height="24" fill="#3a2f1a" />
        </pattern>
      </defs>
      <rect width="400" height="212" fill={`url(#${u}dawn)`} />
      <ellipse cx="210" cy="214" rx="250" ry="54" fill={PAPER} opacity=".22" filter={`url(#${u}soft)`} />
      {/* far rooftops to the right */}
      <path fill="#14100a" d="M250 210 v-30 h36 v12 h30 v-20 h38 v18 h46 v20 Z" />
      {/* street + sidewalk */}
      <rect y="210" width="400" height="90" fill="#0d0a07" />
      <polygon points="0,210 400,210 400,230 0,246" fill="#1a150e" />
      <path d="M0 246 L400 230" stroke="#050403" strokeWidth="1.5" />
      {/* the store — front face + darker corner return */}
      <polygon points="28,58 250,58 250,210 28,210" fill="#17120b" />
      <polygon points="250,58 344,82 344,196 250,210" fill="#0f0c07" />
      <rect x="22" y="48" width="234" height="12" fill="#1d1710" />
      <path d="M22 60 h234" stroke="#050403" strokeWidth="1.5" />
      {/* upstairs, still asleep (one waking) */}
      <g fill="#0b0906" stroke="#241d12" strokeWidth="2">
        <rect x="52" y="74" width="34" height="36" /><rect x="112" y="74" width="34" height="36" /><rect x="172" y="74" width="34" height="36" />
      </g>
      <rect x="114" y="76" width="30" height="32" fill={GOLD} opacity=".22" />
      {/* blank signboard + awning */}
      <rect x="40" y="118" width="176" height="18" fill="#100d08" stroke="#2b241a" strokeWidth="1.5" />
      <polygon points="36,140 244,140 252,164 26,164" fill={`url(#${u}aw)`} />
      <path d="M26 164 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 14 0 q7 9 16 0"
        fill="#201a10" stroke="none" />
      {/* the lit storefront + door, spilling on the walk */}
      <rect x="44" y="170" width="140" height="40" fill={`url(#${u}shopwin)`} />
      <path d="M90 170 v40 M136 170 v40 M44 190 h140" stroke={INK} strokeWidth="2.5" />
      <rect x="196" y="166" width="36" height="44" fill="#d9b366" opacity=".8" />
      <path d="M196 166 v44 M232 166 v44 M202 174 h24 v28 h-24 z" stroke="#17120b" strokeWidth="2" fill="none" />
      <polygon points="44,210 232,210 252,238 30,240" fill={GOLDHI} opacity=".13" />
      {/* the delivery crates, rim-lit by the door */}
      <g>
        <rect x="244" y="196" width="36" height="17" fill={INK} /><rect x="247" y="180" width="30" height="16" fill="#120e08" />
        <path d="M252 180 v16 M262 180 v16 M272 180 v16 M252 196 v17 M263 196 v17 M274 196 v17" stroke="#050403" strokeWidth="1.5" />
        <path d="M247 180 h30 M244 196 h36" stroke={LAMP} strokeWidth="1.4" opacity=".7" />
        <rect x="288" y="199" width="32" height="14" fill={INK} />
        <path d="M288 199 h32" stroke={LAMP} strokeWidth="1.2" opacity=".5" />
        <path d="M253 172 c0 -4 3 -5 3 -8 h4 c0 3 3 4 3 8 z M264 172 c0 -4 3 -5 3 -8 h4 c0 3 3 4 3 8 z" fill="#0d0a06" />
      </g>
      {/* the streetlamp that hasn't clocked off */}
      <rect x="358" y="108" width="3.5" height="118" fill="#050403" />
      <circle cx="360" cy="104" r="5" fill={PAPERHI} />
      <circle cx="360" cy="104" r="16" fill={GOLDHI} opacity=".3" filter={`url(#${u}soft)`} />
    </g>
  ),

  // OPEN WINDOW — a row house at night; exactly one window lit. You told a friend.
  "open-window": (u) => (
    <g>
      <defs>
        <linearGradient id={`${u}lit`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={GOLDHI} /><stop offset="1" stopColor="#b3872f" />
        </linearGradient>
        <pattern id={`${u}brick`} width="26" height="9" patternUnits="userSpaceOnUse">
          <rect width="26" height="9" fill="#191410" /><path d="M0 8.5 H26 M13 0 V8" stroke="#0f0c08" strokeWidth="1" />
        </pattern>
        <radialGradient id={`${u}halo`}>
          <stop offset="0" stopColor={GOLDHI} stopOpacity=".3" /><stop offset="1" stopColor={GOLDHI} stopOpacity="0" />
        </radialGradient>
      </defs>
      <rect width="400" height="300" fill={`url(#${u}brick)`} />
      <circle cx="0" cy="250" r="90" fill={PAPER} opacity=".05" filter={`url(#${u}soft)`} />
      {/* cornice */}
      <rect width="400" height="24" fill="#0d0b07" />
      <path d="M0 28 H400" stroke="#0f0c08" strokeWidth="3" />
      <path d="M6 26 H394" stroke="#241d12" strokeWidth="2" strokeDasharray="4 7" />
      {/* the window grid — dark but for one */}
      {([[46, 44], [168, 44], [290, 44], [46, 132], [168, 132], [46, 220], [290, 220]] as const).map(([x, y], i) => (
        <g key={i}>
          <rect x={x - 4} y={y - 6} width="72" height="6" fill="#221c12" />
          <rect x={x} y={y} width="64" height="64" fill="#0a0806" stroke="#241d12" strokeWidth="2.5" />
          <path d={`M${x + 32} ${y} v64 M${x} ${y + 32} h64`} stroke="#1d1711" strokeWidth="2" />
          <rect x={x - 5} y={y + 64} width="74" height="5" fill="#221c12" />
        </g>
      ))}
      {/* the one lit window — blinds half-drawn */}
      <ellipse cx="322" cy="164" rx="105" ry="80" fill={`url(#${u}halo)`} />
      <rect x="286" y="126" width="72" height="6" fill="#2b241a" />
      <rect x="290" y="132" width="64" height="64" fill={`url(#${u}lit)`} />
      <path d="M290 138 h64 M290 145 h64 M290 152 h64 M290 159 h64" stroke={INK} strokeWidth="2.6" opacity=".55" />
      <path d="M322 132 v64 M290 164 h64" stroke="#3a2c12" strokeWidth="2" />
      <rect x="290" y="132" width="64" height="64" fill="none" stroke="#241d12" strokeWidth="2.5" />
      <rect x="285" y="196" width="74" height="5" fill="#2b241a" />
      {/* the door + stoop */}
      <rect x="176" y="212" width="48" height="88" fill="#0b0906" stroke="#241d12" strokeWidth="2.5" />
      <path d="M186 224 h28 v30 h-28 z M186 262 h28 v26 h-28 z" fill="none" stroke="#1d1711" strokeWidth="2" />
      <path d="M176 208 a24 14 0 0 1 48 0 z" fill={GOLD} opacity=".22" />
      <path d="M200 196 v10 M188 200 l6 7 M212 200 l-6 7" stroke="#0d0b07" strokeWidth="1.5" />
      <rect x="164" y="288" width="72" height="6" fill="#221a10" />
      <rect x="156" y="294" width="88" height="6" fill="#1c150d" />
      <path d="M168 288 v-40 M232 288 v-40 M168 250 l-12 -4 M232 250 l12 -4" stroke={TRIM} strokeWidth="2.5" fill="none" />
    </g>
  ),

  // TIER 0 — the Safehouse: a narrow walk-up over a shuttered shop. New in town, and welcome.
  "safehouse": (u) => (
    <g>
      <rect width="400" height="400" fill={NIGHT} />
      {/* taller, darker neighbors pressing in */}
      <rect x="0" y="54" width="122" height="346" fill="#0e0b07" />
      <rect x="278" y="34" width="122" height="366" fill="#0c0a06" />
      <g fill="#080604">
        <rect x="30" y="90" width="26" height="34" /><rect x="30" y="170" width="26" height="34" />
        <rect x="320" y="80" width="26" height="34" /><rect x="320" y="160" width="26" height="34" /><rect x="320" y="240" width="26" height="34" />
      </g>
      {/* the walk-up */}
      <rect x="116" y="86" width="168" height="14" fill="#221c12" />
      <rect x="122" y="100" width="156" height="300" fill="#1a150e" />
      <path d="M122 100 v300 M278 100 v300" stroke="#0d0a06" strokeWidth="2.5" />
      {/* three floors, two windows each — one glows faintly */}
      {([[142, 118], [216, 118], [142, 190], [216, 190], [142, 262], [216, 262]] as const).map(([x, y], i) => (
        <g key={i}>
          <rect x={x} y={y} width="42" height="54" fill={i === 3 ? "#6a5121" : "#0a0806"} stroke="#2b241a" strokeWidth="2.5" />
          <path d={`M${x + 21} ${y} v54 M${x} ${y + 27} h42`} stroke={i === 3 ? "#3a2c12" : "#1d1711"} strokeWidth="2" />
          <rect x={x - 3} y={y + 54} width="48" height="5" fill="#221c12" />
        </g>
      ))}
      {/* fire escape zigzag */}
      <g stroke={TRIM} strokeWidth="2.2" fill="none" opacity=".95">
        <path d="M132 176 h74 M132 248 h74 M132 320 h74" />
        <path d="M136 176 v-8 M202 176 v-8 M136 248 v-8 M202 248 v-8 M136 320 v-8 M202 320 v-8" />
        <path d="M202 176 L136 248 M202 248 L136 320" />
      </g>
      {/* the shuttered shop */}
      <rect x="128" y="330" width="150" height="12" fill="#0d0a06" />
      <rect x="132" y="342" width="94" height="52" fill={WALL2} />
      <path d="M132 350 h94 M132 358 h94 M132 366 h94 M132 374 h94 M132 382 h94" stroke="#14100a" strokeWidth="2.5" />
      <rect x="234" y="342" width="38" height="52" fill="#0d0a06" stroke="#241d12" strokeWidth="2" />
      {/* the caged lamp — the one warm thing */}
      <circle cx="253" cy="330" r="19" fill={GOLDHI} opacity=".28" filter={`url(#${u}soft)`} />
      <path d="M245 332 a8 8 0 0 1 16 0 z" fill={LAMP} />
      <path d="M245 332 h16 M249 326 v6 M257 326 v6" stroke="#0b0906" strokeWidth="1" />
      <ellipse cx="253" cy="396" rx="42" ry="7" fill={GOLDHI} opacity=".14" />
      <rect y="392" width="400" height="8" fill="#14100e" />
    </g>
  ),

  // TIER 1 — the Row House: brick, a stoop, iron rails. The first purchase decision.
  "row-house": (u) => (
    <g>
      <defs>
        <pattern id={`${u}brick`} width="26" height="9" patternUnits="userSpaceOnUse">
          <rect width="26" height="9" fill="#1b1610" /><path d="M0 8.5 H26 M13 0 V8" stroke="#100d08" strokeWidth="1" />
        </pattern>
      </defs>
      <rect width="400" height="90" fill={NIGHT} />
      <rect y="90" width="400" height="310" fill={`url(#${u}brick)`} />
      {/* party walls: the block continues both ways */}
      <path d="M70 96 V400 M330 96 V400" stroke="#0d0a06" strokeWidth="4" />
      <g fill="#0a0806" opacity=".9">
        <rect x="8" y="130" width="40" height="58" /><rect x="8" y="230" width="40" height="58" />
        <rect x="352" y="130" width="40" height="58" /><rect x="352" y="230" width="40" height="58" />
      </g>
      {/* cornice over the subject house */}
      <rect x="62" y="76" width="276" height="16" fill="#0e0b07" />
      <path d="M70 92 H330" stroke="#241d12" strokeWidth="2.5" strokeDasharray="4 7" />
      {/* two window bays, two floors — the parlor is home */}
      {([[104, 116, 0], [240, 116, 0], [104, 208, 0], [240, 208, 1]] as const).map(([x, y, lit], i) => (
        <g key={i}>
          <rect x={x - 5} y={y - 7} width="66" height="7" fill="#252017" />
          <rect x={x} y={y} width="56" height="66" fill={lit ? "#c9973a" : "#0a0806"} stroke="#2b241a" strokeWidth="2.5" />
          {lit ? <path d={`M${x} ${y + 8} h56 M${x} ${y + 16} h56`} stroke={INK} strokeWidth="2.4" opacity=".45" /> : null}
          <path d={`M${x + 28} ${y} v66 M${x} ${y + 33} h56`} stroke={lit ? "#3a2c12" : "#1d1711"} strokeWidth="2" />
          <rect x={x - 6} y={y + 66} width="68" height="6" fill="#252017" />
        </g>
      ))}
      <circle cx="268" cy="240" r="70" fill={GOLDHI} opacity=".08" filter={`url(#${u}soft)`} />
      {/* the door, its fanlight, the stoop */}
      <rect x="166" y="292" width="56" height="82" fill="#0b0906" stroke="#2b241a" strokeWidth="2.5" />
      <path d="M176 304 h36 v32 h-36 z M176 344 h36 v24 h-36 z" fill="none" stroke="#1d1711" strokeWidth="2" />
      <path d="M166 288 a28 16 0 0 1 56 0 z" fill={LAMP} opacity=".85" />
      <path d="M194 272 v16 M180 276 l8 9 M208 276 l-8 9" stroke="#17120b" strokeWidth="2" />
      <rect x="156" y="374" width="76" height="9" fill="#241c11" />
      <rect x="148" y="383" width="92" height="9" fill="#1d160d" />
      <rect x="140" y="392" width="108" height="8" fill="#17110a" />
      <path d="M156 374 h76 M148 383 h92 M140 392 h108" stroke={GOLD} strokeWidth="1.2" opacity=".35" />
      {/* iron rails */}
      <g stroke={TRIM} strokeWidth="2.6" fill="none">
        <path d="M160 374 v-30 M228 374 v-30 M160 346 l-22 42 M228 346 l22 42" />
        <path d="M148 390 v-14 M240 390 v-14" />
      </g>
      <circle cx="160" cy="341" r="3" fill={TRIM} /><circle cx="228" cy="341" r="3" fill={TRIM} />
      <ellipse cx="194" cy="398" rx="60" ry="5" fill={GOLDHI} opacity=".1" />
    </g>
  ),

  // TIER 2 — the Brownstone: bay windows lit like a promise. Established, with opinions.
  "brownstone": (u) => (
    <g>
      <defs>
        <linearGradient id={`${u}bay`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={LAMP} /><stop offset="1" stopColor="#8a6425" />
        </linearGradient>
      </defs>
      <rect width="400" height="400" fill={NIGHT} />
      <rect x="0" y="120" width="60" height="280" fill="#0d0a06" />
      <rect x="340" y="110" width="60" height="290" fill="#0e0b07" />
      {/* the house */}
      <rect x="60" y="72" width="280" height="328" fill="#1d1811" />
      <rect x="60" y="298" width="280" height="102" fill="#17120b" />
      <path d="M60 316 h280 M60 336 h280 M60 356 h280" stroke="#0f0c07" strokeWidth="2" />
      {/* the cornice, with dentils */}
      <rect x="50" y="54" width="300" height="20" fill="#100d08" />
      <path d="M58 72 H342" stroke={GOLD} strokeWidth="2" strokeDasharray="3 6" opacity=".35" />
      <path d="M60 74 H340" stroke="#050403" strokeWidth="2" />
      {/* the two-story bay, glowing */}
      <circle cx="134" cy="210" r="96" fill={GOLDHI} opacity=".1" filter={`url(#${u}soft)`} />
      <polygon points="76,132 92,118 92,300 76,286" fill="#15100a" />
      <polygon points="176,118 192,132 192,286 176,300" fill="#2e2517" />
      <rect x="92" y="118" width="84" height="182" fill="#221b12" />
      {([[102, 134], [140, 134], [102, 222], [140, 222]] as const).map(([x, y], i) => (
        <g key={i}>
          <rect x={x} y={y} width="26" height="62" fill={`url(#${u}bay)`} />
          <path d={`M${x} ${y + 31} h26 M${x + 13} ${y} v62`} stroke="#3a2c12" strokeWidth="2" />
          <rect x={x} y={y} width="26" height="62" fill="none" stroke="#14100a" strokeWidth="2.5" />
        </g>
      ))}
      <rect x="86" y="202" width="96" height="10" fill="#15100a" />
      {/* right bays — tall, dark, storied */}
      {([[226, 130], [286, 130], [226, 222]] as const).map(([x, y], i) => (
        <g key={i}>
          <rect x={x - 4} y={y - 8} width="52" height="8" fill="#2b241a" />
          <rect x={x} y={y} width="44" height="68" fill="#0a0806" stroke="#241d12" strokeWidth="2.5" />
          <path d={`M${x + 22} ${y} v68 M${x} ${y + 34} h44`} stroke="#1d1711" strokeWidth="2" />
          <rect x={x - 5} y={y + 68} width="54" height="6" fill="#2b241a" />
        </g>
      ))}
      {/* arched entrance + lantern */}
      <path d="M282 400 v-72 a26 26 0 0 1 52 0 v72 z" fill="#0b0906" stroke="#2b241a" strokeWidth="3" />
      <path d="M308 330 v66 M292 340 h32 M292 366 h32" stroke="#1d1711" strokeWidth="2" />
      <circle cx="270" cy="330" r="5" fill={LAMP} />
      <circle cx="270" cy="330" r="16" fill={GOLDHI} opacity=".35" filter={`url(#${u}soft)`} />
      <rect x="267" y="336" width="6" height="10" fill="#0d0a06" />
      {/* stoop + balustrades */}
      <rect x="274" y="386" width="68" height="7" fill="#241c11" />
      <rect x="266" y="393" width="84" height="7" fill="#1d160d" />
      <polygon points="258,400 274,352 282,352 270,400" fill="#221a10" />
      <polygon points="358,400 342,352 334,352 346,400" fill="#221a10" />
      {/* areaway iron fence */}
      <path d="M66 356 H222" stroke={TRIM} strokeWidth="2.5" />
      <path d="M74 356 v40 M94 356 v40 M114 356 v40 M134 356 v40 M154 356 v40 M174 356 v40 M194 356 v40 M214 356 v40" stroke={TRIM} strokeWidth="2" />
      <rect y="394" width="400" height="6" fill="#14100e" />
    </g>
  ),

  // TIER 3 — the Estate: gates, grounds, one porch lit. Serious capital.
  "estate": (u) => (
    <g>
      <defs>
        <linearGradient id={`${u}sky`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={NIGHT} /><stop offset="1" stopColor="#1c160c" />
        </linearGradient>
        <linearGradient id={`${u}drive`} x1="0" y1="1" x2="0" y2="0">
          <stop offset="0" stopColor={GOLDHI} stopOpacity=".16" /><stop offset="1" stopColor={GOLDHI} stopOpacity=".02" />
        </linearGradient>
      </defs>
      <rect width="400" height="240" fill={`url(#${u}sky)`} />
      <circle cx="330" cy="58" r="17" fill={PAPER} opacity=".16" filter={`url(#${u}soft)`} />
      {/* treeline + flanking trees */}
      <path fill="#0e0b07" d="M0 214 q40 -34 84 -26 q30 -26 72 -18 q48 -20 88 -4 q44 -12 76 6 q46 -6 80 18 v40 H0 Z" />
      <g fill="#0a0805">
        <circle cx="52" cy="172" r="44" /><circle cx="86" cy="196" r="34" /><rect x="58" y="204" width="10" height="46" />
        <circle cx="352" cy="164" r="46" /><circle cx="318" cy="196" r="32" /><rect x="346" y="200" width="10" height="50" />
      </g>
      {/* the house on its rise */}
      <polygon points="128,152 202,106 276,152" fill="#0f0c08" />
      <rect x="136" y="152" width="132" height="76" fill="#14100a" />
      <rect x="252" y="170" width="66" height="58" fill="#100d08" />
      <rect x="238" y="112" width="14" height="34" fill="#0d0a06" />
      <rect x="186" y="192" width="26" height="36" fill={LAMP} opacity=".9" />
      <path d="M199 192 v36" stroke="#3a2c12" strokeWidth="2" />
      <rect x="152" y="176" width="18" height="22" fill={GOLD} opacity=".5" />
      <rect x="272" y="184" width="16" height="18" fill={GOLD} opacity=".4" />
      <circle cx="199" cy="204" r="30" fill={GOLDHI} opacity=".18" filter={`url(#${u}soft)`} />
      {/* lawn + the drive sweeping to the gate */}
      <rect y="228" width="400" height="94" fill="#0d0a06" />
      <polygon points="192,228 208,228 224,306 176,306" fill="#14100b" />
      <polygon points="194,230 206,230 220,304 180,304" fill={`url(#${u}drive)`} opacity=".55" />
      {/* the hedge line, then the wall it grows over */}
      <path fill="#0f0b07" d="M0 310 q22 -12 44 0 q22 -11 44 0 q22 -12 44 0 l16 2 v40 H0 Z M252 312 q22 -12 44 0 q22 -11 44 0 q22 -12 44 0 l16 2 v38 h-148 Z" />
      <rect y="330" width="150" height="40" fill="#181209" />
      <rect x="250" y="330" width="150" height="40" fill="#181209" />
      <path d="M0 330 H150 M250 330 H400" stroke={GOLD} strokeWidth="1.4" opacity=".18" />
      <path d="M36 330 v40 M90 330 v40 M310 330 v40 M364 330 v40" stroke="#0d0a06" strokeWidth="2" />
      {/* pillars, lamps, gate */}
      <rect x="144" y="284" width="22" height="82" fill="#1d1711" />
      <rect x="140" y="278" width="30" height="9" fill="#2b241a" />
      <rect x="234" y="284" width="22" height="82" fill="#1d1711" />
      <rect x="230" y="278" width="30" height="9" fill="#2b241a" />
      <circle cx="155" cy="270" r="6" fill={GOLDHI} /><circle cx="245" cy="270" r="6" fill={GOLDHI} />
      <circle cx="155" cy="270" r="17" fill={GOLDHI} opacity=".35" filter={`url(#${u}soft)`} />
      <circle cx="245" cy="270" r="17" fill={GOLDHI} opacity=".35" filter={`url(#${u}soft)`} />
      <g stroke="#050403" strokeWidth="2.6">
        <path d="M172 300 v66 M182 296 v70 M192 294 v72 M200 293 v73 M208 294 v72 M218 296 v70 M228 300 v66" />
        <path d="M166 306 h68 M166 350 h68" strokeWidth="3" />
      </g>
      <g fill="#050403">
        <circle cx="182" cy="292" r="1.8" /><circle cx="192" cy="290" r="1.8" /><circle cx="200" cy="289" r="1.8" />
        <circle cx="208" cy="290" r="1.8" /><circle cx="218" cy="292" r="1.8" />
      </g>
      <rect y="366" width="400" height="34" fill="#0b0906" />
      <ellipse cx="200" cy="370" rx="52" ry="6" fill={GOLDHI} opacity=".06" />
    </g>
  ),

  // TIER 4 — the Compound: the endgame, and the target. Walls, floodlight, one gate.
  "compound": (u) => (
    <g>
      <defs>
        <linearGradient id={`${u}flood`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={GOLDHI} stopOpacity=".22" /><stop offset="1" stopColor={GOLDHI} stopOpacity=".03" />
        </linearGradient>
        <linearGradient id={`${u}gatewash`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={GOLDHI} stopOpacity=".22" /><stop offset="1" stopColor={GOLDHI} stopOpacity="0" />
        </linearGradient>
      </defs>
      <rect width="400" height="400" fill={NIGHT} />
      {/* the main house, long and low, beyond the wall */}
      <rect x="150" y="118" width="92" height="36" fill="#100d08" />
      <rect x="70" y="150" width="262" height="72" fill="#120e09" />
      <path d="M70 150 h262 M150 118 h92" stroke="#050403" strokeWidth="2" />
      <g fill={GOLD} opacity=".75">
        <rect x="92" y="176" width="42" height="8" /><rect x="156" y="176" width="26" height="8" /><rect x="248" y="182" width="52" height="8" />
      </g>
      <rect x="160" y="128" width="20" height="7" fill={GOLD} opacity=".5" />
      {/* comm mast */}
      <path d="M310 62 V150 M300 84 h20 M302 108 h16 M304 130 h12" stroke="#060504" strokeWidth="2.5" />
      <circle cx="310" cy="60" r="3" fill={GOLDHI} />
      <circle cx="310" cy="60" r="9" fill={GOLDHI} opacity=".4" filter={`url(#${u}soft)`} />
      {/* a searchlight beam raking in from off-frame */}
      <polygon points="-40,-10 30,-10 150,244 30,244" fill={`url(#${u}flood)`} filter={`url(#${u}soft)`} />
      {/* yard strip */}
      <rect y="222" width="400" height="30" fill="#0d0a06" />
      {/* the perimeter wall */}
      <rect y="244" width="400" height="12" fill="#221c12" />
      <path d="M0 256 H400" stroke="#050403" strokeWidth="2" />
      <rect y="256" width="400" height="106" fill="#1b1610" />
      <path d="M50 256 V362 M100 256 V362 M300 256 V362 M350 256 V362" stroke="#0f0c08" strokeWidth="2.5" />
      {/* razor coil along the coping */}
      <g stroke={TRIM} strokeWidth="1.3" fill="none" opacity=".7">
        {Array.from({ length: 34 }, (_, i) => <circle key={i} cx={6 + i * 12} cy="241" r="4" />)}
      </g>
      {/* the gate — steel, ribbed, one lit slit */}
      <rect x="156" y="262" width="88" height="100" fill="#0e0b07" />
      <path d="M164 262 v100 M174 262 v100 M184 262 v100 M194 262 v100 M206 262 v100 M216 262 v100 M226 262 v100 M236 262 v100" stroke="#1d1711" strokeWidth="2.2" />
      <path d="M200 262 v100" stroke="#050403" strokeWidth="3" />
      <rect x="156" y="262" width="88" height="100" fill={`url(#${u}gatewash)`} />
      <rect x="156" y="262" width="88" height="100" fill="none" stroke="#050403" strokeWidth="3" />
      <rect x="188" y="298" width="24" height="7" fill={GOLDHI} opacity=".6" />
      {/* gate lamps */}
      <path d="M142 252 a8 8 0 0 1 16 0 z M242 252 a8 8 0 0 1 16 0 z" fill={LAMP} transform="translate(0 8)" />
      <circle cx="150" cy="256" r="20" fill={GOLDHI} opacity=".35" filter={`url(#${u}soft)`} />
      <circle cx="250" cy="256" r="20" fill={GOLDHI} opacity=".35" filter={`url(#${u}soft)`} />
      {/* approach */}
      <rect y="362" width="400" height="38" fill="#0a0805" />
      <ellipse cx="200" cy="370" rx="80" ry="9" fill={GOLDHI} opacity=".1" />
      <path d="M120 384 h60 M240 380 h48" stroke="#120e09" strokeWidth="2.5" />
    </g>
  ),
};
