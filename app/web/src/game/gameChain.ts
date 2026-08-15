// D.O.N. game — chain wiring layer. This module (with gameAbi.ts) is the ONLY place the game
// touches addresses/clients: swapping the GAME_ADDR constants below (and, if the deployed ABIs
// drifted from the architecture sketches, the strings in gameAbi.ts) is the entire integration
// surface. Reads ride the site's existing shared public client (live.ts, READ-ONLY import);
// writes go through the selected-provider wallet pattern (wallet.tsx), same as every other page.
import {
  createWalletClient,
  custom,
  parseAbiItem,
  type Address,
  type Hex,
} from "viem";
import { pub, NET, ADDR, niceError } from "../live";
import { getSelectedProvider } from "../wallet";

export { pub, NET, ADDR, niceError };

export const ZERO = "0x0000000000000000000000000000000000000000" as Address;

// ═════════════════════════════════════════════════════════════════════════════════════════════
// GAME_ADDR — RH testnet deploy, block 100489472. The as-built stack CONSOLIDATED the sketch's
// separate contracts: EIP-712 loadout settlement + brief posting live INSIDE MissionBoard, and
// the sealed Favor slot lives INSIDE HitterNFT — so loadoutRegistry/briefPoster alias the
// MissionBoard address and traitSeal aliases HitterNFT.
// ═════════════════════════════════════════════════════════════════════════════════════════════
export const GAME_ADDR = {
  loadoutRegistry: "0x15D607638BeEcF9d62E6eC00a37601A89E72CDF1" as Address, // = MissionBoard (EIP-712 loadout settle consolidated in)
  missionBoard: "0x15D607638BeEcF9d62E6eC00a37601A89E72CDF1" as Address, // MissionBoard — depart/resolve/reclaim
  briefPoster: "0x15D607638BeEcF9d62E6eC00a37601A89E72CDF1" as Address, // = MissionBoard (briefs posted/stored on the board itself)
  houseDeed: "0x689dF249cEFF6e28d3EB7dDE125CEa7f7f29700d" as Address, // HouseDeed 721 — tiers (soulbound in Phase 0)
  houseEscrow: "0x24cB6Db8F4d52d78742bc0304B08710B053cdB7e" as Address, // HouseEscrow — deployed/hopper custody + bank/repair
  raidEngine: "0xc4B372ff6b3c2Ba511FB8Affa54f88F3Bdc1b2f6" as Address, // RaidEngine — commit/reveal/floorSettle/reclaimRaid
  hitter: "0x5C714163454D525906Ab6273d1cec701A5399103" as Address, // HitterNFT 721 — crew units
  traitSeal: "0x5C714163454D525906Ab6273d1cec701A5399103" as Address, // = HitterNFT (the sealed Favor slot consolidated in)
  scrip: "0x31D04bd5b1c1eAE56698F1A90C3fEe3e590f6E93" as Address, // Scrip — season-scoped points
} as const;

/// The Don collection is the existing deployed 721 — the game plays with the real Dons.
export const DON_COLLECTION = ADDR.don;

/// Are the game contracts wired yet? The UI ships before the deploy; every chain-touching path
/// gates on this and shows the "posts with the season" state instead of reverting txs.
export const gameConfigured = (): boolean => GAME_ADDR.missionBoard !== ZERO;

// ---------------------------------------------------------------------------------------------
// Writes — the same selected-provider viem pattern as live.ts's private `send` (that one is not
// exported, so the ~15 lines are mirrored here rather than modifying live.ts, which is off-limits
// to this lane). Orbit gas cushion included: estimation under-shoots intrinsic gas on this stack.
// ---------------------------------------------------------------------------------------------
export function gameWallet(account: Address) {
  const provider = getSelectedProvider();
  if (!provider) throw new Error("No wallet connected");
  return createWalletClient({
    account,
    chain: undefined,
    transport: custom(provider),
  });
}

export async function gameSend(
  account: Address,
  to: Address,
  abi: readonly unknown[],
  functionName: string,
  args: unknown[] = [],
  value?: bigint,
  gasLimit?: bigint,
): Promise<Hex> {
  // Wallets require balance >= gasLimit x gasPrice + value to SUBMIT — a flat 3M pin made the raid
  // reveal unaffordable for low-gas testers even though it uses ~443k (full-loop verify, HIGH):
  // the ◫50 commit fee then forfeited at window close. Callers pass a right-sized pin; the 3M
  // default stays for heavyweight paths (first-play depart mints deed + stipend + reservation).
  const w = gameWallet(account);
  const hash = await w.writeContract({
    address: to,
    abi: abi as never,
    functionName: functionName as never,
    args: args as never,
    account,
    chain: null,
    gas: gasLimit ?? 3_000_000n,
    ...(value !== undefined ? { value } : {}),
  });
  const rcpt = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  if (rcpt.status !== "success") throw new Error("Transaction reverted");
  return hash;
}

// ---------------------------------------------------------------------------------------------
// Owned-token scan for an arbitrary 721 (Hitters) — the reads.ownedDons technique (Transfer
// in-minus-out; exact and honest), parameterized by collection address.
// ---------------------------------------------------------------------------------------------
const erc721Transfer = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
);

export async function ownedTokens(
  collection: Address,
  a: Address,
  fromBlock: bigint,
): Promise<bigint[]> {
  const [inLogs, outLogs] = await Promise.all([
    pub.getLogs({
      address: collection,
      event: erc721Transfer,
      args: { to: a },
      fromBlock,
      toBlock: "latest",
    }),
    pub.getLogs({
      address: collection,
      event: erc721Transfer,
      args: { from: a },
      fromBlock,
      toBlock: "latest",
    }),
  ]);
  const owned = new Set<string>();
  const evts = [
    ...inLogs.map((l) => ({ l, dir: "in" as const })),
    ...outLogs.map((l) => ({ l, dir: "out" as const })),
  ].sort((x, y) =>
    x.l.blockNumber === y.l.blockNumber
      ? Number(x.l.logIndex - y.l.logIndex)
      : Number(x.l.blockNumber - y.l.blockNumber),
  );
  for (const { l, dir } of evts) {
    const id = (l.args as { tokenId?: bigint }).tokenId?.toString();
    if (id === undefined) continue;
    if (dir === "in") owned.add(id);
    else owned.delete(id);
  }
  return [...owned].map(BigInt).sort((x, y) => (x < y ? -1 : 1));
}

/// Game-stack deploy block (keeps the Hitter/mission log scans cheap).
export const GAME_DEPLOY_BLOCK = 100489472n;

// ---------------------------------------------------------------------------------------------
// Local persistence for the two secrets the client must remember between txs:
//  - the garrison plaintext+salt (handed to the keeper reveal rail; kept locally as the
//    permissionless-reveal fallback)
//  - the raid commit preimage (needed to build the reveal tx)
// ---------------------------------------------------------------------------------------------
export type GarrisonSecret = { hitterIds: string[]; salt: Hex };
export type RaidSecret = {
  attackerDonId: string;
  raidId: string;
  hitterIds: string[];
  targetDonId: string;
  salt: Hex;
  committedAt: number;
};

const jset = (k: string, v: unknown) => {
  try {
    localStorage.setItem(k, JSON.stringify(v));
  } catch {
    /* private mode */
  }
};
const jget = <T>(k: string): T | null => {
  try {
    const s = localStorage.getItem(k);
    return s ? (JSON.parse(s) as T) : null;
  } catch {
    return null;
  }
};

// Keys are namespaced by CONNECTED ADDRESS + token id (pre-push audit, code-security lens): a single
// global key let a second commit clobber the first raid's preimage (forfeiting its 50-Scrip fee) and
// let another account on a shared browser read a defender's REDACTED garrison composition.
const addrKey = (a: Address) => a.toLowerCase();
export const saveGarrisonSecret = (
  addr: Address,
  donId: bigint,
  s: GarrisonSecret,
) => jset(`essey.game.garrison.${addrKey(addr)}.${donId}`, s);
export const loadGarrisonSecret = (addr: Address, donId: bigint) =>
  jget<GarrisonSecret>(`essey.game.garrison.${addrKey(addr)}.${donId}`);
export const saveRaidSecret = (addr: Address, s: RaidSecret) =>
  jset(`essey.game.raid.${addrKey(addr)}.${s.attackerDonId}`, s);
export const loadRaidSecret = (addr: Address, attackerDonId: bigint) =>
  jget<RaidSecret>(`essey.game.raid.${addrKey(addr)}.${attackerDonId}`);
export const clearRaidSecret = (addr: Address, attackerDonId: bigint) => {
  try {
    localStorage.removeItem(
      `essey.game.raid.${addrKey(addr)}.${attackerDonId}`,
    );
  } catch {
    /* ignore */
  }
};
