import { getAddress } from "viem";
import { ZERO } from "./ledger.mjs";

// THE two-snapshot holding gate (docs/MAINNET-ACTIVATION.md:515-529). Weight is min(prev, curr), so a
// wallet that was not already there at the PREVIOUS snapshot has weight 0 no matter how large it is now.
// That is what kills snapshot farming: the economist's sim put the attack net-profitable once epoch
// volume exceeds ~5x eligible float, i.e. worst exactly at launch, and only a holding gate closes it.
//
// min() is commutative, so passing the snapshots in the wrong order would NOT change any weight — the
// order is instead enforced structurally here, because every downstream artifact (the manifest, the
// reported snapshot blocks, any later switch to last-balance or TWAB weighting) reads prev as the older.

/// Inclusive at the bar: a wallet holding EXACTLY the bar is eligible. Decided here, pinned by
/// test/eligibility.test.mjs — bar-1 wei is excluded, bar is included.
export const BAR_MODE = "inclusive";

export function normalizeExclusions(list = []) {
  const set = new Set([getAddress(ZERO)]);
  for (const a of list) set.add(getAddress(a));
  return set;
}

/// Weight every address that appears in either snapshot, then drop the ineligible. Returns a canonical,
/// deterministically ordered list plus the totals the allocator divides by.
export function computeWeights({ prev, curr, barWei, exclusions = [] }) {
  if (prev.block >= curr.block) {
    throw new Error(`eligibility: snapshots out of order — prev ${prev.block} must precede curr ${curr.block}`);
  }
  const bar = BigInt(barWei);
  if (bar <= 0n) throw new Error("eligibility: bar must be positive");
  const excluded = normalizeExclusions(exclusions);

  const holders = [];
  const candidates = new Set([...prev.balances.keys(), ...curr.balances.keys()]);
  for (const account of [...candidates].sort((a, b) => (a.toLowerCase() < b.toLowerCase() ? -1 : 1))) {
    if (excluded.has(account)) continue;
    const before = prev.balances.get(account) ?? 0n;
    const now = curr.balances.get(account) ?? 0n;
    const weight = before < now ? before : now;
    if (weight < bar) continue;
    holders.push({ holder: account, prev: before, curr: now, weight });
  }

  const totalWeight = holders.reduce((sum, h) => sum + h.weight, 0n);
  return { prevBlock: prev.block, currBlock: curr.block, bar, holders, totalWeight };
}

/// The bar as an absolute wei amount. Either a literal (barWei) or bps of a supply read from chain — the
/// founder-locked 0.1% of 8,888,888,888e18 is 10 bps => 8,888,888.888 $ESSEY. Keeper knob, no redeploy.
export function resolveBar({ barWei, barBps, totalSupply }) {
  if (barWei !== undefined && barWei !== null && barWei !== "") return BigInt(barWei);
  if (barBps === undefined || barBps === null) throw new Error("eligibility: set HOLDER_BAR_WEI or HOLDER_BAR_BPS");
  if (totalSupply === undefined) throw new Error("eligibility: barBps needs a totalSupply");
  return (BigInt(totalSupply) * BigInt(barBps)) / 10_000n;
}
