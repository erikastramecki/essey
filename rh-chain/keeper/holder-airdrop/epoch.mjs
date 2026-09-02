// Pure epoch gating, kept out of the I/O path so every "why did it not run" answer is testable.

export const BOOTSTRAP = "bootstrap: no previous snapshot yet — the two-snapshot gate needs one epoch of history";
export const CADENCE_CHAIN = "cadence: postRoot would revert TooEarly against minEpochInterval";
export const CADENCE_LOCAL = "cadence: the configured epoch interval has not elapsed";
export const DUST = "dust: pot is below the buy-side floor";
export const NO_HOLDERS = "no eligible holders above the bar";
export const READY = "ready";

export function decideRun({
  now,
  prevSnapshotBlock,
  lastRootAt,
  minEpochInterval,
  lastSnapshotAt,
  epochSeconds,
  pot,
  minPotUsdg,
}) {
  if (prevSnapshotBlock === null || prevSnapshotBlock === undefined) return { run: false, reason: BOOTSTRAP };
  if (BigInt(now) < BigInt(lastRootAt) + BigInt(minEpochInterval)) return { run: false, reason: CADENCE_CHAIN };
  if (lastSnapshotAt !== null && BigInt(now) < BigInt(lastSnapshotAt) + BigInt(epochSeconds)) {
    return { run: false, reason: CADENCE_LOCAL };
  }
  if (BigInt(pot) < BigInt(minPotUsdg)) return { run: false, reason: DUST };
  return { run: true, reason: READY };
}

/// The keeper may post only while it is the named keeper, or after the grace has opened the bonded
/// fallback; either way it needs a bond (src/market/HolderDistributor.sol:149-153). Checking here turns
/// a wasted revert into a log line.
export function canPost({ sender, keeper, bond, minBond, now, lastKeeperRootAt, keeperGrace }) {
  const isKeeper = sender.toLowerCase() === keeper.toLowerCase();
  if (!isKeeper && BigInt(now) < BigInt(lastKeeperRootAt) + BigInt(keeperGrace)) {
    return { ok: false, reason: "not the keeper and the fallback grace has not elapsed" };
  }
  if (BigInt(bond) < BigInt(minBond)) return { ok: false, reason: `bond ${bond} is below minBond ${minBond}` };
  return { ok: true, reason: READY };
}
