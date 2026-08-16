// Resolve briefIds off the chain by CODENAME instead of trusting the hardcoded chainId in briefs.ts.
// postBrief assigns ids by ++briefCount, so a reseed that posts a different number of rows, in a
// different order, silently repoints every job in the UI. That is not hypothetical: the 2026-08-15
// redeploy seeded four briefs under a UI addressing seven, and MILK RUN, OPEN WINDOW and DEEP RUN
// reverted BriefNotLive for every player until they were re-posted.
import { useEffect, useState } from "react";
import { pub, GAME_ADDR } from "./gameChain";
import { missionBoardAbi } from "./gameAbi";
import { BRIEFS, BRIEF_ORDER, type BriefKey } from "./briefs";

export type LiveBriefIds = Partial<Record<BriefKey, bigint>>;

// The chain writes "GLASS HARVEST - RUSH" where the UI shows "GLASS HARVEST · RUSH", so codenames
// are compared on letters and digits only.
const norm = (s: string): string =>
  s
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, " ")
    .trim();

let cache: LiveBriefIds | null = null;
let inflight: Promise<LiveBriefIds> | null = null;

async function load(): Promise<LiveBriefIds> {
  const count = (await pub.readContract({
    address: GAME_ADDR.missionBoard,
    abi: missionBoardAbi,
    functionName: "briefCount",
  })) as bigint;

  const byName = new Map<string, bigint>();
  for (let id = 1n; id <= count; id++) {
    const row = (await pub.readContract({
      address: GAME_ADDR.missionBoard,
      abi: missionBoardAbi,
      functionName: "briefs",
      args: [id],
    })) as readonly unknown[];
    const live = row[0] as boolean;
    const codename = row[10] as string;
    if (live) byName.set(norm(codename), id);
  }

  const out: LiveBriefIds = {};
  for (const key of BRIEF_ORDER) {
    const id = byName.get(norm(BRIEFS[key].code));
    if (id !== undefined) out[key] = id;
  }
  cache = out;
  return out;
}

/// null while the board is still being read — callers must treat that as "unknown", never as "empty".
export function useLiveBriefIds(): LiveBriefIds | null {
  const [ids, setIds] = useState<LiveBriefIds | null>(cache);
  useEffect(() => {
    if (cache) return;
    let alive = true;
    inflight ??= load();
    inflight
      .then((r) => {
        if (alive) setIds(r);
      })
      .catch(() => {
        inflight = null;
      });
    return () => {
      alive = false;
    };
  }, []);
  return ids;
}
