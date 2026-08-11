import { useState, useEffect, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { BrowserRouter, Routes, Route, NavLink, Link, Navigate, Outlet, useNavigate, useParams, useLocation } from "react-router-dom";
import { marked } from "marked";
import DOMPurify from "dompurify";
import { DOCS, type Doc } from "./docs.generated";
import { EMonogram, ThemeToggle, WarningModal, ExchangeHero, ClubFlow, Mechanics, ProvableTwist, EngineSection } from "./market";
import { CasesPage } from "./cases";
import { TestnetBanner, LiveExchange, LiveBell } from "./live-ui";
import { PortfolioPage } from "./portfolio";
import { PrivatePage } from "./private";
import { LendPage } from "./lend-ui";
import { OperatorPage } from "./operator";
import { ExplorerPage } from "./explorer";
import { BuilderPage } from "./builder";
import { HowItWorksPage } from "./howitworks";
import { FaucetPage } from "./faucet";
import { NotFoundPage } from "./notfound";
import { TickerTapeRail, TapeRoom } from "./tape-ui";
import { WalletProvider, ConnectButton, useWallet } from "./wallet";

const REPO = "https://github.com/erikastramecki/essey";
const GROUPS = ["The Market", "Essey Private", "The engine", "Audits"];

// Action-clear nav (founder: a tester must know where each flow lives). The landing tells the story;
// each app page does exactly one thing, led by the journey strip so "what do I do next" is answered.
const NAV = [
  ["/builder", "Build"],
  ["/how-it-works", "How it works"],
  ["/market", "Exchange"],
  ["/bell", "Bell"],
  ["/cases", "Cases"],
  ["/lend", "Lend"],
  ["/launch", "Launch"],
  ["/explorer", "Scan"],
  ["/tape", "Tape"],
  ["/portfolio", "Portfolio"],
  ["/private", "Private"],
  ["/faucet", "Faucet"],
  ["/docs", "Docs"],
] as const;

/// Thin wrapper for app pages: sets the document title. Each page's own band-head carries its
/// title + description.
function AppPage({ title, children }: { title: string; children: ReactNode }) {
  useEffect(() => { document.title = `${title} · Essey`; }, [title]);
  return <>{children}</>;
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
            <Route path="/market" element={<AppPage title="The Exchange"><LiveExchange /><Mechanics /></AppPage>} />
            <Route path="/bell" element={<AppPage title="The Bell"><LiveBell /></AppPage>} />
            <Route path="/cases" element={<AppPage title="Cases"><CasesPage /></AppPage>} />
            <Route path="/lend" element={<AppPage title="Lend"><LendPage /></AppPage>} />
            <Route path="/launch" element={<AppPage title="Launch"><OperatorPage /></AppPage>} />
            <Route path="/explorer" element={<ExplorerPage />} />
            <Route path="/builder" element={<AppPage title="PFP Builder"><BuilderPage /></AppPage>} />
            <Route path="/how-it-works" element={<AppPage title="How it works"><HowItWorksPage /></AppPage>} />
            <Route path="/faucet" element={<AppPage title="Faucet"><FaucetPage /></AppPage>} />
            <Route path="/tape" element={<AppPage title="The Tape"><TapeRoom /></AppPage>} />
            <Route path="/portfolio" element={<AppPage title="Portfolio"><PortfolioPage /></AppPage>} />
            <Route path="/private" element={<AppPage title="Private"><PrivatePage /></AppPage>} />
            <Route path="/provable" element={<PageShell title="Provable"><ProvableTwist /></PageShell>} />
            <Route path="/engine" element={<PageShell title="The engine"><EngineSection /></PageShell>} />
            <Route path="/docs" element={<DocsPage />} />
            <Route path="/docs/:slug" element={<DocsPage />} />
            <Route path="*" element={<NotFoundPage />} />
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
      <TickerTapeRail />
    </>
  );
}

/// Thin wrapper for single-section pages: consistent top spacing, document title.
function PageShell({ title, children }: { title: string; children: ReactNode }) {
  useEffect(() => { document.title = `${title} · Essey`; }, [title]);
  return <>{children}</>;
}

function Landing() {
  const w = useWallet();
  useEffect(() => { document.title = "Essey — the stock-market club where the odds and the books are both provable"; }, []);
  // Signed-in testers land on their dashboard, not the pitch. Wait for the reconnect probe so we don't
  // flash the marketing page before redirecting.
  if (!w.ready) return null;
  if (w.address) return <Navigate to="/portfolio" replace />;
  return (
    <>
      <ExchangeHero />
      <ClubFlow />
      {/* The one funnel: the landing points everyone at the Don builder. */}
      <section className="band" style={{ paddingTop: 8 }}>
        <div className="wrap">
          <div className="start-cta">
            <div>
              <span className="eyebrow">The Dons · take a seat at the table</span>
              <h2>Build your Don</h2>
              <p>Mint your Don, stake it to take a seat, and earn tokenized stock every time the Bell rings —
                a seat, a stock, and a margin account in one NFT. Customize every trait, or roll a random one.
                Every mechanic below is live to explore.</p>
            </div>
            <Link className="btn btn-gold start-cta-btn" to="/builder">Build your Don →</Link>
          </div>
          <div className="dest-grid" style={{ marginTop: 22 }}>
            {[
              ["/market", "⬡", "Exchange", "Buy, snipe, or sell a Seat on the live Exchange."],
              ["/bell", "🔔", "The Bell", "Stake a Tier, ring the Bell, claim a Payout into your Vault."],
              ["/cases", "🎁", "Cases", "Open a Case — a provably-fair multiplier draw that pays out in real stock."],
              ["/lend", "⚖", "Lend", "Supply USDG to earn, or borrow against the stock you win."],
              ["/private", "🛡", "Private", "Hide your balance, send privately, and earn yield unseen."],
              ["/portfolio", "◈", "Portfolio", "Everything you hold — Seats, Tiers, Vaults, loans."],
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

      {/* Essey Private — the privacy layer. */}
      <section className="band" style={{ paddingTop: 8 }}>
        <div className="wrap">
          <div className="start-cta">
            <div>
              <span className="eyebrow">🛡 Essey Private · experimental · testnet</span>
              <h2>Hold, move, and earn — without being watched</h2>
              <p>A privacy layer on Robinhood Chain: stealth-address payments, a shielded pool that hides your
                balance and amounts, private transfers that recover on any device, a trustless relayer for gasless
                private withdrawals, and private <b>yield-bearing</b> lending supply. Proofs run in your browser;
                your keys never leave your device.</p>
            </div>
            <Link className="btn btn-gold start-cta-btn" to="/private">Open Essey Private →</Link>
          </div>
          <div className="learn-row">
            How it works, plainly: <Link to="/docs">Essey Private — the privacy layer →</Link>
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
            Don holders — mechanically LP-style fee-shares, not dividends, not yield promises. No payout is
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
