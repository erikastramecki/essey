import { useState, useEffect, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { marked } from "marked";
import DOMPurify from "dompurify";
import { DOCS, type Doc } from "./docs.generated";
import { EMonogram, ThemeToggle, WarningModal, ExchangeHero, ClubFlow, Mechanics, ProvableTwist, EngineSection } from "./market";
import { CasesArcade } from "./cases";

const REPO = "https://github.com/erikastramecki/essey";
const GROUPS = ["The Market", "The engine", "Audits"];

// One narrative per page (founder rule): everything here serves the current Market-layer story.
// Prior iterations' surfaces — the any-chain pitch, the Sui demo app, the chain comparison — live in
// git history and the docs room, not on the page.
export default function App() {
  const [menuOpen, setMenuOpen] = useState(false);
  const NAV = [["club", "How it works"], ["market", "The Market"], ["cases", "Cases"], ["provable", "Provable"], ["engine", "The engine"], ["docs", "Docs"]];

  return (
    <>
      <WarningModal />
      <header className="nav">
        <div className="wrap nav-in">
          <a className="brand" href="#top"><EMonogram /> <span><b>Essey</b></span></a>
          <nav className="nav-links">
            {NAV.map(([id, label]) => <a key={id} href={`#${id}`}>{label}</a>)}
          </nav>
          <div className="nav-right">
            <ThemeToggle />
            <a className="btn btn-gold" href="#market">Enter the Market</a>
            <button className="nav-burger" aria-label="menu" aria-expanded={menuOpen} onClick={() => setMenuOpen((o) => !o)}>{menuOpen ? "✕" : "☰"}</button>
          </div>
        </div>
        {menuOpen && (
          <nav className="nav-mobile" onClick={() => setMenuOpen(false)}>
            {NAV.map(([id, label]) => <a key={id} href={`#${id}`}>{label}</a>)}
          </nav>
        )}
      </header>

      <main id="top">
        <ExchangeHero />
        <ClubFlow />
        <Mechanics />
        <CasesArcade />
        <ProvableTwist />
        <EngineSection />
        <DocsSection />

        <footer>
          <div className="wrap foot-in">
            <div>
              <p className="disclaim"><b>"Payout," never "dividend."</b> Bell Payouts are protocol fees distributed to
                Seat holders — mechanically LP-style fee-shares, not dividends, not yield promises. No payout is
                guaranteed, ever. The Market contracts are built and adversarially audited (published rounds in the
                docs room) but <b>not yet deployed</b> — nothing on this page moves real money today.{" "}
                <button className="linklike" onClick={() => window.dispatchEvent(new Event("essey:reopen-warning"))}>Terms &amp; risk</button></p>
              <p className="disclaim" style={{ marginTop: 10 }}><b>Tokenized equities are securities</b> and carry
                issuer, custody, and market-gap risk. On Robinhood Chain the Stock Token issuer holds an
                adminBurn power — verified on-chain — that can destroy tokens at any address; posted collateral
                can therefore cease to exist. Not an offer of securities. Nothing here is financial advice.</p>
              <p className="disclaim" style={{ marginTop: 10 }}>Everything we know is unfinished is published in{" "}
                <a href={`${REPO}/blob/main/docs/OUTSTANDING.md`} target="_blank" rel="noreferrer">OUTSTANDING.md</a> — deliberately.</p>
            </div>
            <div className="foot-links">
              <a href={REPO} target="_blank" rel="noreferrer">GitHub ↗</a>
              <a href={`${REPO}/tree/main/docs/audits`} target="_blank" rel="noreferrer">Audits ↗</a>
              <a href={`${REPO}/blob/main/docs/OUTSTANDING.md`} target="_blank" rel="noreferrer">Known-open ↗</a>
              <a href="#docs">Docs</a>
            </div>
          </div>
        </footer>
      </main>
    </>
  );
}

// EVERY overlay renders into <body>, never into the section that triggered it.
// `section { position: relative; z-index: 1 }` makes each section a stacking context, which caps
// everything inside it no matter how high the child's own z-index is — the sticky header would paint
// over a nested modal. The scroll lock is REFCOUNTED so stacked overlays can't strand a hidden body.
let scrollLocks = 0;
const FOCUSABLE = 'a[href],button:not([disabled]),input:not([disabled]),select,textarea,[tabindex]:not([tabindex="-1"])';

function Overlay({ onClose, lockScroll = true, trapFocus = false, children }: { onClose: () => void; lockScroll?: boolean; trapFocus?: boolean; children: ReactNode }) {
  const close = useRef(onClose);
  useEffect(() => { close.current = onClose; });
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const restoreTo = document.activeElement as HTMLElement | null;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") { close.current(); return; }
      // aria-modal is a promise that the rest of the page is unreachable — keep it by actually
      // cycling Tab inside the overlay.
      if (!trapFocus || e.key !== "Tab") return;
      const f = box.current?.querySelectorAll<HTMLElement>(FOCUSABLE);
      if (!f?.length) return;
      const first = f[0], last = f[f.length - 1], a = document.activeElement;
      const out = !box.current?.contains(a) || a === box.current;
      if (e.shiftKey && (out || a === first)) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && (out || a === last)) { e.preventDefault(); first.focus(); }
    };
    window.addEventListener("keydown", onKey);
    if (lockScroll && scrollLocks++ === 0) document.body.style.overflow = "hidden";
    if (trapFocus) (box.current?.querySelector<HTMLElement>("[data-autofocus]") ?? box.current?.querySelector<HTMLElement>(FOCUSABLE))?.focus();
    return () => {
      window.removeEventListener("keydown", onKey);
      if (lockScroll && (scrollLocks = Math.max(0, scrollLocks - 1)) === 0) document.body.style.overflow = "";
      if (trapFocus) restoreTo?.focus?.();
    };
  }, [lockScroll, trapFocus]);

  // display:contents — the wrapper exists only to scope the focus trap, never to affect layout.
  return createPortal(<div ref={box} className="overlay-root">{children}</div>, document.body);
}

// Docs — renders the repo docs (bundled at build) in a reader modal.
function DocsSection() {
  const [open, setOpen] = useState<Doc | null>(null);
  return (
    <section className="band" id="docs" style={{ paddingTop: 8 }}>
      <div className="wrap">
        <div className="band-head"><div><span className="eyebrow">Docs</span><h2>Read the whole thing</h2>
          <p>The Market's design, the tokenomics, the risk framework, every adversarial audit round, and the list of
            what is still unfinished. These are the repo's own files, rendered here — not a marketing summary of them.</p></div></div>
        {GROUPS.map((g) => {
          const inGroup = DOCS.filter((d) => d.group === g);
          if (inGroup.length === 0) return null;
          return (
            <div className="doc-group" key={g}>
              <div className="doc-group-h">{g}<span>{inGroup.length}</span></div>
              <div className="docs-grid">
                {inGroup.map((d) => (
                  <div key={d.slug} className="doc-card">
                    <button className="doc-card-hit" onClick={() => setOpen(d)} aria-label={`Read ${d.title}`}>
                      <span className="doc-t">{d.title}</span>
                      <span className="doc-d">{d.desc}</span>
                      <span className="doc-r">Read →</span>
                    </button>
                    <div className="doc-foot">
                      <a className="doc-src" href={`${REPO}/blob/main/docs/${d.file}`} target="_blank" rel="noreferrer">source ↗</a>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          );
        })}
      </div>
      {open && (
        <Overlay onClose={() => setOpen(null)} trapFocus>
          <div className="doc-modal" onClick={() => setOpen(null)}>
            {/* key: switching documents must remount the scroll container, or the next doc opens at
                the previous one's scroll offset. role/aria-modal belong on the reader, not the backdrop. */}
            <div className="doc-reader" key={open.slug} tabIndex={-1} data-autofocus
                 role="dialog" aria-modal="true" aria-label={open.title} onClick={(e) => e.stopPropagation()}>
              <div className="doc-reader-h"><span>{open.title}</span><button onClick={() => setOpen(null)} aria-label="close">×</button></div>
              <div className="doc-md" dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(marked.parse(open.md) as string, { FORBID_TAGS: ["form", "input", "button", "textarea"] }) }} />
            </div>
          </div>
        </Overlay>
      )}
    </section>
  );
}
