// The House PROPERTY FILE — canonical composition + the three-box (Vault / Broker / House),
// garrison chairs, and the cork-board robbery log with the REPAIR stamp firing a real tx.
// Reconciled to the AS-BUILT HouseEscrow/HouseDeed: all custody is SCRIP (banked in the Don's
// 6551 vault; deployed/hopper at the escrow), deploy(donId, amt) / bank(donId, fromDeployed,
// fromHopper) / repair(donId) / upgrade(donId). The Safehouse deed is MODULE-minted — it
// auto-claims inside the first depart tx (ensureHouse), there is no user claim call.
import { useState } from "react";
import { Link } from "react-router-dom";
import { parseUnits } from "viem";
import { niceError } from "../live";
import { gameSend, GAME_ADDR, loadGarrisonSecret } from "./gameChain";
import { houseEscrowAbi, houseDeedAbi } from "./gameAbi";
import { HOUSE_TIERS, HOUSE_TIER_LINES } from "./briefs";
import { useGame } from "./useGame";
import { CaseFile, Stamp, PaperClip, ChairSlot, fmtAmt } from "./bits";

/// Row House upgrade fee — HouseDeed.tierStats(1).upgradeFee (1,500 Scrip, burned).
const ROW_HOUSE_FEE = 1_500n * 10n ** 18n;

export function HouseFile({ open, onClose }: { open: boolean; onClose: () => void }) {
  const g = useGame();
  const don = g.selected;
  const [amt, setAmt] = useState("");
  const [busy, setBusy] = useState<null | "deploy" | "bank" | "repair" | "upgrade">(null);
  const [err, setErr] = useState<string | null>(null);
  const [repaired, setRepaired] = useState(false);

  const run = async (kind: "deploy" | "bank" | "repair" | "upgrade") => {
    if (!g.address || !don || busy) return;
    setErr(null); setBusy(kind);
    try {
      if (kind === "repair") {
        await gameSend(g.address, GAME_ADDR.houseEscrow, houseEscrowAbi, "repair", [don.id]);
        setRepaired(true);
      } else if (kind === "upgrade") {
        await gameSend(g.address, GAME_ADDR.houseDeed, houseDeedAbi, "upgrade", [don.id]);
      } else if (kind === "bank") {
        // The sacred function — sweep everything home: deployed + hopper, free forever.
        await gameSend(g.address, GAME_ADDR.houseEscrow, houseEscrowAbi, "bank",
          [don.id, don.deployedScrip, don.hopperScrip]);
      } else {
        const units = parseUnits(amt || "0", 18);
        if (units <= 0n) throw new Error("Enter an amount");
        await gameSend(g.address, GAME_ADDR.houseEscrow, houseEscrowAbi, "deploy", [don.id, units]);
        setAmt("");
      }
      g.refresh();
    } catch (e) {
      setErr(niceError(e));
    } finally {
      setBusy(null);
    }
  };

  const tier = don?.deedTier ?? null;
  const tierName = tier !== null ? HOUSE_TIERS[Math.min(tier, 4)] : null;
  const damage = repaired ? 0 : (don?.damageBps ?? 0);
  const condPct = Math.max(0, 100 - Math.round(damage / 100));
  const garrisonIds = don && g.address ? (loadGarrisonSecret(g.address, don.id)?.hitterIds ?? []) : [];
  const moveGate = !g.configured ? "the escrow opens with the season — contracts pending"
    : !g.connected ? "connect a wallet to move value"
    : don?.away ? "your Don is in the field — the escrow moves only while home" : null;

  return (
    <CaseFile open={open} tab={`PROPERTY FILE · DEED №${don && don.deedId !== 0n ? don.deedId.toString().padStart(4, "0") : "————"}`} head="PROPERTY FILE" onClose={onClose}>
      {!don ? (
        <div className="g-typed">
          <p><span className="lbl">NO DEED ON FILE</span>
            {g.connected
              ? "no family, no address. take a seat at the Registry first — every family starts with a free Safehouse."
              : "connect a wallet to pull your property file."}</p>
          {g.connected && <Link className="g-cta-btn" to="/builder">TO THE REGISTRY →</Link>}
        </div>
      ) : (
        <>
          <div className="g-canon">
            <Stamp corner ok={damage === 0} style={{ fontSize: 11 }}>{damage === 0 ? "INTACT" : "INCIDENT"}</Stamp>
            <div className="g-photowin">
              <PaperClip />
              <div className="g-pframe"><div className="g-extstill" /></div>
              <div className="g-pcap">exterior still · AI-GEN SLOT</div>
            </div>
            <div className="g-typedfields">
              <p className="g-serifname">{tierName ?? "The Safehouse"}</p>
              <div className="g-tf"><label>Tier</label><b>{tier !== null ? `${tier + 1} of 5 — "${HOUSE_TIER_LINES[Math.min(tier, 4)]}"` : "— claims itself at first dispatch"}</b></div>
              <div className="g-tf"><label>Deed</label><b>{don.deedId !== 0n ? "held in own Vault · soulbound this season" : "not yet claimed — the first depart mints it, free"}</b></div>
              <div className="g-tf"><label>Condition</label><b>{damage === 0 ? "100% — no confessions outstanding" : `${condPct}% 🔧 — the scar is a balance-sheet confession`}</b></div>
              <div className="g-tf"><label>Policy</label><b>none — the Fixer quotes on request</b></div>
            </div>
          </div>

          {g.configured && don.deedId !== 0n && tier === 0 && (
            <div style={{ textAlign: "center", margin: "10px 0" }}>
              <button className="g-cta-btn" disabled={busy !== null || don.away} onClick={() => run("upgrade")}>
                {busy === "upgrade" ? "FILING…" : `UPGRADE TO ROW HOUSE · ◫ ${fmtAmt(ROW_HOUSE_FEE)}`}
              </button>
              <p className="g-provnote" style={{ marginTop: 4 }}>burned from the vault · cap ◫ 15,000 · HD 60 · 3 chairs</p>
            </div>
          )}

          <hr className="g-dashrule" />
          <p className="g-pcap-h">THE THREE BOXES — the hierarchy sentence, drawn</p>
          <div className="g-threebox">
            <div className="g-tb vault">
              <h5>🔒 VAULT</h5>
              <div className="g-amt">{g.configured ? `◫ ${fmtAmt(don.vaultScrip)}` : "—"}</div>
              <div className="g-krow"><span>earns</span><b>0</b></div>
              <div className="g-krow"><span>risk</span><b className="ok">never</b></div>
            </div>
            <div className="g-tb">
              <h5>▤ BROKER</h5>
              <div className="g-amt">—</div>
              <div className="g-krow"><span>earns</span><b>index</b></div>
              <div className="g-krow"><span>risk</span><b className="mid">market</b></div>
            </div>
            <div className="g-tb house">
              <h5>♠ HOUSE</h5>
              <div className="g-amt">{g.configured ? `◫ ${fmtAmt(don.deployedScrip + don.hopperScrip)}` : "—"}</div>
              <div className="g-krow"><span>hopper</span><b>{g.configured ? `◫ ${fmtAmt(don.hopperScrip)}` : "—"}</b></div>
              <div className="g-krow"><span>risk</span><b className="hot">robbery</b></div>
            </div>
          </div>
          <p className="g-note">[ bank ⇄ deploy ] moving Scrip between boxes IS the tx — the stamp confirms it</p>
          <div className="g-moverow">
            <input className="g-input" inputMode="decimal" placeholder="Scrip amount" value={amt}
              onChange={(e) => setAmt(e.target.value)} disabled={!!moveGate || busy !== null} aria-label="Scrip amount" />
            <button className="g-stampbtn ok" disabled={!!moveGate || busy !== null} onClick={() => run("deploy")}>
              {busy === "deploy" ? "…" : "DEPLOY"}
            </button>
            <button className="g-stampbtn" disabled={!!moveGate || busy !== null || (don.deployedScrip === 0n && don.hopperScrip === 0n)}
              onClick={() => run("bank")}>
              {busy === "bank" ? "…" : "BANK ALL"}
            </button>
          </div>
          {moveGate && <p className="g-provnote" style={{ marginTop: 4 }}>{moveGate}. banking is never gated once home — the sacred function.</p>}

          <hr className="g-dashrule" />
          <p className="g-pcap-h">GARRISON — {don.garrisonSlots > 0 ? `${Math.min(garrisonIds.length, don.garrisonSlots)} of ${don.garrisonSlots} chairs filled` : "chairs come with the deed"} · hidden to rivals</p>
          <div className="g-garrison">
            {don.garrisonSlots === 0 ? (
              <p className="g-provnote">a Safehouse deed seats the first chairs. the garrison signs at depart — free, frozen for the window.</p>
            ) : (
              Array.from({ length: don.garrisonSlots }, (_, i) => {
                const seated = garrisonIds[i];
                return seated !== undefined
                  ? <ChairSlot key={i} label={`№${seated}`} />
                  : <ChairSlot key={i} label="+ SIGNS AT DEPART" empty />;
              })
            )}
          </div>

          <hr className="g-dashrule" />
          <p className="g-pcap-h">ROBBERY LOG — the cork board</p>
          <div className="g-cork">
            {damage > 0 && !repaired ? (
              <div className="g-corkcard"><span className="t">recent</span><b className="bad">HIT</b> — earning rate −{Math.round(damage / 100)}% until repaired
                <button className="g-stampbtn" style={{ marginLeft: 6 }} disabled={busy !== null}
                  onClick={() => run("repair")}>{busy === "repair" ? "…" : "REPAIR"}</button>
              </div>
            ) : repaired ? (
              <div className="g-corkcard"><span className="t">now</span><b className="okc">REPAIRED</b> — rate restored. the scar is off the books.{" "}
                <Stamp ok thump style={{ fontSize: 10, marginLeft: 6 }}>PAID</Stamp></div>
            ) : (
              <div className="g-corkcard"><span className="t">—</span>no incidents on file. the cork board is empty and intends to stay that way.</div>
            )}
            {!g.configured && (
              <div className="g-corkcard"><span className="t">soon</span>the log pins every attempt — <b className="okc">FAILED</b> or <b className="bad">HIT</b> — with its receipt, once the season opens.</div>
            )}
          </div>
          {err && <div className="g-err">{err}</div>}
        </>
      )}
    </CaseFile>
  );
}
