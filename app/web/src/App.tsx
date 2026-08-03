import { useState, useEffect, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { BrowserRouter, Routes, Route, NavLink, Link, Outlet, useNavigate, useParams, useLocation } from "react-router-dom";
import { marked } from "marked";
import DOMPurify from "dompurify";
import { DOCS, type Doc } from "./docs.generated";
import { EMonogram, ThemeToggle, WarningModal, ExchangeHero, ClubFlow, Mechanics, ProvableTwist, EngineSection } from "./market";
import { CasesArcade } from "./cases";
import { TestnetBanner, LiveExchange, LiveBell } from "./live-ui";
import { StartPage, JourneyStrip, type StepId } from "./journey";
import { PortfolioPage } from "./portfolio";
import { WalletProvider, ConnectButton } from "./wallet";

const REPO = "https://github.com/erikastramecki/essey";
const GROUPS = ["The Market", "The engine", "Audits"];

// Action-clear nav (founder: a tester must know where each flow lives). The landing tells the story;
// each app page does exactly one thing, led by the journey strip so "what do I do next" is answered.
const NAV = [
  ["/start", "Start"],
  ["/market", "Market"],
  ["/bell", "Stake"],
  ["/cases", "Cases"],
  ["/portfolio", "Portfolio"],
  ["/docs", "Docs"],
] as const;

/// Every app page opens with the journey strip + a one-line "what you're testing" header, so a
/// newcomer always knows where they are and what's next.
function AppPage({ title, what, here, children }: { title: string; what: string; here?: StepId; children: ReactNode }) {
  useEffect(() => { document.title = `${title} · Essey`; }, [title]);
  return (
    <>
      <JourneyStrip here={here} />
      <div className="wrap app-page-head">
        <span className="eyebrow">You're testing</span>
        <h1 className="app-page-title">{title}</h1>
        <p className="app-page-what">{what}</p>
      </div>
      {children}
    </>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <WalletProvider>
        <ScrollToTop />
        <WarningModal />
        <Routes>
          <Route element={<Layout />}>
            <Route path="/" element={<Landing />} />
            <Route path="/start" element={<StartPage />} />
            <Route path="/market" element={
              <AppPage title="The Market" here="seat" what="Trade $ESSEY for a Seat on the Exchange — buy the next one, snipe an exact number, or sell one back. Every trade fee feeds the Bell's pot.">
                <LiveExchange /><Mechanics />
              </AppPage>} />
            <Route path="/bell" element={
              <AppPage title="Stake &amp; the Bell" here="stake" what="Stake $ESSEY on a Seat to raise its Tier, ring the Bell when the pot's worth it, and claim your Payout into the Seat's Vault.">
                <LiveBell />
              </AppPage>} />
            <Route path="/cases" element={
              <AppPage title="Cases" here="case" what="Open a Case for a provably-fair stock draw — every pull is ~fair value; the draw only decides which name.">
                <CasesArcade />
              </AppPage>} />
            <Route path="/portfolio" element={<PortfolioPage />} />
            <Route path="/provable" element={<PageShell title="Provable"><ProvableTwist /></PageShell>} />
            <Route path="/engine" element={<PageShell title="The engine"><EngineSection /></PageShell>} />
            <Route path="/docs" element={<DocsPage />} />
            <Route path="/docs/:slug" element={<DocsPage />} />
            <Route path="*" element={<Landing />} />
          </Route>
        </Routes>
      </WalletProvider>
    </BrowserRouter>
  );
}

function ScrollToTop() {
  const { pathname } = useLocation();
  useEffect(() => { window.scrollTo(0, 0); }, [pathname]);
  return null;
}

function Layout() {
  const [menuOpen, setMenuOpen] = useState(false);
  return (
    <>
      <header className="nav">
        <div className="wrap nav-in">
          <Link className="brand" to="/"><EMonogram /> <span><b>Essey</b></span></Link>
          <nav className="nav-links">
            {NAV.map(([to, label]) => (
              <NavLink key={to} to={to} className={({ isActive }) => (isActive ? "on" : "")}>{label}</NavLink>
            ))}
          </nav>
          <div className="nav-right">
            <ThemeToggle />
            <ConnectButton />
            <button className="nav-burger" aria-label="menu" aria-expanded={menuOpen} onClick={() => setMenuOpen((o) => !o)}>{menuOpen ? "✕" : "☰"}</button>
          </div>
        </div>
        {menuOpen && (
          <nav className="nav-mobile" onClick={() => setMenuOpen(false)}>
            {NAV.map(([to, label]) => <NavLink key={to} to={to}>{label}</NavLink>)}
          </nav>
        )}
      </header>
      <main id="top">
        <TestnetBanner />
        <Outlet />
        <Footer />
      </main>
    </>
  );
}

/// Thin wrapper for single-section pages: consistent top spacing, document title.
function PageShell({ title, children }: { title: string; children: ReactNode }) {
  useEffect(() => { document.title = `${title} · Essey`; }, [title]);
  return <>{children}</>;
}

function Landing() {
  useEffect(() => { document.title = "Essey — the stock-market club where the odds and the books are both provable"; }, []);
  return (
    <>
      <ExchangeHero />
      <ClubFlow />
      {/* The one funnel: the landing points everyone at the guided journey. */}
      <section className="band" style={{ paddingTop: 8 }}>
        <div className="wrap">
          <div className="start-cta">
            <div>
              <span className="eyebrow">Live on testnet</span>
              <h2>Play the whole thing, free</h2>
              <p>Every mechanic is deployed and playable right now with play money. Follow the six-step tour and
                you'll trade a Seat, stake a Tier, ring the Bell, claim a Payout, and open a Case — no risk, real contracts.</p>
            </div>
            <Link className="btn btn-gold start-cta-btn" to="/start">Start testing →</Link>
          </div>
          <div className="dest-grid" style={{ marginTop: 22 }}>
            {[
              ["/market", "⬡", "Market", "Buy, snipe, or sell a Seat on the live Exchange."],
              ["/bell", "🔔", "Stake", "Raise a Tier, ring the Bell, claim a Payout into your Vault."],
              ["/cases", "🎁", "Cases", "Open a Case for a provably-fair real-stock draw."],
              ["/portfolio", "◈", "Portfolio", "Everything you hold — Seats, Tiers, Vaults, winnings."],
            ].map(([to, icon, h, p]) => (
              <Link key={to} className="dest-card" to={to}>
                <span className="dest-icon" aria-hidden>{icon}</span>
                <b>{h}</b>
                <p>{p}</p>
                <span className="dest-go">Open →</span>
              </Link>
            ))}
          </div>
          <div className="learn-row">
            Curious how it holds together? <Link to="/provable">Provable</Link> · <Link to="/engine">The engine</Link> · <Link to="/docs">Docs</Link>
          </div>
        </div>
      </section>
    </>
  );
}

function Footer() {
  return (
    <footer>
      <div className="wrap foot-in">
        <div>
          <p className="disclaim"><b>"Payout," never "dividend."</b> Bell Payouts are protocol fees distributed to
            Seat holders — mechanically LP-style fee-shares, not dividends, not yield promises. No payout is
            guaranteed, ever. The Market contracts are adversarially audited (published rounds in the docs room)
            and <b>live on Robinhood Chain testnet</b> — everything here is play money with no real value; not
            on mainnet.{" "}
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
          <Link to="/docs">Docs</Link>
        </div>
      </div>
    </footer>
  );
}

// EVERY overlay renders into <body> — sections are stacking contexts and the sticky header would
// paint over a nested modal. Scroll lock is refcounted so stacked overlays can't strand a hidden body.
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

  return createPortal(<div ref={box} className="overlay-root">{children}</div>, document.body);
}

/// Docs — the reading room. Deep-linkable: /docs/:slug opens the reader; closing returns to /docs.
function DocsPage() {
  const { slug } = useParams();
  const navigate = useNavigate();
  const open = slug ? DOCS.find((d) => d.slug === slug) ?? null : null;
  useEffect(() => { document.title = open ? `${open.title} · Essey` : "Docs · Essey"; }, [open]);
  const close = () => navigate("/docs");
  return (
    <section className="band" id="docs">
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
                    <Link className="doc-card-hit" to={`/docs/${d.slug}`} aria-label={`Read ${d.title}`}>
                      <span className="doc-t">{d.title}</span>
                      <span className="doc-d">{d.desc}</span>
                      <span className="doc-r">Read →</span>
                    </Link>
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
        <Overlay onClose={close} trapFocus>
          <div className="doc-modal" onClick={close}>
            {/* key: switching documents must remount the scroll container, or the next doc opens at
                the previous one's scroll offset. */}
            <div className="doc-reader" key={open.slug} tabIndex={-1} data-autofocus
                 role="dialog" aria-modal="true" aria-label={open.title} onClick={(e) => e.stopPropagation()}>
              <div className="doc-reader-h"><span>{open.title}</span><button onClick={close} aria-label="close">×</button></div>
              <div className="doc-md" dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(marked.parse(open.md) as string, { FORBID_TAGS: ["form", "input", "button", "textarea"] }) }} />
            </div>
          </div>
        </Overlay>
      )}
    </section>
  );
}
