import { useEffect } from "react";
import { Link, useParams } from "react-router-dom";
import { marked } from "marked";
import DOMPurify from "dompurify";
import { getPost, POSTS } from "./blog/blog";

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
          <div className="dest-grid">
            {POSTS.map((p) => (
              <Link key={p.slug} to={`/blog/${p.slug}`} className="dest-card">
                <b>{p.title}</b>
                <p>
                  {p.date && <b>{fmtDate(p.date)}</b>}
                  {p.date && p.summary && " — "}
                  {p.summary}
                </p>
                <span className="dest-go">Read →</span>
              </Link>
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
      </div>
    </section>
  );
}
