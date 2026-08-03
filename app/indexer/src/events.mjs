// The Tape's event vocabulary — every row type maps to a real emitted event from a shipped contract.
// One source of truth for both the poller and the decode test.
import { parseAbi } from "viem";

// Per-contract ABIs (events only). Addresses come from env; any unset contract is skipped.
export const CONTRACT_EVENTS = {
  seat: parseAbi([
    "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
  ]),
  bell: parseAbi([
    "event Rang(address indexed ringer, uint256 pot, uint256 tip, uint256 distributed)",
    "event Claimed(uint256 indexed id, uint256 amount, address vault)",
    "event Activated(uint256 indexed id, uint8 tier, uint256 fee)",
    "event Upgraded(uint256 indexed id, uint8 fromTier, uint8 toTier, uint256 fee)",
    "event ClaimConverted(uint256 indexed id, address token, uint256 amountOut)",
  ]),
  exchange: parseAbi([
    "event Bought(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee)",
    "event Sniped(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee)",
    "event Sold(uint256 indexed id, address indexed seller, uint256 price, uint256 fee)",
  ]),
  cases: parseAbi([
    "event CaseBought(uint256 indexed caseId, address indexed buyer, uint64 drawBlock)",
    "event CaseOpened(uint256 indexed caseId, address indexed buyer, address indexed token, uint256 amount)",
    "event SoldBack(address indexed seller, address indexed token, uint256 amount, uint256 paid, uint256 toBell)",
  ]),
  distributor: parseAbi([
    "event Claimed(uint256 indexed stage, address indexed account, uint256 allocation, uint256 firstId)",
  ]),
};

// Normalize a decoded log into a Tape row. `kind` drives the site's row styling; `proven` marks rows
// the hallmark stamps (events whose correctness is on-chain-checkable, not just reported).
export function toTapeRow(contract, eventName, args, log) {
  const base = { block: Number(log.blockNumber), tx: log.transactionHash };
  const s = (v) => (typeof v === "bigint" ? v.toString() : v);
  switch (`${contract}.${eventName}`) {
    case "seat.Transfer":
      return args.from === "0x0000000000000000000000000000000000000000"
        ? { ...base, kind: "seat_minted", proven: true, id: s(args.tokenId), to: args.to }
        : { ...base, kind: "seat_transfer", proven: false, id: s(args.tokenId), from: args.from, to: args.to };
    case "bell.Rang":
      return { ...base, kind: "bell_rung", proven: true, ringer: args.ringer, pot: s(args.pot), tip: s(args.tip), distributed: s(args.distributed) };
    case "bell.Claimed":
      return { ...base, kind: "payout_claimed", proven: true, id: s(args.id), amount: s(args.amount), vault: args.vault };
    case "bell.Activated":
      return { ...base, kind: "tier_activated", proven: false, id: s(args.id), tier: Number(args.tier) };
    case "bell.Upgraded":
      return { ...base, kind: "tier_up", proven: false, id: s(args.id), from: Number(args.fromTier), to: Number(args.toTier) };
    case "bell.ClaimConverted":
      return { ...base, kind: "payout_converted", proven: true, id: s(args.id), token: args.token, amountOut: s(args.amountOut) };
    case "exchange.Bought":
      return { ...base, kind: "exchange_buy", proven: false, id: s(args.id), buyer: args.buyer, price: s(args.price) };
    case "exchange.Sniped":
      return { ...base, kind: "exchange_snipe", proven: false, id: s(args.id), buyer: args.buyer, price: s(args.price) };
    case "exchange.Sold":
      return { ...base, kind: "exchange_sell", proven: false, id: s(args.id), seller: args.seller, price: s(args.price) };
    case "cases.CaseBought":
      return { ...base, kind: "case_bought", proven: true, caseId: s(args.caseId), buyer: args.buyer };
    case "cases.CaseOpened":
      return { ...base, kind: "case_opened", proven: true, caseId: s(args.caseId), buyer: args.buyer, token: args.token, amount: s(args.amount) };
    case "cases.SoldBack":
      return { ...base, kind: "case_soldback", proven: true, seller: args.seller, token: args.token, paid: s(args.paid) };
    case "distributor.Claimed":
      return { ...base, kind: "whitelist_claimed", proven: true, account: args.account, allocation: s(args.allocation) };
    default:
      return null; // unmapped event: skip rather than misreport
  }
}
