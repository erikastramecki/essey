// THE WIRE — the game-era explorer's data layer. One multi-address full-history getLogs over the
// six game contracts (proven cheap live: ~236 logs, ~200ms), decoded client-side and enriched
// (briefId→codename from BriefPosted history, raidId→parties joined across commit/reveal/settle).
// The row store is MONOTONIC (the useGame.ts log-lag rule): rows are deduped by tx:logIndex and
// never removed on a scan miss; street membership changes only when a direct read confirms it.
// Reads batch through multicall3 at the canonical address — live.ts's `pub` is created without a
// chain object, so viem cannot auto-resolve the multicall address: it is ALWAYS passed explicitly.
//
// Enum ground truth (verified against the .sol before wiring copy — the two ladders have OPPOSITE
// polarity and must never share a legend):
//   MissionBoard.Resolved.outcome  — 0 SUCCESS (clean) / 1 PARTIAL (sideways) / 2 FAIL (bust)
//   RaidEngine.RaidSettled.outcome — 0 MISS / 1 COMMON / 2 BIG / 4 RECLAIMED (3 never emitted)
//   HitterNFT.FavorRevealed.band   — 0 empty / 1 small / 2 real / 3 THE DON OWES YOU (1 in 67)
import { decodeEventLog, parseAbi, type Address, type Hex } from "viem";
import { pub, reads } from "../live";
import { GAME_ADDR, GAME_DEPLOY_BLOCK, DON_COLLECTION, ownedTokens } from "./gameChain";
import { missionBoardAbi, houseDeedAbi, houseEscrowAbi, raidEngineAbi, hitterAbi, scripAbi } from "./gameAbi";
import { fmtAmt } from "./bits";
import { BRIEFS } from "./briefs";

export const MC3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as Address;

type Call = { address: Address; abi: readonly unknown[]; functionName: string; args?: readonly unknown[] };
/// multicall3 wrapper — allowFailure, per-read null on failure, multicallAddress explicit.
export async function mc(contracts: Call[]): Promise<(unknown | null)[]> {
  if (contracts.length === 0) return [];
  const res = await pub.multicall({ multicallAddress: MC3, allowFailure: true, contracts: contracts as never });
  return (res as { status: string; result?: unknown }[]).map((r) => (r.status === "success" ? (r.result as unknown) : null));
}

// ---------------------------------------------------------------------------------------------
// Row model. ⟦…⟧ segments render as mono-white <b>; the rest stays muted. Amounts: ◫ = Scrip.
// ---------------------------------------------------------------------------------------------
export type StampTone = "ok" | "crit" | "gold" | "warn" | "mut" | "carbon";
export type WireRow = {
  key: string; block: bigint; logIndex: number; tx: Hex;
  filter: "JOBS" | "RAIDS" | "HOUSES" | "CREW" | "MONEY";
  kind: string;           // decoded event name (or "tape" for protocol MONEY rows)
  icon: string;
  text: string;
  muted?: boolean;
  stamp?: { text: string; tone: StampTone; big?: boolean; thump?: boolean };
  donId?: bigint; missionId?: bigint; raidId?: bigint; hitterId?: bigint;
  countdown?: boolean;    // Departed rows: live chip from missions(missionId).due
  amt?: bigint; amt2?: bigint; // primary amount / secondary (raid tax) — the FLOOR's burn sums
  hit?: { taken: bigint; big: boolean }; // RaidSettled outcome 1|2 (donId = target)
};

const b = (s: unknown) => `⟦${String(s)}⟧`;
const don = (id: unknown) => `Don ⟦№${String(id ?? "?")}⟧`;
const hid = (id: unknown) => `⟦H-${String(id)}⟧`;
/// ◫ Scrip amount via the existing fmtAmt — 2dp under 100 so small fees don't print as 0.
export const fmtScrip = (v: unknown): string => {
  const n = (v as bigint) ?? 0n; const a = n < 0n ? -n : n;
  return `◫${fmtAmt(n, a < 100n * 10n ** 18n && a % 10n ** 18n !== 0n ? 2 : 0)}`;
};
const fmtDur = (s: number): string => (s < 120 ? `${s}s` : s < 7200 ? `${Math.round(s / 60)}m` : `${Math.round(s / 3600)}h`);

// ---------------------------------------------------------------------------------------------
// Enrichment caches (module-level; every entry is immutable chain history).
// ---------------------------------------------------------------------------------------------
const briefInfo = new Map<string, { codename: string; tier: number; duration: number }>();
for (const bf of Object.values(BRIEFS)) briefInfo.set(bf.chainId.toString(), { codename: bf.code, tier: -1, duration: Math.round(bf.durationH * 3600) });
const missionBrief = new Map<string, bigint>();    // missionId → briefId (from Departed)
const raidParties = new Map<string, { attacker: bigint; target?: bigint }>(); // from commit/reveal
const missionDue = new Map<string, number>();      // missionId → due (ms), from missions() reads
export const missionDueMs = (mid: bigint): number | null => missionDue.get(mid.toString()) ?? null;

const codename = (briefId: bigint | undefined) => (briefId !== undefined && briefInfo.get(briefId.toString())?.codename) || `brief #${briefId ?? "?"}`;
/// Jackpot tier = ABSOLUTE ZERO's posted tier (brief 4); falls back to the briefId itself.
const isJackpotBrief = (briefId: bigint | undefined): boolean => {
  if (briefId === undefined) return false;
  const zt = briefInfo.get("4")?.tier ?? -1;
  const t = briefInfo.get(briefId.toString())?.tier ?? -2;
  return zt >= 0 ? t === zt : briefId === 4n;
};

// ---------------------------------------------------------------------------------------------
// The scan: one unfiltered multi-address getLogs, decoded against each contract's own ABI.
// ---------------------------------------------------------------------------------------------
const SRC: { name: string; address: Address; abi: readonly unknown[] }[] = [
  { name: "board", address: GAME_ADDR.missionBoard, abi: missionBoardAbi },
  { name: "escrow", address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi },
  { name: "raid", address: GAME_ADDR.raidEngine, abi: raidEngineAbi },
  { name: "hitter", address: GAME_ADDR.hitter, abi: hitterAbi },
  { name: "deed", address: GAME_ADDR.houseDeed, abi: houseDeedAbi },
  { name: "scrip", address: GAME_ADDR.scrip, abi: scripAbi },
];
const byAddr = new Map(SRC.map((s) => [s.address.toLowerCase(), s]));

type Decoded = { src: string; name: string; a: Record<string, unknown>; block: bigint; logIndex: number; tx: Hex };

export async function fetchGameWire(since?: bigint): Promise<{ rows: WireRow[]; head: bigint; scanned: bigint }> {
  const head = await pub.getBlockNumber();
  // Incremental scans re-cover 60 blocks of overlap: the load-balanced RPC's nodes index logs at
  // different speeds, and the dedupe key absorbs the re-reads.
  const from = since === undefined ? GAME_DEPLOY_BLOCK : since > 60n ? since - 60n : 0n;
  const logs = await pub.getLogs({ address: SRC.map((s) => s.address), fromBlock: from, toBlock: head });
  const dec: Decoded[] = [];
  for (const l of logs) {
    const src = byAddr.get((l.address as string).toLowerCase());
    if (!src || l.blockNumber === null || l.transactionHash === null || l.logIndex === null) continue;
    try {
      const d = decodeEventLog({ abi: src.abi as never, data: l.data, topics: l.topics as never }) as unknown as { eventName: string; args: Record<string, unknown> };
      dec.push({ src: src.name, name: d.eventName, a: d.args ?? {}, block: l.blockNumber, logIndex: l.logIndex, tx: l.transactionHash });
    } catch { /* event not in our ABI surface — skip */ }
  }
  // Pass 1 — enrichment caches (must land before row copy is built: Resolved needs Departed's briefId).
  for (const d of dec) {
    if (d.src === "board" && d.name === "BriefPosted") briefInfo.set(String(d.a.briefId), { codename: String(d.a.codename), tier: Number(d.a.tier), duration: Number(d.a.duration) });
    if (d.src === "board" && d.name === "Departed") missionBrief.set(String(d.a.missionId), d.a.briefId as bigint);
    if (d.src === "raid" && d.name === "RaidCommitted") raidParties.set(String(d.a.raidId), { attacker: d.a.attackerDon as bigint, ...raidParties.get(String(d.a.raidId)) });
    if (d.src === "raid" && d.name === "RaidRevealed") raidParties.set(String(d.a.raidId), { attacker: d.a.attackerDon as bigint, target: d.a.targetDon as bigint });
  }
  const rows = dec.map(rowFor).filter((r): r is WireRow => r !== null);
  return { rows, head, scanned: head };
}

/// One decoded log → one world-voice row (or null: suppressed by the design's event table).
function rowFor(d: Decoded): WireRow | null {
  const a = d.a;
  const base = { key: `${d.tx}:${d.logIndex}`, block: d.block, logIndex: d.logIndex, tx: d.tx, kind: d.name };
  switch (`${d.src}.${d.name}`) {
    case "board.BriefPosted": {
      const dur = fmtDur(Number(a.duration));
      return { ...base, filter: "JOBS", icon: "§", text: `NEW POSTING · "${b(a.codename)}" hits the board · tier ${b(a.tier)} · ${b(dur)} window` };
    }
    case "board.Departed":
      return { ...base, filter: "JOBS", icon: "→", donId: a.donId as bigint, missionId: a.missionId as bigint, countdown: true, amt: a.fee as bigint,
        text: `${don(a.donId)} took the ${b(codename(a.briefId as bigint))} job · door fee ${b(fmtScrip(a.fee))} paid · back in ~${fmtDur(briefInfo.get(String(a.briefId))?.duration ?? 0)}` };
    case "board.ResolveRequested":
      return { ...base, filter: "JOBS", icon: "◇", muted: true, missionId: a.missionId as bigint, text: `the Keeper picked up mission #${b(a.missionId)}` };
    case "board.Resolved": {
      const briefId = missionBrief.get(String(a.missionId));
      const cn = codename(briefId); const o = Number(a.outcome); // 0 SUCCESS / 1 PARTIAL / 2 FAIL (MissionBoard.sol L341)
      const donId = a.donId as bigint; const missionId = a.missionId as bigint; const amt = a.payout as bigint;
      if (o === 0 && isJackpotBrief(briefId))
        return { ...base, filter: "JOBS", icon: "◆", donId, missionId, amt, stamp: { text: "JACKPOT", tone: "gold", big: true, thump: true }, text: `${don(donId)} PULLED IT OFF — the ${b(cn)} jackpot · ${b(fmtScrip(amt))}` };
      if (o === 0)
        return { ...base, filter: "JOBS", icon: "◆", donId, missionId, amt, stamp: { text: "CLEAN", tone: "ok" }, text: `${don(donId)} came home CLEAN from ${b(cn)} · ${b(fmtScrip(amt))} lands in the hopper` };
      if (o === 1)
        return { ...base, filter: "JOBS", icon: "◆", donId, missionId, amt, text: `the ${b(cn)} job went SIDEWAYS on ${don(donId)} · ${b(fmtScrip(amt))} partial pay` };
      return { ...base, filter: "JOBS", icon: "✕", donId, missionId, amt, stamp: { text: "BUST", tone: "crit" }, text: `${don(donId)} busted on ${b(cn)} · nothing came home · provisions gone` };
    }
    case "board.Reclaimed":
      return { ...base, filter: "JOBS", icon: "◇", donId: a.donId as bigint, missionId: a.missionId as bigint, amt: a.payout as bigint,
        text: `the Keeper stalled · mission #${b(a.missionId)} settled itself at the sideways floor · ${b(fmtScrip(a.payout))} to ${don(a.donId)} · slow is possible, stuck is not` };
    case "board.BudgetFunded": // the mission budget (FLOOR "refills" sum keys on kind BudgetFunded)
      return { ...base, filter: "MONEY", icon: "◆", amt: a.amount as bigint, text: `the city budget got funded · ${b(fmtScrip(a.amount))}` };
    case "escrow.BudgetFunded": // the yield/stipend lines — same voice, separate kind for the sums
      return { ...base, kind: "BudgetFundedLine", filter: "MONEY", icon: "◆", amt: a.amount as bigint, text: `the city budget got funded · ${b(fmtScrip(a.amount))}` };
    case "raid.RaidCommitted":
      return { ...base, filter: "RAIDS", icon: "✉", donId: a.attackerDon as bigint, raidId: a.raidId as bigint,
        text: `a sealed hit order was filed by a crew working for ${don(a.attackerDon)} · target undisclosed · 50 Scrip on the table` };
    case "raid.RaidRevealed":
      return { ...base, filter: "RAIDS", icon: "▶", donId: a.targetDon as bigint, raidId: a.raidId as bigint,
        text: `THE DOOR GETS KICKED · ${don(a.attackerDon)}'s crew moves on ${don(a.targetDon)}'s house · attack power ${b(a.attackPower)}` };
    case "raid.GarrisonRevealed":
      return { ...base, filter: "RAIDS", icon: "▣", donId: a.targetDon as bigint, raidId: a.raidId as bigint,
        text: `${don(a.targetDon)}'s garrison steps out of the fog · defense power ${b(a.defensePower)}` };
    case "raid.RaidSettled": {
      const p = raidParties.get(String(a.raidId));
      const o = Number(a.outcome); // 0 MISS / 1 COMMON / 2 BIG / 4 RECLAIMED (RaidEngine.sol L133)
      const raidId = a.raidId as bigint; const amt = a.taken as bigint; const amt2 = a.tax as bigint;
      if (o === 0) return { ...base, filter: "RAIDS", icon: "✕", raidId, donId: p?.target, amt2, stamp: { text: "HELD", tone: "ok" }, text: `THE DOOR HELD · the crew on ${don(p?.target)}'s house walked away with nothing` };
      if (o === 1) return { ...base, filter: "RAIDS", icon: "▪", raidId, donId: p?.target, amt, amt2, hit: { taken: amt, big: false }, stamp: { text: "HIT", tone: "crit" }, text: `THEY CRACKED THE BACK OFFICE · ${don(p?.target)}'s hopper emptied — ${b(fmtScrip(amt))} taken, ${b(fmtScrip(amt2))} to the Floor` };
      if (o === 2) return { ...base, filter: "RAIDS", icon: "▪", raidId, donId: p?.target, amt, amt2, hit: { taken: amt, big: true }, stamp: { text: "BIG SCORE", tone: "crit", big: true, thump: true }, text: `THE SAFE CAME OUT THE WINDOW — ${don(p?.target)}'s house lost ${b(fmtScrip(amt))} to a crew working for ${don(p?.attacker)} · the Floor ate ${b(fmtScrip(amt2))}` };
      return { ...base, filter: "RAIDS", icon: "◇", raidId, text: `entropy withheld · raid #${b(raidId)} unwound, nobody paid` };
    }
    case "raid.HitterDown":
      return { ...base, filter: "RAIDS", icon: "✚", raidId: a.raidId as bigint, hitterId: a.hitterId as bigint, stamp: { text: "TAKEN", tone: "carbon" }, text: `${hid(a.hitterId)} got TAKEN on the job · 48 hours in the hospital` };
    case "raid.RaidForfeited":
      return { ...base, filter: "RAIDS", icon: "✕", raidId: a.raidId as bigint, amt: 50n * 10n ** 18n, text: `a crew lost its nerve · raid #${b(a.raidId)} forfeited · the 50 burns at the incinerator` };
    case "escrow.Deployed":
      return { ...base, filter: "HOUSES", icon: "↥", donId: a.donId as bigint, amt: a.amount as bigint, text: `${don(a.donId)} put ${b(fmtScrip(a.amount))} to work on the House · robbable now, and everyone knows it` };
    case "escrow.Banked":
      return { ...base, filter: "HOUSES", icon: "⌂", donId: a.donId as bigint, amt: (a.fromDeployed as bigint) + (a.fromHopper as bigint), text: `${don(a.donId)} BANKED ${b(fmtScrip((a.fromDeployed as bigint) + (a.fromHopper as bigint)))} · vaulted, untouchable, free forever` };
    case "escrow.LootCredited":
      return { ...base, filter: "HOUSES", icon: "▪", donId: a.donId as bigint, amt: a.amount as bigint, text: `${b(fmtScrip(a.amount))} in loot lands in ${don(a.donId)}'s hopper` };
    case "escrow.YieldAccrued":
      return { ...base, filter: "HOUSES", icon: "◆", donId: a.donId as bigint, amt: a.amount as bigint, text: `the House pays · ${b(fmtScrip(a.amount))} yield to ${don(a.donId)}` };
    case "escrow.RaidApplied":
      return null; // suppressed by design: RaidSettled tells the story (same tx — avoid the double-print)
    case "escrow.Damaged":
      return { ...base, filter: "HOUSES", icon: "▨", donId: a.donId as bigint, stamp: { text: "SCARRED", tone: "warn" }, text: `${don(a.donId)}'s house is SCARRED · earning -40% until repaired · a public confession on the Tape` };
    case "escrow.Repaired":
      return { ...base, filter: "HOUSES", icon: "▧", donId: a.donId as bigint, amt: a.fee as bigint, text: `${don(a.donId)} settled the repair bill · ${b(fmtScrip(a.fee))} · the house earns whole again` };
    case "escrow.StipendPaid":
      return { ...base, filter: "HOUSES", icon: "◇", donId: a.donId as bigint, amt: a.amount as bigint, text: `stipend · ${b(fmtScrip(a.amount))} to ${don(a.donId)}` };
    case "deed.SafehouseClaimed":
      return { ...base, filter: "HOUSES", icon: "⌂", donId: a.donId as bigint, text: `${don(a.donId)} claimed a Safehouse · deed #${b(a.deedId)} · nobody sneers at a Safehouse` };
    case "deed.Upgraded":
      return { ...base, filter: "HOUSES", icon: "▲", donId: a.donId as bigint, amt: a.fee as bigint, text: `${don(a.donId)} moved up · the deed climbs to tier ${b(a.toTier)} · ${b(fmtScrip(a.fee))} paid` };
    case "hitter.HitterMinted":
      return { ...base, filter: "CREW", icon: "✚", donId: a.payerDonId as bigint, hitterId: a.id as bigint, text: `${don(a.payerDonId)} put a new soldier on the payroll · ${hid(a.id)} · envelope sealed` };
    case "hitter.FavorRevealRequested":
      return { ...base, filter: "CREW", icon: "✉", muted: true, hitterId: a.id as bigint, text: `${hid(a.id)}'s envelope is at the Keeper's desk` };
    case "hitter.FavorRevealed": {
      const band = Number(a.band); // 0 empty / 1 small / 2 real / 3 top (HitterNFT.sol _bandName)
      const forced = a.forced ? " · forced open after 30 days · forced envelopes come up empty" : "";
      const hitterId = a.id as bigint;
      if (band === 3) return { ...base, filter: "CREW", icon: "✉", hitterId, stamp: { text: "THE DON OWES YOU", tone: "gold", big: true, thump: true }, text: `CITYWIDE · ${hid(hitterId)} opened the envelope and THE DON OWES HIM · 1 in 67${forced}` };
      if (band === 2) return { ...base, filter: "CREW", icon: "✉", hitterId, stamp: { text: "A REAL FAVOR", tone: "ok" }, text: `${hid(hitterId)} opened the envelope · a real favor from the family${forced}` };
      if (band === 1) return { ...base, filter: "CREW", icon: "✉", hitterId, text: `${hid(hitterId)} opened the envelope · a small favor${forced}` };
      return { ...base, filter: "CREW", icon: "✉", hitterId, stamp: { text: "EMPTY", tone: "mut" }, text: `${hid(hitterId)} opened the envelope · empty · the moment still prints${forced}` };
    }
    default:
      return null; // Transfer / KitAttested / AttemptNoted / Hospitalized / Scrip flows: no design template — never fabricate a line
  }
}

/// Monotonic merge — union by key, never remove, newest first, capped.
export function mergeWire(prev: WireRow[], next: WireRow[], cap = 300): WireRow[] {
  const seen = new Map(prev.map((r) => [r.key, r]));
  for (const r of next) if (!seen.has(r.key)) seen.set(r.key, r);
  return [...seen.values()]
    .sort((x, y) => (x.block === y.block ? y.logIndex - x.logIndex : x.block < y.block ? 1 : -1))
    .slice(0, cap);
}

// ---------------------------------------------------------------------------------------------
// Block timestamps: the RPC returns blockTimestamp 0 on logs, so wall-clock time costs one
// getBlock per UNIQUE block — memoized forever, resolved only for visible rows.
// ---------------------------------------------------------------------------------------------
const tsCache = new Map<string, number>();
export async function blockTs(block: bigint): Promise<number | null> {
  const k = block.toString();
  const hit = tsCache.get(k);
  if (hit !== undefined) return hit;
  try {
    const bl = await pub.getBlock({ blockNumber: block });
    const t = Number(bl.timestamp) * 1000;
    tsCache.set(k, t);
    return t;
  } catch { return null; }
}
export const tsOf = (block: bigint): number | null => tsCache.get(block.toString()) ?? null;

// ---------------------------------------------------------------------------------------------
// THE FLOOR — the proven one-multicall economy read (custody invariant checked live).
// ---------------------------------------------------------------------------------------------
const extraAbi = parseAbi([
  "function outstandingReserved() view returns (uint256)",
  "function totalDeployed() view returns (uint256)",
  "function totalHopper() view returns (uint256)",
  "function yieldBudget() view returns (uint256)",
  "function stipendBudget() view returns (uint256)",
  "function raidCount() view returns (uint64)",
]);

export type Economy = {
  supply: bigint | null; burned: bigint | null; seasonId: number | null;
  missionBudget: bigint | null; outstandingReserved: bigint | null;
  totalDeployed: bigint | null; totalHopper: bigint | null; escrowBal: bigint | null;
  yieldBudget: bigint | null; stipendBudget: bigint | null;
  raidCount: number | null; missionCount: number | null; briefCount: number | null; hittersMinted: number | null;
  custodyOk: boolean | null; // scrip.balanceOf(escrow) === totalDeployed + totalHopper, exactly
};

export async function fetchEconomy(): Promise<Economy> {
  const r = await mc([
    { address: GAME_ADDR.scrip, abi: scripAbi, functionName: "totalSupply" },
    { address: GAME_ADDR.scrip, abi: scripAbi, functionName: "totalBurned" },
    { address: GAME_ADDR.scrip, abi: scripAbi, functionName: "seasonId" },
    { address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "missionBudget" },
    { address: GAME_ADDR.missionBoard, abi: extraAbi, functionName: "outstandingReserved" },
    { address: GAME_ADDR.houseEscrow, abi: extraAbi, functionName: "totalDeployed" },
    { address: GAME_ADDR.houseEscrow, abi: extraAbi, functionName: "totalHopper" },
    { address: GAME_ADDR.scrip, abi: scripAbi, functionName: "balanceOf", args: [GAME_ADDR.houseEscrow] },
    { address: GAME_ADDR.houseEscrow, abi: extraAbi, functionName: "yieldBudget" },
    { address: GAME_ADDR.houseEscrow, abi: extraAbi, functionName: "stipendBudget" },
    { address: GAME_ADDR.raidEngine, abi: extraAbi, functionName: "raidCount" },
    { address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "missionCount" },
    { address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "briefCount" },
    { address: GAME_ADDR.hitter, abi: hitterAbi, functionName: "totalMinted" },
  ]);
  const bi = (v: unknown | null) => (v === null ? null : (v as bigint));
  const num = (v: unknown | null) => (v === null ? null : Number(v));
  const totalDeployed = bi(r[5]), totalHopper = bi(r[6]), escrowBal = bi(r[7]);
  return {
    supply: bi(r[0]), burned: bi(r[1]), seasonId: num(r[2]),
    missionBudget: bi(r[3]), outstandingReserved: bi(r[4]),
    totalDeployed, totalHopper, escrowBal,
    yieldBudget: bi(r[8]), stipendBudget: bi(r[9]),
    raidCount: num(r[10]), missionCount: num(r[11]), briefCount: num(r[12]), hittersMinted: num(r[13]),
    custodyOk: totalDeployed !== null && totalHopper !== null && escrowBal !== null ? escrowBal === totalDeployed + totalHopper : null,
  };
}

// ---------------------------------------------------------------------------------------------
// THE STREET — away Dons, open hit orders, houses hit, the hospital. Candidates come from the
// wire store (0 extra getLogs); membership is confirmed by direct reads (log-lag rule).
// ---------------------------------------------------------------------------------------------
export type StreetJob = { donId: bigint; missionId: bigint; briefId: bigint; codename: string; dueMs: number; deployed: bigint; hopper: bigint; heatMs: number; bigLockMs: number };
export type StreetRaid = { raidId: bigint; attacker: bigint; target: bigint; state: number; committedAt: number; revealedAt: number; garrisonRevealed: boolean };
export type HospitalRow = { hitterId: bigint; untilMs: number };
export type HouseHit = { donId: bigint; raidId: bigint; taken: bigint; big: boolean; damaged: boolean; tx: Hex; tsMs: number | null };
export type Street = { jobs: StreetJob[]; raids: StreetRaid[]; hospital: HospitalRow[]; hits: HouseHit[] };

const WEEK_MS = 7 * 24 * 3600 * 1000;

export async function fetchStreet(rows: WireRow[]): Promise<Street> {
  // OUT ON JOBS — distinct departed Dons, kept only while activeMissionOf confirms them away.
  const cand = [...new Set(rows.filter((r) => r.kind === "Departed" && r.donId !== undefined).map((r) => r.donId!.toString()))].map(BigInt);
  const active = await mc(cand.map((id) => ({ address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "activeMissionOf", args: [id] })));
  const away = cand.map((id, i) => ({ donId: id, mid: (active[i] as bigint | null) ?? 0n })).filter((x) => x.mid !== 0n);
  const per = await mc(away.flatMap(({ donId, mid }) => [
    { address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "missions", args: [mid] },
    { address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "deployedOf", args: [donId] },
    { address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "hopperOf", args: [donId] },
    { address: GAME_ADDR.raidEngine, abi: raidEngineAbi, functionName: "heatUntil", args: [donId] },
    { address: GAME_ADDR.raidEngine, abi: raidEngineAbi, functionName: "bigLockUntil", args: [donId] },
  ] as Call[]));
  const jobs: StreetJob[] = [];
  away.forEach(({ donId, mid }, i) => {
    const m = per[i * 5] as readonly unknown[] | null;
    if (!m) return;
    const briefId = m[1] as bigint; const due = Number(m[3]) * 1000;
    missionDue.set(mid.toString(), due); // feeds the WIRE's Departed countdown chips
    jobs.push({
      donId, missionId: mid, briefId, codename: codename(briefId), dueMs: due,
      deployed: (per[i * 5 + 1] as bigint | null) ?? 0n, hopper: (per[i * 5 + 2] as bigint | null) ?? 0n,
      heatMs: Number((per[i * 5 + 3] as bigint | null) ?? 0n) * 1000, bigLockMs: Number((per[i * 5 + 4] as bigint | null) ?? 0n) * 1000,
    });
  });
  jobs.sort((x, y) => x.dueMs - y.dueMs);

  // OPEN HIT ORDERS — commits minus settles/forfeits, state confirmed by raids(raidId).
  const done = new Set(rows.filter((r) => r.kind === "RaidSettled" || r.kind === "RaidForfeited").map((r) => r.raidId!.toString()));
  const openIds = [...new Set(rows.filter((r) => r.kind === "RaidCommitted").map((r) => r.raidId!.toString()))].filter((id) => !done.has(id)).map(BigInt);
  const raidReads = await mc(openIds.map((id) => ({ address: GAME_ADDR.raidEngine, abi: raidEngineAbi, functionName: "raids", args: [id] })));
  const raids: StreetRaid[] = [];
  openIds.forEach((raidId, i) => {
    const r = raidReads[i] as readonly unknown[] | null;
    if (!r) return;
    const state = Number(r[9]); // RaidState: 0 Committed / 1 Revealed / 2 Settled / 3 Forfeited
    if (state >= 2) return;     // the read confirms it closed even if the settle log lagged
    raids.push({ raidId, attacker: r[0] as bigint, target: r[1] as bigint, state, committedAt: Number(r[2]) * 1000, revealedAt: Number(r[3]) * 1000, garrisonRevealed: Boolean(r[11]) });
  });

  // THE HOSPITAL — every minted Hitter's hospitalUntil (12 today; capped at the last 50).
  const hitterIds = [...new Set(rows.filter((r) => r.kind === "HitterMinted" && r.hitterId !== undefined).map((r) => r.hitterId!.toString()))].map(BigInt).slice(-50);
  const hosp = await mc(hitterIds.map((id) => ({ address: GAME_ADDR.hitter, abi: hitterAbi, functionName: "hospitalUntil", args: [id] })));
  const now = Date.now();
  const hospital: HospitalRow[] = hitterIds
    .map((hitterId, i) => ({ hitterId, untilMs: Number((hosp[i] as bigint | null) ?? 0n) * 1000 }))
    .filter((h) => h.untilMs > now)
    .sort((x, y) => x.untilMs - y.untilMs);

  // HOUSES HIT THIS WEEK — RaidSettled outcome 1|2, timestamped, plus current damage state.
  const hitRows = rows.filter((r) => r.hit && r.donId !== undefined);
  const hitTs = await Promise.all(hitRows.map((r) => blockTs(r.block)));
  const recent = hitRows.filter((_, i) => hitTs[i] === null || now - (hitTs[i] as number) <= WEEK_MS);
  const dmg = await mc(recent.map((r) => ({ address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "damageBps", args: [r.donId!] })));
  const hits: HouseHit[] = recent.map((r, i) => ({
    donId: r.donId!, raidId: r.raidId ?? 0n, taken: r.hit!.taken, big: r.hit!.big,
    damaged: Number((dmg[i] as bigint | null) ?? 0n) > 0, tx: r.tx, tsMs: hitTs[hitRows.indexOf(r)] ?? null,
  }));
  return { jobs, raids, hospital, hits };
}

// ---------------------------------------------------------------------------------------------
// FAMILIES — the per-Don dossier. Two sequential multicall round-trips, wallet-free.
// Vault figure mirrors useGame.ts exactly: reads.donState(id).vault → scrip.balanceOf(vault).
// ---------------------------------------------------------------------------------------------
const ownerOfAbi = parseAbi(["function ownerOf(uint256) view returns (address)"]);

export type CrewRow = { id: bigint; sealed: boolean; favor: number; hospitalMs: number };
export type Dossier = {
  donId: bigint; owner: Address;
  deedId: bigint; tier: number; defense: number; slots: number; deployCap: bigint;
  deployed: bigint; hopper: bigint; damageBps: number; pendingYield: bigint; repairFee: bigint;
  missionId: bigint; away: boolean; dueMs: number | null; briefId: bigint | null; codename: string | null;
  kitClaimed: boolean; kitClass: number; heatMs: number; bigLockMs: number;
  vault: Address | null; vaultScrip: bigint | null;
  crew: CrewRow[];
};

export async function fetchDossier(donId: bigint): Promise<Dossier | null> {
  const r1 = await mc([
    { address: DON_COLLECTION, abi: ownerOfAbi, functionName: "ownerOf", args: [donId] },
    { address: GAME_ADDR.houseDeed, abi: houseDeedAbi, functionName: "deedOf", args: [donId] },
    { address: GAME_ADDR.houseDeed, abi: houseDeedAbi, functionName: "tierOf", args: [donId] },
    { address: GAME_ADDR.houseDeed, abi: houseDeedAbi, functionName: "defenseOf", args: [donId] },
    { address: GAME_ADDR.houseDeed, abi: houseDeedAbi, functionName: "garrisonSlotsOf", args: [donId] },
    { address: GAME_ADDR.houseDeed, abi: houseDeedAbi, functionName: "deployCapOf", args: [donId] },
    { address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "deployedOf", args: [donId] },
    { address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "hopperOf", args: [donId] },
    { address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "damageBps", args: [donId] },
    { address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "pendingYieldOf", args: [donId] },
    { address: GAME_ADDR.houseEscrow, abi: houseEscrowAbi, functionName: "repairFeeOf", args: [donId] },
    { address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "activeMissionOf", args: [donId] },
    { address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "kitClaimed", args: [donId] },
    { address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "kitClassOf", args: [donId] },
    { address: GAME_ADDR.raidEngine, abi: raidEngineAbi, functionName: "heatUntil", args: [donId] },
    { address: GAME_ADDR.raidEngine, abi: raidEngineAbi, functionName: "bigLockUntil", args: [donId] },
  ]);
  const owner = r1[0] as Address | null;
  if (!owner) return null; // no such Don (or unminted): "no file under that number"
  const missionId = (r1[11] as bigint | null) ?? 0n;
  const d: Dossier = {
    donId, owner,
    deedId: (r1[1] as bigint | null) ?? 0n, tier: Number(r1[2] ?? 0), defense: Number(r1[3] ?? 0), slots: Number(r1[4] ?? 0), deployCap: (r1[5] as bigint | null) ?? 0n,
    deployed: (r1[6] as bigint | null) ?? 0n, hopper: (r1[7] as bigint | null) ?? 0n, damageBps: Number(r1[8] ?? 0), pendingYield: (r1[9] as bigint | null) ?? 0n, repairFee: (r1[10] as bigint | null) ?? 0n,
    missionId, away: missionId !== 0n, dueMs: null, briefId: null, codename: null,
    kitClaimed: Boolean(r1[12]), kitClass: Number(r1[13] ?? 0), heatMs: Number((r1[14] as bigint | null) ?? 0n) * 1000, bigLockMs: Number((r1[15] as bigint | null) ?? 0n) * 1000,
    vault: null, vaultScrip: null, crew: [],
  };
  // Round-trip 2: the 6551 vault (useGame's read, not re-derived), the mission if away, the crew.
  const [st, crewIds] = await Promise.all([
    reads.donState(donId).catch(() => null),
    ownedTokens(GAME_ADDR.hitter, owner, GAME_DEPLOY_BLOCK).catch(() => [] as bigint[]),
  ]);
  const calls: Call[] = [];
  if (st?.vault) calls.push({ address: GAME_ADDR.scrip, abi: scripAbi, functionName: "balanceOf", args: [st.vault] });
  if (d.away) calls.push({ address: GAME_ADDR.missionBoard, abi: missionBoardAbi, functionName: "missions", args: [missionId] });
  for (const id of crewIds) {
    calls.push({ address: GAME_ADDR.hitter, abi: hitterAbi, functionName: "sealed_", args: [id] });
    calls.push({ address: GAME_ADDR.hitter, abi: hitterAbi, functionName: "favorOf", args: [id] });
    calls.push({ address: GAME_ADDR.hitter, abi: hitterAbi, functionName: "hospitalUntil", args: [id] });
  }
  const r2 = await mc(calls);
  let k = 0;
  if (st?.vault) { d.vault = st.vault; d.vaultScrip = (r2[k++] as bigint | null); }
  if (d.away) {
    const m = r2[k++] as readonly unknown[] | null;
    if (m) {
      d.briefId = m[1] as bigint; d.dueMs = Number(m[3]) * 1000; d.codename = codename(d.briefId);
      missionDue.set(missionId.toString(), d.dueMs);
    }
  }
  d.crew = crewIds.map((id, i) => ({
    id,
    sealed: Boolean(r2[k + i * 3] ?? true),
    favor: Number(r2[k + i * 3 + 1] ?? 0),
    hospitalMs: Number((r2[k + i * 3 + 2] as bigint | null) ?? 0n) * 1000,
  }));
  return d;
}
