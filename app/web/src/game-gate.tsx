// Preview-only routes (the D.O.N. game wing, Essey Private, the Holder Hub) render this in place of
// their live UI until each ships to mainnet (founder standing rule), so a deep link lands here rather
// than on an action. One component, parametrised per surface — each gate passes its own copy so the
// page says what THIS surface is, not the game's. Layout mirrors NotFoundPage's band so it reads as
// the same site, not a broken page.
import { type ReactNode, useEffect } from "react";
import { Link } from "react-router-dom";
import { EMonogram } from "./market";

type ComingSoonProps = { eyebrow: string; title: string; body: ReactNode };

export function ComingSoon({ eyebrow, title, body }: ComingSoonProps) {
  useEffect(() => {
    document.title = "Coming soon · Essey";
  }, []);
  return (
    <section className="band" id="coming-soon">
      <div
        className="wrap"
        style={{ textAlign: "center", padding: "72px 0 96px" }}
      >
        <EMonogram size={56} stamped={false} />
        <span className="eyebrow" style={{ display: "block", marginTop: 18 }}>
          {eyebrow}
        </span>
        <h2 style={{ marginTop: 10 }}>{title}</h2>
        <p className="lede" style={{ margin: "10px auto 26px", maxWidth: 520 }}>
          {body}
        </p>
        <div className="hero-cta" style={{ justifyContent: "center" }}>
          <Link className="btn btn-gold" to="/blog">
            Latest updates →
          </Link>
          <Link className="btn btn-ghost" to="/">
            Home
          </Link>
        </div>
      </div>
    </section>
  );
}

export function GameComingSoon() {
  return (
    <ComingSoon
      eyebrow="D.O.N. — the on-chain game"
      title="Coming soon to mainnet."
      body="The game wing isn't open on the live site yet. We're building it in the open — follow along and we'll say the moment it's playable."
    />
  );
}
