// Generate src/docs.generated.ts from the repo docs so the site can render them (self-contained).
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import posix from "node:path/posix";
import { execSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const DOCS = join(HERE, "..", "..", "docs");

// The site renders the checked-out working tree, so "source" links must point at the ref that was
// actually built — a hardcoded `main` 404s for any doc that hasn't merged yet (that bug shipped:
// GAME-GUIDE.md and TOKENOMICS-v3.md live only on feat/essey-market-layer today). Vercel exposes the
// built ref as VERCEL_GIT_COMMIT_REF; local builds ask git. When the feature branch merges, builds
// from main flip every link back to blob/main automatically — nothing to edit.
const gitBranch = () => {
  try {
    const b = execSync("git rev-parse --abbrev-ref HEAD", { cwd: HERE }).toString().trim();
    return b === "HEAD" ? "" : b; // detached checkout — fall through
  } catch { return ""; }
};
const BRANCH = process.env.VERCEL_GIT_COMMIT_REF || gitBranch() || "main";
const REPO_DOCS = `https://github.com/erikastramecki/essey/blob/${BRANCH}/docs/`;

// Visitor-facing docs, grouped for the reading room. CURATION RULE (founder, 2026-08): only docs that
// serve the current Market-layer narrative appear here — prior iterations' docs stay in the repo but
// off the page. The audit trail follows the same rule: every CURRENT (Robinhood Chain, Essey-era)
// round is surfaced clean or not, but the superseded pre-RH-pivot rounds — the Move/Sui rounds and the
// first Solidity-port round — are archived IN THE REPO and off the page (audit trail preserved, not
// deleted; verifiable on GitHub). fix-first transparency is about the CURRENT system, not every
// abandoned iteration.
// `file` is relative to /docs and doubles as the GitHub source link, so every card in the site can
// point at the exact file it renders — no separately-maintained list to drift out of sync.
// TWO-SECTION SILO (founder, 2026-09): the reading room mirrors the site — PROTOCOL docs and the
// DONS/GAME docs are separate top-level sections that never mix. `section` is that dimension; `group`
// is the sub-heading within a section. The consumer (App.tsx SECTIONS) owns render order.
const PICK = [
  // PROTOCOL
  ["PROTOCOL", "Base layer", "BASE-LAYER.md", "The base layer — $ESSEY & the reserve", "The live floor: fixed-supply adminless $ESSEY (8,888,888,888) and the equity-pegged EsseyReserve — a redeemable, pro-rata, burn-based claim on a pile of real tokenized equity. If you read one protocol doc, read this. Every property cited to the deployed contracts."],
  ["PROTOCOL", "The engine", "SCOPE-robinhood-chain.md", "Robinhood Chain scope", "The lending engine underneath: real Stock Tokens, Chainlink feeds, and what the chain does and doesn't give us."],
  ["PROTOCOL", "The engine", "LTV-RISK-FRAMEWORK.md", "LTV & risk framework", "How loan-to-value limits are chosen per asset from a stress model."],
  ["PROTOCOL", "The engine", "INTEREST-RATE-MODEL.md", "Interest rate model", "How supply/borrow rates are set by utilization to attract liquidity."],
  ["PROTOCOL", "Essey Private", "ESSEY-PRIVATE.md", "Essey Private — the privacy layer", "Stealth-address payments, a shielded pool that hides amounts, private transfers with cross-device recovery, a trustless relayer, and private yield-bearing lending supply. What each does, plainly, with the honest limits and what's still ahead."],
  ["PROTOCOL", "Known-open", "OUTSTANDING.md", "Known-open items", "Everything we know is unfinished on the protocol, including what blocks mainnet. Published deliberately."],
  ["PROTOCOL", "Protocol audits", "audits/README.md", "How we audit", "Independent agents attack every change; findings are published fix-first, clean or not."],
  ["PROTOCOL", "Protocol audits", "audits/esseyreservehook-gate-2026-08-31.md", "$ESSEY launch hook — audit gate", "The three-bucket fee hook (reserve/holders/dons) and the single-sided launch seeder: three consecutive clean rounds across all three lenses, one test-integrity finding fixed, invariants pinned by mutation-verified tests, deploy-config preconditions spelled out."],
  // DONS / THE GAME
  ["DONS", "The game", "GAME-GUIDE.md", "D.O.N. — the full house rules", "The complete rulebook for the city of Solvency: the Ledger's three clauses, every mission brief with its published odds ladder, robberies and the cap stack, Hitters and the Favor, the House ladder, and everything stamped as arriving with a later posting. Every number is the number on the chain."],
  ["DONS", "Dons tokenomics", "TOKENOMICS-v3.md", "Tokenomics — the Dons", "8,888 Dons: a seat, a floor, and a margin account in one NFT. Fixed-supply $ESSEY, the 300,030 floor that only rises, the five-rung tier ladder, exchange fees that buy stock for holders, and $ESSEY loans with provable solvency — every number reconciled to the deployed contracts."],
  ["DONS", "Game known-open", "GAME-OUTSTANDING.md", "Game known-open items", "Everything unfinished on the D.O.N. game / market layer — the Bell, Cases, Degen, Quests, and the converters that feed stock payouts — split out of the protocol list so each stays honest about its own chain and gates."],
  ["DONS", "Game-era contracts", "audits/market-layer-round-1.md", "Market layer — round 1", "Seats, Vaults, the Bell, the converter, Notes: the first adversarial gate on the game's contracts."],
  ["DONS", "Game-era contracts", "audits/market-layer-round-2.md", "Market layer — round 2", "$ESSEY and the Exchange: one hardening applied, re-audit clean."],
  ["DONS", "Game-era contracts", "audits/market-layer-round-3.md", "Market layer — round 3", "The mint distributor: two hardenings — including a deploy-unfixable defect the gate caught before it could ship."],
  ["DONS", "Game-era contracts", "audits/market-layer-round-4.md", "Market layer — round 4", "The Cases contract under adversarial review — re-audit clean."],
  ["DONS", "Game-era contracts", "audits/market-layer-round-5.md", "Market layer — round 5", "The reserve-routing addition to the lending pool — re-audit clean."],
  ["DONS", "Game-era contracts", "audits/market-layer-round-6.md", "Market layer — round 6", "The on-chain Seat art renderer — re-audit clean."],
];

// Founder rule (2026-08, strengthened): the site presents our design and tokenomics ON THEIR OWN
// MERITS — no competitor names AND no borrowed-provenance framing ("modeled on", "the reference
// protocol"). Internal modeling docs stay in the repo for engineering; the site renders standalone
// public docs instead, and the sanitizer + gate below are the backstop, not the plan.
const sanitize = (md) => md
  .replace(/stonkbrokers\.cash/gi, "the reference protocol's site")
  .replace(/Stonk\s?Brokers?'s/gi, "the reference protocol's")
  .replace(/Stonk\s?Brokers?'/gi, "the reference protocol's")
  .replace(/Stonk\s?Brokers?/gi, "the reference protocol")
  .replace(/Stonk(?=[A-Z])/g, "Ref") // their contract identifiers: StonkLoanVault -> RefLoanVault
  .replace(/(^|[.!?]\s+)the reference protocol/g, "$1The reference protocol"); // sentence starts

const slugOf = (file) => file.replace(/\.md$/, "").toLowerCase().replace(/\//g, "-");
const SLUGS = new Map(PICK.map(([, , file]) => [file, slugOf(file)]));

// Docs cross-reference each other with relative links (`market-layer-round-1.md`) so they render
// natively on GitHub — but the site's reader serves them under /docs/:slug, where a relative href
// resolves to a dead /docs/<file>.md. Rewrite at generation time: picked docs become in-site
// /docs/:slug links; anything else in the repo becomes a GitHub source link on the built branch.
const brokenRel = [];
const relink = (md, file) =>
  md.replace(/\]\((?!(?:https?:)?\/|#|mailto:)([^)#\s]+\.md)(#[^)]*)?\)/g, (whole, target, hash = "") => {
    const resolved = posix.normalize(posix.join(posix.dirname(file), target));
    if (resolved.startsWith("..")) return whole; // escapes /docs — leave untouched
    if (!existsSync(join(DOCS, resolved))) { brokenRel.push(`${file} -> ${target}`); return whole; }
    return SLUGS.has(resolved) ? `](/docs/${SLUGS.get(resolved)})` : `](${REPO_DOCS}${resolved}${hash})`;
  });

const missing = [];
const docs = PICK.map(([section, group, file, title, desc]) => {
  let md = "";
  try { md = relink(sanitize(readFileSync(join(DOCS, file), "utf8")), file); } catch { missing.push(file); md = `# ${title}\n\n_(document unavailable)_`; }
  const slug = slugOf(file);
  return { slug, section, group, file, title, desc, md };
});
// The rule is a hard gate, not a best effort: fail the build if any reference survives.
const leak = docs.filter((d) => /stonk|reference protocol/i.test(d.md));
if (leak.length) { console.error(`gen-docs: competitor reference leaked in ${leak.map((d) => d.file).join(", ")}`); process.exit(1); }
// A doc that silently renders as "(document unavailable)" is worse than a failed build — it ships
// a dead card to visitors. Fail loudly instead. Same for a cross-reference to a doc that isn't in
// the repo: that's a dead link on the page, not a best effort.
if (missing.length) { console.error(`gen-docs: MISSING ${missing.join(", ")}`); process.exit(1); }
if (brokenRel.length) { console.error(`gen-docs: DEAD relative link(s): ${brokenRel.join("; ")}`); process.exit(1); }

const out = `// GENERATED by gen-docs.mjs — do not edit by hand.
export interface Doc { slug: string; section: string; group: string; file: string; title: string; desc: string; md: string }
// The git ref this build rendered — GitHub "source" links must use it, or docs that haven't merged
// to main yet 404. Flips back to "main" automatically once the branch merges and main is built.
export const DOCS_BRANCH = ${JSON.stringify(BRANCH)};
export const DOCS: Doc[] = ${JSON.stringify(docs, null, 0)};
`;
writeFileSync(join(HERE, "src", "docs.generated.ts"), out);
console.log(`generated src/docs.generated.ts — ${docs.length} docs (branch: ${BRANCH})`);
