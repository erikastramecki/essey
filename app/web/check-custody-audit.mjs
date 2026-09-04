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

// The first version of this gate asked only whether the contract's NAME appeared in the status file.
// That proves the question was asked, never that it was answered — a stale "UNAUDITED, accepted by
// nobody yet" line held the build green for a full day after round 1 came back clean. So the section
// must now carry a verdict word, and UNAUDITED alone is not one.
const VERDICT = /\b(CLEAN|ACCEPTED-RISK)\b/;

const sectionFor = (name, doc) => {
  const heads = [...doc.matchAll(/^##\s+(.+)$/gm)];
  for (let i = 0; i < heads.length; i++) {
    if (!new RegExp(`\\b${name}\\b(?!Hook)`).test(heads[i][1])) continue;
    const from = heads[i].index;
    const to = i + 1 < heads.length ? heads[i + 1].index : doc.length;
    return doc.slice(from, to);
  }
  return "";
};

const status = existsSync(STATUS) ? readFileSync(STATUS, "utf8") : "";
const corpus = auditNames();
const problems = [];

for (const c of CUSTODY) {
  const section = sectionFor(c.name, status);
  if (!section) {
    problems.push(
      `${c.name} takes custody and has no "## ${c.name}" section in docs/CUSTODY-AUDIT-STATUS.md.`,
    );
    continue;
  }
  if (!VERDICT.test(section)) {
    problems.push(
      `${c.name}'s section states no verdict. It must say CLEAN (an audit reached that conclusion) or ` +
        `ACCEPTED-RISK (someone decided, with a date, to carry it anyway). "UNAUDITED" on its own is ` +
        `the question, not the answer, and it must not hold the build green.`,
    );
  }
  if (!isAudited(c.name, corpus) && !/\bACCEPTED-RISK\b/.test(section)) {
    problems.push(
      `${c.name} has NO audit document naming it, so its section must carry an explicit dated ACCEPTED-RISK.`,
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
