// The lending read layer — Robinhood Chain MAINNET (4663). Sibling of reserve.ts (the reserve's read
// half) and mainnet-tx.ts (the shared write path); live.ts is the TESTNET game and is deliberately not
// touched here, because flipping its NET would move the game wing off 46630 with it.
//
// THE LENDING CONTRACTS ARE NOT ON MAINNET YET. There is no 4663 broadcast for DeployMarkets.s.sol
// (rh-chain/broadcast/ has 4663 dirs only for DeployEsseyFoundation, Deploy, DeployMarket/dry-run and
// RehearseEsseyLadder). So `LENDING.markets` is the zero address and `lendingDeployed()` is false, and
// every panel that would need a contract renders an honest not-yet state instead of a dead button.
//
// ONE address turns it on. EsseyMarkets is the root: `activePool(token)` names each market's pool,
// `liveness()` and `health()` name the two oracles, and the pool names its own Note and asset. So the
// activation edit is `LENDING.markets = <deployed address>` — not a rewrite.
//
// What IS live on 4663 today, and what this file therefore still reads for real: USDG, both Stock
// Tokens (with the non-forgeable beacon check), and both Chainlink feeds. Those are the rails the
// markets will run on, and showing them read-live is the honest version of "not deployed yet".
import { parseAbi, type Address, type PublicClient } from "viem";
import { chainNow, priceOf, type Price } from "./prices";
import { mainnetPub } from "./reserve";

const ZERO = "0x0000000000000000000000000000000000000000" as Address;

/// Set `markets` to the deployed EsseyMarkets address to bring the whole page live. Everything else
/// is discovered from it on chain, so there is no second address to keep in sync.
export const LENDING = {
  markets: ZERO,
};

export const lendingDeployed = (): boolean => LENDING.markets !== ZERO;

/// USDG, the borrow asset. VERIFIED on 4663 2026-09-02: symbol() == "USDG", decimals() == 6.
/// Address from docs/MAINNET-CONFIG.md:11. Six decimals, not eighteen — the testnet mock was 18 and
/// the old page's parseUnits(amt, 18) would have been a millionfold error against the real token.
export const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168" as Address;

export type MarketDef = {
  symbol: string;
  token: Address;
  feed: Address;
};

/// The two markets DeployMarkets.s.sol:118-119 lists on 4663 — AAPL and NVDA, nothing else. Feeds are
/// RobinhoodFeeds.sol:10,12. Token addresses are the same RH Stock Tokens the reserve holds
/// (reserve.ts BASKET), both VERIFIED on chain 2026-09-02 as beacon proxies of the issuer beacon.
export const MARKETS: MarketDef[] = [
  {
    symbol: "AAPL",
    token: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9",
    feed: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0",
  },
  {
    symbol: "NVDA",
    token: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC",
    feed: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15",
  },
];

/// The risk terms the deploy script PROPOSES for every market (DeployMarkets.s.sol:274-282). These are
/// a proposal, not a chain read: once the market is committed the UI reads `market(token)` instead and
/// this constant is only used to say what the deploy will ask for.
export const PROPOSED = {
  ltvBps: 5_000,
  liqThresholdBps: 7_500,
  liqBonusBps: 500,
  capUsdg: 250_000,
  maxPositionBps: 2_000,
};

// ------------------------------------------------------------------ the chain surface

export const erc20Abi = parseAbi([
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
]);

/// The ERC-8056 surface RH Stock Tokens carry themselves (rh-chain/src/interfaces/IScaledUI.sol:6-12).
export const scaledUiAbi = parseAbi([
  "function uiMultiplier() view returns (uint256)",
  "function newUIMultiplier() view returns (uint256 newMultiplier, uint256 effectiveAt)",
]);

/// Only what this page reads. Every entry is a view (or a public state variable) on
/// rh-chain/src/EsseyMarkets.sol, except priceOf which it inherits from StaleFeedGuard.sol:118.
export const marketsAbi = parseAbi([
  "function canBorrow(address) view returns (bool)",
  "function market(address) view returns ((bool enabled, uint16 ltvBps, uint16 liqThresholdBps, uint16 liqBonusBps, uint8 collateralDecimals, uint128 cap, uint16 maxPositionBps))",
  "function maxBorrow(address,uint256) view returns (uint256)",
  "function borrowCap(address) view returns (uint256)",
  "function collateralValue(address,uint256) view returns (uint256 value, bool inSession)",
  "function priceOf(address) view returns (uint256 price, uint8 decimals, bool inSession)",
  "function activePool(address) view returns (address)",
  "function multiplierSource(address) view returns (address)",
  "function multiplierMovedAt(address) view returns (uint256)",
  "function MULTIPLIER_GUARD_WINDOW() view returns (uint256)",
  "function liveness() view returns (address)",
  "function health() view returns (address)",
  "function assetDecimals() view returns (uint8)",
]);

export const livenessAbi = parseAbi([
  "function liquidationsAllowed() view returns (bool)",
  "function secondsUntilLiquidationsAllowed() view returns (uint256)",
]);

export const healthAbi = parseAbi([
  "function effectiveCap(address) view returns (uint256)",
]);

export const poolAbi = parseAbi([
  "function asset() view returns (address)",
  "function collateralToken() view returns (address)",
  "function note() view returns (address)",
  "function totalAssets() view returns (uint256)",
  "function borrowRateBps() view returns (uint256)",
  "function utilizationBps() view returns (uint256)",
  "function reserveBps() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function convertToAssets(uint256) view returns (uint256)",
  "function nextPositionId() view returns (uint256)",
  "function positions(uint256) view returns (address token, uint256 collateralRaw, uint256 principal, uint256 indexSnapshot, uint256 collIndexSnapshot)",
  "function debtOf(uint256) view returns (uint256)",
  "function collateralIndex(address) view returns (uint256)",
  "function shortfallRaw(address) view returns (uint256)",
  "function marketBorrows(address) view returns (uint256)",
  "function deposit(uint256 assets, address receiver) returns (uint256)",
  "function withdraw(uint256 assets, address receiver, address owner) returns (uint256)",
  "function borrow(uint256 collateralRaw, uint256 debt) returns (uint256)",
  "function repay(uint256 id, uint256 amount)",
]);

export const noteAbi = parseAbi([
  "function ownerOf(uint256) view returns (address)",
  "function balanceOf(address) view returns (uint256)",
]);

const pub = mainnetPub as PublicClient;

const read = <T>(
  address: Address,
  abi: readonly unknown[],
  functionName: string,
  args?: unknown[],
): Promise<T> =>
  pub.readContract({ address, abi, functionName, args } as never) as Promise<T>;

// ------------------------------------------------------------------ session + beacon

/// The US equity session exactly as StaleFeedGuard computes it: the INTERSECTION of the EST and EDT
/// windows (14:30-20:00 UTC, StaleFeedGuard.sol:170-176) so the UI is never open when the chain
/// thinks it is closed, plus the holiday check against the earliest possible open
/// (13:30 UTC, StaleFeedGuard.sol:150-153) so a Thanksgiving print cannot read as in-session.
const SESSION_OPEN_UTC = 14 * 3600 + 30 * 60;
const SESSION_CLOSE_UTC = 20 * 3600;
const SESSION_OPEN_EARLIEST_UTC = 13 * 3600 + 30 * 60;

export function inUsSession(nowSec: number, feedUpdatedAt: number): boolean {
  const dow = (Math.floor(nowSec / 86400) + 3) % 7;
  if (dow >= 5) return false;
  const sod = nowSec % 86400;
  if (sod < SESSION_OPEN_UTC || sod >= SESSION_CLOSE_UTC) return false;
  const earliestOpen =
    Math.floor(nowSec / 86400) * 86400 + SESSION_OPEN_EARLIEST_UTC;
  return feedUpdatedAt >= earliestOpen;
}

/// Same non-forgeable legitimacy gate the reserve applies (reserve.ts:171-176): a real Robinhood Stock
/// Token is an EIP-1967 beacon proxy pointing at the issuer's shared beacon. Duplicated rather than
/// imported because reserve.ts does not export it and is not this changeset's to edit.
const RH_STOCK_BEACON = "e10b6f6b275de231345c20d14ab812db62151b00";
const EIP1967_BEACON_SLOT =
  "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50" as `0x${string}`;

async function isRhStock(token: Address): Promise<boolean> {
  const slot = await pub
    .getStorageAt({ address: token, slot: EIP1967_BEACON_SLOT })
    .catch(() => null);
  return !!slot && slot.toLowerCase().endsWith(RH_STOCK_BEACON);
}

// ------------------------------------------------------------------ the rails (live today)

export type Rail = {
  def: MarketDef;
  symbol: string;
  decimals: number;
  isRhStock: boolean;
  uiMultiplier: bigint | null;
  price: Price;
  /// Whether the equity session is open AND the feed has printed since today's open — the same two
  /// conditions `canBorrow` folds into `inSession`. Advisory before the market exists; once it does,
  /// `BorrowGate` below reads the contract instead.
  inSession: boolean;
};

export type Rails = {
  usdg: { symbol: string; decimals: number };
  rails: Rail[];
  asOf: number;
};

export const reads = {
  /// What is live on 4663 right now, market contracts or not. Nothing here is invented: every field is
  /// a call against a deployed token or feed.
  async rails(): Promise<Rails> {
    const asOf = await chainNow(pub);
    const [usdgSymbol, usdgDecimals] = await Promise.all([
      read<string>(USDG, erc20Abi, "symbol"),
      read<number>(USDG, erc20Abi, "decimals"),
    ]);
    const rails = await Promise.all(
      MARKETS.map(async (def): Promise<Rail> => {
        const [symbol, decimals, stock, mult, price] = await Promise.all([
          read<string>(def.token, erc20Abi, "symbol").catch(() => def.symbol),
          read<number>(def.token, erc20Abi, "decimals").catch(() => 18),
          isRhStock(def.token),
          read<bigint>(def.token, scaledUiAbi, "uiMultiplier").catch(
            () => null,
          ),
          priceOf(pub, def.token, asOf),
        ]);
        return {
          def,
          symbol,
          decimals: Number(decimals),
          isRhStock: stock,
          uiMultiplier: mult,
          price,
          inSession: price.ok ? inUsSession(asOf, price.updatedAt) : false,
        };
      }),
    );
    return {
      usdg: { symbol: usdgSymbol, decimals: Number(usdgDecimals) },
      rails,
      asOf,
    };
  },

  /// Everything the page needs once EsseyMarkets exists. Per market: the pool, its rates, the risk
  /// parameters, and — when borrowing is closed — WHICH gate closed it.
  async markets(addr: Address | null): Promise<MarketState[]> {
    const [liveness, health, assetDecimals, guardWindow] = await Promise.all([
      read<Address>(LENDING.markets, marketsAbi, "liveness"),
      read<Address>(LENDING.markets, marketsAbi, "health"),
      read<number>(LENDING.markets, marketsAbi, "assetDecimals"),
      read<bigint>(LENDING.markets, marketsAbi, "MULTIPLIER_GUARD_WINDOW"),
    ]);
    const now = await chainNow(pub);
    return Promise.all(
      MARKETS.map((def) =>
        marketState(def, addr, {
          liveness,
          health,
          assetDecimals: Number(assetDecimals),
          guardWindow,
          now,
        }),
      ),
    );
  },
};

// ------------------------------------------------------------------ per-market state

export type GateCode =
  | "open"
  | "no-pool"
  | "not-listed"
  | "retiring"
  | "chain-liveness"
  | "depth-cap"
  | "corporate-action"
  | "feed-unreadable"
  | "closed"
  | "unknown";

export type BorrowGate = { code: GateCode; detail: string };

export type LoanRow = {
  id: bigint;
  collateralRaw: bigint;
  /// What the position is actually entitled to after any issuer burn it lived through
  /// (CollateralReconciler.sol:81-93). Equal to collateralRaw when nothing was burned.
  effectiveRaw: bigint;
  debt: bigint;
  /// debt as a share of the liquidation line. >= 1 means liquidatable on value.
  liqRatio: number | null;
};

export type MarketState = {
  def: MarketDef;
  pool: Address | null;
  risk: {
    enabled: boolean;
    ltvBps: number;
    liqThresholdBps: number;
    liqBonusBps: number;
    collateralDecimals: number;
    cap: bigint;
    maxPositionBps: number;
  } | null;
  assetDecimals: number;
  /// null when the pool is not deployed for this market yet.
  stats: PoolStats | null;
  gate: BorrowGate;
  borrowed: bigint;
  borrowCap: bigint;
  /// Issuer burn observed against this pool's collateral, in raw token units. Non-zero is the
  /// adminBurn hazard having actually fired.
  shortfallRaw: bigint;
  mine: MyPosition | null;
};

export type PoolStats = {
  tvl: bigint;
  borrowApr: number;
  supplyApy: number;
  utilPct: number;
};

export type MyPosition = {
  stock: bigint;
  supplied: bigint;
  shares: bigint;
  loans: LoanRow[];
};

type Ctx = {
  liveness: Address;
  health: Address;
  assetDecimals: number;
  guardWindow: bigint;
  now: number;
};

async function marketState(
  def: MarketDef,
  addr: Address | null,
  ctx: Ctx,
): Promise<MarketState> {
  const pool = await read<Address>(LENDING.markets, marketsAbi, "activePool", [
    def.token,
  ]).catch(() => ZERO);
  const risk = await read<{
    enabled: boolean;
    ltvBps: number;
    liqThresholdBps: number;
    liqBonusBps: number;
    collateralDecimals: number;
    cap: bigint;
    maxPositionBps: number;
  }>(LENDING.markets, marketsAbi, "market", [def.token]).catch(() => null);

  const [gate, cap] = await Promise.all([
    borrowGate(def, pool, ctx),
    read<bigint>(LENDING.markets, marketsAbi, "borrowCap", [def.token]).catch(
      () => 0n,
    ),
  ]);

  if (pool === ZERO) {
    return {
      def,
      pool: null,
      risk,
      assetDecimals: ctx.assetDecimals,
      stats: null,
      gate,
      borrowed: 0n,
      borrowCap: cap,
      shortfallRaw: 0n,
      mine: null,
    };
  }

  const [tvl, borrowBps, utilBps, reserveBps, borrowed, shortfallRaw] =
    await Promise.all([
      read<bigint>(pool, poolAbi, "totalAssets"),
      read<bigint>(pool, poolAbi, "borrowRateBps"),
      read<bigint>(pool, poolAbi, "utilizationBps"),
      read<bigint>(pool, poolAbi, "reserveBps"),
      read<bigint>(pool, poolAbi, "marketBorrows", [def.token]),
      read<bigint>(pool, poolAbi, "shortfallRaw", [def.token]).catch(() => 0n),
    ]);
  const borrowApr = Number(borrowBps) / 100;
  return {
    def,
    pool,
    risk,
    assetDecimals: ctx.assetDecimals,
    stats: {
      tvl,
      borrowApr,
      supplyApy:
        borrowApr *
        (Number(utilBps) / 10_000) *
        (1 - Number(reserveBps) / 10_000),
      utilPct: Number(utilBps) / 100,
    },
    gate,
    borrowed,
    borrowCap: cap,
    shortfallRaw,
    mine: addr ? await myPosition(def, pool, addr, risk) : null,
  };
}

/// Why new borrowing is closed, in the SAME order EsseyMarkets.canBorrow tests it
/// (EsseyMarkets.sol:222-248). `canBorrow` itself is the authority — the ladder below only names the
/// input that made it false, and every rung is its own contract read, never a guess.
async function borrowGate(
  def: MarketDef,
  pool: Address,
  ctx: Ctx,
): Promise<BorrowGate> {
  if (pool === ZERO)
    return {
      code: "no-pool",
      detail: "No pool is registered for this collateral yet.",
    };
  const open = await read<boolean>(LENDING.markets, marketsAbi, "canBorrow", [
    def.token,
  ]).catch(() => false);
  if (open) return { code: "open", detail: "" };

  const risk = await read<{ enabled: boolean; ltvBps: number }>(
    LENDING.markets,
    marketsAbi,
    "market",
    [def.token],
  ).catch(() => null);
  if (!risk?.enabled)
    return {
      code: "not-listed",
      detail: "This market is not enabled in the risk registry.",
    };
  if (risk.ltvBps === 0)
    return {
      code: "retiring",
      detail:
        "This market is being retired: its max LTV is zero, so nothing new can be drawn. Existing loans can still be repaid.",
    };

  const [live, effCap, movedAt] = await Promise.all([
    read<boolean>(ctx.liveness, livenessAbi, "liquidationsAllowed").catch(
      () => false,
    ),
    read<bigint>(ctx.health, healthAbi, "effectiveCap", [def.token]).catch(
      () => 0n,
    ),
    read<bigint>(LENDING.markets, marketsAbi, "multiplierMovedAt", [
      def.token,
    ]).catch(() => 0n),
  ]);
  if (!live)
    return {
      code: "chain-liveness",
      detail:
        "The chain has not demonstrated liveness for long enough. New borrows are declined until the resume grace elapses.",
    };
  if (effCap === 0n)
    return {
      code: "depth-cap",
      detail:
        "The depth oracle reports no borrowable capacity for this market right now.",
    };
  if (movedAt !== 0n && BigInt(ctx.now) - movedAt < ctx.guardWindow)
    return {
      code: "corporate-action",
      detail:
        "A corporate action just moved this token's UI multiplier. Borrowing is closed for an hour while the multiplier and the price feed reconcile.",
    };

  try {
    const [, , inSession] = await read<[bigint, number, boolean]>(
      LENDING.markets,
      marketsAbi,
      "priceOf",
      [def.token],
    );
    if (!inSession)
      return {
        code: "closed",
        detail:
          "The US equity session is closed. The feed is 24/5, so there is no fresh price to lend against — the protocol declines rather than price the unknown.",
      };
  } catch {
    return {
      code: "feed-unreadable",
      detail:
        "The price feed is unreadable or past its staleness bound, so no loan can be sized against this collateral.",
    };
  }
  return {
    code: "unknown",
    detail: "The registry declines new borrows right now.",
  };
}

async function myPosition(
  def: MarketDef,
  pool: Address,
  addr: Address,
  risk: { liqThresholdBps: number } | null,
): Promise<MyPosition> {
  const [stock, shares, note] = await Promise.all([
    read<bigint>(def.token, erc20Abi, "balanceOf", [addr]),
    read<bigint>(pool, poolAbi, "balanceOf", [addr]),
    read<Address>(pool, poolAbi, "note"),
  ]);
  const supplied =
    shares > 0n
      ? await read<bigint>(pool, poolAbi, "convertToAssets", [shares])
      : 0n;
  return {
    stock,
    supplied,
    shares,
    loans: await myLoans(def, pool, note, addr, risk),
  };
}

/// Note is a plain ERC-721 (no Enumerable), so ownership is found by walking ids. `balanceOf` short-
/// circuits the common case to zero calls, and the walk stops once every owned Note is accounted for.
async function myLoans(
  def: MarketDef,
  pool: Address,
  note: Address,
  addr: Address,
  risk: { liqThresholdBps: number } | null,
): Promise<LoanRow[]> {
  const held = await read<bigint>(note, noteAbi, "balanceOf", [addr]).catch(
    () => 0n,
  );
  if (held === 0n) return [];
  const next = await read<bigint>(pool, poolAbi, "nextPositionId");
  const index = await read<bigint>(pool, poolAbi, "collateralIndex", [
    def.token,
  ]).catch(() => 0n);
  const out: LoanRow[] = [];
  for (let id = next - 1n; id >= 1n && BigInt(out.length) < held; id--) {
    const owner = await read<Address>(note, noteAbi, "ownerOf", [id]).catch(
      () => null,
    );
    if (owner?.toLowerCase() !== addr.toLowerCase()) continue;
    const [pos, debt] = await Promise.all([
      read<[Address, bigint, bigint, bigint, bigint]>(
        pool,
        poolAbi,
        "positions",
        [id],
      ),
      read<bigint>(pool, poolAbi, "debtOf", [id]),
    ]);
    const [, collateralRaw, , , collIndexSnapshot] = pos;
    const effectiveRaw = effectiveCollateral(
      collateralRaw,
      index,
      collIndexSnapshot,
    );
    out.push({
      id,
      collateralRaw,
      effectiveRaw,
      debt,
      liqRatio: await liqRatio(def.token, effectiveRaw, debt, risk),
    });
  }
  return out;
}

/// A position's entitlement after any burn it lived through — CollateralReconciler.sol:81-93, the same
/// arithmetic, so the number on screen is the number the contract will pay back.
function effectiveCollateral(
  raw: bigint,
  index: bigint,
  snapshot: bigint,
): bigint {
  if (snapshot === 0n) return raw;
  if (index >= snapshot) return raw;
  const eff = (raw * index) / snapshot;
  return eff > raw ? raw : eff;
}

/// Debt over the liquidation line, from the registry's own valuation. Null when the price is
/// unreadable — an unpriceable position must show "unknown", never a comfortable-looking ratio.
async function liqRatio(
  token: Address,
  effectiveRaw: bigint,
  debt: bigint,
  risk: { liqThresholdBps: number } | null,
): Promise<number | null> {
  if (!risk || debt === 0n) return null;
  try {
    const [value] = await read<[bigint, boolean]>(
      LENDING.markets,
      marketsAbi,
      "collateralValue",
      [token, effectiveRaw],
    );
    const line = (value * BigInt(risk.liqThresholdBps)) / 10_000n;
    if (line === 0n) return null;
    return Number((debt * 10_000n) / line) / 10_000;
  } catch {
    return null;
  }
}

/// Live quote for a typed collateral amount. Returns null rather than a fallback figure when the
/// registry cannot price it — the borrow field stays unavailable instead of showing an invented cap.
export const quoteMaxBorrow = (
  token: Address,
  collateralRaw: bigint,
): Promise<bigint | null> =>
  read<bigint>(LENDING.markets, marketsAbi, "maxBorrow", [
    token,
    collateralRaw,
  ]).catch(() => null);

export const allowanceOf = (
  token: Address,
  owner: Address,
  spender: Address,
): Promise<bigint> =>
  read<bigint>(token, erc20Abi, "allowance", [owner, spender]).catch(() => 0n);
