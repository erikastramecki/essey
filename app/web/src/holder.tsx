import { useEffect, useState } from "react";
import { Link } from "react-router-dom";

// PREVIEW ONLY. The Holder Hub is designed against a live reference (Floor, chain 4663) but Essey's own
// backing — the holder stock distributor and per-basket allocator — is NOT deployed on 4663 yet. So this
// page reads no chain, shows no real figure, and asks for no signature. Everything is illustrative and
// labeled as such; the live floor that backs $ESSEY today is the Treasury page. Grounded in
// rh-chain/docs/research/floor-flr-scope.md §B (basket packs, rails, gasless sign, Merkle claim).

// Category packs — descriptors only. The reference product's exact per-asset weights are unverified, so
// this preview never prints a fabricated split; it shows the pack's intent and the rails a basket obeys.
const PACKS: [string, string][] = [
  ["Default", "Everything the floor holds, standard split"],
  ["Chip Lead", "NVDA-heavy — the chips and big tech"],
  ["Gold Tilt", "Gold first, anchored to the metal"],
  ["Wall Street", "The index, the chips, and gold"],
  ["Headlines", "Media, chips, and devices"],
  ["Ecosystem", "The chain's own tokens"],
  ["All NVIDIA", "One asset, all in"],
  ["Custom", "Build your own split, within the rails"],
];

// The rails a basket obeys — from the reference product's fine print; the intended design for Essey.
const RAILS = [
  "Signing is free and authorizes no transaction",
  "NVDA stays at a 35% minimum — it is the deepest pool",
  "Every other asset is capped at 75%",
  "One preference change per 48 hours",
  "Served within the reserve's available inventory",
];

export function HolderHubPage() {
  const [pack, setPack] = useState("Default");
  useEffect(() => {
    document.title = "Holder Hub · Essey";
  }, []);

  return (
    <section className="band">
      <div className="wrap">
        <div className="band-head">
          <div>
            <span className="eyebrow">Holder Hub · the Floor experience</span>
            <h2>Your basket. Your claim.</h2>
            <p>
              Your $ESSEY is a claim on the floor of real tokenized stock
              beneath it. The Holder Hub is where you say which stocks your
              share is paid out in, and where you claim it as the reserve
              accrues.
            </p>
          </div>
        </div>

        {/* The honest gate: none of this is on chain yet. */}
        <div className="hw-warn">
          <div className="hw-warn-h">Preview · not on chain</div>
          <div>
            This is a design preview. The contracts that power it — the holder
            stock distributor and the per-basket allocator — are{" "}
            <b>not deployed on Robinhood Chain (4663)</b>. Nothing here signs,
            claims, or moves anything, and every figure is illustrative until
            the reserve's distributor is live. The live floor that backs $ESSEY
            today is on the <Link to="/treasury">Treasury</Link>.
          </div>
        </div>

        {/* Basket selection — a gasless signed preference, not a transaction. */}
        <div className="hw-sec">
          <h2>Choose your basket</h2>
          <p className="hw-p">
            Your share of the floor is paid out in stock. A basket preference
            tells the reserve which stocks to deliver it in — the whole basket
            by default, a category pack, or a split you build yourself. It is a{" "}
            <b>gasless signed message, not a transaction</b>: it authorizes
            nothing, costs no gas, and a keeper reads it when it builds each
            epoch's allocation.
          </p>
          <div className="mech-grid">
            {PACKS.map(([nm, desc]) => (
              <button
                type="button"
                key={nm}
                className={"mech-card" + (pack === nm ? " open" : "")}
                onClick={() => setPack(nm)}
                style={{
                  appearance: "none",
                  WebkitAppearance: "none",
                  font: "inherit",
                  textAlign: "left",
                  cursor: "pointer",
                }}
              >
                <span className="mech-hit" style={{ cursor: "pointer" }}>
                  <span className="mech-nm">
                    {nm}
                    <i>{desc}</i>
                  </span>
                  {pack === nm && (
                    <span className="mech-status audited">chosen</span>
                  )}
                </span>
              </button>
            ))}
          </div>
          <div className="hw-note">
            <b>The rules a basket follows.</b>
            <ul className="hw-list">
              {RAILS.map((r) => (
                <li key={r}>{r}</li>
              ))}
            </ul>
            The exact signed-message format is still being finalized — it will
            be an EIP-712 typed message, but the fields are not fixed yet, so
            this preview does not ask you to sign.
          </div>
          <div className="hero-cta">
            <button
              className="btn btn-gold"
              disabled
              title="Preview — signing is not live yet"
            >
              Sign &amp; save — free, no gas
            </button>
            <span className="preview-chip">not live</span>
          </div>
        </div>

        {/* Claim — one running balance, Merkle-based, cumulative accrual. */}
        <div className="hw-sec">
          <h2>Your claim</h2>
          <p className="hw-p">
            Each epoch the reserve publishes a Merkle allocation of the stock it
            holds. You see <b>one running claimable balance</b>, not a list of
            epochs — unclaimed value carries forward into the next allocation,
            so skipping epochs costs you nothing.
          </p>
          <div className="hw-stats">
            <div className="hw-stat">
              <b>—</b>
              <span>
                Claimable now · reads live once the distributor deploys
              </span>
            </div>
            <div className="hw-stat">
              <b>—</b>
              <span>Stock held for you · illustrative until live</span>
            </div>
            <div className="hw-stat">
              <b>~12h</b>
              <span>Auto-drop cadence · designed keeper schedule</span>
            </div>
          </div>
          <div className="hw-note">
            <b>Two ways off one ledger.</b> Your stock arrives automatically on
            a recurring drop to your wallet, and you can claim manually any time
            — anything you claim is simply deducted from your next auto-drop.
          </div>
          <div className="hw-warn">
            <div className="hw-warn-h">Sell and your claim shrinks</div>
            <div>
              A claim is capped by what you still hold at claim time. Sell part
              of your $ESSEY after a snapshot and your claimable share is
              reduced in proportion — no cliff, but no free snapshot-and-dump
              either.
            </div>
          </div>
        </div>

        {/* The journey — chains into surfaces that already exist; shielded-or-not is the holder's choice. */}
        <div className="hw-sec">
          <h2>Where your stock goes next</h2>
          <p className="hw-p">
            Once the stock is yours, the rest of the protocol is one step away —
            shielded or not, your choice throughout.
          </p>
          <div className="dest-grid">
            <Link className="dest-card" to="/private">
              <span className="dest-icon" aria-hidden>
                ◐
              </span>
              <b>Shield it</b>
              <p>
                Turn on private shielding and claim your stock without revealing
                amounts. Experimental — not yet live on mainnet.
              </p>
              <span className="dest-go">Open Private →</span>
            </Link>
            <Link className="dest-card" to="/lend">
              <span className="dest-icon" aria-hidden>
                ⇄
              </span>
              <b>Borrow against it</b>
              <p>
                Post your stock and borrow against it without selling — LTV,
                terms, and loan management. Coming to mainnet.
              </p>
              <span className="dest-go">See lending →</span>
            </Link>
            <Link className="dest-card" to="/explorer">
              <span className="dest-icon" aria-hidden>
                🔎
              </span>
              <b>See it on chain</b>
              <p>
                Loans and balances surface publicly, so anyone can watch the
                floor and the book. Read-only, live.
              </p>
              <span className="dest-go">Open Explorer →</span>
            </Link>
          </div>
        </div>

        {/* Bridge back to the game wing — a Don is also a holder. */}
        <div className="start-cta plate">
          <div>
            <span className="eyebrow">Your other half</span>
            <h2>You also hold Dons?</h2>
            <p>
              A Don is a holder too. Flip to the game whenever you like — your
              holdings stay right here.
            </p>
          </div>
          <Link className="btn btn-ghost start-cta-btn" to="/dons">
            Enter the game →
          </Link>
        </div>
      </div>
    </section>
  );
}
