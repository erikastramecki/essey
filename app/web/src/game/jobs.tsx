// The Job Board (folder drawer) + the Mission Dossier (flagship slide-over): the live odds
// ladder off the on-chain cumPpm bands, provisioning (burned Scrip boosting the success payout
// at betaBps — the AS-BUILT mechanic), and the wax seal firing the REAL depart tx: sign the
// EIP-712 loadout (garrison commit rides the same signature), then MissionBoard.depart(l, sig).
// Entropy is requested at RESOLVE, not depart — the depart tx carries no ETH.
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { niceError } from "../live";
import { gameSend, GAME_ADDR, saveGarrisonSecret } from "./gameChain";
import { missionBoardAbi } from "./gameAbi";
import {
  garrisonCommit,
  buildLoadout,
  signLoadout,
  randomSalt,
} from "./loadout";
import { BRIEFS, BRIEF_ORDER, type BriefKey } from "./briefs";
import { useGame } from "./useGame";
import {
  CaseFile,
  WaxSeal,
  Stamp,
  RatingStamp,
  OddsLadder,
  PaperClip,
  DonImg,
  fmtAmt,
} from "./bits";
import { ExhibitStill } from "./stills";

// ---------------------------------------------------------------------------------------------
// THE JOB BOARD — the folder drawer
// ---------------------------------------------------------------------------------------------
export function JobBoardFile({
  open,
  under,
  onClose,
}: {
  open: boolean;
  under: boolean;
  onClose: () => void;
}) {
  const navigate = useNavigate();
  return (
    <CaseFile
      open={open}
      under={under}
      tab="THE JOB BOARD · FOLDER DRAWER"
      head="DISPATCH · OPEN POSTINGS"
      onClose={onClose}
    >
      {/* The Scrip faucet, spelled out — testers kept looking for a claim button (founder report). */}
      <button
        className="g-target"
        style={{ width: "100%", marginBottom: 10, textAlign: "left" }}
        onClick={() => navigate("/game/jobs/sprint")}
      >
        <div className="g-tmeta" style={{ width: "100%" }}>
          <b>NEW IN TOWN? START HERE.</b> Scrip is earned, never claimed. Your
          first job mints a free Safehouse and a <b>◫ 50</b> starter stake, so
          run the <b>MILK RUN</b> (75 seconds, pays <b>◫ 6,000</b> on a
          near-sure wire) and you can retain a Hitter (◫ 900), file hit orders
          (◫ 50), and build the House — all off one job. When it lands,{" "}
          <b>BANK IT</b> at the House desk: it sits in the hopper, raidable,
          until you do.
        </div>
      </button>
      <div className="g-drawer">
        {BRIEF_ORDER.map((k) => {
          const j = BRIEFS[k];
          return (
            <button
              key={k}
              className={"g-jobfolder" + (j.featured ? " featured" : "")}
              data-tab={j.tab}
              onClick={() => navigate(`/game/jobs/${k}`)}
            >
              <div className="g-jf-top">
                <span className="g-jf-code">
                  {j.code}
                  {j.featured && <i> ★</i>}
                </span>
                <span className="g-jf-take">
                  ▸ <b>◫ {fmtAmt(j.successPay)}</b> · {j.durationH}h
                </span>
              </div>
              <div className="g-jf-mid">
                <span className="g-jf-risk">
                  risk{" "}
                  {Array.from({ length: 8 }, (_, i) =>
                    i < j.riskBlocks ? (
                      <b key={i}>▮</b>
                    ) : (
                      <span key={i}>▮</span>
                    ),
                  )}
                </span>
                <RatingStamp rating={j.rating}>{j.ratingLabel}</RatingStamp>
              </div>
            </button>
          );
        })}
        {/* one locked folder — level-gated, strapped shut */}
        <div
          className="g-jobfolder locked"
          data-tab="the exchange raid · float squeeze"
          aria-disabled
        >
          <div className="g-jf-top">
            <span className="g-jf-code">SHORT FUSE</span>
            <span className="g-jf-take">
              ▸ <b>GME</b> · 5h
            </span>
          </div>
          <div className="g-jf-mid">
            <span className="g-jf-risk">
              risk <b>▮▮▮▮▮▮</b>▮▮
            </span>
            <RatingStamp rating="steep">STEEP</RatingStamp>
          </div>
          <div className="g-strap">REQUIRES LEVEL 9</div>
        </div>
      </div>
      <p className="g-note" style={{ marginTop: 14 }}>
        the dispatcher never lies. if the odds are bad, THE WORD says so.
      </p>
    </CaseFile>
  );
}

// ---------------------------------------------------------------------------------------------
// THE MISSION DOSSIER — one parameterized component for every brief
// ---------------------------------------------------------------------------------------------
type Phase = "idle" | "signing" | "submitting" | "departed" | "error";

/// Provision presets — fractions of the brief's on-chain provisionCap. Provision burns at
/// dispatch and boosts the SUCCESS payout by provision × betaBps / 1e4 (odds never change).
// HouseEscrow.STIPEND — minted by ensureHouse INSIDE the first depart tx, so a Don with deedId 0n
// can spend it in the very tx that mints it.
const STIPEND = 50n * 10n ** 18n;

const PROV_STEPS = [
  { label: "none", num: 0n, den: 1n },
  { label: "½ cap", num: 1n, den: 2n },
  { label: "full cap", num: 1n, den: 1n },
] as const;

export function DossierFile({
  briefKey,
  open,
  onClose,
}: {
  briefKey: BriefKey | null;
  open: boolean;
  onClose: () => void;
}) {
  const g = useGame();
  const brief = briefKey ? BRIEFS[briefKey] : null;
  const [provIdx, setProvIdx] = useState(0);
  const [phase, setPhase] = useState<Phase>("idle");
  const [err, setErr] = useState<string | null>(null);
  const [departedAt, setDepartedAt] = useState<string | null>(null);

  // Opening a fresh dossier resets the working state to that brief's defaults.
  useEffect(() => {
    if (open && brief) {
      setProvIdx(0);
      setPhase("idle");
      setErr(null);
      setDepartedAt(null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, briefKey]);

  if (!brief) return null;

  const don = g.selected;
  const departed = phase === "departed";
  const busy = phase === "signing" || phase === "submitting";

  const step = PROV_STEPS[provIdx];
  const provision = (brief.provisionCap * step.num) / step.den;
  const boost = (provision * brief.betaBps) / 10_000n;

  const cost = brief.dispatchFee + provision;
  const spendable =
    (don?.vaultScrip ?? 0n) + (don && don.deedId === 0n ? STIPEND : 0n);

  // Why the seal might be inert — one honest sentence at a time.
  const gate = !g.configured
    ? "THE BOARD POSTS WITH THE SEASON · CONTRACTS PENDING"
    : !g.connected
      ? "CONNECT A WALLET TO SIGN"
      : !don
        ? "NO DON ON THE DESK — VISIT THE REGISTRY"
        : don.away
          ? (g.dons ?? []).some((d) => !d.away)
            ? "THIS DON IS IN THE FIELD — SWITCH OPERATIVES AT THE DESK"
            : "YOUR DON IS IN THE FIELD"
          : cost > spendable
            ? `THIS RUN COSTS ◫ ${fmtAmt(cost, 1)} · THE VAULT HOLDS ◫ ${fmtAmt(spendable, 1)} — CARRY LESS`
            : null;

  const depart = async () => {
    if (gate || !don || !g.address || busy || departed) return;
    setErr(null);
    try {
      // 1. Garrison commit — freezes at depart for the whole away window (the gas law). The launch UI
      //    ships no garrison picker, and an EMPTY garrison must go up as bytes32(0) — "openly
      //    ungarrisoned" — NOT as a salted hash of an empty roster (UI-verify F2): a hashed empty
      //    roster earns zero extra defense but makes every raid against this Don wait the full 1h
      //    unrevealed-garrison timeout before settling, for nothing. bytes32(0) settles instantly.
      //    When the garrison picker ships, a non-empty roster goes back to garrisonCommit(ids, salt).
      const salt = randomSalt();
      const garrisonIds: bigint[] = [];
      const gHash =
        garrisonIds.length > 0
          ? garrisonCommit(garrisonIds, salt)
          : (("0x" + "0".repeat(64)) as `0x${string}`);
      saveGarrisonSecret(g.address, don.id, { hitterIds: [], salt });
      // 2. The EIP-712 loadout: binds briefId + provision + garrison commit in one signature.
      const loadout = await buildLoadout(
        don.id,
        brief.chainId,
        provision,
        gHash,
      );
      setPhase("signing");
      const sig = await signLoadout(g.address, loadout);
      // 3. The one tx: depart(loadout, sig). No ETH — entropy is requested at resolve, not here.
      setPhase("submitting");
      await gameSend(
        g.address,
        GAME_ADDR.missionBoard,
        missionBoardAbi,
        "depart",
        [loadout, sig],
      );
      const now = new Date();
      setDepartedAt(
        `${String(now.getUTCHours()).padStart(2, "0")}:${String(now.getUTCMinutes()).padStart(2, "0")} UTC`,
      );
      setPhase("departed");
      g.refresh();
    } catch (e) {
      setPhase("error");
      setErr(niceError(e));
    }
  };

  const hint = departed
    ? "SIGNED · THE FOLDER IS THE ACTIVE CASE"
    : phase === "signing"
      ? "SIGN THE LOADOUT IN YOUR WALLET…"
      : phase === "submitting"
        ? "SUBMITTING THE DEPART TX…"
        : (gate ?? "CLICK THE SEAL TO SIGN");

  return (
    <CaseFile
      open={open}
      stack2
      tab={`OPERATION BRIEF · №${brief.no}`}
      head="CASE FILE"
      onClose={onClose}
    >
      <div className="g-canon">
        {departed && (
          <Stamp corner thump>
            DEPARTED
          </Stamp>
        )}
        <div className="g-photowin">
          <PaperClip />
          <div className="g-pframe">
            {don ? (
              <DonImg
                id={don.id}
                className="g-pimg"
                alt={`Don №${don.id.toString()} — the operative`}
              />
            ) : (
              <span className="g-pimg g-imgph">NO FILE</span>
            )}
          </div>
          <div className="g-pcap">
            subject · {don ? `don №${don.id.toString()}` : "unassigned"}
          </div>
        </div>
        <div className="g-typedfields">
          <p className="g-serifname">{brief.code}</p>
          <div className="g-tf">
            <label>Archetype</label>
            <b>{brief.arch}</b>
          </div>
          <div className="g-tf">
            <label>Operative</label>
            <b>{don ? `DON №${don.id.toString()}` : "— none on desk"}</b>
          </div>
          <div className="g-tf">
            <label>Clearance</label>
            <b className={don ? "ok" : undefined}>
              {don ? "clears ✓" : "no operative"}
            </b>
          </div>
          <div className="g-tf">
            <label>Rating</label>
            <b>
              {brief.ratingLabel}
              {brief.rating === "unins"
                ? " — the Fixer declines"
                : " (the Fixer quotes on request)"}
            </b>
          </div>
        </div>
      </div>

      <hr className="g-dashrule" />
      <ExhibitStill
        scene={brief.scene}
        ts="CAM 4 · 02:41"
        tag={brief.exhibit}
      />

      <hr className="g-dashrule" />
      <div className="g-typed">
        <p>
          <span className="lbl">THE JOB</span>
          {brief.job}
        </p>
        <p>
          <span className="lbl">THE TAKE</span>
          {brief.takeLine}
        </p>
        <p>
          <span className="lbl">THE RISK</span>
          {brief.risk}
        </p>
        <p>
          <span className="lbl">THE WORD</span>
          {brief.word}
        </p>
      </div>

      <hr className="g-dashrule" />
      <OddsLadder
        odds={brief.odds}
        payout={`◫ ${fmtAmt(brief.partialPay, 1)} sideways · ◫ ${fmtAmt(brief.successPay + boost, 1)} clean`}
      />

      <p className="g-pcap-h" style={{ marginTop: 12 }}>
        DURATION — fixed by the posting
      </p>
      <div className="g-exposure">
        exposure window: {brief.durationH}h — your House is robbable while
        you're away. that sentence is always on the folder.
      </div>

      <p className="g-pcap-h" style={{ marginTop: 14 }}>
        PROVISIONING — burned at dispatch, boosts the clean take
      </p>
      <div className="g-provs">
        {PROV_STEPS.map((p, i) => {
          const amt = (brief.provisionCap * p.num) / p.den;
          return (
            <button
              key={p.label}
              aria-pressed={provIdx === i}
              onClick={() => {
                if (!departed && !busy) setProvIdx(i);
              }}
            >
              {p.label}
              {amt > 0n ? ` · ◫ ${fmtAmt(amt)}` : ""}
            </button>
          );
        })}
      </div>
      <p className="g-provnote">
        provisions are consumed win or lose — the gamble. success pays +◫{" "}
        {fmtAmt(boost, 1)} on top of the posted take. odds never move.
      </p>

      <div className="g-feeline">
        <span>dispatch fee ◫ {fmtAmt(brief.dispatchFee, 2)} · burned</span>
        <span>terms as published on-chain</span>
      </div>

      {err && <div className="g-err">{err}</div>}

      {!departed ? (
        <WaxSeal
          disabled={!!gate || busy}
          sealed={departed}
          hint={hint}
          onCommit={depart}
        />
      ) : (
        <div className="g-departbar">
          <Stamp big thump>
            DEPARTED {departedAt}
          </Stamp>
          <p className="g-provnote" style={{ marginTop: 10 }}>
            folder is now the active case — read-only, reachable from the desk.
            the resolve arrives as a stamp, not a popup.
          </p>
        </div>
      )}
    </CaseFile>
  );
}
