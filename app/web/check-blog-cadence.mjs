// Reports the gap between what we have SHIPPED and what we have PUBLISHED.
//
// Erik, 2026-09-03: "I haven't seen any post published in forever... How do I actually make sure
// you're on top of this?" The blog stopped because the Jester's publish authority expired, publishing
// reverted to needing his sign-off, sign-off needed somebody to ASK him, and nobody did. It failed
// silently. Nothing was watching the thing that was supposed to watch it.
//
// The signal is the GAP, not the calendar — the Jester's own point, and it is right. "Days since the
// last post" would manufacture filler on a quiet week; log-ahead-of-blog is the literal definition of
// a backlog and is silent when there genuinely is not one.
//
// Read-only by design: it must not write during a build, or it would dirty the tree and trip the
// clean-tree deploy gate. Run it any time: `node app/web/check-blog-cadence.mjs`.
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..", "..");
const LOG = join(REPO, "docs", "JESTER-BUILD-LOG.md");
const POSTS = join(HERE, "src", "blog", "posts");

const STALE_DAYS = 7; // loud backstop only — the daily check is the real mechanism
const DAY = 86_400_000;

const newestDateIn = (text) => {
  const found = [...text.matchAll(/\b(20\d{2}-\d{2}-\d{2})\b/g)].map((m) => m[1]);
  return found.length ? found.sort().at(-1) : null;
};

const newestPost = () => {
  if (!existsSync(POSTS)) return { date: null, slug: null };
  let best = { date: null, slug: null };
  for (const f of readdirSync(POSTS).filter((f) => f.endsWith(".md"))) {
    const m = readFileSync(join(POSTS, f), "utf8").match(/^date:\s*(\S+)/m);
    if (!m) continue;
    const d = m[1].slice(0, 10);
    if (!best.date || d > best.date) best = { date: d, slug: f.replace(/\.md$/, "") };
  }
  return best;
};

const logDate = existsSync(LOG) ? newestDateIn(readFileSync(LOG, "utf8")) : null;
const post = newestPost();

if (!logDate || !post.date) {
  console.log("blog-cadence: SKIP (no build log or no dated posts)");
  process.exit(0);
}

const gapDays = Math.round((Date.parse(logDate) - Date.parse(post.date)) / DAY);

if (gapDays <= 0) {
  console.log(`blog-cadence: current (newest post ${post.date} "${post.slug}", log ${logDate})`);
  process.exit(0);
}

console.log(
  `blog-cadence: BACKLOG — shipped work logged through ${logDate}, newest post is ${post.date} ` +
    `("${post.slug}"), a gap of ${gapDays} day(s).`,
);
console.log(
  "  The Jester holds standing publish authority (persona bible §33). Read docs/JESTER-BUILD-LOG.md " +
    "for the unpublished material and draft from it — do not wait to be asked.",
);

if (gapDays > STALE_DAYS) {
  console.error(
    `\nblog-cadence: FAIL — the gap is ${gapDays} days, past the ${STALE_DAYS}-day backstop.\n` +
      "  This fires only when the daily check has itself stopped running, which is the failure this\n" +
      "  file exists to catch. Publish, or record why not.\n",
  );
  process.exit(1);
}
