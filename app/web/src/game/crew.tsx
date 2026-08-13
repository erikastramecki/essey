// The Hitter RAP SHEETS — faceless muscle as a theme, not a gap: pure-CSS redacted mugshots,
// the RETAIN (mint) stamp, and the sealed-envelope Favor state (the sealed slot lives INSIDE
// HitterNFT as-built — every unrevealed Hitter is a lottery ticket with disclosed odds).
// mint(payerDonId) burns ◫900 from the paying Don's vault — no ETH, the Scrip-mode sink.
import { useEffect, useState } from "react";
import { niceError } from "../live";
import { pub, gameSend, GAME_ADDR } from "./gameChain";
import { hitterAbi } from "./gameAbi";
import { useGame, fmtHMS, HITTER_COOLDOWN_MS, type GameHitter } from "./useGame";
import { CaseFile, RatingStamp, RedactedMug, SealedEnvelopeIcon, Stamp, fmtAmt } from "./bits";

/// HitterNFT.MINT_PRICE — ◫900, burned from the payer Don's vault.
const MINT_PRICE = 900n * 10n ** 18n;

const disposition = (h: GameHitter): { label: string; rating: "low" | "std" | "steep" } => {
  const now = Date.now();
  if (h.hospitalUntil > now) return { label: `HOSPITAL ${fmtHMS((h.hospitalUntil - now) / 1000)}`, rating: "steep" };
  if (h.lastAttemptAt > 0 && now - h.lastAttemptAt < HITTER_COOLDOWN_MS)
    return { label: `COOLDOWN ${fmtHMS((h.lastAttemptAt + HITTER_COOLDOWN_MS - now) / 1000)}`, rating: "std" };
  return { label: "AT THE SLICK", rating: "std" };
};

/// FavorRevealed band names (HitterNFT._bandName) — 70 / 20 / 8.5 / 1.5.
const FAVOR_BANDS = [
  "AN EMPTY ENVELOPE — 70% are. the ticket was the thrill",
  "A SMALL FAVOR — the family remembers little things",
  "A REAL FAVOR — one genuine edge, on the record",
  "THE DON OWES YOU — say it quietly",
] as const;

export function CrewFile({ open, onClose }: { open: boolean; onClose: () => void }) {
  const g = useGame();
  const [busy, setBusy] = useState<null | "mint" | "reveal" | "opening">(null);
  const [err, setErr] = useState<string | null>(null);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [favorBand, setFavorBand] = useState<string | null>(null);

  const don = g.selected;
  const expandedSealed = g.hitters.find((h) => h.id.toString() === (expandedId ?? g.hitters[0]?.id.toString()))?.sealed;

  // The revealed band, fetched for the expanded sheet (favorOf is only meaningful once unsealed).
  useEffect(() => {
    setFavorBand(null);
    const id = expandedId ?? g.hitters[0]?.id.toString();
    if (!id || expandedSealed !== false) return;
    let live = true;
    pub.readContract({ address: GAME_ADDR.hitter, abi: hitterAbi, functionName: "favorOf", args: [BigInt(id)] })
      .then((b) => { if (live) setFavorBand(FAVOR_BANDS[Number(b)] ?? null); })
      .catch(() => {});
    return () => { live = false; };
  }, [expandedId, expandedSealed, g.hitters.length]);

  const mint = async () => {
    if (!g.address || !don || busy || !g.configured) return;
    setErr(null); setBusy("mint");
    try {
      await gameSend(g.address, GAME_ADDR.hitter, hitterAbi, "mint", [don.id]);
      g.refresh();
    } catch (e) {
      setErr(niceError(e));
    } finally {
      setBusy(null);
    }
  };

  const revealFavor = async (id: bigint) => {
    if (!g.address || busy) return;
    setErr(null); setBusy("reveal");
    try {
      let fee = 0n;
      try { fee = await pub.readContract({ address: GAME_ADDR.hitter, abi: hitterAbi, functionName: "entropyFee" }); } catch { /* optional */ }
      await gameSend(g.address, GAME_ADDR.hitter, hitterAbi, "revealFavor", [id], fee);
      // The word lands via the keeper seconds later — fast-poll so the envelope flips NOW, not on
      // the 15s cadence (founder hit this: reveal worked, UI lagged, second click reverted).
      setBusy("opening");
      for (let i = 0; i < 15; i++) {
        await new Promise((r) => setTimeout(r, 3000));
        try {
          const stillSealed = await pub.readContract({ address: GAME_ADDR.hitter, abi: hitterAbi, functionName: "sealed_", args: [id] });
          if (!stillSealed) break;
        } catch { /* transient read — keep polling */ }
      }
      g.refresh();
    } catch (e) {
      const msg = niceError(e);
      // The chain refusing a second open means the first one WORKED — say so instead of scaring.
      setErr(/AlreadyRevealed|already/i.test(msg) ? "the envelope is already open — the Favor below is the record" : msg);
      g.refresh();
    } finally {
      setBusy(null);
    }
  };

  const mintGate = !g.configured ? "the crews sign with the season — contracts pending"
    : !g.connected ? "connect a wallet to retain a crew"
    : !don ? "a crew signs to a family — take a seat at the Registry first"
    : don.vaultScrip < MINT_PRICE ? `the retainer is ◫ ${fmtAmt(MINT_PRICE)} — the vault is short. run the MILK RUN on the job board (75s, pays ◫ 6,000), then BANK IT at the house` : null;
  const expanded = g.hitters.find((h) => h.id.toString() === expandedId) ?? g.hitters[0] ?? null;

  return (
    <CaseFile open={open} jacket="grey" tab="RAP SHEETS · THE CREW" head="CREW ROSTER" onClose={onClose}>
      <p className="g-typed" style={{ marginBottom: 10 }}>
        no photographs on file. the crews prefer it that way, and so does the fog. a Hitter is a{" "}
        <b>rap sheet, not a face</b> — faceless muscle is the theme, not a gap.
      </p>

      {g.hitters.length === 0 ? (
        <div className="g-typed">
          <p><span className="lbl">NO CREW ON FILE</span>
            every family keeps a crew: the people who watch houses, mind doors, case jobs, and — when a rival
            Don is out — do the other thing. retain your first Hitter below.</p>
        </div>
      ) : (
        <div className="g-crewstrip">
          {g.hitters.map((h) => {
            const d = disposition(h);
            return (
              <div key={h.id.toString()} className={"g-hitcard" + (expanded?.id === h.id ? " on" : "")}
                onClick={() => setExpandedId(h.id.toString())} role="button" tabIndex={0}
                onKeyDown={(e) => { if (e.key === "Enter") setExpandedId(h.id.toString()); }}>
                <RedactedMug />
                <div className="g-hname">№{h.id.toString()}</div>
                <div className="g-hstat">carries <b>—</b> · gear ships with the ItemVault</div>
                <div className="g-hstamp"><RatingStamp rating={d.rating}>{d.label}</RatingStamp></div>
                <div className={"g-sealedslot" + (h.sealed ? "" : " revealed")}>
                  <SealedEnvelopeIcon /> {h.sealed ? "THE FAVOR · SEALED" : "FAVOR REVEALED"}
                </div>
              </div>
            );
          })}
        </div>
      )}

      <div style={{ textAlign: "center", margin: "12px 0 4px" }}>
        <button className="g-cta-btn" disabled={!!mintGate || busy !== null} onClick={mint}
          style={mintGate ? { opacity: 0.5, cursor: "not-allowed" } : undefined}>
          {busy === "mint" ? "SIGNING…" : `RETAIN A HITTER · ◫ ${fmtAmt(MINT_PRICE)}`}
        </button>
        {mintGate && <p className="g-provnote" style={{ marginTop: 6 }}>{mintGate}</p>}
        <p className="g-provnote" style={{ marginTop: 6 }}>
          the retainer burns from your Don's vault. every mint arrives with one <b>sealed slot — the Favor</b>:
          an unopened envelope from the family, committed at mint against published odds (70 / 20 / 8.5 / 1.5).
          maybe nothing. maybe an edge.
        </p>
      </div>
      {err && <div className="g-err">{err}</div>}

      {expanded && (
        <>
          <p className="g-pcap-h" style={{ marginTop: 12 }}>EXPANDED SHEET — №{expanded.id.toString()}</p>
          <div className="g-rapsheet">
            <div className="g-canon">
              <Stamp corner style={{ fontSize: 10 }}>{disposition(expanded).label.split(" ")[0] === "COOLDOWN" ? "COOLING OFF" : disposition(expanded).label.split(" ")[0]}</Stamp>
              <div className="g-photowin" style={{ flexBasis: 96, width: 96 }}>
                <div className="g-pframe" style={{ paddingBottom: 8 }}><RedactedMug /></div>
              </div>
              <div className="g-typedfields">
                <div className="g-tf"><label>Codename</label><b>№{expanded.id.toString()} — the Tape declines to elaborate</b></div>
                <div className="g-tf"><label>Disposition</label><b>{disposition(expanded).label.toLowerCase()}</b></div>
                <div className="g-tf"><label>Carries</label><b>— · takeable once carried</b></div>
                <div className="g-tf"><label>The Favor</label>
                  <b className={expanded.sealed ? undefined : "ok"}>
                    {expanded.sealed ? "SEALED ✉ — contents unknown to rivals" : (favorBand ?? "REVEALED — the Favor is on the record")}
                  </b></div>
              </div>
            </div>
            {expanded.sealed && g.connected && (
              <div style={{ marginTop: 8, textAlign: "center" }}>
                <button className="g-stampbtn" disabled={busy !== null} onClick={() => revealFavor(expanded.id)}>
                  {busy === "reveal" ? "SIGNING…" : busy === "opening" ? "THE WORD IS OUT — OPENING…" : "OPEN THE ENVELOPE · REVEAL THE FAVOR"}
                </button>
              </div>
            )}
            <p className="g-typed" style={{ margin: "8px 0 0", fontSize: 11, color: "var(--g-ink-type-mut)" }}>
              what you carry on the job, you carried on the job. nobody mourns a lost crowbar. they mourn the good coat.
            </p>
          </div>
        </>
      )}
    </CaseFile>
  );
}
