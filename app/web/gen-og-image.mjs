// Render the default social share card (public/og-default.png) from the house tokens, so a shared
// blog/site link unfurls into a branded card instead of a bare URL. Run by hand when the card
// changes — it is NOT in the build chain (the PNG is committed), to keep CI free of a font-render
// dependency. Serif is Georgia, the last name in the --serif stack, so librsvg resolves it without
// Didot installed; every color is a styles.css :root token, not a new value.
import sharp from "sharp";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const INK = "#12100c";
const S2 = "#1e1a14";
const GOLD = "#c9a24b";
const GOLD_HI = "#e2c177";
const TX = "#ede8dc";
const TX_MUT = "#a69e8c";
const LINE = "#3b3427";
const OX = "#c4675b";
const SERIF = "Georgia, 'Times New Roman', serif";
const MONO = "Menlo, 'DejaVu Sans Mono', monospace";

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <rect width="1200" height="630" fill="${INK}"/>
  <rect x="0" y="0" width="1200" height="6" fill="${GOLD}"/>
  <rect x="28" y="28" width="1144" height="574" fill="none" stroke="${LINE}" stroke-width="1"/>
  <rect x="40" y="40" width="1120" height="550" fill="none" stroke="${GOLD}" stroke-opacity="0.32" stroke-width="1"/>
  <text x="96" y="150" font-family="${MONO}" font-size="22" letter-spacing="6" fill="${GOLD}">ESSEY · ON ROBINHOOD CHAIN</text>
  <text x="92" y="330" font-family="${SERIF}" font-size="150" font-weight="700" fill="${TX}" letter-spacing="2">Essey</text>
  <rect x="98" y="372" width="120" height="3" fill="${GOLD}"/>
  <text x="96" y="452" font-family="${SERIF}" font-size="42" fill="${TX_MUT}">A token backed by real tokenized equities.</text>
  <text x="96" y="508" font-family="${SERIF}" font-size="42" fill="${TX_MUT}">An adminless floor. Every number on-chain.</text>
  <circle cx="104" cy="560" r="7" fill="${OX}"/>
  <text x="124" y="566" font-family="${MONO}" font-size="24" letter-spacing="2" fill="${GOLD_HI}">essey.xyz</text>
</svg>`;

const out = join(HERE, "public", "og-default.png");
await sharp(Buffer.from(svg)).png().toFile(out);
console.log(`wrote ${out}`);
