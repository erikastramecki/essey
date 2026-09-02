// Bake per-post social meta into static HTML so shared blog links unfurl. This is a POST-build step:
// the site is a client-routed SPA, so every /blog/:slug is served the same dist/index.html, and its
// title/description are set in a useEffect that crawlers (Twitterbot, facebookexternalhit, Slackbot,
// Discordbot, LinkedInBot) never run. Fix: emit dist/blog/<slug>/index.html per published post with
// the post's OG/Twitter/canonical tags in the served <head>. Vercel's filesystem match beats the SPA
// rewrite, so a crawler reads the file's meta while a human still boots the React bundle and routes.
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const DIST = join(HERE, "dist");
const POSTS_DIR = join(HERE, "src", "blog", "posts");
const SHELL = join(DIST, "index.html");

// One place to change the origin. Absolute URLs are non-negotiable: a relative og:image or og:url
// does not unfurl. Flagged to the founder — swap if the blog ever moves off the apex domain.
const SITE = (process.env.VITE_SITE_URL || "https://essey.xyz").replace(/\/$/, "");
const OG_IMAGE_DEFAULT = `${SITE}/og-default.png`;
const PUBLIC_OG = join(HERE, "public", "og");

const die = (msg) => { console.error(`prerender-blog: ${msg}`); process.exit(1); };

const esc = (s) => String(s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

// Same front-matter shape the app's blog.ts parses (title/date/slug/summary, optional image/draft);
// kept in lockstep because both read src/blog/posts/*.md. Node reads with fs; the app uses Vite glob.
function parse(raw, file) {
  const fence = /^---\n([\s\S]*?)\n---\n?/.exec(raw);
  const meta = {};
  if (fence) for (const line of fence[1].split("\n")) {
    const kv = /^(\w+):\s*(.*)$/.exec(line);
    if (kv) meta[kv[1]] = kv[2].trim().replace(/^["']|["']$/g, "");
  }
  const fileSlug = file.replace(/\.md$/, "");
  // title/summary are NOT defaulted — a published post missing either fails the build below, rather
  // than silently shipping a filename-as-title or an empty description. slug still falls back (legit).
  return {
    file,
    title: meta.title ?? "",
    date: meta.date ?? "",
    slug: meta.slug ?? fileSlug,
    summary: meta.summary ?? "",
    image: meta.image ?? "",
    draft: meta.draft === "true",
  };
}

// Absolute image URL: an explicit per-post `image:` front-matter (root-relative or absolute) wins;
// else the post's auto-generated card (gen-og-image.mjs writes public/og/<slug>.png before the build);
// else the branded default. Relative paths don't unfurl, so always resolve against the origin.
const imageFor = (post) => {
  if (post.image) {
    if (/^https?:\/\//.test(post.image)) return post.image;
    return `${SITE}/${post.image.replace(/^\//, "")}`;
  }
  if (existsSync(join(PUBLIC_OG, `${post.slug}.png`))) return `${SITE}/og/${post.slug}.png`;
  return OG_IMAGE_DEFAULT;
};

function metaBlock({ type, title, description, url, image }) {
  const t = esc(title), d = esc(description);
  return [
    `<meta property="og:type" content="${type}" />`,
    `<meta property="og:site_name" content="Essey" />`,
    `<meta property="og:title" content="${t}" />`,
    `<meta property="og:description" content="${d}" />`,
    `<meta property="og:url" content="${esc(url)}" />`,
    `<meta property="og:image" content="${esc(image)}" />`,
    `<meta name="twitter:card" content="summary_large_image" />`,
    `<meta name="twitter:site" content="@EsseyMarkets" />`,
    `<meta name="twitter:title" content="${t}" />`,
    `<meta name="twitter:description" content="${d}" />`,
    `<meta name="twitter:image" content="${esc(image)}" />`,
    `<link rel="canonical" href="${esc(url)}" />`,
  ].join("\n    ");
}

// Rewrite the shell's <head> for one page: swap the marker block, and the <title> + description so a
// crawler reading only the plain title still gets the page's, not the site default. Each replace is
// asserted — a silent no-op would ship the wrong card and look fine in the build log.
function renderPage(shell, { title, description, block }) {
  const OG = /<!-- OG:START[\s\S]*?<!-- OG:END -->/;
  if (!OG.test(shell)) die("OG marker block not found in dist/index.html — did index.html lose the <!-- OG:START --> markers?");
  let html = shell.replace(OG, `<!-- OG:START -->\n    ${block}\n    <!-- OG:END -->`);
  const withTitle = html.replace(/<title>[\s\S]*?<\/title>/, `<title>${esc(title)}</title>`);
  if (withTitle === html) die("could not replace <title>");
  html = withTitle;
  const withDesc = html.replace(/<meta name="description" content="[\s\S]*?" \/>/, `<meta name="description" content="${esc(description)}" />`);
  if (withDesc === html) die("could not replace description meta");
  return withDesc;
}

function write(relDir, html) {
  const dir = join(DIST, relDir);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "index.html"), html);
}

if (!existsSync(SHELL)) die("dist/index.html missing — run `vite build` first");
if (!existsSync(POSTS_DIR)) die("src/blog/posts missing");
const shell = readFileSync(SHELL, "utf8");

const posts = readdirSync(POSTS_DIR)
  .filter((f) => f.endsWith(".md"))
  .map((f) => parse(readFileSync(join(POSTS_DIR, f), "utf8"), f))
  .filter((p) => !p.draft);

// A published post ships a social card, so its ingredients are mandatory (drafts are exempt — they are
// filtered out above). Fail loud and name the file, rather than unfurling a blank title/description.
for (const p of posts) {
  if (!p.title) die(`${p.file}: published post is missing required front-matter \`title\``);
  if (!p.summary) die(`${p.file}: published post is missing required front-matter \`summary\``);
  if (!existsSync(join(PUBLIC_OG, `${p.slug}.png`))) die(`${p.file}: social card public/og/${p.slug}.png missing — gen-og-image.mjs must run before the build`);
}

// The /blog index gets its own card. Copy is the blog's own standing description (blog.tsx band-head).
const INDEX_TITLE = "Blog · Essey";
const INDEX_DESC = "Building Essey in the open — the mechanics, the reasoning, and the on-chain facts behind each change. Every mechanical claim is true to the deployed contracts.";
write("blog", renderPage(shell, {
  title: INDEX_TITLE,
  description: INDEX_DESC,
  block: metaBlock({ type: "website", title: "Building Essey in the open", description: INDEX_DESC, url: `${SITE}/blog`, image: OG_IMAGE_DEFAULT }),
}));

for (const p of posts) {
  const url = `${SITE}/blog/${p.slug}`;
  const description = p.summary || INDEX_DESC;
  write(join("blog", p.slug), renderPage(shell, {
    title: `${p.title} · Essey`,
    description,
    block: metaBlock({ type: "article", title: p.title, description, url, image: imageFor(p) }),
  }));
}

console.log(`prerender-blog: wrote /blog + ${posts.length} post page(s) [${posts.map((p) => p.slug).join(", ")}] at ${SITE}`);
