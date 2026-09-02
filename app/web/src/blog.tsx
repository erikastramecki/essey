import { useEffect, useRef } from "react";
import { Link, useParams } from "react-router-dom";
import { marked } from "marked";
import DOMPurify from "dompurify";
import { getPost, POSTS, type Post } from "./blog/blog";

const WIDGETS_SRC = "https://platform.x.com/widgets.js";
const WIDGETS_ID = "twitter-wjs";

type Twttr = { widgets?: { load: (el?: HTMLElement) => void } };
declare global {
  interface Window {
    twttr?: Twttr;
  }
}

/// widgets.js is injected ONLY here, never in index.html — so a reader downloads X's script only on a
/// post that carries a `tweet:`. Injected once and reused across posts (guarded on window.twttr). On a
/// client-side route change X does NOT auto-scan the new blockquote, so callers run widgets.load()
/// themselves after mount; this just resolves the shared script, loaded or freshly injected.
function whenWidgetsReady(done: (t: Twttr) => void) {
  if (window.twttr?.widgets) return void done(window.twttr);
  const ready = () => window.twttr?.widgets && done(window.twttr);
  let s = document.getElementById(WIDGETS_ID) as HTMLScriptElement | null;
  if (!s) {
    s = document.createElement("script");
    s.id = WIDGETS_ID;
    s.src = WIDGETS_SRC;
    s.async = true;
    document.body.appendChild(s);
  }
  s.addEventListener("load", ready, { once: true });
}

/// Theme is read once at mount from the same attribute styles.css keys off; re-theming on a live toggle
/// is deliberately skipped — X has already swapped the blockquote for an iframe, and forcing a remount
/// fights that DOM mutation. The blockquote degrades to a plain linked quote if the script never loads.
function TweetEmbed({ url }: { url: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const theme =
    document.documentElement.dataset.theme === "light" ? "light" : "dark";
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let cancelled = false;
    whenWidgetsReady((t) => {
      if (!cancelled) t.widgets?.load(el);
    });
    return () => {
      cancelled = true;
    };
  }, [url]);
  return (
    <div className="bl-x" ref={ref}>
      <span className="eyebrow">On X</span>
      <blockquote className="twitter-tweet" data-theme={theme}>
        <a href={url}>{url}</a>
      </blockquote>
    </div>
  );
}

/// Front-matter dates are plain YYYY-MM-DD; render them at UTC so the day never shifts by timezone.
function fmtDate(d: string): string {
  if (!d) return "";
  const t = new Date(`${d}T00:00:00Z`);
  return Number.isNaN(t.getTime())
    ? d
    : t.toLocaleDateString("en-US", {
        year: "numeric",
        month: "long",
        day: "numeric",
        timeZone: "UTC",
      });
}

/// Compact rail date for the timeline ("Aug 29"). Year lives in the group header, so the row stays lean.
function fmtShort(d: string): string {
  if (!d) return "—";
  const t = new Date(`${d}T00:00:00Z`);
  return Number.isNaN(t.getTime())
    ? d
    : t.toLocaleDateString("en-US", {
        month: "short",
        day: "numeric",
        timeZone: "UTC",
      });
}

/// Group posts by year, preserving POSTS' newest-first order so both the years and the entries within
/// each year read most-recent-first. Undated posts (drafts promoted without a date) sort last.
function byYear(posts: Post[]): [string, Post[]][] {
  const groups = new Map<string, Post[]>();
  for (const p of posts) {
    const y = p.date ? p.date.slice(0, 4) : "Undated";
    if (!groups.has(y)) groups.set(y, []);
    groups.get(y)!.push(p);
  }
  return [...groups.entries()];
}

export function BlogIndex() {
  useEffect(() => {
    document.title = "Blog · Essey";
  }, []);
  return (
    <section className="band">
      <div className="wrap">
        <div className="band-head">
          <div>
            <span className="eyebrow">Blog</span>
            <h2>Building Essey in the open</h2>
            <p>
              A running log of what we ship — the mechanics, the reasoning, and
              the on-chain facts behind each change. Every mechanical claim is
              true to the deployed contracts.
            </p>
          </div>
        </div>

        {POSTS.length === 0 ? (
          <div className="hw-card">
            <div className="hw-card-h">No posts yet</div>
            <p>The first entries land here soon.</p>
          </div>
        ) : (
          <div className="bl-time">
            {byYear(POSTS).map(([year, posts]) => (
              <div className="bl-year" key={year}>
                <div className="bl-year-h">{year}</div>
                {posts.map((p) => (
                  <Link
                    key={p.slug}
                    to={`/blog/${p.slug}`}
                    className="bl-entry"
                  >
                    <span className="bl-date">{fmtShort(p.date)}</span>
                    <span className="bl-body">
                      <span className="bl-title">
                        {p.title}
                        {p.slug === POSTS[0].slug && (
                          <span className="bl-latest">Latest</span>
                        )}
                      </span>
                      {p.summary && <span className="bl-sum">{p.summary}</span>}
                      <span className="bl-go">Read →</span>
                    </span>
                  </Link>
                ))}
              </div>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}

export function BlogPost() {
  const { slug } = useParams();
  const post = slug ? getPost(slug) : undefined;

  useEffect(() => {
    document.title = post ? `${post.title} · Essey` : "Blog · Essey";
  }, [post]);

  if (!post) {
    return (
      <section className="band">
        <div className="wrap">
          <div className="hw-card">
            <div className="hw-card-h">Post not found</div>
            <p>
              This entry doesn&apos;t exist.{" "}
              <Link to="/blog">Back to the blog ↗</Link>
            </p>
          </div>
        </div>
      </section>
    );
  }

  // Same renderer the docs reading room uses — marked into sanitized HTML, never raw markup from a post.
  const html = DOMPurify.sanitize(marked.parse(post.body) as string, {
    FORBID_TAGS: ["form", "input", "button", "textarea"],
  });

  return (
    <section className="band">
      <div className="wrap">
        <div className="band-head">
          <div>
            <span className="eyebrow">
              <Link to="/blog">Blog</Link>
            </span>
            <h2>{post.title}</h2>
            {post.date && <p>{fmtDate(post.date)}</p>}
          </div>
        </div>

        <div className="hw-card" style={{ padding: 0 }}>
          <div className="doc-md" dangerouslySetInnerHTML={{ __html: html }} />
        </div>

        {post.tweet && <TweetEmbed url={post.tweet} />}
      </div>
    </section>
  );
}
