// The redemption layer for EsseyReserve on RH mainnet 4663 — the reads, the exact quote math, and the
// receipt bookkeeping behind /redeem. Reads ride reserve.ts's `mainnetPub`; writes ride mainnet-tx.ts.
//
// Redemption is TWO steps by design (EsseyReserve.sol:29-32): `redeem(essey)` burns and mints a receipt
// paying nothing, then `claim`/`claimMany` pull the per-token slices. That is what keeps a paused token
// from bricking a whole redemption, and it is why this module models an open receipt as first-class
// state rather than treating a redeem as a completed action.
import { parseAbi, parseAbiItem, type Address } from "viem";
import { BASKET, mainnetPub, RESERVE } from "./reserve";

/// Only the redemption surface. reserve.ts's `reserveAbi` stays the Treasury page's read set; keeping
/// this here means the gated redemption feature owns its own ABI and can be lifted out whole.
export const redeemAbi = parseAbi([
  "function redeem(uint256 esseyAmount) returns (uint256 receiptId)",
  "function claim(uint256 receiptId, address token)",
  "function claimMany(uint256 receiptId, address[] tokens)",
  "function previewClaim(uint256 receiptId, address token) view returns (uint256)",
  "function claimedShares(address token) view returns (uint256)",
  "function claimed(uint256 receiptId, address token) view returns (bool)",
  "function receipts(uint256 receiptId) view returns (address owner, uint256 essey)",
  "function receiptCount() view returns (uint256)",
  "function claimBase() view returns (uint256)",
  "function circulatingSupply() view returns (uint256)",
  "function reserveOf(address token) view returns (uint256)",
  "function EXIT_FEE_BPS() view returns (uint256)",
  "function BPS() view returns (uint256)",
]);

/// Split out of `redeemAbi` because both are needed standalone: `Redeemed` is the ONLY way to learn a
/// fresh receiptId (a mined tx cannot return one), and `Claimed` carries the units a leg actually paid.
export const redeemedEvent = parseAbiItem(
  "event Redeemed(uint256 indexed receiptId, address indexed owner, uint256 essey)",
);
export const claimedEvent = parseAbiItem(
  "event Claimed(uint256 indexed receiptId, address indexed token, uint256 amount)",
);

export const esseyAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
]);

const erc20Meta = parseAbi([
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
]);

export const ESSEY_DECIMALS = 18; // VERIFIED on chain: decimals() == 18 on 0x3157…1610

export type RedeemToken = {
  address: Address;
  symbol: string;
  decimals: number;
  reserve: bigint; // reserveOf(token) — units the reserve holds right now
  claimedShares: bigint; // Σ fee-adjusted weight ever claimed against this token
};

export type ReserveParams = {
  claimBase: bigint;
  exitFeeBps: bigint;
  bps: bigint;
  circulating: bigint;
};

export type Quote = { token: RedeemToken; units: bigint };

// ------------------------------------------------------------------ the quote (GAP G-R1, client-side)

/// The fee-adjusted claim weight, mirroring EsseyReserve.sol:147 exactly. BigInt division truncates
/// toward zero and every operand is non-negative, so this is the same integer arithmetic the contract
/// runs — not an approximation of it.
export const claimWeight = (essey: bigint, p: ReserveParams): bigint =>
  p.bps === 0n ? 0n : (essey * (p.bps - p.exitFeeBps)) / p.bps;

/// What burning `essey` pays out per token RIGHT NOW. The reserve exposes no view for a hypothetical
/// burn — `previewClaim` needs a receipt that already exists (EsseyReserve.sol:181) — so this replays
/// the contract's own two lines: weight at :147, then `bal * weight / (claimBase - claimedShares)` at
/// :148 and :169. The reduced denominator is load-bearing: `floorOf` divides by the FULL claimBase and
/// therefore understates the real slice the moment anyone has claimed. Never quote from floorOf.
export function previewRedeem(
  essey: bigint,
  tokens: RedeemToken[],
  p: ReserveParams,
): Quote[] {
  const w = claimWeight(essey, p);
  return tokens.map((token) => {
    const denom = p.claimBase - token.claimedShares;
    const units = w === 0n || denom <= 0n ? 0n : (token.reserve * w) / denom;
    return { token, units };
  });
}

/// The $ESSEY forfeited to the exit fee — the gap between what you burn and what your receipt weighs.
export const exitFeeOn = (essey: bigint, p: ReserveParams): bigint =>
  essey - claimWeight(essey, p);

// ------------------------------------------------------------------ receipts

export type ReceiptLeg = {
  token: RedeemToken;
  units: bigint; // previewClaim — what this leg pays if pulled now
  claimed: boolean; // the leg is consumed on chain; never payable again
  paused: boolean; // previewClaim reverted (a gated Stock Token) — retryable, not failed
};

export type OpenReceipt = { id: bigint; essey: bigint; legs: ReceiptLeg[] };

export type ClaimRow = {
  receiptId: bigint;
  token: Address;
  symbol: string;
  decimals: number;
  units: bigint;
  txHash: `0x${string}`;
};

/// Receipts are struct entries, not tokens (EsseyReserve.sol:65) — there is no `receiptsOf(owner)` and
/// they never appear in a wallet. We enumerate ids and read the owner off each, which is exact and does
/// not depend on log retention (this RPC is not an archive node). Capped so the page can never fan out
/// unboundedly; a truncated scan is reported, not hidden, and localStorage ids are always included.
const SCAN_MAX = 400n;

const key = (a: Address) => `essey.redeem.receipts.${a.toLowerCase()}`;

export function rememberReceipt(owner: Address, id: bigint): void {
  try {
    const have = loadReceiptIds(owner);
    if (have.includes(id)) return;
    localStorage.setItem(key(owner), JSON.stringify([...have, id].map(String)));
  } catch {
    /* private mode — the on-chain scan below still finds it */
  }
}

export function loadReceiptIds(owner: Address): bigint[] {
  try {
    const raw = localStorage.getItem(key(owner));
    return raw ? (JSON.parse(raw) as string[]).map(BigInt) : [];
  } catch {
    return [];
  }
}

const read = <T>(functionName: string, args?: unknown[]): Promise<T> =>
  mainnetPub.readContract({
    address: RESERVE.reserve,
    abi: redeemAbi,
    functionName,
    args,
  } as never) as Promise<T>;

async function tokenMeta(token: Address): Promise<RedeemToken> {
  const [symbol, decimals, reserve, claimedShares] = await Promise.all([
    mainnetPub
      .readContract({ address: token, abi: erc20Meta, functionName: "symbol" })
      .catch(() => "?") as Promise<string>,
    mainnetPub
      .readContract({
        address: token,
        abi: erc20Meta,
        functionName: "decimals",
      })
      .catch(() => 18) as Promise<number>,
    read<bigint>("reserveOf", [token]).catch(() => 0n),
    read<bigint>("claimedShares", [token]).catch(() => 0n),
  ]);
  return {
    address: token,
    symbol,
    decimals: Number(decimals),
    reserve,
    claimedShares,
  };
}

export type RedeemState = {
  params: ReserveParams;
  tokens: RedeemToken[];
  receiptCount: bigint;
};

export type Position = { essey: bigint; allowance: bigint };

export const reads = {
  async state(): Promise<RedeemState> {
    const [claimBase, exitFeeBps, bps, circulating, receiptCount] =
      await Promise.all([
        read<bigint>("claimBase"),
        read<bigint>("EXIT_FEE_BPS"),
        read<bigint>("BPS"),
        read<bigint>("circulatingSupply"),
        read<bigint>("receiptCount"),
      ]);
    const tokens = await Promise.all(BASKET.map(tokenMeta));
    return {
      params: { claimBase, exitFeeBps, bps, circulating },
      tokens,
      receiptCount,
    };
  },

  async position(owner: Address): Promise<Position> {
    const [essey, allowance] = await Promise.all([
      mainnetPub.readContract({
        address: RESERVE.essey,
        abi: esseyAbi,
        functionName: "balanceOf",
        args: [owner],
      }),
      mainnetPub.readContract({
        address: RESERVE.essey,
        abi: esseyAbi,
        functionName: "allowance",
        args: [owner, RESERVE.reserve],
      }),
    ]);
    return { essey, allowance };
  },

  /// Every receipt this address owns, with each token leg priced. A leg whose `previewClaim` reverts is
  /// a paused Stock Token, which the contract skips WITHOUT consuming the leg (EsseyReserve.sol:45-48) —
  /// so it is reported as waiting, never as lost.
  async receipts(
    owner: Address,
    tokens: RedeemToken[],
    receiptCount: bigint,
  ): Promise<{ receipts: OpenReceipt[]; truncated: boolean }> {
    const from = receiptCount > SCAN_MAX ? receiptCount - SCAN_MAX : 0n;
    const ids = new Set<bigint>(loadReceiptIds(owner));
    for (let i = from; i < receiptCount; i++) ids.add(i);
    const owned: { id: bigint; essey: bigint }[] = [];
    for (const id of [...ids].sort((a, b) => (a < b ? -1 : 1))) {
      const r = await read<[Address, bigint]>("receipts", [id]).catch(
        () => null,
      );
      if (r && r[0].toLowerCase() === owner.toLowerCase() && r[1] > 0n)
        owned.push({ id, essey: r[1] });
    }
    const receipts = await Promise.all(
      owned.map(async ({ id, essey }) => ({
        id,
        essey,
        legs: await Promise.all(tokens.map((t) => leg(id, t))),
      })),
    );
    return { receipts, truncated: from > 0n };
  },

  /// The claimed ledger. `Claimed` carries the units actually paid, which no view exposes afterwards.
  /// Log queries on this RPC can time out, so a failure degrades to an empty ledger — the on-chain
  /// `claimed` flag on each leg stays the authoritative record of what was pulled.
  async ledger(
    receipts: OpenReceipt[],
    tokens: RedeemToken[],
  ): Promise<ClaimRow[]> {
    if (receipts.length === 0) return [];
    const meta = new Map(tokens.map((t) => [t.address.toLowerCase(), t]));
    const logs = await mainnetPub
      .getLogs({
        address: RESERVE.reserve,
        event: claimedEvent,
        args: { receiptId: receipts.map((r) => r.id) },
        fromBlock: 0n,
        toBlock: "latest",
      })
      .catch(() => []);
    return logs.map((l) => {
      const a = l.args as {
        receiptId?: bigint;
        token?: Address;
        amount?: bigint;
      };
      const t = meta.get((a.token ?? "0x").toLowerCase());
      return {
        receiptId: a.receiptId ?? 0n,
        token: (a.token ?? "0x") as Address,
        symbol: t?.symbol ?? "?",
        decimals: t?.decimals ?? 18,
        units: a.amount ?? 0n,
        txHash: l.transactionHash as `0x${string}`,
      };
    });
  },
};

async function leg(id: bigint, token: RedeemToken): Promise<ReceiptLeg> {
  const [preview, done] = await Promise.all([
    read<bigint>("previewClaim", [id, token.address]).then(
      (v) => ({ ok: true as const, v }),
      () => ({ ok: false as const, v: 0n }),
    ),
    read<boolean>("claimed", [id, token.address]).catch(() => false),
  ]);
  return {
    token,
    units: preview.v,
    claimed: done,
    paused: !preview.ok && !done,
  };
}
