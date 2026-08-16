// /game — the D.O.N. dossier interface. One grammar, two materials: the desk (Material A, chain
// truth) always underneath; case files (Material B, the fiction) slide over it, driven by the URL:
//   /game                 the desk
//   /game/jobs            job board (folder drawer)
//   /game/jobs/:brief     mission dossier, stacked over the board (2-deep max)
//   /game/don/:id         a Don's case file
//   /game/crew            hitter rap sheets
//   /game/house           the house property file
//   /game/raid            stakeout (target list)
//   /game/raid/:target    hit order → envelope → after-action, stacked over the stakeout
import { useMemo, useState } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { useWallet } from "../wallet";
import { niceError } from "../live";
import { pub, gameSend, GAME_ADDR, loadGarrisonSecret } from "./gameChain";
import { missionBoardAbi } from "./gameAbi";
import { GameCtx, useGame, useGameStateValue, useCountdown } from "./useGame";
import {
  BRIEFS,
  BRIEF_ORDER,
  SEASON,
  HOUSE_TIERS,
  type BriefKey,
} from "./briefs";
import {
  DonStats,
  DonTraits,
  SORTS,
  traitText,
  useTraitIndex,
} from "../don-traits";
import { DonImg, Stamp, fmtAmt } from "./bits";
import { JobBoardFile, DossierFile } from "./jobs";
import { HouseFile } from "./house";
import { StakeoutFile, HitOrderFile } from "./raid";
import { CrewFile } from "./crew";
import { DonFile } from "./donfile";
import { SpreadStrip } from "./spread";
import "./game.css";

const TABS = [
  ["desk", "DESK"],
  ["jobs", "JOBS"],
  ["raid", "RAID"],
  ["crew", "CREW"],
  ["house", "HOUSE"],
] as const;

/// The Tape's postings count, derived so it can never drift from the board again (it read "four"
/// through two brief additions). Falls back to the digit past the spelled-out range.
const NUMBER_WORDS = [
  "no",
  "one",
  "two",
  "three",
  "four",
  "five",
  "six",
  "seven",
  "eight",
  "nine",
  "ten",
];
const WIRE_COUNT_WORD =
  NUMBER_WORDS[BRIEF_ORDER.length] ?? String(BRIEF_ORDER.length);

export function GamePage() {
  const state = useGameStateValue();
  return (
    <GameCtx.Provider value={state}>
      <div className="game-root">
        <Phone />
      </div>
    </GameCtx.Provider>
  );
}

function Phone() {
  const { pathname } = useLocation();
  const navigate = useNavigate();
  const segs = useMemo(
    () =>
      pathname
        .replace(/^\/game\/?/, "")
        .split("/")
        .filter(Boolean),
    [pathname],
  );
  const view = segs[0] ?? "desk";
  const briefKey: BriefKey | null =
    view === "jobs" && segs[1] && segs[1] in BRIEFS
      ? (segs[1] as BriefKey)
      : null;
  const donParam =
    view === "don" && segs[1] && /^\d+$/.test(segs[1]) ? BigInt(segs[1]) : null;
  const raidTarget =
    view === "raid" && segs[1] && /^\d+$/.test(segs[1])
      ? BigInt(segs[1])
      : null;
  const fileOpen = view !== "desk";
  const toDesk = () => navigate("/game");

  return (
    <div className={"g-phone" + (fileOpen ? " file-open" : "")}>
      <Desk />
      <div className="g-scrim" aria-hidden />

      <JobBoardFile
        open={view === "jobs"}
        under={briefKey !== null}
        onClose={toDesk}
      />
      <DossierFile
        briefKey={briefKey}
        open={briefKey !== null}
        onClose={() => navigate("/game/jobs")}
      />
      <DonFile donId={donParam} open={donParam !== null} onClose={toDesk} />
      <CrewFile open={view === "crew"} onClose={toDesk} />
      <HouseFile open={view === "house"} onClose={toDesk} />
      <StakeoutFile
        open={view === "raid"}
        under={raidTarget !== null}
        onClose={toDesk}
      />
      <HitOrderFile
        targetDonId={raidTarget}
        open={raidTarget !== null}
        onClose={() => navigate("/game/raid")}
      />

      <nav className="g-tabbar" aria-label="game views">
        {TABS.map(([key, label]) => (
          <button
            key={key}
            className={
              view === key || (key === "desk" && view === "don") ? "on" : ""
            }
            onClick={() => navigate(key === "desk" ? "/game" : `/game/${key}`)}
          >
            {label}
          </button>
        ))}
      </nav>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------
// THE DESK — the world layer. Season header, your Dons as case-file objects, the ledger strip
// (money truth, Material A), the tape.
// ---------------------------------------------------------------------------------------------
function Desk() {
  const g = useGame();
  const w = useWallet();
  const navigate = useNavigate();
  const [deskOpen, setDeskOpen] = useState(false);
  const [deskQ, setDeskQ] = useState("");
  const [deskHome, setDeskHome] = useState(false);
  const [compare, setCompare] = useState<string[]>([]);
  const [sortBy, setSortBy] = useState("");
  const don = g.selected;
  const traitIndex = useTraitIndex(
    deskOpen ? (g.dons ?? []).map((d) => d.id) : [],
  );
  const shown = (g.dons ?? []).filter((d) => {
    if (deskHome && d.away) return false;
    const q = deskQ.trim().toLowerCase();
    if (!q) return true;
    return (
      `№${d.id}`.includes(q) ||
      String(d.id).includes(q) ||
      traitText(traitIndex[String(d.id)]).includes(q)
    );
  });
  const sorter = SORTS.find((x) => x.key === sortBy);
  if (sorter) {
    // Sheets arrive progressively, so the order settles as they land; un-sheeted Dons sink to the
    // bottom rather than reading as zeroes ranked alongside a genuine zero.
    shown.sort((a, b) => {
      const sa = traitIndex[String(a.id)]?.stats;
      const sb = traitIndex[String(b.id)]?.stats;
      return (sb ? sorter.of(sb) : -1) - (sa ? sorter.of(sa) : -1);
    });
  }
  const away = (g.dons ?? []).filter((d) => d.away).length;
  const toggleCompare = (id: string) =>
    setCompare((c) =>
      c.includes(id)
        ? c.filter((x) => x !== id)
        : c.length >= 3
          ? c
          : [...c, id],
    );
  const cd = useCountdown(don?.away ? don.dueMs : null);
  const [resolving, setResolving] = useState(false);
  const [resolveErr, setResolveErr] = useState<string | null>(null);

  // Missions roll at expiry, permissionlessly: resolve(missionId) + the entropy fee. The keeper
  // normally runs it, but the player can always call their own Don home.
  const due = don?.away && don.dueMs !== null && don.dueMs <= Date.now();
  const resolveMission = async () => {
    if (!g.address || !don || don.missionId === 0n || resolving) return;
    setResolveErr(null);
    setResolving(true);
    try {
      let fee = 0n;
      try {
        fee = await pub.readContract({
          address: GAME_ADDR.missionBoard,
          abi: missionBoardAbi,
          functionName: "entropyFee",
        });
      } catch {
        /* optional */
      }
      await gameSend(
        g.address,
        GAME_ADDR.missionBoard,
        missionBoardAbi,
        "resolve",
        [don.missionId],
        fee,
        1_000_000n,
      );
      g.refresh();
    } catch (e) {
      setResolveErr(niceError(e));
    } finally {
      setResolving(false);
    }
  };

  return (
    <div className="g-desk">
      <div className="g-topnav">
        <div className="g-brand">
          SOLVENCY <i>▾</i>
        </div>
        <div
          className="g-scrip"
          title="season Scrip — the settlement points of the current season"
        >
          ◫ SCRIP <b>{g.scrip !== null ? fmtAmt(g.scrip) : "—"}</b>
        </div>
      </div>
      <div className="g-season">
        <span>
          SEASON {g.seasonId} · {SEASON.name}
        </span>
        <span>{g.configured ? "live" : "posts soon"}</span>
      </div>

      {/* wallet / ownership states — each one is a paper object with one honest message */}
      {!g.ready ? null : !g.address ? (
        <div className="g-cta">
          <div className="g-cta-h">NO FILE ON THE DESK</div>
          <p>
            the city keeps a file on every family. connect a wallet and we'll
            pull yours.
          </p>
          <button
            className="g-cta-btn"
            onClick={() => {
              void g.connect();
            }}
          >
            CONNECT A WALLET
          </button>
        </div>
      ) : !g.connected ? (
        <div className="g-cta">
          <div className="g-cta-h">WRONG DISTRICT</div>
          <p>
            your wallet is connected, but not to Robinhood Chain. switch
            networks and the desk fills in.
          </p>
          <button
            className="g-cta-btn"
            onClick={() => {
              void w.switchChain();
            }}
          >
            SWITCH TO ROBINHOOD CHAIN
          </button>
        </div>
      ) : g.dons === null ? (
        <div className="g-cta">
          <div className="g-cta-h">PULLING THE FILES…</div>
          <p>reading the Ledger. it has never once been wrong.</p>
        </div>
      ) : g.dons.length === 0 ? (
        <div className="g-cta">
          <div className="g-cta-h">NO SEAT AT THE TABLE</div>
          <p>
            8,888 signatures on the Ledger, and none of them is yours — yet. a
            Don is a seat, a share of the Floor, a deed, and a face. the
            Registry is minting.
          </p>
          <Link className="g-cta-btn" to="/builder">
            ACQUIRE A DON · THE REGISTRY →
          </Link>
        </div>
      ) : (
        <>
          {don && (
            <button
              className="g-deskcard"
              onClick={() => navigate(`/game/don/${don.id.toString()}`)}
              aria-label={`open the case file of Don ${don.id.toString()}`}
            >
              <div className="g-row">
                <div className="g-ph">
                  <DonImg id={don.id} alt="" />
                </div>
                <div style={{ minWidth: 0 }}>
                  <h3>DON №{don.id.toString()}</h3>
                  <div className="g-sub">
                    {don.deedTier !== null
                      ? `${HOUSE_TIERS[Math.min(don.deedTier, 4)]} on file`
                      : "founding family"}
                  </div>
                  <div style={{ margin: "6px 0 2px" }}>
                    <Stamp ok={!don.away} style={{ fontSize: 11 }}>
                      {don.away ? "DEPARTED" : "HOME"}
                    </Stamp>
                  </div>
                  {don.away && (
                    <div className="g-cd">
                      <small>
                        {don.briefId !== null
                          ? `BRIEF №${don.briefId.toString()} · returns in`
                          : "returns in"}
                      </small>
                      <br />
                      {cd}
                    </div>
                  )}
                </div>
              </div>
            </button>
          )}
          {due && don && (
            <div style={{ textAlign: "center", margin: "6px 0" }}>
              <button
                className="g-stampbtn ok"
                disabled={resolving}
                onClick={(e) => {
                  e.stopPropagation();
                  void resolveMission();
                }}
              >
                {resolving ? "ROLLING…" : "CALL IT IN · RESOLVE THE JOB"}
              </button>
              {resolveErr && <div className="g-err">{resolveErr}</div>}
            </div>
          )}
          {g.dons.length > 1 && (
            <div className="g-chips">
              {g.dons.map((d) => (
                <button
                  key={d.id.toString()}
                  className={"g-chip" + (don?.id === d.id ? " on" : "")}
                  onClick={() => g.setSelectedId(d.id)}
                >
                  <span className="g-chip-ph">
                    <DonImg id={d.id} alt="" />
                  </span>
                  №{d.id.toString()}{" "}
                  <i className={d.away ? "away" : ""}>
                    {d.away ? "AWAY" : "HOME"}
                  </i>
                </button>
              ))}
              <button
                className="g-chip g-chip-more"
                onClick={() => setDeskOpen((o) => !o)}
              >
                {deskOpen ? "close desk" : `open the desk (${g.dons.length})`}
              </button>
            </div>
          )}
          {deskOpen && (
            <div className="g-desk">
              <div className="g-cap">
                <span>
                  The desk — {shown.length} of {g.dons.length}
                </span>
                <input
                  className="g-desk-find"
                  value={deskQ}
                  placeholder="filter by trait, name or №"
                  onChange={(e) => setDeskQ(e.target.value)}
                />
                <button
                  className={"g-desk-toggle" + (deskHome ? " on" : "")}
                  onClick={() => setDeskHome((v) => !v)}
                  disabled={!away}
                  title={
                    away ? `${away} out on jobs` : "every Don you hold is home"
                  }
                >
                  {deskHome
                    ? "showing home only"
                    : away
                      ? `hide the ${away} away`
                      : "all home"}
                </button>
                <select
                  className="g-desk-sort"
                  value={sortBy}
                  onChange={(e) => setSortBy(e.target.value)}
                >
                  <option value="">no order</option>
                  {SORTS.map((x) => (
                    <option key={x.key} value={x.key}>
                      by {x.label}
                    </option>
                  ))}
                </select>
              </div>
              <div className="g-desk-grid">
                {shown.map((d) => (
                  <div key={d.id.toString()} className="g-desk-slot">
                    <span
                      role="checkbox"
                      tabIndex={0}
                      aria-checked={compare.includes(d.id.toString())}
                      className={
                        "g-desk-pick" +
                        (compare.includes(d.id.toString()) ? " on" : "")
                      }
                      title={
                        compare.length >= 3 &&
                        !compare.includes(d.id.toString())
                          ? "three at a time — drop one first"
                          : "hold side by side (up to 3)"
                      }
                      onClick={() => toggleCompare(d.id.toString())}
                      onKeyDown={(e) =>
                        e.key === "Enter" && toggleCompare(d.id.toString())
                      }
                    >
                      vs
                    </span>
                    <button
                      className={
                        "g-desk-card" + (don?.id === d.id ? " on" : "")
                      }
                      onClick={() => {
                        g.setSelectedId(d.id);
                        setDeskOpen(false);
                      }}
                    >
                      <span className="g-desk-ph">
                        <DonImg id={d.id} alt="" />
                      </span>
                      <span className="g-desk-h">
                        №{d.id.toString()}{" "}
                        <i className={d.away ? "away" : ""}>
                          {d.away ? "AWAY" : "HOME"}
                        </i>
                      </span>
                      <DonTraits id={d.id} only={4} />
                    </button>
                  </div>
                ))}
              </div>
              {!shown.length && (
                <div className="live-note">No Don matches that filter.</div>
              )}
              {compare.length > 1 && (
                <div className="g-vs">
                  <div className="g-cap">
                    <span>Side by side</span>
                    <button
                      className="g-desk-toggle"
                      onClick={() => setCompare([])}
                    >
                      clear
                    </button>
                  </div>
                  <div className="g-vs-row">
                    {compare.map((id) => (
                      <div key={id} className="g-vs-col">
                        <div className="g-vs-h">
                          <DonImg id={BigInt(id)} alt="" />
                          <span>№{id}</span>
                        </div>
                        <DonStats id={BigInt(id)} />
                        <DonTraits id={BigInt(id)} />
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}

          <div className="g-ledgerstrip">
            <div className="g-cap">
              <span>
                {don?.deedTier !== null && don
                  ? `Property — ${HOUSE_TIERS[Math.min(don.deedTier ?? 0, 4)]}`
                  : "Property — no deed on file"}
              </span>
              <span>ledger</span>
            </div>
            {g.configured && don ? (
              <>
                <div className="g-lrow">
                  <span>VAULT (banked)</span>
                  <b>
                    ◫ {fmtAmt(don.vaultScrip)}{" "}
                    <span className="ok">never at risk</span>
                  </b>
                </div>
                <div className="g-lrow">
                  <span>HOUSE (working)</span>
                  <b>
                    ◫ {fmtAmt(don.deployedScrip)}
                    {don.away && don.deployedScrip > 0n ? (
                      <span className="warnc"> · EXPOSED ⚠</span>
                    ) : null}
                  </b>
                </div>
                <div className="g-lrow">
                  <span>HOPPER (unbanked)</span>
                  <b>
                    ◫ {fmtAmt(don.hopperScrip)}
                    {don.hopperScrip > 0n ? (
                      don.away ? (
                        <span className="warnc"> · at risk on the board</span>
                      ) : (
                        <Link
                          to="/game/house"
                          className="warnc"
                          style={{ textDecoration: "underline" }}
                        >
                          {" "}
                          · BANK IT NOW →
                        </Link>
                      )
                    ) : null}
                  </b>
                </div>
                <div className="g-lrow">
                  <span>GARRISON</span>
                  <b>
                    {Math.min(
                      (g.address
                        ? loadGarrisonSecret(g.address, don.id)?.hitterIds
                            .length
                        : 0) ?? 0,
                      don.garrisonSlots,
                    )}
                    /{don.garrisonSlots || "—"}{" "}
                    <span className="ok">on the door</span>
                  </b>
                </div>
              </>
            ) : (
              <>
                <div className="g-lrow">
                  <span>VAULT</span>
                  <b>
                    <span className="ok">never at risk</span>
                  </b>
                </div>
                <div className="g-lrow">
                  <span>HOUSE (working)</span>
                  <b>
                    —{" "}
                    <span style={{ color: "var(--g-tx-faint)" }}>
                      posts with the season
                    </span>
                  </b>
                </div>
                <div className="g-lrow">
                  <span>GARRISON</span>
                  <b>—</b>
                </div>
              </>
            )}
          </div>

          {/* THE SPREAD — the family-wide view under the selected Don's ledger. Same reads, one
              level up: how the whole family's Scrip sits across its Houses (OG-4). */}
          <SpreadStrip />

          <div className="g-tapefeed">
            {don?.away && (
              <div className="g-tape-row">
                <span className="t">now</span>
                <span className="fresh">▸</span>
                <span>
                  your Don is in the field — <b>the House stands open</b>. both
                  facts print on the Tape.
                </span>
              </div>
            )}
            <div className="g-tape-row">
              <span className="t">—</span>
              <span>
                word is out: <b>{SEASON.name.toUpperCase()}</b>{" "}
                {g.configured ? "is live" : "posts soon"}. {WIRE_COUNT_WORD}{" "}
                wires on the board, and the doors are already getting kicked.
              </span>
            </div>
            <div className="g-tape-row">
              <span className="t">—</span>
              <span>
                the dispatcher never lies. open <b>JOBS</b> and read THE WORD
                for yourself.
              </span>
            </div>
            <div className="g-tape-row">
              <span className="t">—</span>
              <span>
                the Snitch was retained. by whom, the Tape declines to say.
              </span>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
