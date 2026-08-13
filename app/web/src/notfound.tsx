// 404 — the honest dead-end. The catch-all used to silently render the Landing, which hid every
// stale bookmark and dead link (the /start loop). Now a wrong address says so, and points home.
// Route: * (catch-all).
import { useEffect } from "react";
import { Link } from "react-router-dom";
import { EMonogram } from "./market";

export function NotFoundPage() {
  useEffect(() => { document.title = "404 · Essey"; }, []);
  return (
    <section className="band" id="notfound">
      <div className="wrap" style={{ textAlign: "center", padding: "72px 0 96px" }}>
        <EMonogram size={56} stamped={false} />
        <h2 style={{ marginTop: 18 }}>This page isn't on the books.</h2>
        <p className="lede" style={{ margin: "10px auto 26px", maxWidth: 520 }}>
          The address you followed doesn't exist. It may be left over from an older version of the site.
          Everything that's live is one click away:
        </p>
        <div className="hero-cta" style={{ justifyContent: "center" }}>
          <Link className="btn btn-gold" to="/">Home</Link>
          <Link className="btn btn-ghost" to="/game">The Game</Link>
          <Link className="btn btn-ghost" to="/how-to-play">How to Play</Link>
        </div>
      </div>
    </section>
  );
}
