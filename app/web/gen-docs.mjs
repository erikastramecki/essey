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
// off the page. The audit trail is the exception: every published round stays, clean or not, because
// fix-first transparency transcends any single narrative.
// `file` is relative to /docs and doubles as the GitHub source link, so every card in the site can
// point at the exact file it renders — no separately-maintained list to drift out of sync.
const PICK = [
  ["The game", "GAME-GUIDE.md", "D.O.N. — the full house rules", "The complete rulebook for the city of Solvency: the Ledger's three clauses, every mission brief with its published odds ladder, robberies and the cap stack, Hitters and the Favor, the House ladder, and everything stamped as arriving with a later posting. Every number is the number on the chain."],
  ["The Market", "TOKENOMICS-v3.md", "Tokenomics — the Dons", "8,888 Dons: a seat, a floor, and a margin account in one NFT. Fixed-supply $ESSEY, the 300,030 floor that only rises, the five-rung tier ladder, exchange fees that buy stock for holders, and $ESSEY loans with provable solvency — every number reconciled to the deployed contracts."],
  ["Essey Private", "ESSEY-PRIVATE.md", "Essey Private — the privacy layer", "Stealth-address payments, a shielded pool that hides amounts, private transfers with cross-device recovery, a trustless relayer, and private yield-bearing lending supply. What each does, plainly, with the honest limits and what's still ahead."],
  ["The engine", "SCOPE-robinhood-chain.md", "Robinhood Chain scope", "The lending engine underneath: real Stock Tokens, Chainlink feeds, and what the chain does and doesn't give us."],
  ["The engine", "LTV-RISK-FRAMEWORK.md", "LTV & risk framework", "How loan-to-value limits are chosen per asset from a stress model."],
  ["The engine", "INTEREST-RATE-MODEL.md", "Interest rate model", "How supply/borrow rates are set by utilization to attract liquidity."],
  ["The engine", "OUTSTANDING.md", "Known-open items", "Everything we know is unfinished, including what blocks mainnet. Published deliberately."],
  ["Audits", "audits/README.md", "How we audit", "Independent agents attack every change; findings are published fix-first, clean or not."],
  ["Audits", "audits/market-layer-round-1.md", "Market layer — round 1", "Seats, Vaults, the Bell, the converter, Notes: the first adversarial gate on the game's contracts."],
  ["Audits", "audits/market-layer-round-2.md", "Market layer — round 2", "$ESSEY and the Exchange: one hardening applied, re-audit clean."],
  ["Audits", "audits/market-layer-round-3.md", "Market layer — round 3", "The mint distributor: two hardenings — including a deploy-unfixable defect the gate caught before it could ship."],
  ["Audits", "audits/sui-rounds-1-6.md", "Move / Sui — rounds 1–6", "66 confirmed findings across six adversarial rounds on an earlier iteration. No round came back clean."],
  ["Audits", "audits/solidity-round-1.md", "Solidity — round 1", "19 confirmed, 5 refuted against the lending engine. Not clean."],
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
const SLUGS = new Map(PICK.map(([, file]) => [file, slugOf(file)]));

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
const docs = PICK.map(([group, file, title, desc]) => {
  let md = "";
  try { md = relink(sanitize(readFileSync(join(DOCS, file), "utf8")), file); } catch { missing.push(file); md = `# ${title}\n\n_(document unavailable)_`; }
  const slug = slugOf(file);
  return { slug, group, file, title, desc, md };
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
export interface Doc { slug: string; group: string; file: string; title: string; desc: string; md: string }
// The git ref this build rendered — GitHub "source" links must use it, or docs that haven't merged
// to main yet 404. Flips back to "main" automatically once the branch merges and main is built.
export const DOCS_BRANCH = ${JSON.stringify(BRANCH)};
export const DOCS: Doc[] = ${JSON.stringify(docs, null, 0)};
`;
writeFileSync(join(HERE, "src", "docs.generated.ts"), out);
console.log(`generated src/docs.generated.ts — ${docs.length} docs (branch: ${BRANCH})`);
