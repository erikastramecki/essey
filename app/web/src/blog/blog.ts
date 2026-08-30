// The scribe drops markdown files into ./posts; this module is the whole content pipeline — no CMS,
// no fetch, no runtime deps. Vite inlines every post at build time, so the index and each entry are
// static and the front-matter is the only source of a post's title/date/slug/summary.
//
// DRAFTS: unpublished posts live in ../drafts (NOT globbed here), so an unfinished entry can never
// reach the index by accident. A `draft: true` front-matter flag is honored too, as a second guard
// for a post kept in ./posts while it awaits the founder's sign-off.
export type PostMeta = {
  title: string;
  date: string;
  slug: string;
  summary: string;
};
export type Post = PostMeta & { body: string };

const FILES = import.meta.glob("./posts/*.md", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

function parse(raw: string, path: string): Post & { draft: boolean } {
  const fence = /^---\n([\s\S]*?)\n---\n?/.exec(raw);
  const meta: Record<string, string> = {};
  let body = raw;
  if (fence) {
    body = raw.slice(fence[0].length);
    for (const line of fence[1].split("\n")) {
      const kv = /^(\w+):\s*(.*)$/.exec(line);
      if (kv) meta[kv[1]] = kv[2].trim().replace(/^["']|["']$/g, "");
    }
  }
  const fileSlug = path.split("/").pop()!.replace(/\.md$/, "");
  return {
    title: meta.title ?? fileSlug,
    date: meta.date ?? "",
    slug: meta.slug ?? fileSlug,
    summary: meta.summary ?? "",
    draft: meta.draft === "true",
    body: body.trim(),
  };
}

export const POSTS: Post[] = Object.entries(FILES)
  .map(([path, raw]) => parse(raw, path))
  .filter((p) => !p.draft)
  .sort((a, b) => (a.date < b.date ? 1 : -1));

export const getPost = (slug: string): Post | undefined =>
  POSTS.find((p) => p.slug === slug);
