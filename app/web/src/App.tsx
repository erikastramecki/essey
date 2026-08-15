import { useState, useEffect, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import {
  BrowserRouter,
  Routes,
  Route,
  NavLink,
  Link,
  Navigate,
  Outlet,
  useNavigate,
  useParams,
  useLocation,
} from "react-router-dom";
import { marked } from "marked";
import DOMPurify from "dompurify";
import { DOCS, DOCS_BRANCH, type Doc } from "./docs.generated";
import {
  EMonogram,
  ThemeToggle,
  WarningModal,
  GameHero,
  GameLoop,
  ProvableTwist,
  EngineSection,
} from "./market";
import { TestnetBanner, LiveExchange, LiveBell } from "./live-ui";
import { PortfolioPage } from "./portfolio";
import { PrivatePage } from "./private";
import { LendPage } from "./lend-ui";
import { OperatorPage } from "./operator";
import { ExplorerPage } from "./explorer";
import { BuilderPage } from "./builder";
import { HowToPlayPage } from "./howtoplay";
import { FaucetPage } from "./faucet";
import { NotFoundPage } from "./notfound";
import { TickerTapeRail, TapeRoom } from "./tape-ui";
import { GamePage } from "./game/GamePage";
import { WalletProvider, ConnectButton, useWallet } from "./wallet";

const REPO = "https://github.com/erikastramecki/essey";
const GROUPS = [
  "The game",
  "The Market",
  "Essey Private",
  "The engine",
  "Audits",
];

// The nav is game-first and stays condensed: The Game and How to Play lead, Mint/Trade feed them,
// and everything else lives behind two doors. Lending is HIDDEN (not linked, route still resolves);
// the Bell moved under More — it's plumbing now, not the pitch. Every old route still resolves.
type NavLeaf = { to: string; label: string; desc: string };
type NavItem =
  { to: string; label: string } | { label: string; items: NavLeaf[] };
// The leaf groups are named consts and reused by MOBILE_NAV — never index into NAV for these
// (positional refs broke the mobile sheet once already when the doors shifted).
const LEARN_ITEMS: NavLeaf[] = [
  {
    to: "/docs",
    label: "Technical docs",
    desc: "The protocol underneath, from the repo's own files",
  },
  { to: "/provable", label: "Provable", desc: "Fair rolls, solvent books" },
  {
    to: "/engine",
    label: "The engine",
    desc: "The lending machinery underneath",
  },
];
const MORE_ITEMS: NavLeaf[] = [
  { to: "/faucet", label: "Faucet", desc: "Free testnet $ESSEY, USDG + gas" },
  { to: "/tape", label: "The Tape", desc: "Every event, with its receipt" },
  { to: "/explorer", label: "Explorer", desc: "Contracts, blocks, balances" },
  {
    to: "/bell",
    label: "The Bell",
    desc: "Where protocol fees pool and pay out",
  },
  { to: "/private", label: "Private", desc: "Shielded balances and transfers" },
  { to: "/launch", label: "Launch", desc: "Operator console" },
];
const NAV: NavItem[] = [
  { to: "/game", label: "The Game" },
  { to: "/docs/game-guide", label: "Game Guide" },
  { to: "/how-to-play", label: "How to Play" },
  { to: "/builder", label: "Mint" },
  { to: "/market", label: "Trade" },
  { label: "Learn", items: LEARN_ITEMS },
  { label: "More", items: MORE_ITEMS },
];
// The mobile sheet flattens the same IA under three headers.
const MOBILE_NAV: [string, NavLeaf[]][] = [
  [
    "The city",
    [
      {
        to: "/game",
        label: "The Game",
        desc: "jobs · raids · the city of Solvency",
      },
      {
        to: "/docs/game-guide",
        label: "Game Guide",
        desc: "the rulebook, every brief and number",
      },
      {
        to: "/how-to-play",
        label: "How to Play",
        desc: "the walkthrough, file by file",
      },
      { to: "/builder", label: "Mint", desc: "build your Don" },
      { to: "/market", label: "Trade", desc: "buy · snipe · sell" },
      { to: "/portfolio", label: "Portfolio", desc: "everything you hold" },
    ],
  ],
  ["Learn", LEARN_ITEMS],
  ["More", MORE_ITEMS],
];

/// Thin wrapper for app pages: sets the document title. Each page's own band-head carries its
/// title + description.
function AppPage({ title, children }: { title: string; children: ReactNode }) {
  useEffect(() => {
    document.title = `${title} · Essey`;
  }, [title]);
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
            <Route
              path="/market"
              element={
                <AppPage title="The Exchange">
                  <LiveExchange />
                </AppPage>
              }
            />
            <Route
              path="/bell"
              element={
                <AppPage title="The Bell">
                  <LiveBell />
                </AppPage>
              }
            />
            <Route
              path="/game/*"
              element={
                <AppPage title="D.O.N. — the Game">
                  <GamePage />
                </AppPage>
              }
            />
            {/* Lending is hidden from the nav for now but stays functional at its old address. */}
            <Route
              path="/lend"
              element={
                <AppPage title="Lend">
                  <LendPage />
                </AppPage>
              }
            />
            <Route
              path="/launch"
              element={
                <AppPage title="Launch">
                  <OperatorPage />
                </AppPage>
              }
            />
            <Route path="/explorer" element={<ExplorerPage />} />
            <Route
              path="/builder"
              element={
                <AppPage title="PFP Builder">
                  <BuilderPage />
                </AppPage>
              }
            />
            <Route
              path="/how-to-play"
              element={
                <AppPage title="How to Play">
                  <HowToPlayPage />
                </AppPage>
              }
            />
            {/* The Seats-era explainer is retired; old links land on the game walkthrough. */}
            <Route
              path="/how-it-works"
              element={<Navigate to="/how-to-play" replace />}
            />
            <Route
              path="/faucet"
              element={
                <AppPage title="Faucet">
                  <FaucetPage />
                </AppPage>
              }
            />
            <Route
              path="/tape"
              element={
                <AppPage title="The Tape">
                  <TapeRoom />
                </AppPage>
              }
            />
            <Route
              path="/portfolio"
              element={
                <AppPage title="Portfolio">
                  <PortfolioPage />
                </AppPage>
              }
            />
            <Route
              path="/private"
              element={
                <AppPage title="Private">
                  <PrivatePage />
                </AppPage>
              }
            />
            <Route
              path="/provable"
              element={
                <PageShell title="Provable">
                  <ProvableTwist />
                </PageShell>
              }
            />
            <Route
              path="/engine"
              element={
                <PageShell title="The engine">
                  <EngineSection />
                </PageShell>
              }
            />
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
  useEffect(() => {
    window.scrollTo(0, 0);
  }, [pathname]);
  return null;
}

/// One dropdown door in the masthead. Opens on click, closes on route change, Escape,
/// or a click anywhere else (the parent owns which group is open, so only one ever is).
function NavGroup({
  label,
  items,
  open,
  setOpen,
}: {
  label: string;
  items: NavLeaf[];
  open: boolean;
  setOpen: (l: string | null) => void;
}) {
  const { pathname } = useLocation();
  const active = items.some((i) => pathname.startsWith(i.to));
  return (
    <div className="nav-group">
      <button
        className={"nav-group-btn" + (active ? " on" : "")}
        aria-expanded={open}
        aria-haspopup="menu"
        onClick={(e) => {
          e.stopPropagation();
          setOpen(open ? null : label);
        }}
      >
        {label} <i aria-hidden>▼</i>
      </button>
      {open && (
        <div className="nav-menu" role="menu">
          {items.map((i) => (
            <NavLink
              key={i.to}
              to={i.to}
              role="menuitem"
              className={({ isActive }) => (isActive ? "on" : "")}
            >
              <b>{i.label}</b>
              <span>{i.desc}</span>
            </NavLink>
          ))}
        </div>
      )}
    </div>
  );
}

function Layout() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [openGroup, setOpenGroup] = useState<string | null>(null);
  const { pathname } = useLocation();
  useEffect(() => {
    setOpenGroup(null);
    setMenuOpen(false);
  }, [pathname]);
  useEffect(() => {
    if (!openGroup) return;
    const close = () => setOpenGroup(null);
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpenGroup(null);
    };
    window.addEventListener("click", close);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("keydown", onKey);
    };
  }, [openGroup]);
  return (
    <>
      <header className="nav">
        <div className="wrap nav-in">
          <Link className="brand" to="/">
            <EMonogram />{" "}
            <span>
              <b>Essey</b>
            </span>
          </Link>
          <nav className="nav-links">
            {NAV.map((item) =>
              "to" in item ? (
                <NavLink
                  key={item.label}
                  to={item.to}
                  className={({ isActive }) => (isActive ? "on" : "")}
                >
                  {item.label}
                </NavLink>
              ) : (
                <NavGroup
                  key={item.label}
                  label={item.label}
                  items={item.items}
                  open={openGroup === item.label}
                  setOpen={setOpenGroup}
                />
              ),
            )}
          </nav>
          <div className="nav-right">
            <NavLink
              to="/portfolio"
              className={({ isActive }) => "nav-pf" + (isActive ? " on" : "")}
            >
              Portfolio
            </NavLink>
            <ThemeToggle />
            <ConnectButton />
            <button
              className="nav-burger"
              aria-label="menu"
              aria-expanded={menuOpen}
              onClick={() => setMenuOpen((o) => !o)}
            >
              {menuOpen ? "✕" : "☰"}
            </button>
          </div>
        </div>
        {menuOpen && (
          <nav className="nav-mobile" onClick={() => setMenuOpen(false)}>
            {MOBILE_NAV.map(([h, leaves]) => (
              <div key={h}>
                <div className="nm-h">{h}</div>
                {leaves.map((l) => (
                  <NavLink key={l.to} to={l.to}>
                    {l.label}
                    <i>{l.desc}</i>
                  </NavLink>
                ))}
              </div>
            ))}
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
function PageShell({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  useEffect(() => {
    document.title = `${title} · Essey`;
  }, [title]);
  return <>{children}</>;
}

function Landing() {
  const w = useWallet();
  useEffect(() => {
    document.title =
      "Essey · D.O.N. — the on-chain city where the odds and the books are both provable";
  }, []);
  // Signed-in testers land on their dashboard, not the pitch. Wait for the reconnect probe so we don't
  // flash the marketing page before redirecting.
  if (!w.ready) return null;
  if (w.address) return <Navigate to="/portfolio" replace />;
  return (
    <>
      <GameHero />
      <GameLoop />
      {/* The doors — the same IA as the masthead, with one line of truth each. */}
      <section className="band" style={{ paddingTop: 8 }}>
        <div className="wrap">
          <div className="band-head">
            <div>
              <span className="eyebrow">The city</span>
              <h2>Six doors. Start at the game.</h2>
            </div>
          </div>
          <div className="dest-grid">
            {[
              [
                "/game",
                "♠",
                "The Game",
                "The desk, the job board, the stakeout. Send your Don to work in the city of Solvency.",
              ],
              [
                "/how-to-play",
                "🗂",
                "How to Play",
                "The whole game, file by file: jobs, banking, raids, and every number from the chain.",
              ],
              [
                "/builder",
                "◇",
                "Mint",
                "Build your Don trait by trait, reroll a random one, or claim free on the whitelist.",
              ],
              [
                "/market",
                "⇄",
                "Trade",
                "Buy, snipe, or sell Dons at the floor-pinned price on the live on-chain desk.",
              ],
              [
                "/tape",
                "📈",
                "The Tape",
                "Everything the city does, printed live — every line a real transaction receipt.",
              ],
              [
                "/portfolio",
                "◈",
                "Portfolio",
                "Everything you hold: your Dons, their Vaults, and every action on them.",
              ],
            ].map(([to, icon, h, p]) => (
              <Link key={to} className="dest-card" to={to}>
                <span className="dest-icon" aria-hidden>
                  {icon}
                </span>
                <b>{h}</b>
                <p>{p}</p>
                <span className="dest-go">Open →</span>
              </Link>
            ))}
          </div>
          <div className="learn-row">
            The rails underneath: <Link to="/provable">Provable</Link> ·{" "}
            <Link to="/engine">The engine</Link> ·{" "}
            <Link to="/docs">Technical docs</Link>
          </div>
        </div>
      </section>

      {/* Essey Private — the privacy layer. */}
      <section className="band" style={{ paddingTop: 8 }}>
        <div className="wrap">
          <div className="start-cta plate">
            <div>
              <span className="eyebrow">
                Essey Private · experimental · testnet
              </span>
              <h2>Hold, move, and earn, unseen</h2>
              <p>
                Stealth-address payments, a shielded pool that hides balances
                and amounts, gasless private withdrawals through a trustless
                relayer, and private yield-bearing lending supply. Proofs run in
                your browser; keys never leave your device.
              </p>
            </div>
            <Link className="btn btn-gold start-cta-btn" to="/private">
              Open Essey Private →
            </Link>
          </div>
        </div>
      </section>
    </>
  );
}

function Footer() {
  return (
    <footer>
      <div className="wrap foot-cols">
        {(
          [
            [
              "The city",
              [
                ["/game", "The Game"],
                ["/how-to-play", "How to Play"],
                ["/builder", "Mint"],
                ["/market", "Trade"],
                ["/portfolio", "Portfolio"],
              ],
            ],
            [
              "Learn",
              [
                ["/docs", "Technical docs"],
                ["/provable", "Provable"],
                ["/engine", "The engine"],
              ],
            ],
            [
              "More",
              [
                ["/faucet", "Faucet"],
                ["/tape", "The Tape"],
                ["/explorer", "Explorer"],
                ["/bell", "The Bell"],
                ["/private", "Private"],
                ["/launch", "Launch"],
              ],
            ],
          ] as const
        ).map(([h, links]) => (
          <div className="foot-col" key={h}>
            <span className="fc-h">{h}</span>
            {links.map(([to, label]) => (
              <Link key={to} to={to}>
                {label}
              </Link>
            ))}
          </div>
        ))}
      </div>
      <div className="wrap foot-in">
        <div>
          <p className="disclaim">
            <b>This season settles in Scrip</b> — play points marked to tickers.
            Real-token settlement is the roadmap; nothing won in the game today
            is real stock. "Payout," never "dividend": protocol fee
            distributions are mechanically LP-style fee-shares, not dividends,
            not yield promises, and no payout is guaranteed, ever. The contracts
            are adversarially audited (published rounds in the technical docs)
            and <b>live on Robinhood Chain testnet</b>. Everything here is play
            money with no real value; not on mainnet.{" "}
            <button
              className="linklike"
              onClick={() =>
                window.dispatchEvent(new Event("essey:reopen-warning"))
              }
            >
              Terms &amp; risk
            </button>
          </p>
          <p className="disclaim" style={{ marginTop: 10 }}>
            <b>Tokenized equities are securities</b> and carry issuer, custody,
            and market-gap risk. On Robinhood Chain the Stock Token issuer holds
            an adminBurn power (verified on-chain) that can destroy tokens at
            any address; posted collateral can therefore cease to exist. Not an
            offer of securities. Nothing here is financial advice.
          </p>
          <p className="disclaim" style={{ marginTop: 10 }}>
            Everything we know is unfinished is published in{" "}
            <a
              href={`${REPO}/blob/main/docs/OUTSTANDING.md`}
              target="_blank"
              rel="noreferrer"
            >
              OUTSTANDING.md
            </a>
            , deliberately.
          </p>
        </div>
        <div className="foot-links">
          <a href={REPO} target="_blank" rel="noreferrer">
            GitHub ↗
          </a>
          <a
            href={`${REPO}/tree/main/docs/audits`}
            target="_blank"
            rel="noreferrer"
          >
            Audits ↗
          </a>
          <Link to="/docs">Technical docs</Link>
        </div>
      </div>
    </footer>
  );
}

// EVERY overlay renders into <body> — sections are stacking contexts and the sticky header would
// paint over a nested modal. Scroll lock is refcounted so stacked overlays can't strand a hidden body.
let scrollLocks = 0;
const FOCUSABLE =
  'a[href],button:not([disabled]),input:not([disabled]),select,textarea,[tabindex]:not([tabindex="-1"])';

function Overlay({
  onClose,
  lockScroll = true,
  trapFocus = false,
  children,
}: {
  onClose: () => void;
  lockScroll?: boolean;
  trapFocus?: boolean;
  children: ReactNode;
}) {
  const close = useRef(onClose);
  useEffect(() => {
    close.current = onClose;
  });
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const restoreTo = document.activeElement as HTMLElement | null;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        close.current();
        return;
      }
      if (!trapFocus || e.key !== "Tab") return;
      const f = box.current?.querySelectorAll<HTMLElement>(FOCUSABLE);
      if (!f?.length) return;
      const first = f[0],
        last = f[f.length - 1],
        a = document.activeElement;
      const out = !box.current?.contains(a) || a === box.current;
      if (e.shiftKey && (out || a === first)) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && (out || a === last)) {
        e.preventDefault();
        first.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    if (lockScroll && scrollLocks++ === 0)
      document.body.style.overflow = "hidden";
    if (trapFocus)
      (
        box.current?.querySelector<HTMLElement>("[data-autofocus]") ??
        box.current?.querySelector<HTMLElement>(FOCUSABLE)
      )?.focus();
    return () => {
      window.removeEventListener("keydown", onKey);
      if (lockScroll && (scrollLocks = Math.max(0, scrollLocks - 1)) === 0)
        document.body.style.overflow = "";
      if (trapFocus) restoreTo?.focus?.();
    };
  }, [lockScroll, trapFocus]);

  return createPortal(
    <div ref={box} className="overlay-root">
      {children}
    </div>,
    document.body,
  );
}

/// Docs — the reading room. Deep-linkable: /docs/:slug opens the reader; closing returns to /docs.
function DocsPage() {
  const { slug } = useParams();
  const navigate = useNavigate();
  const open = slug ? (DOCS.find((d) => d.slug === slug) ?? null) : null;
  useEffect(() => {
    document.title = open ? `${open.title} · Essey` : "Docs · Essey";
  }, [open]);
  const close = () => navigate("/docs");
  return (
    <section className="band" id="docs">
      <div className="wrap">
        <div className="band-head">
          <div>
            <span className="eyebrow">Technical docs</span>
            <h2>Read the whole thing</h2>
            <p>
              The game's rulebook, the tokenomics, the lending engine's risk
              framework, every adversarial audit round, and the list of what is
              still unfinished. These are the repo's own files, rendered here,
              not a marketing summary of them.
            </p>
          </div>
        </div>
        {GROUPS.map((g) => {
          const inGroup = DOCS.filter((d) => d.group === g);
          if (inGroup.length === 0) return null;
          return (
            <div className="doc-group" key={g}>
              <div className="doc-group-h">
                {g}
                <span>{inGroup.length}</span>
              </div>
              <div className="docs-grid">
                {inGroup.map((d) => (
                  <div key={d.slug} className="doc-card">
                    <Link
                      className="doc-card-hit"
                      to={`/docs/${d.slug}`}
                      aria-label={`Read ${d.title}`}
                    >
                      <span className="doc-t">{d.title}</span>
                      <span className="doc-d">{d.desc}</span>
                      <span className="doc-r">Read →</span>
                    </Link>
                    <div className="doc-foot">
                      {/* DOCS_BRANCH, not "main": the site renders the built checkout, and some docs
                          haven't merged yet — a main link would 404 for those. Self-heals at merge. */}
                      <a
                        className="doc-src"
                        href={`${REPO}/blob/${DOCS_BRANCH}/docs/${d.file}`}
                        target="_blank"
                        rel="noreferrer"
                      >
                        source ↗
                      </a>
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
            <div
              className="doc-reader"
              key={open.slug}
              tabIndex={-1}
              data-autofocus
              role="dialog"
              aria-modal="true"
              aria-label={open.title}
              onClick={(e) => e.stopPropagation()}
            >
              <div className="doc-reader-h">
                <span>{open.title}</span>
                <button onClick={close} aria-label="close">
                  ×
                </button>
              </div>
              <div
                className="doc-md"
                dangerouslySetInnerHTML={{
                  __html: DOMPurify.sanitize(marked.parse(open.md) as string, {
                    FORBID_TAGS: ["form", "input", "button", "textarea"],
                  }),
                }}
              />
            </div>
          </div>
        </Overlay>
      )}
    </section>
  );
}
