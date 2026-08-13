// D.O.N. game — the read-side hooks, reconciled to the AS-BUILT contracts. All chain reads are
// wrapped so an RPC hiccup degrades to honest empty state, never a crash.
import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { parseAbiItem, type Address } from "viem";
import { useWallet } from "../wallet";
import { reads } from "../live";
import { pub, GAME_ADDR, GAME_DEPLOY_BLOCK, gameConfigured } from "./gameChain";
import { ownedTokens } from "./gameChain";
import { missionBoardAbi, houseDeedAbi, houseEscrowAbi, hitterAbi, scripAbi, raidEngineAbi } from "./gameAbi";
import { SEASON } from "./briefs";

/// RaidEngine.COOLDOWN — the (t/20h)² diminished-odds anchor (display only; never a hard gate).
export const HITTER_COOLDOWN_MS = 20 * 3600 * 1000;

export type GameDon = {
  id: bigint;
  away: boolean;
  dueMs: number | null;    // mission return time, ms epoch (null while home)
  briefId: bigint | null;
  missionId: bigint;       // activeMissionOf — 0n = home
  deedId: bigint;          // 0n = no House deed yet (auto-claimed at first depart)
  deedTier: number | null;
  garrisonSlots: number;
  deployedScrip: bigint;   // HouseEscrow working capital (robbable while away)
  hopperScrip: bigint;     // mission loot + yield landed, not yet banked
  damageBps: number;       // condition debuff; 0 = intact
  vault: Address | null;   // the Don's 6551 — where banked Scrip lives
  vaultScrip: bigint;      // banked Scrip (never at risk)
};

export type GameHitter = {
  id: bigint;
  hospitalUntil: number;  // ms epoch; > now = in the hospital (hard unavailability)
  lastAttemptAt: number;  // ms epoch; cooldown anchor for the (t/20h)² curve. 0 = never used
  sealed: boolean;        // the Favor envelope still sealed (HitterNFT.sealed_)
};

const HOME_DON = (id: bigint): GameDon => ({
  id, away: false, dueMs: null, briefId: null, missionId: 0n, deedId: 0n, deedTier: null,
  garrisonSlots: 0, deployedScrip: 0n, hopperScrip: 0n, damageBps: 0, vault: null, vaultScrip: 0n,
});

async function readDon(id: bigint): Promise<GameDon> {
  const d = HOME_DON(id);
  if (!gameConfigured()) return d;
  await Promise.all([
    pub.readContract({ address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "activeMissionOf", args: [id] })
      .then(async (mid) => {
        if (mid === 0n) return; // home — settle zeroes activeMissionOf
        d.missionId = BigInt(mid);
        const [, briefId, , due] = await pub.readContract({
          address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "missions", args: [mid],
        });
        d.away = true;
        d.dueMs = Number(due) * 1000;
        d.briefId = BigInt(briefId);
      }).catch(() => {}),
    pub.readContract({ address: GAME_ADDR.houseDeed, abi: houseDeedAbi, functionName: "deedOf", args: [id] })
      .then(async (deedId) => {
        d.deedId = deedId;
        if (deedId !== 0n) {
          const [tier, slots] = await Promise.all([
            pub.readContract({ address: GAME_ADDR.houseDeed, abi: houseDeedAbi, functionName: "tierOf", args: [id] }),
            pub.readContract({ address: GAME_ADDR.houseDeed, abi: houseDeedAbi, functionName: "garrisonSlotsOf", args: [id] }),
          ]);
          d.deedTier = tier; d.garrisonSlots = Number(slots);
        }
      }).catch(() => {}),
    pub.readContract({ address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "deployedOf", args: [id] })
      .then((v) => { d.deployedScrip = v; }).catch(() => {}),
    pub.readContract({ address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "hopperOf", args: [id] })
      .then((v) => { d.hopperScrip = v; }).catch(() => {}),
    pub.readContract({ address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "damageBps", args: [id] })
      .then((v) => { d.damageBps = Number(v); }).catch(() => {}),
    reads.donState(id)
      .then(async (st: { vault: Address }) => {
        d.vault = st.vault;
        d.vaultScrip = await pub.readContract({ address: GAME_ADDR.scrip, abi: scripAbi, functionName: "balanceOf", args: [st.vault] });
      }).catch(() => {}),
  ]);
  return d;
}

async function readHitters(a: Address): Promise<GameHitter[]> {
  if (!gameConfigured()) return [];
  try {
    const ids = await ownedTokens(GAME_ADDR.hitter, a, GAME_DEPLOY_BLOCK);
    return Promise.all(ids.map(async (id) => {
      const h: GameHitter = { id, hospitalUntil: 0, lastAttemptAt: 0, sealed: true };
      await Promise.all([
        pub.readContract({ address: GAME_ADDR.hitter, abi: hitterAbi, functionName: "hospitalUntil", args: [id] }).then((v) => { h.hospitalUntil = Number(v) * 1000; }).catch(() => {}),
        pub.readContract({ address: GAME_ADDR.hitter, abi: hitterAbi, functionName: "lastAttemptAt", args: [id] }).then((v) => { h.lastAttemptAt = Number(v) * 1000; }).catch(() => {}),
        pub.readContract({ address: GAME_ADDR.hitter, abi: hitterAbi, functionName: "sealed_", args: [id] }).then((v) => { h.sealed = v; }).catch(() => {}),
      ]);
      return h;
    }));
  } catch {
    return [];
  }
}

async function readSeason(): Promise<number | null> {
  if (!gameConfigured()) return null;
  try {
    const season = await pub.readContract({ address: GAME_ADDR.scrip, abi: scripAbi, functionName: "seasonId" });
    return Number(season);
  } catch {
    return null;
  }
}

export type GameState = {
  configured: boolean;
  connected: boolean;      // address present AND on the right chain
  ready: boolean;          // wallet reconnect probe settled — safe to show connect CTA
  address: Address | null;
  dons: GameDon[] | null;  // null = still loading (or not connected)
  hitters: GameHitter[];
  scrip: bigint | null;    // banked Scrip across the family's vaults (Scrip lives in Don vaults)
  seasonId: number;
  seasonName: string;
  selected: GameDon | null;
  setSelectedId: (id: bigint) => void;
  refresh: () => void;
  connect: () => Promise<void>;
};

const GameCtx = createContext<GameState>({
  configured: false, connected: false, ready: false, address: null, dons: null, hitters: [],
  scrip: null, seasonId: SEASON.id, seasonName: SEASON.name, selected: null,
  setSelectedId: () => {}, refresh: () => {}, connect: async () => {},
});
export const useGame = () => useContext(GameCtx);
export { GameCtx };

/// The polling brain behind GameProvider (GamePage.tsx renders the context). 15s cadence — the
/// usePortfolio pattern, slightly tighter because mission countdowns resolve on-chain.
export function useGameStateValue(): GameState {
  const w = useWallet();
  const a = w.address as Address | null;
  const connected = !!a && w.chainOk;
  const [dons, setDons] = useState<GameDon[] | null>(null);
  const [hitters, setHitters] = useState<GameHitter[]>([]);
  const [season, setSeason] = useState<number | null>(null);
  const [selectedId, setSelectedId] = useState<bigint | null>(null);

  const refresh = useCallback(() => {
    if (!a) { setDons(null); setHitters([]); return; }
    reads.ownedDons(a)
      .then((ids) => Promise.all(ids.map(readDon)))
      .then(setDons)
      .catch(() => { setDons((prev) => prev ?? []); });
    readHitters(a).then(setHitters);
    readSeason().then(setSeason);
  }, [a]);

  useEffect(() => { refresh(); const t = setInterval(refresh, 15_000); return () => clearInterval(t); }, [refresh]);

  const selected = dons && dons.length > 0
    ? (dons.find((d) => d.id === selectedId) ?? dons[0])
    : null;

  return {
    configured: gameConfigured(), connected, ready: w.ready, address: a,
    dons, hitters,
    scrip: dons === null ? null : dons.reduce((acc, d) => acc + d.vaultScrip, 0n),
    seasonId: season ?? SEASON.id, seasonName: SEASON.name,
    selected, setSelectedId: (id) => setSelectedId(id), refresh, connect: w.connect,
  };
}

export type AwayTarget = { donId: bigint; briefId: bigint; dueMs: number; deployedScrip: bigint; heatUntilMs: number };

/// Raid targets — Dons currently away, from MissionBoard Departed events cross-checked against
/// activeMissionOf (a Don stays robbable until resolve/reclaim, even past due). Own Dons are
/// excluded — you don't case your own House.
export function useAwayTargets(exclude: bigint[]): { targets: AwayTarget[] | null } {
  const [targets, setTargets] = useState<AwayTarget[] | null>(null);
  const key = exclude.map(String).join(",");
  useEffect(() => {
    let live = true;
    if (!gameConfigured()) { setTargets([]); return; }
    const excl = new Set(key.split(",").filter(Boolean));
    (async () => {
      try {
        const logs = await pub.getLogs({
          address: GAME_ADDR.missionBoard,
          event: parseAbiItem("event Departed(uint64 indexed missionId, uint256 indexed donId, uint64 indexed briefId, uint256 provision, uint256 fee, uint256 reserved, bytes32 garrisonHash)"),
          fromBlock: GAME_DEPLOY_BLOCK, toBlock: "latest",
        });
        const donIds = new Set<string>();
        for (const l of logs) {
          const args = (l as { args?: { donId?: bigint } }).args;
          if (args?.donId === undefined || excl.has(args.donId.toString())) continue;
          donIds.add(args.donId.toString());
        }
        const list: AwayTarget[] = [];
        await Promise.all([...donIds].map(async (idStr) => {
          const donId = BigInt(idStr);
          const mid = await pub.readContract({ address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "activeMissionOf", args: [donId] });
          if (mid === 0n) return; // came home — no longer a target
          const [[, briefId, , due], deployed, heat] = await Promise.all([
            pub.readContract({ address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "missions", args: [mid] }),
            pub.readContract({ address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "deployedOf", args: [donId] }).catch(() => 0n),
            // Heat check (UI-verify F1): a heat-locked target's reveal is doomed (TargetOnHeat) but the
            // 50-Scrip commit fee would burn anyway — surface it so nobody files a doomed hit order.
            pub.readContract({ address: GAME_ADDR.raidEngine, abi: raidEngineAbi, functionName: "heatUntil", args: [donId] }).catch(() => 0n),
          ]);
          list.push({ donId, briefId: BigInt(briefId), dueMs: Number(due) * 1000, deployedScrip: deployed, heatUntilMs: Number(heat) * 1000 });
        }));
        if (live) setTargets(list.sort((x, y) => x.dueMs - y.dueMs));
      } catch {
        if (live) setTargets([]);
      }
    })();
    return () => { live = false; };
  }, [key]);
  return { targets };
}

/// HH:MM:SS from seconds.
export const fmtHMS = (s: number): string => {
  const c = Math.max(0, Math.floor(s));
  const h = Math.floor(c / 3600), m = Math.floor((c % 3600) / 60), x = c % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(x).padStart(2, "0")}`;
};

/// One live countdown string to a target time (ms epoch). Ticks each second; "00:00:00" once due.
export function useCountdown(targetMs: number | null): string {
  const [, force] = useState(0);
  useEffect(() => {
    if (targetMs === null) return;
    const t = setInterval(() => force((n) => n + 1), 1000);
    return () => clearInterval(t);
  }, [targetMs]);
  if (targetMs === null) return "—";
  return fmtHMS((targetMs - Date.now()) / 1000);
}
