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
import { SeasonBanner, LiveExchange, LiveBell } from "./live-ui";
import { PortfolioPage } from "./portfolio";
import { PrivatePage } from "./private";
import { LendPage } from "./lend-ui";
import { ExplorerPage } from "./explorer";
import { BuilderPage } from "./builder";
import { HowToPlayPage } from "./howtoplay";
import { FaucetPage } from "./faucet";
import { ComingPage } from "./coming";
import { ComingSoon, GameComingSoon } from "./game-gate";
import { NotFoundPage } from "./notfound";
import { TreasuryPage } from "./treasury";
import { HolderHubPage } from "./holder";
import { RedeemPage } from "./redeem-ui";
import { BlogIndex, BlogPost } from "./blog";
import { TapeRoom } from "./tape-ui";
import { GamePage } from "./game/GamePage";
import { GameExplorerPage } from "./game/explorer";
import { WalletProvider, ConnectButton } from "./wallet";

const REPO = "https://github.com/erikastramecki/essey";
// The Holder Hub is preview-only until its distributor deploys (founder standing rule). It is OFF on the
// live domain and ON everywhere else (preview URLs, local dev). Two guards: __HOLDER_BUILD__ is false on
// a prod build (covers SSR/prerender, which has no window), and the hostname check covers an alias-promote
// of a preview build to the live domain. Either being restrictive keeps it off essey.xyz.
const PROD_HOSTS = new Set(["essey.xyz", "www.essey.xyz"]);
const HOLDER_ON =
  typeof window === "undefined"
    ? __HOLDER_BUILD__
    : !PROD_HOSTS.has(window.location.hostname);
// Redemption writes to a LIVE mainnet contract and destroys supply, so it stays preview-only until the
// founder opens it (founder standing rule). Same two guards as HOLDER_ON: __HOLDER_BUILD__ is false on a
// prod build (covers SSR/prerender, no window), and the hostname check covers an alias-promote of a
// preview build to the live domain. Off the live host /redeem renders the coming-soon screen and the
// Redeem door drops from the nav, so no visitor to essey.xyz can reach a burn.
const REDEEM_ON =
  typeof window === "undefined"
    ? __HOLDER_BUILD__
    : !PROD_HOSTS.has(window.location.hostname);
// The whole D.O.N. game wing is preview-only until it ships to mainnet (founder standing rule). Same
// two guards as HOLDER_ON: __HOLDER_BUILD__ is false on a prod build (covers SSR/prerender, no window),
// and the hostname check covers an alias-promote of a preview build to the live domain. Off the live
// host every game route renders the coming-soon screen and every game door drops from the nav.
const GAME_ON =
  typeof window === "undefined"
    ? __HOLDER_BUILD__
    : !PROD_HOSTS.has(window.location.hostname);
// Essey Private (shielding) is preview-only until it ships to mainnet (founder standing rule). Same
// two guards as HOLDER_ON/GAME_ON: __HOLDER_BUILD__ is false on a prod build (covers SSR/prerender,
// no window), and the hostname check covers an alias-promote of a preview build to the live domain.
// Off the live host /private renders the coming-soon screen and the Private door drops from the nav.
const PRIVATE_ON =
  typeof window === "undefined"
    ? __HOLDER_BUILD__
    : !PROD_HOSTS.has(window.location.hostname);
// The game wing's routes — the season banner and the game framing apply only under these prefixes.
const GAME_PREFIXES = [
  "/dons",
  "/game",
  "/builder",
  "/market",
  "/bell",
  "/portfolio",
  "/how-to-play",
  "/coming",
  "/faucet",
];
// The reading room is siloed the way the site is: PROTOCOL docs and DONS/GAME docs are separate
// top-level sections that never mix. `key` matches Doc.section from gen-docs.mjs; `groups` fixes the
// sub-heading order within each section. Protocol leads (the front door), the game is the wing.
const DOC_SECTIONS = [
  {
    key: "PROTOCOL",
    label: "Protocol",
    groups: [
      "Base layer",
      "The engine",
      "Essey Private",
      "Known-open",
      "Protocol audits",
    ],
  },
  {
    key: "DONS",
    label: "Dons / The Game",
    groups: [
      "The game",
      "Dons tokenomics",
      "Game known-open",
      "Game-era contracts",
    ],
  },
];

// The site is TWO SECTIONS under ONE identity: the Essey protocol (the front door) and the D.O.N.
// game (a wing you only reach by going looking). The masthead is protocol-first — the Floor and the
// Holder Hub lead — and the whole game lives behind the single "Dons" door. Every old route still
// resolves. The leaf groups are named consts reused by MOBILE_NAV — never index into NAV positionally
// (that broke the mobile sheet once when the doors shifted).
type NavLeaf = { to: string; label: string; desc: string };
type NavItem =
  { to: string; label: string } | { label: string; items: NavLeaf[] };
const LEARN_ITEMS: NavLeaf[] = [
  { to: "/blog", label: "Blog", desc: "Building Essey in the open" },
  {
    to: "/docs",
    label: "Technical docs",
    desc: "The protocol underneath, from the repo's own files",
  },
  { to: "/tape", label: "The Tape", desc: "Every event, with its receipt" },
  { to: "/provable", label: "Provable", desc: "Fair rolls, solvent books" },
];
// The Dons wing — the entire game behind one door. A holder never lands here unless they open it.
const DONS_ITEMS: NavLeaf[] = [
  {
    to: "/dons",
    label: "The Dons game",
    desc: "The on-chain city of Solvency",
  },
  { to: "/game", label: "Play", desc: "The desk, the job board, the stakeout" },
  { to: "/builder", label: "Mint", desc: "Build your Don" },
  { to: "/market", label: "Trade", desc: "Buy · snipe · sell" },
  {
    to: "/how-to-play",
    label: "How to Play",
    desc: "The walkthrough, file by file",
  },
  { to: "/docs/game-guide", label: "Game Guide", desc: "The full house rules" },
  {
    to: "/portfolio",
    label: "Portfolio",
    desc: "Your Dons and every action on them",
  },
  {
    to: "/dons/explorer",
    label: "Solvency Scan",
    desc: "The wire, the street, the families",
  },
];
const NAV: NavItem[] = [
  { to: "/treasury", label: "The Floor" },
  ...(HOLDER_ON ? [{ to: "/holder", label: "Holder Hub" } as NavItem] : []),
  ...(REDEEM_ON ? [{ to: "/redeem", label: "Redeem" } as NavItem] : []),
  ...(PRIVATE_ON ? [{ to: "/private", label: "Private" } as NavItem] : []),
  { label: "Learn", items: LEARN_ITEMS },
  ...(GAME_ON ? [{ label: "Dons", items: DONS_ITEMS } as NavItem] : []),
];
// The mobile sheet flattens the same IA under its three faces: protocol, learn, game.
const PROTOCOL_ITEMS: NavLeaf[] = [
  {
    to: "/treasury",
    label: "The Floor",
    desc: "What backs $ESSEY, live on mainnet",
  },
  ...(HOLDER_ON
    ? [
        {
          to: "/holder",
          label: "Holder Hub",
          desc: "Your basket and your claim — preview",
        },
      ]
    : []),
  ...(REDEEM_ON
    ? [
        {
          to: "/redeem",
          label: "Redeem",
          desc: "Burn $ESSEY for your slice of the floor",
        },
      ]
    : []),
  ...(PRIVATE_ON
    ? [
        {
          to: "/private",
          label: "Private",
          desc: "Shielded balances and transfers",
        },
      ]
    : []),
  {
    to: "/explorer",
    label: "Explorer",
    desc: "The reserve's state and every event, on mainnet",
  },
];
const MOBILE_NAV: [string, NavLeaf[]][] = [
  ["Essey — the protocol", PROTOCOL_ITEMS],
  ["Learn", LEARN_ITEMS],
  ...(GAME_ON
    ? ([["D.O.N. — the game", DONS_ITEMS]] as [string, NavLeaf[]][])
    : []),
];

/// Thin wrapper for app pages: sets the document title. Each page's own band-head carries its
/// title + description.
function AppPage({ title, children }: { title: string; children: ReactNode }) {
  useEffect(() => {
    document.title = `${title} · Essey`;
  }, [title]);
  return <>{children}</>;
}

/// Route-level gate for the game wing: off the live domain (GAME_ON false) the page never mounts and
/// the coming-soon screen renders in its place, so deep-linking a game route reaches no gameplay action.
function GameGate({ children }: { children: ReactNode }) {
  return GAME_ON ? <>{children}</> : <GameComingSoon />;
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
            {/* The Dons wing — the game's own front door. The marketing that used to sit at "/". */}
            <Route
              path="/dons"
              element={
                <GameGate>
                  <AppPage title="D.O.N. — the Game">
                    <DonsLanding />
                  </AppPage>
                </GameGate>
              }
            />
            {/* The Holder Hub — preview only (founder standing rule); withheld from the live domain
                until its distributor deploys. Off the live host the route renders the coming-soon screen. */}
            <Route
              path="/holder"
              element={
                HOLDER_ON ? (
                  <AppPage title="Holder Hub">
                    <HolderHubPage />
                  </AppPage>
                ) : (
                  <ComingSoon
                    eyebrow="Holder Hub"
                    title="Coming soon to mainnet."
                    body="The holder hub isn't open on the live site yet. When it's live, holders will claim their airdrops and manage their position from here — we're building it in the open and will say the moment it's ready."
                  />
                )
              }
            />
            <Route
              path="/market"
              element={
                <GameGate>
                  <AppPage title="The Exchange">
                    <LiveExchange />
                  </AppPage>
                </GameGate>
              }
            />
            <Route
              path="/bell"
              element={
                <GameGate>
                  <AppPage title="The Bell">
                    <LiveBell />
                  </AppPage>
                </GameGate>
              }
            />
            <Route
              path="/game/*"
              element={
                <GameGate>
                  <AppPage title="D.O.N. — the Game">
                    <GamePage />
                  </AppPage>
                </GameGate>
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
            <Route path="/explorer" element={<ExplorerPage />} />
            {/* The game-era desk reads the game chain, so it is gated with the rest of the wing. */}
            <Route
              path="/dons/explorer"
              element={
                <GameGate>
                  <GameExplorerPage />
                </GameGate>
              }
            />
            <Route
              path="/builder"
              element={
                <GameGate>
                  <AppPage title="PFP Builder">
                    <BuilderPage />
                  </AppPage>
                </GameGate>
              }
            />
            <Route
              path="/coming"
              element={
                <GameGate>
                  <AppPage title="Coming to Solvency">
                    <ComingPage />
                  </AppPage>
                </GameGate>
              }
            />
            <Route
              path="/how-to-play"
              element={
                <GameGate>
                  <AppPage title="How to Play">
                    <HowToPlayPage />
                  </AppPage>
                </GameGate>
              }
            />
            {/* The Seats-era explainer is retired; old links land on the game walkthrough. */}
            <Route
              path="/how-it-works"
              element={
                <GameGate>
                  <Navigate to="/how-to-play" replace />
                </GameGate>
              }
            />
            <Route
              path="/faucet"
              element={
                <GameGate>
                  <AppPage title="Faucet">
                    <FaucetPage />
                  </AppPage>
                </GameGate>
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
                <GameGate>
                  <AppPage title="Portfolio">
                    <PortfolioPage />
                  </AppPage>
                </GameGate>
              }
            />
            {/* Essey Private — preview only (founder standing rule); withheld from the live domain
                until it ships to mainnet. Off the live host the route renders the coming-soon screen,
                so deep-linking /private reaches no shielding UI. */}
            <Route
              path="/private"
              element={
                PRIVATE_ON ? (
                  <AppPage title="Private">
                    <PrivatePage />
                  </AppPage>
                ) : (
                  <ComingSoon
                    eyebrow="Essey Private"
                    title="Coming soon to mainnet."
                    body="Private balances and payments aren't open on the live site yet. When shielding is live you'll be able to hold and move value without it showing on-chain — we're finishing it in the open and will say the moment it's ready."
                  />
                )
              }
            />
            {/* Redemption — preview only (founder standing rule). The reserve is live and adminless
                on mainnet; what is gated is the WRITE surface, so deep-linking /redeem on the live
                host reaches the coming-soon screen and never a burn. */}
            <Route
              path="/redeem"
              element={
                REDEEM_ON ? (
                  <AppPage title="Redeem">
                    <RedeemPage />
                  </AppPage>
                ) : (
                  <ComingSoon
                    eyebrow="Redemption"
                    title="Coming soon to mainnet."
                    body="Redeeming $ESSEY for its slice of the reserve isn't open on the live site yet. The reserve itself is live and adminless — you can read every figure that backs the token on The Floor — and we'll say the moment redemption opens."
                  />
                )
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
            <Route
              path="/treasury"
              element={
                <AppPage title="Treasury">
                  <TreasuryPage />
                </AppPage>
              }
            />
            <Route path="/blog" element={<BlogIndex />} />
            <Route path="/blog/:slug" element={<BlogPost />} />
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
        {/* The Season-Zero play-money banner belongs to the game wing only — on the protocol side it
            would falsely frame the live-mainnet floor as a play-money preview. */}
        {GAME_ON && GAME_PREFIXES.some((p) => pathname.startsWith(p)) && (
          <SeasonBanner />
        )}
        <Outlet />
        <Footer />
      </main>
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

// The protocol front door's live/roadmap ledger. A green ("audited") stamp is on chain and checkable;
// a grey ("scoped") stamp is designed but not deployed — never claimable, never shown as live. Every
// address here is verified against reserve.ts:44-46. Keep this honest: this list is the whole pitch.
const LANDING_CARDS: {
  to: string;
  icon: string;
  nm: string;
  sub: string;
  live: boolean;
  badge: string;
  line: string;
}[] = [
  {
    to: "/treasury",
    icon: "◈",
    nm: "$ESSEY — the token",
    sub: "fixed supply, adminless",
    live: true,
    badge: "live · mainnet",
    line: "8.888B minted once, no mint key, no admin. The chip you hold; a claim on the floor beneath it.",
  },
  {
    to: "/treasury",
    icon: "⚖",
    nm: "The floor — the reserve",
    sub: "real tokenized equities",
    live: true,
    badge: "live · mainnet",
    line: "An adminless reserve of on-chain stock. Redeem pro-rata against whatever it holds, minus a 5% exit fee. Backing only rises.",
  },
  {
    to: "/holder",
    icon: "▦",
    nm: "Holder basket & claim",
    sub: "choose your split",
    live: false,
    badge: "coming",
    line: "Pick which stocks your share of the floor pays out in, then claim it each epoch. Designed and scoped — not yet on chain.",
  },
  {
    to: "/lend",
    icon: "⇄",
    nm: "Borrow against your stock",
    sub: "a loan, not a sale",
    live: false,
    badge: "coming",
    line: "Post your tokenized equities and borrow against them without selling. The lending engine is built; mainnet activation is ahead.",
  },
  {
    to: "/private",
    icon: "◐",
    nm: "Shielded claim",
    sub: "hold and claim unseen",
    live: false,
    badge: "experimental",
    line: "Turn on private shielding to hold and claim your stock without revealing amounts. Experimental — not yet live on mainnet.",
  },
];

/// The Essey protocol front door. Someone who bought $ESSEY lands here and can do everything on the
/// protocol side without ever touching the Dons game — the game is one door, opened only on purpose.
function Landing() {
  useEffect(() => {
    document.title =
      "Essey · a token backed by a floor of real tokenized equities";
  }, []);
  return (
    <>
      {/* The claim, honest: the floor is live; the rest is labeled roadmap below, not asserted here. */}
      <section className="band">
        <div className="wrap">
          <div className="band-head">
            <div>
              <span className="eyebrow">Essey · the protocol</span>
              <h2>
                A token backed by a floor of <em>real tokenized equities</em>.
              </h2>
              <p>
                $ESSEY is pegged to a reserve of on-chain tokenized stock —
                adminless, claim-based, redeemable pro-rata against whatever the
                floor holds. Fixed supply, no mint key, backing that only rises.
                The floor is live on Robinhood Chain mainnet today; everything
                else on this page says plainly what is built and what is still
                ahead.
              </p>
            </div>
          </div>
          <div className="hero-cta">
            <Link className="btn btn-gold" to="/treasury">
              See the floor →
            </Link>
            <Link className="btn btn-ghost" to="/blog/intro">
              Read the thesis
            </Link>
          </div>
          <div className="learn-row">
            $ESSEY <code>0x315790…1610</code> · EsseyReserve{" "}
            <code>0xd970Ca…5A7b</code> — both adminless, live on mainnet.{" "}
            <Link to="/explorer">Verify on the explorer →</Link>
          </div>
        </div>
      </section>

      {/* The honest ledger — what is real today, what is coming, one badged card each. */}
      <section className="band" style={{ paddingTop: 8 }}>
        <div className="wrap">
          <div className="band-head">
            <div>
              <span className="eyebrow">Live &amp; roadmap</span>
              <h2>What is real today, and what is coming</h2>
              <p>
                No vapor. A green stamp is on chain right now and you can check
                it yourself. A grey stamp is designed and scoped — not deployed,
                not claimable, not live.
              </p>
            </div>
          </div>
          <div className="mech-grid">
            {LANDING_CARDS.map((c) => {
              // The Holder Hub card STAYS as an honest roadmap card, but its link is inert on the live
              // domain (where /holder redirects home) — render it as a plain div there, not a Link.
              const inert = !HOLDER_ON && c.to === "/holder";
              const inner = (
                <>
                  <span
                    className="mech-hit"
                    style={{ cursor: inert ? "default" : "pointer" }}
                  >
                    <span className="mech-icon" aria-hidden>
                      {c.icon}
                    </span>
                    <span className="mech-nm">
                      {c.nm}
                      <i>{c.sub}</i>
                    </span>
                    <span
                      className={
                        "mech-status " + (c.live ? "audited" : "scoped")
                      }
                    >
                      {c.badge}
                    </span>
                  </span>
                  <p className="mech-line">{c.line}</p>
                </>
              );
              return inert ? (
                <div className="mech-card" key={c.nm}>
                  {inner}
                </div>
              ) : (
                <Link className="mech-card" to={c.to} key={c.nm}>
                  {inner}
                </Link>
              );
            })}
          </div>
        </div>
      </section>

      {/* The Dons game — the wing you only reach by going looking. Bridged, never in the way. */}
      {/* The game entrance from the protocol front door — withheld on the live domain (GAME_ON false),
          where the whole wing is preview-only, so nothing advertises a door that lands on coming-soon. */}
      {GAME_ON && (
        <section className="band" style={{ paddingTop: 8 }}>
          <div className="wrap">
            <div className="start-cta plate">
              <div>
                <span className="eyebrow">Also by Essey · a separate wing</span>
                <h2>D.O.N. — the on-chain game</h2>
                <p>
                  Essey also runs a game: 8,888 Don NFTs work the city of
                  Solvency for provably-fair odds against a provably-solvent
                  house. It runs in play-money Scrip and is entirely optional —
                  a Don is also a holder, so you can flip between the game and
                  your holdings whenever you like.
                </p>
              </div>
              <Link className="btn btn-gold start-cta-btn" to="/dons">
                Enter the game →
              </Link>
            </div>
          </div>
        </section>
      )}
    </>
  );
}

/// The Dons wing's own front door — the game marketing that used to live at "/". A Don is also a
/// holder, so this page bridges back to the protocol-side Holder Hub and the live floor.
function DonsLanding() {
  useEffect(() => {
    document.title = "D.O.N. — the on-chain city of Solvency · Essey";
  }, []);
  return (
    <>
      <GameHero />
      <GameLoop />
      {/* The game's own terms — the Scrip / play-money / house-edge specifics scoped to the game wing,
          off the protocol front door where they don't belong. */}
      <section className="band" style={{ paddingTop: 8 }}>
        <div className="wrap">
          <div className="hw-note">
            <b>Season Zero — the game terms.</b> D.O.N. runs in play-money
            Scrip: nothing you win here is real stock. Every roll's odds are
            published on-chain before you pay, and the house keeps an edge —
            across the city, roughly 10 of every 100 Scrip staked on a gamble
            stays with the house. <b>Banked is sacred:</b> no mechanic, robbery,
            or admin can touch your Vault — only what you deploy is ever at
            risk. <b>Exits are free, forever.</b>
          </div>
        </div>
      </section>
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

      {/* The bridge — a Don is also a holder. Its only action is the Holder Hub, which is preview-only,
          so the whole band is withheld on the live domain (where /holder redirects home) and returns
          intact once the hub goes live. */}
      {HOLDER_ON && (
        <section className="band" style={{ paddingTop: 8 }}>
          <div className="wrap">
            <div className="start-cta">
              <div>
                <span className="eyebrow">Your other half</span>
                <h2>A Don is also a holder</h2>
                <p>
                  Every Don is an $ESSEY holder too. Flip from the game to your
                  holder view — the live floor that backs the token, and the
                  Holder Hub where you choose your basket and claim your share.
                </p>
              </div>
              <Link className="btn btn-ghost start-cta-btn" to="/holder">
                Open the Holder Hub →
              </Link>
            </div>
          </div>
        </section>
      )}

      {/* Essey Private — the privacy layer. */}
      <section className="band" style={{ paddingTop: 8 }}>
        <div className="wrap">
          <div className="start-cta plate">
            <div>
              <span className="eyebrow">
                Essey Private · experimental · not yet live
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
              "Essey — the protocol",
              [
                ["/treasury", "The Floor"],
                ["/holder", "Holder Hub"],
                ["/private", "Private"],
                ["/explorer", "Explorer"],
              ],
            ],
            [
              "Learn",
              [
                ["/blog", "Blog"],
                ["/docs", "Technical docs"],
                ["/tape", "The Tape"],
                ["/provable", "Provable"],
                ["/engine", "The engine"],
              ],
            ],
            [
              "D.O.N. — the game",
              [
                ["/dons", "The game"],
                ["/game", "Play"],
                ["/builder", "Mint"],
                ["/market", "Trade"],
                ["/portfolio", "Portfolio"],
                ["/dons/explorer", "Solvency Scan"],
              ],
            ],
          ] as const
        )
          .filter(([h]) => GAME_ON || h !== "D.O.N. — the game")
          .map(([h, links]) => (
            <div className="foot-col" key={h}>
              <span className="fc-h">{h}</span>
              {/* The Holder Hub is preview-only: drop its footer link on the live domain, where the
                page redirects home — nothing should advertise a route that bounces. */}
              {links
                .filter(([to]) => HOLDER_ON || to !== "/holder")
                .filter(([to]) => PRIVATE_ON || to !== "/private")
                .map(([to, label]) => (
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
            <b>The base layer is live on Robinhood Chain mainnet</b> — the
            $ESSEY token and its adminless on-chain floor reserve. Everything
            else on this site says plainly whether it is live, or built and not
            yet open. $ESSEY is <b>not tradable at this time</b>; no market has
            been seeded against it. "Payout," never "dividend": protocol fee
            distributions are mechanically LP-style fee-shares, not dividends,
            not yield promises, and no payout is guaranteed, ever. The contracts
            are adversarially audited, with the rounds published in the
            technical docs. The D.O.N. game is <b>not open here</b>: it runs on
            a test network in play-money Scrip with no real value, and nothing
            in it is real stock.{" "}
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
          {/* Curated current-rounds view, not the raw GitHub tree — the reading room's Audits group
              shows the clean market-layer rounds; superseded Sui/Solidity rounds stay in the repo. */}
          <Link to="/docs">Audits</Link>
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
        {DOC_SECTIONS.map((sec) => {
          const inSection = DOCS.filter((d) => d.section === sec.key);
          if (inSection.length === 0) return null;
          return (
            <div className="doc-section" key={sec.key}>
              <div className="doc-section-h">{sec.label}</div>
              {sec.groups.map((g) => {
                const inGroup = inSection.filter((d) => d.group === g);
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
                            {/* DOCS_BRANCH, not "main": the site renders the built checkout, and some
                                docs haven't merged yet — a main link would 404. Self-heals at merge. */}
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
