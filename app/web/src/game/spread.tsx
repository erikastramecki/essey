// THE SPREAD — the "spread the risk" strip on the desk (OG-4). Read-only, and deliberately so:
// every number here is derived from the SAME reads the rest of the desk already runs
// (HouseEscrow.deployedOf / hopperOf per Don + the Scrip balance of each Don's 6551 vault, all
// loaded by useGame.readDon). No new contract call, no new cap, no writes.
//
// What it surfaces is the diversification the AS-BUILT per-target caps already reward:
//   · a House is only raidable while its Don is away          (RaidEngine.commit → TargetNotAway)
//   · a common hit takes that House's WHOLE hopper, minus the 7.5% hit tax burned
//                                                              (HouseEscrow.applyRaidCommon, HIT_TAX_BPS 750)
//   · a big score takes 15%–30% of that House's DEPLOYED only  (RaidEngine sliceBps = 1500 + 1500·u²,
//                                                              HouseEscrow.applyRaidBig caps at 3000 bps)
//   · then that House is cool for 8h (HEAT) and cannot be big-scored again for 48h
//                                                              (RaidEngine BIG_SCORE_LOCKOUT)
//   · the vault is never touched by either path
// Every one of those caps keys on the TARGET, so the same pile behind two doors gives up less to
// any single raid than it does behind one.
import { useGame, type GameDon } from "./useGame";
import { fmtAmt } from "./bits";

/// Mirrored contract constants (display only, same pattern as raid.tsx's COMMIT_FEE / windows).
const BIG_SLICE_MIN_BPS = 1_500n; // RaidEngine: sliceBps = 1500 + 1500·u²
const BIG_SLICE_MAX_BPS = 3_000n; // HouseEscrow.applyRaidBig hard cap
const BPS = 10_000n;

/// The most a SINGLE successful raid can pull out of one House: either the whole hopper (common
/// hit) or the top of the big-score band on deployed. One raid rolls one of those, never both.
const reachOf = (d: GameDon): bigint => {
  const big = (d.deployedScrip * BIG_SLICE_MAX_BPS) / BPS;
  return big > d.hopperScrip ? big : d.hopperScrip;
};

/// Scrip at the House: working capital plus whatever has landed in the hopper unbanked. This is
/// the whole raidable surface. The vault sits outside it, permanently.
const atHouse = (d: GameDon): bigint => d.deployedScrip + d.hopperScrip;

/// bigint ratio → percent, one decimal of headroom, clamped for display.
const pct = (part: bigint, whole: bigint): number =>
  whole <= 0n ? 0 : Math.min(100, Number((part * 1_000n) / whole) / 10);

const round = (n: number): number => Math.round(n);

export function SpreadStrip() {
  const g = useGame();
  const dons = g.dons ?? [];
  if (!g.configured || dons.length === 0) return null;

  const exposed = dons.reduce((a, d) => a + atHouse(d), 0n);
  const banked = dons.reduce((a, d) => a + d.vaultScrip, 0n);
  const family = exposed + banked;

  // Sorted by what each House actually has on the table — the concentration reads off the top row.
  const rows = [...dons].sort((a, b) => (atHouse(b) > atHouse(a) ? 1 : atHouse(b) < atHouse(a) ? -1 : 0));
  const top = rows[0];
  const topShare = pct(atHouse(top), exposed);
  const worstAny = rows.reduce((m, d) => (reachOf(d) > m ? reachOf(d) : m), 0n);
  const awayDons = rows.filter((d) => d.away);
  const worstNow = awayDons.reduce((m, d) => (reachOf(d) > m ? reachOf(d) : m), 0n);
  const fatAway = awayDons.filter((d) => d.hopperScrip > 0n);

  const single = dons.length === 1;
  const concentrated = !single && topShare > 50;

  return (
    <div className="g-ledgerstrip g-spread">
      <div className="g-cap">
        <span>THE SPREAD</span>
        <span>{dons.length === 1 ? "one House" : `${dons.length} Houses`}</span>
      </div>

      {exposed === 0n ? (
        <p className="g-sp-note">
          nothing is on the table. every Scrip you hold is banked in a vault, where no raid can reach it.
          the House only earns once you deploy, and only what you deploy can be taken.
        </p>
      ) : (
        rows.map((d) => {
          const house = atHouse(d);
          const share = pct(house, exposed);
          return (
            <button
              key={d.id.toString()}
              className={"g-sp-row" + (g.selected?.id === d.id ? " on" : "")}
              onClick={() => g.setSelectedId(d.id)}
              aria-label={`select Don ${d.id.toString()}, ${round(share)} percent of the family's exposed Scrip`}
            >
              <div className="g-sp-head">
                <span className="who">
                  №{d.id.toString()} <i className={d.away ? "away" : ""}>{d.away ? "AWAY" : "HOME"}</i>
                </span>
                <span className="amt">◫ {fmtAmt(house)} · {round(share)}%</span>
              </div>
              <div className="g-sp-bar" aria-hidden>
                <i className="dep" style={{ width: `${pct(d.deployedScrip, exposed)}%` }} />
                <i className="hop" style={{ width: `${pct(d.hopperScrip, exposed)}%` }} />
              </div>
              <div className="g-sp-legs">
                deployed ◫ {fmtAmt(d.deployedScrip)} · hopper ◫ {fmtAmt(d.hopperScrip)} · vault ◫ {fmtAmt(d.vaultScrip)}
              </div>
            </button>
          );
        })
      )}

      <div className="g-lrow"><span>ON THE TABLE</span><b>◫ {fmtAmt(exposed)}{family > 0n ? ` · ${round(pct(exposed, family))}% of the family` : ""}</b></div>
      <div className="g-lrow"><span>IN THE VAULTS</span><b>◫ {fmtAmt(banked)} <span className="ok">never at risk</span></b></div>
      <div className="g-lrow">
        <span>WORST SINGLE HIT</span>
        <b>◫ {fmtAmt(worstAny)}{exposed > 0n ? <span className="warnc"> · {round(pct(worstAny, exposed))}% of the table</span> : null}</b>
      </div>
      {awayDons.length > 0 && (
        <div className="g-lrow">
          <span>REACHABLE RIGHT NOW</span>
          <b>◫ {fmtAmt(worstNow)}{worstNow > 0n ? <span className="warnc"> · {awayDons.length === 1 ? "one Don is away" : `${awayDons.length} Dons are away`}</span> : null}</b>
        </div>
      )}

      {/* The honest framing. Nothing here promises a cap that the contracts do not already key
          on the target, and the one-House case says plainly that spreading is not available. */}
      <p className="g-sp-note">
        {exposed === 0n ? (
          <>a raid can only reach a House whose Don is away, and only what sits at that House.
            deploy when you want the yield, bank when you want it safe.</>
        ) : single ? (
          <>one Don is one House, so there is nothing to spread yet. everything you deploy sits behind
            the same door: a hit takes the whole hopper, a big score takes 15% to 30% of what is deployed,
            and both only while your Don is away. banking is your only cover here. a second Don is a
            second door, and every raid cap keys on the door it hits.</>
        ) : concentrated ? (
          <><b>{round(topShare)}% of what is on the table sits behind Don №{top.id.toString()}.</b> raid caps
            key on the target, not on the raider: one House cools for 8 hours after any hit and cannot be
            big-scored again for 48 hours. moving some of that pile behind another door means a single
            raid reaches less of it, and the second door carries its own cooldown.</>
        ) : (
          <>no single door holds more than {round(topShare)}% of what is on the table. the caps are
            per House, so a raider has to kick every door separately, and each one it kicks goes cool
            for 8 hours. keep it that way.</>
        )}
      </p>

      {fatAway.length > 0 && (
        <p className="g-sp-note warn">
          {fatAway.length === 1
            ? <>Don №{fatAway[0].id.toString()} is in the field with ◫ {fmtAmt(fatAway[0].hopperScrip)} unbanked.
                the hopper is the first thing a hit takes, and the escrow only moves while a Don is home.
                bank it the moment it lands.</>
            : <>{fatAway.length} of your Dons are in the field with Scrip still in the hopper. the hopper
                is the first thing a hit takes, and the escrow only moves while a Don is home. bank each
                one the moment it lands.</>}
        </p>
      )}

      <p className="g-sp-fine">
        those bands are chain truth, not estimates: a hit clears the hopper of the House it lands on, minus the
        7.5% hit tax that burns. a big score takes between {Number(BIG_SLICE_MIN_BPS) / 100}% and{" "}
        {Number(BIG_SLICE_MAX_BPS) / 100}% of that House's deployed Scrip. the vault is on neither path.
      </p>
    </div>
  );
}
