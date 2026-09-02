// Render the social share cards from the house tokens, so a shared link unfurls into a branded card
// instead of a bare URL: the shared default (public/og-default.png) plus one UNIQUE card per published
// post (public/og/<slug>.png) with the post title as the hero. Now a build step — it runs before
// `vite build` so Vite copies public/og/* into dist/, and prerender-blog.mjs then points each post's
// og:image at its own card. Serif is Georgia, the last name in the --serif stack, so librsvg resolves
// it without Didot installed; every color is a styles.css :root token, not a new value.
import sharp from "sharp";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdirSync, readFileSync, readdirSync } from "node:fs";

const HERE = dirname(fileURLToPath(import.meta.url));
const INK = "#12100c";
const GOLD = "#c9a24b";
const GOLD_HI = "#e2c177";
const TX = "#ede8dc";
const TX_MUT = "#a69e8c";
const LINE = "#3b3427";
const OX = "#c4675b";
const SERIF = "Georgia, 'Times New Roman', serif";
const MONO = "Menlo, 'DejaVu Sans Mono', monospace";

const esc = (s) => String(s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// Shared house frame every card sits in: the ground, the gold top rule, and the two inset borders.
const frame = `<rect width="1200" height="630" fill="${INK}"/>
  <rect x="0" y="0" width="1200" height="6" fill="${GOLD}"/>
  <rect x="28" y="28" width="1144" height="574" fill="none" stroke="${LINE}" stroke-width="1"/>
  <rect x="40" y="40" width="1120" height="550" fill="none" stroke="${GOLD}" stroke-opacity="0.32" stroke-width="1"/>`;

const eyebrow = `<text x="96" y="150" font-family="${MONO}" font-size="22" letter-spacing="6" fill="${GOLD}">ESSEY · ON ROBINHOOD CHAIN</text>`;

const footer = `<circle cx="104" cy="560" r="7" fill="${OX}"/>
  <text x="124" y="566" font-family="${MONO}" font-size="24" letter-spacing="2" fill="${GOLD_HI}">essey.xyz</text>`;

const defaultCardSvg = () => `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  ${frame}
  ${eyebrow}
  <text x="92" y="330" font-family="${SERIF}" font-size="150" font-weight="700" fill="${TX}" letter-spacing="2">Essey</text>
  <rect x="98" y="372" width="120" height="3" fill="${GOLD}"/>
  <text x="96" y="452" font-family="${SERIF}" font-size="42" fill="${TX_MUT}">A token backed by real tokenized equities.</text>
  <text x="96" y="508" font-family="${SERIF}" font-size="42" fill="${TX_MUT}">An adminless floor. Every number on-chain.</text>
  ${footer}
</svg>`;

// librsvg can't measure text, so title lines are sized against a per-glyph width estimate rounded UP
// (calibrated to real pixel extents): when the estimate fits SAFE_W the glyphs do, so the worst case is
// a smaller title, never the overflow the old flat 0.52 average caused on wide caps like "$ESSEY".
const SAFE_W = 1000;         // text x=96 .. 1096, ~64px inside the inner gold frame at x=1160
const MAX_LINES = 3;
const LETTER_SPACING = 1;    // the title text's letter-spacing="1"
const TITLE_SIZES = [92, 80, 70, 62, 54, 46, 40];

function glyphEm(ch) {       // em advance, Georgia bold; caps, $, M/W are the wide classes the average missed
  if (ch === " ") return 0.32;
  if (ch === "M" || ch === "W") return 1.15;
  if (ch === "m" || ch === "w") return 0.98;
  if (ch >= "A" && ch <= "Z") return 0.85;
  if ((ch >= "0" && ch <= "9") || ch === "$") return 0.70;
  if ("ijltfrI.,:;'!|()[]-".includes(ch)) return 0.38;
  return 0.62;
}
const emWidth = (s) => [...s].reduce((w, c) => w + glyphEm(c), 0);
const lineWidth = (s, size) => emWidth(s) * size + LETTER_SPACING * Math.max(0, s.length - 1);

function wrapAt(words, size) {
  const lines = [];
  let cur = "";
  for (const w of words) {
    const cand = cur ? `${cur} ${w}` : w;
    if (cur && lineWidth(cand, size) > SAFE_W) { lines.push(cur); cur = w; } else cur = cand;
  }
  if (cur) lines.push(cur);
  return lines;
}

const linesFit = (lines, size) => lines.every((ln) => lineWidth(ln, size) <= SAFE_W);

function layoutTitle(title) {
  const words = title.split(/\s+/).filter(Boolean);
  for (const size of TITLE_SIZES) {
    const lines = wrapAt(words, size);
    if (lines.length <= MAX_LINES && linesFit(lines, size)) return { size, lines };
  }
  // No rung fit (usually one word wider than the column): clamp to MAX_LINES, then shrink below the
  // ladder so even the widest line lands inside SAFE_W rather than overflow.
  const base = TITLE_SIZES[TITLE_SIZES.length - 1];
  let lines = wrapAt(words, base);
  if (lines.length > MAX_LINES) {
    lines = lines.slice(0, MAX_LINES);
    lines[MAX_LINES - 1] = `${lines[MAX_LINES - 1].replace(/.$/, "")}…`;
  }
  const widest = Math.max(...lines.map(emWidth));
  const size = Math.min(base, Math.floor(SAFE_W / widest));
  return { size, lines };
}

// The POST TITLE is the hero: large serif, vertically centered so a 1-line and a 3-line title both sit
// balanced. The Essey wordmark + its gold underline keep the brand; a single muted summary line rides
// under short titles (dropped for 3-liners, which have no room above the footer).
function postCardSvg(title, summary) {
  const { size, lines } = layoutTitle(title);
  const lineHeight = Math.round(size * 1.16);
  const first = Math.round(380 - ((lines.length - 1) * lineHeight) / 2);
  const last = first + (lines.length - 1) * lineHeight;
  const underlineY = last + 34;

  const titleSvg = lines.map((ln, i) =>
    `<text x="96" y="${first + i * lineHeight}" font-family="${SERIF}" font-size="${size}" font-weight="700" fill="${TX}" letter-spacing="1">${esc(ln)}</text>`
  ).join("\n  ");

  let summarySvg = "";
  if (lines.length <= 2 && summary) {
    let one = summary;
    if (lineWidth(one, 30) > SAFE_W) {
      while (one && lineWidth(`${one.trimEnd()}…`, 30) > SAFE_W) one = one.slice(0, -1);
      one = `${one.trimEnd()}…`;
    }
    summarySvg = `<text x="96" y="${underlineY + 48}" font-family="${SERIF}" font-size="30" fill="${TX_MUT}">${esc(one)}</text>`;
  }

  return `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  ${frame}
  ${eyebrow}
  <text x="96" y="206" font-family="${SERIF}" font-size="46" font-weight="700" fill="${TX}" letter-spacing="1">Essey</text>
  <rect x="98" y="222" width="88" height="3" fill="${GOLD}"/>
  ${titleSvg}
  <rect x="96" y="${underlineY}" width="160" height="3" fill="${GOLD}"/>
  ${summarySvg}
  ${footer}
</svg>`;
}

function frontMatter(raw, file) {
  const fence = /^---\n([\s\S]*?)\n---\n?/.exec(raw);
  const meta = {};
  if (fence) for (const line of fence[1].split("\n")) {
    const kv = /^(\w+):\s*(.*)$/.exec(line);
    if (kv) meta[kv[1]] = kv[2].trim().replace(/^["']|["']$/g, "");
  }
  const slug = meta.slug || file.replace(/\.md$/, "");
  return { title: meta.title || "", summary: meta.summary || "", slug, draft: meta.draft === "true" };
}

async function render(svg, out) {
  await sharp(Buffer.from(svg)).png().toFile(out);
  console.log(`wrote ${out}`);
}

await render(defaultCardSvg(), join(HERE, "public", "og-default.png"));

const OG_DIR = join(HERE, "public", "og");
mkdirSync(OG_DIR, { recursive: true });
const POSTS_DIR = join(HERE, "src", "blog", "posts");
const posts = readdirSync(POSTS_DIR)
  .filter((f) => f.endsWith(".md"))
  .map((f) => frontMatter(readFileSync(join(POSTS_DIR, f), "utf8"), f))
  .filter((p) => !p.draft);

for (const p of posts) {
  await render(postCardSvg(p.title || p.slug, p.summary), join(OG_DIR, `${p.slug}.png`));
}
