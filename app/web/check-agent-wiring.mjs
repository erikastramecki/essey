// Accountability layer for the agent knowledge base (Erik, 2026-09-05).
//
// The read/write instructions in a charter are prose, and prose is what gets skipped. This fails the
// build when the wiring has drifted. It checks the wiring, which is falsifiable — not whether an
// agent thought about a lesson, which is not.
import { readFileSync, readdirSync, existsSync } from "node:fs";
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

const roster = existsSync(AGENTS)
  ? readdirSync(AGENTS).filter((f) => f.endsWith(".md") && owned(f))
  : [];
if (!roster.length)
  problems.push(
    "No essey/don/jester agent charters found — cannot verify wiring.",
  );

for (const f of roster) {
  const name = f.replace(/\.md$/, "");
  const text = readFileSync(join(AGENTS, f), "utf8");
  if (!text.includes(MARK))
    problems.push(
      `${name}: charter is not wired to the knowledge base (missing the read/write block).`,
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

console.log(
  `agent-wiring: ${roster.length} charter(s), ${problems.length} problem(s)`,
);
if (!problems.length) process.exit(0);
console.error("\nagent-wiring: FAIL — the knowledge base has drifted.");
for (const p of problems) console.error(`  ${p}`);
console.error("");
process.exit(1);
