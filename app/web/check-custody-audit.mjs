// Build gate: never publish an address that takes custody of real value without an explicit,
// dated audit status. Erik, 2026-09-02: "There should have been a rule where you caught that the
// reserve was unaudited prior to me sending stock and tokens there."
//
// He was right, and the rule existed only as intent. EsseyReserve went live on mainnet, was
// published on /treasury as the deposit target, and took real stock — and no audit document names
// it. A grep for "EsseyReserve" even reads as covered, because it is a substring of
// "EsseyReserveHook", which IS audited. That near-miss is why this file matches on word boundaries.
//
// This fails the build, so the status is re-affirmed every deploy instead of being remembered.
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..", "..");
const STATUS = join(REPO, "docs", "CUSTODY-AUDIT-STATUS.md");
const AUDITS = join(REPO, "docs", "audits");

const die = (...lines) => {
  console.error("\ncustody-audit gate: FAIL");
  for (const l of lines) console.error("  " + l);
  console.error("");
  process.exit(1);
};

// Contracts that hold, or will hold, someone's value. Name -> the address the site publishes.
const CUSTODY = [
  { name: "EsseyReserve", src: "src/reserve.ts", key: "reserve" },
  { name: "Essey", src: "src/reserve.ts", key: "essey" },
];

const auditNames = () => {
  if (!existsSync(AUDITS)) return "";
  return readdirSync(AUDITS)
    .filter((f) => f.endsWith(".md"))
    .map((f) => readFileSync(join(AUDITS, f), "utf8"))
    .join("\n");
};

// \b so "EsseyReserve" never matches inside "EsseyReserveHook" — the exact false positive that made
// an unaudited contract look covered.
const isAudited = (name, corpus) =>
  new RegExp(`\\b${name}\\b(?!Hook)`).test(corpus);

const status = existsSync(STATUS) ? readFileSync(STATUS, "utf8") : "";
const corpus = auditNames();
const problems = [];

for (const c of CUSTODY) {
  const audited = isAudited(c.name, corpus);
  const acked = new RegExp(`\\b${c.name}\\b`).test(status);
  if (!audited && !acked) {
    problems.push(
      `${c.name} takes custody, has NO audit document naming it, and is not acknowledged in docs/CUSTODY-AUDIT-STATUS.md.`,
    );
  }
}

if (problems.length) {
  die(
    ...problems,
    "",
    "Either land an audit that names the contract, or record the accepted risk with a date",
    `in ${STATUS} — the point is that it is a decision someone made, not something forgotten.`,
  );
}

console.log(
  `custody-audit gate: PASS (${CUSTODY.length} custody contracts accounted for)`,
);
