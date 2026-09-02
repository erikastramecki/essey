// The Tape's PROTOCOL feed — Robinhood Chain MAINNET (4663), the EsseyReserve's own history. Kept
// apart from tape.ts, the TESTNET game feed /explorer reads: one page pointed at both is what put
// 46630 rows under a "live" chip on the protocol front door.
//
// Deposits are queried on the recipient topic ALONE — no token allowlist, so the feed cannot miss a
// token nobody listed (a raw Transfer is how backing lands, EsseyReserve.sol:89-97). `fund()` emits
// both a Transfer and a Funded log, so Funded wins and its Transfer twin is dropped.
import { parseAbi, parseAbiItem, type Address, type Log } from "viem";
import { MAINNET, RESERVE, deployed, fmt, mainnetPub } from "./reserve";

export const mainnetLive = deployed;

export type TapeKind = "deposit" | "redeem" | "claim";

export type MainnetTapeRow = {
  key: string;
  block: bigint;
  tx: `0x${string}`;
  kind: TapeKind;
  mark: boolean; // an EsseyReserve event, vs a plain token transfer
  icon: string;
  text: string;
};

const TRANSFER = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 value)");

const RESERVE_EVENTS = [
  parseAbiItem("event Funded(address indexed from, address indexed token, uint256 amount)"),
  parseAbiItem("event Redeemed(uint256 indexed receiptId, address indexed owner, uint256 essey)"),
  parseAbiItem("event Claimed(uint256 indexed receiptId, address indexed token, uint256 amount)"),
  parseAbiItem("event ClaimSkipped(uint256 indexed receiptId, address indexed token)"),
] as const;

const erc20Meta = parseAbi([
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
]);

type Meta = { symbol: string; decimals: number };

/// A token whose symbol() reverts gets its address, never a guessed ticker.
const metaCache = new Map<string, Promise<Meta>>();
function meta(token: Address): Promise<Meta> {
  const key = token.toLowerCase();
  const hit = metaCache.get(key);
  if (hit) return hit;
  const pending = Promise.all([
    mainnetPub.readContract({ address: token, abi: erc20Meta, functionName: "symbol" }).catch(() => null),
    mainnetPub.readContract({ address: token, abi: erc20Meta, functionName: "decimals" }).catch(() => 18),
  ]).then(([symbol, decimals]) => ({
    symbol: (symbol as string | null) ?? `${token.slice(0, 6)}…${token.slice(-4)}`,
    decimals: Number(decimals),
  }));
  metaCache.set(key, pending);
  return pending;
}

/// Precision follows magnitude, or a real sub-share stock deposit renders as 0.00.
const amount = (v: bigint, decimals: number): string =>
  fmt(v, decimals, v < 10n ** BigInt(decimals) ? 6 : 2);

const isEssey = (t: Address) => t.toLowerCase() === RESERVE.essey.toLowerCase();

type AnyLog = Log & { eventName?: string; args?: Record<string, unknown> };

const base = (l: AnyLog) => ({
  key: `${l.transactionHash}:${l.logIndex}`,
  block: l.blockNumber ?? 0n,
  tx: l.transactionHash as `0x${string}`,
});

async function depositRow(l: AnyLog): Promise<MainnetTapeRow> {
  const token = l.address as Address;
  const value = (l.args?.value ?? 0n) as bigint;
  const { symbol, decimals } = await meta(token);
  // $ESSEY is never backing (EsseyReserve.sol:56) — sending it here only cuts circulatingSupply (:193).
  if (isEssey(token))
    return { ...base(l), kind: "deposit", mark: true, icon: "◇", text: `${amount(value, decimals)} $ESSEY sent to the reserve · out of the circulating claim` };
  return { ...base(l), kind: "deposit", mark: false, icon: "◆", text: `DEPOSIT · ${amount(value, decimals)} ${symbol} into the reserve · the floor under every $ESSEY rises` };
}

async function reserveRow(l: AnyLog): Promise<MainnetTapeRow | null> {
  const a = (l.args ?? {}) as Record<string, unknown>;
  switch (l.eventName) {
    case "Funded": {
      const { symbol, decimals } = await meta(a.token as Address);
      return { ...base(l), kind: "deposit", mark: true, icon: "◆", text: `DEPOSIT · ${amount(a.amount as bigint, decimals)} ${symbol} funded into the reserve · the floor under every $ESSEY rises` };
    }
    case "Redeemed":
      return { ...base(l), kind: "redeem", mark: true, icon: "◈", text: `REDEMPTION · ${amount(a.essey as bigint, 18)} $ESSEY burned · receipt #${a.receiptId} opened on 95% of its pro-rata slice` };
    case "Claimed": {
      const { symbol, decimals } = await meta(a.token as Address);
      return { ...base(l), kind: "claim", mark: true, icon: "→", text: `CLAIM · receipt #${a.receiptId} pulled ${amount(a.amount as bigint, decimals)} ${symbol} out of the reserve` };
    }
    case "ClaimSkipped": {
      const { symbol } = await meta(a.token as Address);
      return { ...base(l), kind: "claim", mark: true, icon: "·", text: `CLAIM SKIPPED · receipt #${a.receiptId}'s ${symbol} leg paid nothing and stays retryable` };
    }
    default:
      return null;
  }
}

/// The whole history, newest first: a bounded window would quietly hide the deposits that built the floor.
export async function fetchMainnetTape(): Promise<{ rows: MainnetTapeRow[]; head: bigint }> {
  const [head, transfers, events] = await Promise.all([
    mainnetPub.getBlockNumber(),
    mainnetPub.getLogs({ event: TRANSFER, args: { to: RESERVE.reserve }, fromBlock: 0n, toBlock: "latest" }),
    mainnetPub.getLogs({ address: RESERVE.reserve, events: RESERVE_EVENTS, fromBlock: 0n, toBlock: "latest" }),
  ]);
  const fromReserve = (await Promise.all(events.map((l) => reserveRow(l as AnyLog)))).filter(
    (r): r is MainnetTapeRow => r !== null,
  );
  const funded = new Set(
    events
      .filter((l) => (l as AnyLog).eventName === "Funded")
      .map((l) => `${l.transactionHash}:${((l as AnyLog).args?.token as string)?.toLowerCase()}`),
  );
  const fromTransfers = await Promise.all(
    transfers
      .filter((l) => !funded.has(`${l.transactionHash}:${l.address.toLowerCase()}`))
      .map((l) => depositRow(l as AnyLog)),
  );
  const rows = [...fromReserve, ...fromTransfers].sort((x, y) =>
    x.block === y.block ? (x.key < y.key ? 1 : -1) : x.block < y.block ? 1 : -1,
  );
  return { rows, head };
}

export const mainnetTxUrl = (tx: string) => `${MAINNET.explorer}/tx/${tx}`;
