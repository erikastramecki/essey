// The RAID flow — four beats matching the AS-BUILT commit-reveal RaidEngine, each a file in the
// case-file grammar: (1) STAKEOUT target list (surveillance stills of away Dons), (2) HIT ORDER
// on carbon stock with the wax seal firing commit(attackerDonId, h) — the ◫50 commit fee moves
// from the attacker Don's vault, sunk win-or-lose, (3) the sealed envelope while the [10, 40]min
// reveal window runs, (4) the AFTER-ACTION REPORT — settlement lands with the entropy callback,
// so the report polls the RaidSettled event and shows PENDING until the word arrives.
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { parseEventLogs, parseAbiItem } from "viem";
import { niceError } from "../live";
import {
  pub,
  gameSend,
  GAME_ADDR,
  GAME_DEPLOY_BLOCK,
  saveRaidSecret,
  loadRaidSecret,
  clearRaidSecret,
  type RaidSecret,
} from "./gameChain";
import { raidEngineAbi } from "./gameAbi";
import { raidCommitHash, randomSalt } from "./loadout";
import { useGame, useAwayTargets, useCountdown, fmtHMS } from "./useGame";
import { CaseFile, WaxSeal, Stamp, DonImg, BigEnvelope, fmtAmt } from "./bits";

/// RaidEngine constants mirrored for the window UX (REVEAL_DELAY / REVEAL_WINDOW / COMMIT_FEE).
const REVEAL_DELAY_MS = 10 * 60 * 1000;
const REVEAL_WINDOW_MS = 40 * 60 * 1000;
const COMMIT_FEE = 50n * 10n ** 18n;
const MAX_CREW = 5;

// coarse exposure band — bands, not numbers (fog UI): 8 blocks by order of magnitude of Scrip
const band = (v: bigint): number => {
  if (v <= 0n) return 0;
  const scrip = Number(v / 10n ** 18n);
  return Math.max(
    1,
    Math.min(8, Math.floor(Math.log10(Math.max(1, scrip)) * 2)),
  );
};

// ---------------------------------------------------------------------------------------------
// 1) STAKEOUT — the target list (away Dons, own Dons excluded)
// ---------------------------------------------------------------------------------------------
export function StakeoutFile({
  open,
  under,
  onClose,
}: {
  open: boolean;
  under: boolean;
  onClose: () => void;
}) {
  const g = useGame();
  const navigate = useNavigate();
  const { targets } = useAwayTargets((g.dons ?? []).map((d) => d.id));
  return (
    <CaseFile
      open={open}
      under={under}
      jacket="carbon"
      tab="STAKEOUT · TARGETS ON THE TAPE"
      head="SURVEILLANCE · AWAY DONS"
      onClose={onClose}
    >
      <p className="g-typed" style={{ marginBottom: 10 }}>
        every depart prints on the Tape: somewhere, work is getting done — and
        back there, a House is standing open. exposure shows in{" "}
        <b>bands, not numbers</b>. garrisons stay redacted; the commit was
        frozen at their depart.
      </p>
      {!g.configured ? (
        <div className="g-typed">
          <p>
            <span className="lbl">THE WORD</span>the stakeout ledger opens with
            the season. contracts pending — nothing to case yet, and casing
            nothing is free.
          </p>
        </div>
      ) : targets === null ? (
        <p className="g-note">reading the Tape…</p>
      ) : targets.length === 0 ? (
        <div className="g-typed">
          <p>
            <span className="lbl">THE WORD</span>every Don in the city is home
            tonight. patience is also a strategy.
          </p>
        </div>
      ) : (
        targets.map((t) => (
          <TargetRow
            key={t.donId.toString()}
            donId={t.donId}
            dueMs={t.dueMs}
            deployed={t.deployedScrip}
            heatUntilMs={t.heatUntilMs}
            onPick={() => navigate(`/game/raid/${t.donId.toString()}`)}
          />
        ))
      )}
    </CaseFile>
  );
}

function TargetRow({
  donId,
  dueMs,
  deployed,
  heatUntilMs,
  onPick,
}: {
  donId: bigint;
  dueMs: number;
  deployed: bigint;
  heatUntilMs: number;
  onPick: () => void;
}) {
  const cd = useCountdown(dueMs);
  const heatCd = useCountdown(heatUntilMs);
  const b = band(deployed);
  // Heat gate (UI-verify F1): the chain rejects a reveal against a hot target (TargetOnHeat) but the
  // 50-Scrip commit fee burns regardless — so a hot door is shown, marked, and not clickable.
  const hot = Date.now() < heatUntilMs;
  return (
    <button
      className="g-target"
      onClick={hot ? undefined : onPick}
      disabled={hot}
      style={hot ? { opacity: 0.55, cursor: "not-allowed" } : undefined}
    >
      <div className="g-surv">
        <span className="g-ts">CAM 2 · LIVE</span>
        <DonImg
          id={donId}
          alt={`surveillance still — Don №${donId.toString()}`}
        />
      </div>
      <div className="g-tmeta">
        DON №{donId.toString()}
        <br />
        <span className="away">AWAY</span> · returns {cd}
        <br />
        deployed{" "}
        <span className="band">
          <b>{"▮".repeat(b)}</b>
          {"░".repeat(8 - b)}
        </span>
        <br />
        {hot ? (
          <>
            heat{" "}
            <span className="red">TOO HOT · cops on the block · {heatCd}</span>
          </>
        ) : (
          <>
            garrison <span className="red">REDACTED</span>
          </>
        )}
      </div>
    </button>
  );
}

// ---------------------------------------------------------------------------------------------
// 2–4) HIT ORDER → sealed envelope → AFTER-ACTION REPORT
// ---------------------------------------------------------------------------------------------
type RaidPhase =
  "order" | "committing" | "committed" | "revealing" | "report" | "error";

/// RaidSettled outcome (RaidEngine): 0 MISS / 1 COMMON hit / 2 BIG score / 4 RECLAIMED
/// (entropy withheld — settles as a miss). Outcome 3 is never emitted: floorSettle runs the
/// real roll with the garrison counting zero, so it lands as 0/1/2 too.
const OUTCOME_STAMP: Record<number, { label: string; ok: boolean }> = {
  0: { label: "THE DOOR HELD", ok: false },
  1: { label: "HIT LANDED", ok: true },
  2: { label: "BIG SCORE", ok: true },
  4: { label: "NO ROLL · RECLAIMED", ok: false },
};

export function HitOrderFile({
  targetDonId,
  open,
  onClose,
}: {
  targetDonId: bigint | null;
  open: boolean;
  onClose: () => void;
}) {
  const g = useGame();
  const [phase, setPhase] = useState<RaidPhase>("order");
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [err, setErr] = useState<string | null>(null);
  const [outcome, setOutcome] = useState<number | null>(null);
  const [secret, setSecret] = useState<RaidSecret | null>(null);
  const [, tick] = useState(0); // 1s tick while the envelope waits on the reveal window

  // Resume a pending commit across refreshes — the preimage lives in localStorage until reveal.
  // Keyed by connected address + attacker Don (audit fix: a global key let a second commit clobber
  // the first preimage and forfeit its fee).
  useEffect(() => {
    if (!open) return;
    const s =
      g.address && g.selected ? loadRaidSecret(g.address, g.selected.id) : null;
    if (s && targetDonId !== null && s.targetDonId === targetDonId.toString()) {
      setSecret(s);
      setPhase("committed");
      // Stale-envelope guard (full-loop verify): the raid may have settled OUT-OF-BAND (keeper
      // floorSettle / another device) while this order sat closed — showing a live reveal button
      // then would just revert. Check the engine's state and jump straight to the report.
      if (s.raidId !== "" && g.address) {
        const addr = g.address;
        const attackerId = g.selected!.id;
        pub
          .readContract({
            address: GAME_ADDR.raidEngine,
            abi: raidEngineAbi,
            functionName: "raids",
            args: [BigInt(s.raidId)],
          })
          .then((r) => {
            const state = Number((r as readonly unknown[])[9]); // Raid.state — 2 = Settled, 3 = Forfeited
            if (state === 2 || state === 3) {
              clearRaidSecret(addr, attackerId);
              setSecret(null);
              if (state === 2) {
                setPhase("report");
                pub
                  .getLogs({
                    address: GAME_ADDR.raidEngine,
                    event: parseAbiItem(
                      "event RaidSettled(uint64 indexed raidId, uint8 outcome, uint256 pHitPpm, uint256 taken, uint256 tax)",
                    ),
                    args: { raidId: BigInt(s.raidId) },
                    fromBlock: GAME_DEPLOY_BLOCK,
                    toBlock: "latest",
                  })
                  .then((logs) => {
                    const o = (
                      logs[0]?.args as { outcome?: number } | undefined
                    )?.outcome;
                    if (o !== undefined) setOutcome(Number(o));
                  })
                  .catch(() => {});
              } else {
                setPhase("order");
                setErr("that order lapsed and was forfeited — the ◫50 burned");
              }
            }
          })
          .catch(() => {});
      }
    } else {
      setSecret(null);
      setPhase("order");
      setPicked(new Set());
      setErr(null);
      setOutcome(null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, targetDonId?.toString(), g.address, g.selected?.id?.toString()]);

  useEffect(() => {
    if (phase !== "committed") return;
    const t = setInterval(() => tick((n) => n + 1), 1000);
    return () => clearInterval(t);
  }, [phase]);

  if (targetDonId === null) return null;

  const attacker = g.selected;
  const now = Date.now();
  // Hospital is the only hard gate; cooldown is diminished odds, never a revert.
  const available = g.hitters.filter((h) => h.hospitalUntil <= now);
  // One open hit order per Don (gate-audit hardening): a second commit from the same Don would
  // overwrite the first raid's stored preimage, making it unrevealable — its 50-Scrip fee forfeits.
  const pending =
    g.address && attacker ? loadRaidSecret(g.address, attacker.id) : null;
  // raidId === "" means the commit tx never landed (rejected prompt / revert) — that secret protects
  // nothing (reveal needs a raidId), so it must never gate other targets (review fix: phantom lockout).
  const pendingLive =
    pending !== null &&
    pending.raidId !== "" &&
    now <= pending.committedAt + REVEAL_WINDOW_MS &&
    pending.targetDonId !== targetDonId.toString();
  const gate = !g.configured
    ? "THE ENGINE OPENS WITH THE SEASON · CONTRACTS PENDING"
    : !g.connected
      ? "CONNECT A WALLET TO SIGN"
      : !attacker
        ? "NO DON ON THE DESK — VISIT THE REGISTRY"
        : pendingLive
          ? `THIS DON HAS AN OPEN HIT ORDER ON №${pending.targetDonId} — KICK THAT DOOR FIRST`
          : attacker.vaultScrip < COMMIT_FEE
            ? `THE ORDER COSTS ◫ ${fmtAmt(COMMIT_FEE)} · VAULT SHORT — RUN A JOB ON THE BOARD, THEN BANK THE HOPPER AT THE HOUSE`
            : available.length === 0
              ? "NO CREW AVAILABLE — VISIT THE RAP SHEETS"
              : picked.size === 0
                ? "PICK YOUR CREW FIRST"
                : picked.size > MAX_CREW
                  ? `FIVE THROUGH THE DOOR, MAX`
                  : null;

  const commit = async () => {
    if (gate || !g.address || !attacker || phase !== "order") return;
    setErr(null);
    setPhase("committing");
    try {
      const ids = [...picked].map(BigInt).sort((a, b) => (a < b ? -1 : 1));
      const salt = randomSalt();
      const h = raidCommitHash(attacker.id, ids, targetDonId, salt);
      const s: RaidSecret = {
        attackerDonId: attacker.id.toString(),
        raidId: "",
        hitterIds: ids.map(String),
        targetDonId: targetDonId.toString(),
        salt,
        committedAt: Date.now(),
      };
      saveRaidSecret(g.address, s); // the preimage — reveal needs it; losing it means the fee, so save FIRST
      const hash = await gameSend(
        g.address,
        GAME_ADDR.raidEngine,
        raidEngineAbi,
        "commit",
        [attacker.id, h],
        undefined,
        600_000n,
      );
      // The raidId comes back in the RaidCommitted event — reveal is keyed by it.
      const rcpt = await pub.getTransactionReceipt({ hash });
      const evts = parseEventLogs({
        abi: raidEngineAbi,
        logs: rcpt.logs,
        eventName: "RaidCommitted",
      });
      if (evts.length > 0)
        s.raidId = (evts[0].args as { raidId: bigint }).raidId.toString();
      saveRaidSecret(g.address, s);
      setSecret(s);
      setPhase("committed");
    } catch (e) {
      // The save-first design stored the preimage before the tx; if the commit never landed the
      // secret is a phantom (raidId "") — remove it so it can't confuse a later session (review fix).
      const phantom =
        g.address && attacker ? loadRaidSecret(g.address, attacker.id) : null;
      if (phantom !== null && phantom.raidId === "")
        clearRaidSecret(g.address, attacker.id);
      setPhase("error");
      setErr(niceError(e));
    }
  };

  const revealOpensAt = secret ? secret.committedAt + REVEAL_DELAY_MS : 0;
  const revealClosesAt = secret ? secret.committedAt + REVEAL_WINDOW_MS : 0;
  const windowOpen =
    secret !== null && now >= revealOpensAt && now <= revealClosesAt;
  const windowMissed = secret !== null && now > revealClosesAt;

  const reveal = async () => {
    if (
      !g.address ||
      !secret ||
      !secret.raidId ||
      phase !== "committed" ||
      !windowOpen
    )
      return;
    setErr(null);
    setPhase("revealing");
    try {
      let fee = 0n;
      try {
        fee = await pub.readContract({
          address: GAME_ADDR.raidEngine,
          abi: raidEngineAbi,
          functionName: "entropyFee",
        });
      } catch {
        /* optional */
      }
      const raidId = BigInt(secret.raidId);
      // 1.2M pin (uses ~443k): the old 3M pin made reveal UNAFFORDABLE for low-gas wallets — they
      // could commit but not reveal, forfeiting the ◫50 (full-loop verify, HIGH finding).
      const hash = await gameSend(
        g.address,
        GAME_ADDR.raidEngine,
        raidEngineAbi,
        "reveal",
        [
          raidId,
          secret.hitterIds.map(BigInt),
          BigInt(secret.targetDonId),
          secret.salt,
        ],
        fee,
        1_200_000n,
      );
      clearRaidSecret(g.address, BigInt(secret.attackerDonId));
      setPhase("report");
      g.refresh();
      // Settlement lands with the entropy callback (a later tx) — poll the RaidSettled event.
      const rcpt = await pub.getTransactionReceipt({ hash });
      const settledEvt = raidEngineAbi.find(
        (x) => x.type === "event" && x.name === "RaidSettled",
      );
      for (let i = 0; i < 12; i++) {
        await new Promise((r) => setTimeout(r, 5000));
        try {
          const logs = await pub.getLogs({
            address: GAME_ADDR.raidEngine,
            event: settledEvt as never,
            args: { raidId } as never,
            fromBlock: rcpt.blockNumber,
            toBlock: "latest",
          });
          if (logs.length > 0) {
            setOutcome(
              Number(
                (logs[0] as { args?: { outcome?: number } }).args?.outcome ?? 0,
              ),
            );
            g.refresh();
            break;
          }
        } catch {
          /* keep polling */
        }
      }
    } catch (e) {
      setPhase("committed");
      setErr(niceError(e));
    }
  };

  const sealHint =
    phase === "committing"
      ? "SUBMITTING THE COMMIT TX…"
      : (gate ?? `CLICK THE SEAL · ◫ ${fmtAmt(COMMIT_FEE)} SUNK, WIN OR LOSE`);

  return (
    <CaseFile
      open={open}
      stack2
      jacket="carbon"
      tab={`HIT ORDER · TARGET №${targetDonId.toString()}`}
      head="HIT ORDER"
      onClose={onClose}
    >
      {(phase === "order" || phase === "committing" || phase === "error") && (
        <>
          <div className="g-canon">
            <div className="g-photowin">
              <div className="g-pframe">
                <div className="g-surv" style={{ border: "none" }}>
                  <span className="g-ts">STILL</span>
                  <DonImg
                    id={targetDonId}
                    alt={`target — Don №${targetDonId.toString()}`}
                  />
                </div>
              </div>
              <div className="g-pcap">
                target · don №{targetDonId.toString()}
              </div>
            </div>
            <div className="g-typedfields">
              <p className="g-serifname">House Robbery</p>
              <div className="g-tf">
                <label>Target</label>
                <b>DON №{targetDonId.toString()} — away, House standing open</b>
              </div>
              <div className="g-tf">
                <label>Mode</label>
                <b>HOUSE ROBBERY · commit now, reveal in 10–40 min</b>
              </div>
              <div className="g-tf">
                <label>Odds</label>
                <b>
                  vs UNKNOWN garrison — 5–70%, crew vs the door. a range,
                  because fog.
                </b>
              </div>
              <div className="g-tf">
                <label>Stakes</label>
                <b>
                  ◫ {fmtAmt(COMMIT_FEE)} order fee, sunk · a miss can
                  hospitalize the crew 48h
                </b>
              </div>
            </div>
          </div>

          <hr className="g-dashrule" />
          <p className="g-pcap-h">
            THE CREW — who goes through the door · five max
          </p>
          {available.length === 0 ? (
            <p className="g-typed" style={{ fontSize: 11 }}>
              no Hitters out of the hospital. a raid needs muscle — retain a
              crew at the RAP SHEETS.
            </p>
          ) : (
            <div className="g-provs">
              {available.map((h) => {
                const cooling =
                  h.lastAttemptAt > 0 &&
                  now - h.lastAttemptAt < 20 * 3600 * 1000;
                return (
                  <button
                    key={h.id.toString()}
                    aria-pressed={picked.has(h.id.toString())}
                    title={
                      cooling
                        ? "on cooldown — hunts at diminished odds, (t/20h)²"
                        : undefined
                    }
                    onClick={() =>
                      setPicked((p) => {
                        const n = new Set(p);
                        const k = h.id.toString();
                        if (n.has(k)) n.delete(k);
                        else if (n.size < MAX_CREW) n.add(k);
                        return n;
                      })
                    }
                  >
                    ♟ №{h.id.toString()}
                    {cooling ? " ·⏳" : ""}
                  </button>
                );
              })}
            </div>
          )}
          <p className="g-provnote">
            the order seals the crew list. nobody — including you — can change
            it after the wax takes the die. ⏳ = cooling: allowed, at (t/20h)²
            odds.
          </p>
          {err && <div className="g-err">{err}</div>}
          <WaxSeal
            disabled={!!gate || phase === "committing"}
            hint={sealHint}
            onCommit={commit}
          />
        </>
      )}

      {(phase === "committed" || phase === "revealing") && secret && (
        <div className="g-envelope waiting">
          <BigEnvelope />
          <p
            className="g-typed"
            style={{ textAlign: "center", maxWidth: "38ch" }}
          >
            <span className="lbl">THE ENVELOPE IS SEALED</span>
            committed {fmtHMS((now - secret.committedAt) / 1000)} ago. the
            reveal window is 10–40 minutes after the commit — it kills mempool
            sniping in both directions.
          </p>
          {windowMissed && (
            <p className="g-err">
              the window closed — the order lapses and the fee burns. anyone may
              file the forfeit.
            </p>
          )}
          {err && <div className="g-err">{err}</div>}
          <button
            className="g-stampbtn"
            disabled={phase === "revealing" || !windowOpen || !secret.raidId}
            onClick={reveal}
          >
            {phase === "revealing"
              ? "OPENING…"
              : windowMissed
                ? "WINDOW MISSED"
                : !windowOpen
                  ? `OPENS IN ${fmtHMS((revealOpensAt - now) / 1000)}`
                  : "OPEN THE ENVELOPE · REVEAL"}
          </button>
        </div>
      )}

      {phase === "report" && (
        <div>
          <p className="g-pcap-h">AFTER-ACTION REPORT</p>
          <div className="g-rapsheet">
            <div
              className="g-canon"
              style={{ display: "block", paddingRight: 90 }}
            >
              {outcome !== null && OUTCOME_STAMP[outcome] ? (
                <Stamp
                  corner
                  big
                  thump
                  ok={OUTCOME_STAMP[outcome].ok}
                  style={{ top: -6 }}
                >
                  {OUTCOME_STAMP[outcome].label}
                </Stamp>
              ) : (
                <Stamp corner carbon style={{ top: -6 }}>
                  PENDING
                </Stamp>
              )}
              <p className="g-serifname">Target №{targetDonId.toString()}</p>
            </div>
            <div className="g-typed" style={{ marginTop: 8 }}>
              {outcome !== null && OUTCOME_STAMP[outcome] ? (
                OUTCOME_STAMP[outcome].ok ? (
                  <p>
                    <span className="lbl">THE TAKE</span>the door gave. hit tax
                    burned at the cage; the rest landed in your Don's vault —
                    already banked, already yours.
                  </p>
                ) : (
                  <p>
                    <span className="lbl">THE DOOR HELD</span>the House was
                    waiting. check the hospital ward — returning fire is real,
                    and the defended punish hard.
                  </p>
                )
              ) : (
                <p>
                  <span className="lbl">REPORT PENDING</span>the entropy roll is
                  still in the wire — the stamp lands when the keeper's callback
                  settles the outcome. the garrison may also need its own reveal
                  first.
                </p>
              )}
              <p>
                <span className="lbl">CREW</span>cooldown starts now. hunting
                early is allowed — at sharply reduced odds. that's strategy, not
                a gate.
              </p>
            </div>
          </div>
          <div style={{ marginTop: 12, textAlign: "center" }}>
            <button className="g-stampbtn ok" onClick={onClose}>
              FILE THE REPORT · CLOSE
            </button>
          </div>
        </div>
      )}
    </CaseFile>
  );
}
