// Accountability layer for the agent knowledge base (Erik, 2026-09-05).
//
// The read/write instructions in a charter are prose, and prose is what gets skipped. This fails the
// build when the wiring has drifted. It checks the wiring, which is falsifiable — not whether an
// agent thought about a lesson, which is not.
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, existsSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..", "..");
const AGENTS = join(homedir(), ".claude", "agents");
const CONT = join(REPO, "docs", "agents", "continuity");
const LESSONS = join(REPO, "docs", "agents", "LESSONS.md");
const MARK = "## Your knowledge base — read at start, write at finish";

const problems = [];
const owned = (f) => /^(essey-|don-)/.test(f) || f === "jester.md";

if (!existsSync(LESSONS))
  problems.push(
    "docs/agents/LESSONS.md is missing — the shared surface is gone.",
  );
else {
  const blocks = readFileSync(LESSONS, "utf8").split("\n### ").slice(1);
  for (const b of blocks) {
    const title = b.split("\n")[0].trim();
    if (!/^\*\*Applies to:\*\*\s*\S/m.test(b))
      problems.push(
        `LESSONS.md "${title}" has no **Applies to:** line — it routes to nobody and nobody will read it.`,
      );
    if (!/^\*\*Apply:\*\*/m.test(b))
      problems.push(
        `LESSONS.md "${title}" records a trap but no **Apply:** — a story, not a lesson.`,
      );
  }
}

const report = () => {
  console.error("\nagent-wiring: FAIL — the knowledge base has drifted.");
  for (const p of problems) console.error(`  ${p}`);
  console.error("");
};

const hasCharters = existsSync(AGENTS);
if (!hasCharters)
  console.log(
    "agent-wiring: charter checks SKIPPED (no charter dir here); repo checks still enforced.",
  );

const roster = hasCharters
  ? readdirSync(AGENTS).filter((f) => f.endsWith(".md") && owned(f))
  : [];
if (hasCharters && !roster.length)
  problems.push("Charter directory exists but holds no charters.");

for (const f of roster) {
  const name = f.replace(/\.md$/, "");
  const text = readFileSync(join(AGENTS, f), "utf8");
  if (!text.includes(MARK))
    problems.push(
      `${name}: charter is not wired to the knowledge base (missing the read/write block).`,
    );
  // Hardcoded per charter, not left to the routed lessons an agent must remember to read.
  if (
    !text.includes(
      "THE HARD RULE — never cite a gate you have not watched fail",
    )
  )
    problems.push(
      `${name}: charter is missing THE HARD RULE (never cite a gate you have not watched fail).`,
    );
  if (!text.includes(`cat ~/.claude/agents/${name}.md`))
    problems.push(
      `${name}: charter does not tell it to re-read its own charter FROM DISK first.`,
    );
  if (!text.includes(`tools/lessons.py --role ${name}`))
    problems.push(
      `${name}: charter does not tell it to read ITS OWN lessons slice.`,
    );
  if (!existsSync(join(CONT, `${name}.md`)))
    problems.push(
      `${name}: has no continuity file at docs/agents/continuity/${name}.md.`,
    );
}

// The blueprint must never describe a structure that no longer exists. It is deliberately NOT
// auto-updated: silently regenerating the stamp would let the prose rot while the gate stayed green.
// Drift fails the build and names what moved; whoever reconciles the prose re-stamps on purpose.
const FOUNDATION = join(REPO, "docs", "AGENT-COMPANY-FOUNDATION.md");
const MECHANISMS = [
  "tools/lessons.py",
  "tools/runlock.py",
  "tools/broadcast.py",
  "app/web/check-agent-wiring.mjs",
  "docs/agents/LESSONS.md",
  "docs/agents/BROADCASTS.md",
  "docs/AGENT-HIERARCHY.md",
];

const fingerprint = () => {
  const lessons = existsSync(LESSONS)
    ? readFileSync(LESSONS, "utf8")
        .split("\n### ")
        .slice(1)
        .map((b) => {
          const id = b.split(/[\s\u2014]/)[0].trim();
          const m = b.match(/^\*\*Applies to:\*\*\s*(.+)$/m);
          return `${id}:${(m ? m[1] : "")
            .split(",")
            .map((r) => r.trim())
            .sort()
            .join("|")}`;
        })
        .sort()
    : [];
  // Bodies too: an id-and-tags fingerprint let a rewritten lesson through.
  const bodies = existsSync(LESSONS)
    ? createHash("sha256")
        .update(readFileSync(LESSONS, "utf8").replace(/\s+/g, " ").trim())
        .digest("hex")
        .slice(0, 12)
    : "none";
  const mech = MECHANISMS.filter((f) => existsSync(join(REPO, f))).sort();
  const names = roster.map((f) => f.replace(/\.md$/, "")).sort();
  return `roster=${names.join(",")};lessons=${lessons.join(",")};bodies=${bodies};mech=${mech.join(",")}`;
};

const hash = createHash("sha256")
  .update(fingerprint())
  .digest("hex")
  .slice(0, 16);

if (process.argv.includes("--stamp")) {
  const t = readFileSync(FOUNDATION, "utf8")
    .replace(/<!-- STRUCTURE-FINGERPRINT:[^>]*-->/, "")
    .trimEnd();
  writeFileSync(
    FOUNDATION,
    `${t}\n\n<!-- STRUCTURE-FINGERPRINT: ${hash} -->\n`,
  );
  console.log(
    `agent-wiring: stamped ${hash}. Confirm the prose actually describes this structure.`,
  );
  process.exit(0);
}

if (!hasCharters) {
  if (problems.length) {
    report();
  }
  process.exit(problems.length ? 1 : 0);
}

if (!existsSync(FOUNDATION))
  problems.push(
    "docs/AGENT-COMPANY-FOUNDATION.md is missing — the portable blueprint is gone.",
  );
else {
  const m = readFileSync(FOUNDATION, "utf8").match(
    /<!-- STRUCTURE-FINGERPRINT:\s*([0-9a-f]+)\s*-->/,
  );
  if (!m)
    problems.push(
      "AGENT-COMPANY-FOUNDATION.md has no structure fingerprint — run --stamp.",
    );
  else if (m[1] !== hash)
    problems.push(
      `AGENT-COMPANY-FOUNDATION.md is STALE: roster, lessons or mechanisms changed since it was last ` +
        `reconciled (stamped ${m[1]}, live ${hash}). Update the prose to match, then re-stamp with --stamp.`,
    );
}

for (const f of roster) {
  const name = f.replace(/\.md$/, "");
  const c = join(CONT, `${name}.md`);
  if (
    existsSync(c) &&
    readFileSync(c, "utf8")
      .split("\n")
      .filter((l) => l.trim()).length <= 4
  )
    console.log(`  note: ${name} has never written to its continuity file.`);
}

console.log(
  `agent-wiring: ${roster.length} charter(s), ${problems.length} problem(s)`,
);
if (!problems.length) process.exit(0);
console.error("\nagent-wiring: FAIL — the knowledge base has drifted.");
for (const p of problems) console.error(`  ${p}`);
console.error("");
process.exit(1);
