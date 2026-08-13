// The Tape — the live proof feed, read straight from the testnet chain. Every row is a real event
// from a deployed contract with a verify link; no hosted indexer, no fabricated motion. When the
// chain is quiet, the Tape says so.
import { parseAbiItem, type Address, type Log } from "viem";
import { pub, ADDR, NET, fmt } from "./live";

export type TapeRow = {
  key: string; // dedup / react key: tx + logIndex
  block: bigint;
  tx: `0x${string}`;
  kind: string;
  proven: boolean; // hallmark-stamped: correctness is on-chain-checkable
  icon: string;
  text: string;
};

// Event signatures we surface, per contract. Kept minimal and legible — one line per Tape row type.
const EVENTS = {
  don: [parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)")],
  bell: [
    parseAbiItem("event Rang(address indexed ringer, uint256 pot, uint256 tip, uint256 distributed)"),
    parseAbiItem("event Claimed(uint256 indexed id, uint256 amount, address vault)"),
    parseAbiItem("event Activated(uint256 indexed id, uint8 tier, uint256 fee)"),
    parseAbiItem("event Upgraded(uint256 indexed id, uint8 fromTier, uint8 toTier, uint256 fee)"),
  ],
  exchange: [
    parseAbiItem("event Bought(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee)"),
    parseAbiItem("event Sniped(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee)"),
    parseAbiItem("event Sold(uint256 indexed id, address indexed seller, uint256 net, uint256 fee)"),
  ],
  donloan: [
    parseAbiItem("event Borrowed(uint256 indexed donId, address indexed borrower, uint256 amount, uint64 nonce)"),
    parseAbiItem("event Repaid(uint256 indexed donId, address indexed payer, uint256 interestPaid, uint256 principalPaid, bool closed)"),
    parseAbiItem("event Liquidated(uint256 indexed donId, address indexed caller, uint256 proceeds, uint256 debtRecovered, uint256 surplusToBorrower, uint256 tip)"),
  ],
  pool: [
    parseAbiItem("event Borrowed(uint256 indexed id, address indexed borrower, address indexed token, uint256 collateral, uint256 debt)"),
    parseAbiItem("event Repaid(uint256 indexed id, uint256 paid, uint256 collateralReturned)"),
    parseAbiItem("event ReservesSkimmed(address indexed caller, uint256 toBell, uint256 toTreasury)"),
  ],
} as const;

const ZERO = "0x0000000000000000000000000000000000000000";
const stock = (t?: string) => t?.toLowerCase() === ADDR.aapl.toLowerCase() ? "AAPL" : t?.toLowerCase() === ADDR.nvda.toLowerCase() ? "NVDA" : "stock";

// Decode one log into a Tape row, or null to skip. `en` is the decoded eventName; `a` its args.
function row(contract: string, l: Log & { eventName?: string; args?: Record<string, unknown> }): TapeRow | null {
  const a = (l.args ?? {}) as Record<string, bigint | string>;
  const base = { key: `${l.transactionHash}:${l.logIndex}`, block: l.blockNumber ?? 0n, tx: l.transactionHash as `0x${string}` };
  const usd = (v: unknown) => fmt(v as bigint, 2);
  switch (`${contract}.${l.eventName}`) {
    case "don.Transfer":
      return a.from === ZERO
        ? { ...base, kind: "don_minted", proven: true, icon: "◆", text: `DON #${a.tokenId} minted · Vault created` }
        : { ...base, kind: "don_move", proven: false, icon: "→", text: `DON #${a.tokenId} changed hands` };
    case "bell.Rang":
      return { ...base, kind: "bell_rung", proven: true, icon: "🔔", text: `BELL RUNG · ${usd(a.distributed)} USDG paid out across staked Dons` };
    case "bell.Claimed":
      return { ...base, kind: "payout", proven: true, icon: "◆", text: `PAYOUT · Don #${a.id} claimed ${usd(a.amount)} USDG → Vault` };
    case "bell.Activated":
      return { ...base, kind: "tier", proven: false, icon: "▲", text: `TIER · Don #${a.id} activated at Tier ${a.tier}` };
    case "bell.Upgraded":
      return { ...base, kind: "tier", proven: false, icon: "▲", text: `TIER UP · Don #${a.id} → Tier ${a.toTier}` };
    case "exchange.Bought":
      return { ...base, kind: "trade", proven: false, icon: "⇄", text: `EXCHANGE · Don #${a.id} bought · fee → stock + treasury` };
    case "exchange.Sniped":
      return { ...base, kind: "trade", proven: false, icon: "⇄", text: `EXCHANGE · Don #${a.id} sniped · fee → stock + treasury` };
    case "exchange.Sold":
      return { ...base, kind: "trade", proven: false, icon: "⇄", text: `EXCHANGE · Don #${a.id} sold back for ${usd(a.net)} $ESSEY` };
    case "donloan.Borrowed":
      return { ...base, kind: "loan", proven: true, icon: "📜", text: `DON LOAN · ${usd(a.amount)} $ESSEY borrowed against Don #${a.donId} (lien in place)` };
    case "donloan.Repaid":
      return { ...base, kind: "loan", proven: true, icon: "📜", text: `DON LOAN · Don #${a.donId} repaid ${usd((a.interestPaid as bigint) + (a.principalPaid as bigint))} $ESSEY${a.closed ? " · lien released" : ""}` };
    case "donloan.Liquidated":
      return { ...base, kind: "loan", proven: true, icon: "📜", text: `LIQUIDATED · Don #${a.donId} consumed at the floor · ${usd(a.debtRecovered)} $ESSEY recovered` };
    case "pool.Borrowed":
      return { ...base, kind: "loan", proven: true, icon: "📜", text: `LOAN · borrowed ${usd(a.debt)} USDG against ${stock(a.token as string)}` };
    case "pool.Repaid":
      return { ...base, kind: "loan", proven: true, icon: "📜", text: `LOAN #${a.id} repaid ${usd(a.paid)} USDG · collateral returned` };
    case "pool.ReservesSkimmed":
      return { ...base, kind: "interest", proven: true, icon: "◆", text: `LOAN INTEREST · ${usd(a.toBell)} USDG skimmed to the Bell` };
    default:
      return null;
  }
}

const SRC: [string, Address][] = [
  ["don", ADDR.don], ["bell", ADDR.bell], ["exchange", ADDR.exchange], ["donloan", ADDR.loan], ["pool", ADDR.pool],
];

/// Read the freshest Tape rows — a bounded window of recent blocks, newest first. Errors on any one
/// contract are swallowed so a single RPC hiccup can't blank the whole feed.
export async function fetchTape(limit = 40, windowBlocks = 400_000n): Promise<{ rows: TapeRow[]; head: bigint }> {
  const head = await pub.getBlockNumber();
  const from = head > windowBlocks ? head - windowBlocks : 0n;
  const perContract = await Promise.all(SRC.map(async ([name, address]) => {
    try {
      const logs = await pub.getLogs({ address, events: EVENTS[name as keyof typeof EVENTS] as never, fromBlock: from, toBlock: head });
      return logs.map((l) => row(name, l as never)).filter((r): r is TapeRow => r !== null);
    } catch { return []; }
  }));
  const rows = perContract.flat()
    .sort((x, y) => (x.block === y.block ? (x.key < y.key ? 1 : -1) : x.block < y.block ? 1 : -1))
    .slice(0, limit);
  return { rows, head };
}

export const txUrl = (tx: string) => `${NET.explorer}/tx/${tx}`;
