// The Don CASE FILE — the founding family's civic monument: real composed art in the evidence
// framing, the weapon-in-art callout ("comes equipped" — the auto-equip rule made visible), and
// the rap-sheet field grid.
import { useEffect, useState } from "react";
import { parseAbiItem } from "viem";
import { pub, GAME_ADDR, GAME_DEPLOY_BLOCK, gameConfigured } from "./gameChain";
import { useGame, useCountdown } from "./useGame";
import { CaseFile, Stamp, PaperClip, DonImg } from "./bits";

export function DonFile({
  donId,
  open,
  onClose,
}: {
  donId: bigint | null;
  open: boolean;
  onClose: () => void;
}) {
  const g = useGame();
  const don =
    donId !== null ? (g.dons?.find((d) => d.id === donId) ?? null) : null;
  const [missions, setMissions] = useState<number | null>(null);
  const cd = useCountdown(don?.dueMs ?? null);

  // Missions run — counted straight off the MissionBoard's Departed events for this Don.
  useEffect(() => {
    if (!open || donId === null) return;
    let live = true;
    if (!gameConfigured()) {
      setMissions(0);
      return;
    }
    pub
      .getLogs({
        address: GAME_ADDR.missionBoard,
        event: parseAbiItem(
          "event Departed(uint64 indexed missionId, uint256 indexed donId, uint64 indexed briefId, uint256 provision, uint256 fee, uint256 reserved, bytes32 garrisonHash)",
        ),
        args: { donId },
        fromBlock: GAME_DEPLOY_BLOCK,
        toBlock: "latest",
      })
      .then((logs) => {
        if (live) setMissions(logs.length);
      })
      .catch(() => {
        if (live) setMissions(0);
      });
    return () => {
      live = false;
    };
  }, [open, donId?.toString()]); // eslint-disable-line react-hooks/exhaustive-deps

  if (donId === null) return null;
  const away = don?.away ?? false;
  const damage = don?.damageBps ?? 0;

  return (
    <CaseFile
      open={open}
      tab="CASE FILE · FOUNDING FAMILY"
      head="CASE FILE"
      onClose={onClose}
    >
      <div className="g-canon" style={{ display: "block", paddingRight: 80 }}>
        <Stamp corner ok={!away} style={{ fontSize: 11, top: -2 }}>
          {away ? "DEPARTED" : "HOME"}
        </Stamp>
        <p className="g-serifname">Don №{donId.toString()}</p>
      </div>
      <div className="g-bigphoto">
        <PaperClip />
        <DonImg
          id={donId}
          alt={`Don №${donId.toString()} — the locked portrait, a small civic monument`}
        />
        <div className="g-pcap">portrait locked at seating</div>
        {/* the equip-from-art callout: what the portrait carries, the family carries */}
        <div className="g-evi-dot" style={{ left: "38%", top: "72%" }} />
        <div className="g-evi-tag" style={{ right: "2%", top: "78%" }}>
          <b>EXHIBIT A</b>
          whatever the locked portrait holds in hand. the Keeper records its
          class on the record after your first job resolves. the kit itself
          mints, and plays, with a later posting.
        </div>
      </div>
      {away && (
        <div className="g-island" style={{ marginBottom: 10 }}>
          <div className="g-cap">
            <span>IN THE FIELD</span>
            <span>the ledger keeps the clock</span>
          </div>
          <div className="g-odds-row">
            <span className="k">returns</span>
            <span className="blocks" />
            <span className="pct" style={{ flexBasis: 90 }}>
              {cd}
            </span>
          </div>
        </div>
      )}
      <p className="g-pcap-h">RAP SHEET</p>
      <div className="g-rapgrid">
        <div className="g-tf">
          <label>Seat</label>
          <b>№{donId.toString()} of 8,888 — a signature on the Ledger</b>
        </div>
        <div className="g-tf">
          <label>Missions run</label>
          <b>
            {missions === null
              ? "…"
              : missions === 0
                ? "0 — no missions on the record yet"
                : `${missions} on the record`}
          </b>
        </div>
        <div className="g-tf">
          <label>Credit standing</label>
          <b className={damage === 0 ? "ok" : undefined}>
            {damage === 0
              ? "GOOD — 0 unpaid repairs"
              : "1 unpaid repair — see the PROPERTY FILE"}
          </b>
        </div>
        <div className="g-tf">
          <label>Kit class</label>
          <b>recorded from the portrait once your first job resolves</b>
        </div>
        <div className="g-tf">
          <label>Traits</label>
          <b>live — NRV widens this Don's mission success band, up to +5pp</b>
        </div>
      </div>
    </CaseFile>
  );
}
