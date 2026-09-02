// The StockLpVault read layer — Robinhood Chain MAINNET (4663). Reads ride reserve.ts's `mainnetPub`;
// writes ride mainnet-tx.ts. This is the vault's own module so the gated Earn surface owns its ABI and
// can be lifted out whole, exactly as redeem.ts owns the redemption surface.
//
// The vault is NOT DEPLOYED anywhere (`docs/MAINNET-ACTIVATION.md:1152` — G3 restarted from zero on
// 2026-09-02 after the whole-dollar-mark fix), so every VAULTS entry below carries the zero address and
// `deployed()` renders the honest "not yet" state instead of a broken read.
//
// Two numbers here are replayed from the contract rather than read: the deposit share quote and the
// pool-vs-oracle deviation. Both mirror named lines of StockLpVault.sol and are cited at their helper,
// because the alternative — showing a button that reverts, or no reason why it is closed — is worse.
import { parseAbi, type Address } from "viem";
import { mainnetPub } from "./reserve";

const ZERO = "0x0000000000000000000000000000000000000000" as Address;

export type VaultDef = {
  address: Address;
  /// What the pair IS, for the picker. The share token's own name/symbol is read on chain.
  label: string;
};

/// Fill in at deploy, exactly as reserve.ts:34 does for the reserve. The Phase-1 MVP targets the live
/// NVDA/USDG fee-500 pool 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3 (VERIFIED on chain 2026-09-02:
/// token0 USDG 6dec, token1 NVDA 18dec, tickSpacing 10) — but the pool being live is not the vault
/// being live, and nothing here prints a figure until the vault address is non-zero.
export const VAULTS: VaultDef[] = [{ address: ZERO, label: "NVDA · USDG" }];

export const deployed = (v: VaultDef): boolean => v.address !== ZERO;
export const anyDeployed = (): boolean => VAULTS.some(deployed);

/// Only the surface the Earn page reads or writes. `previewWithdraw` and `pendingFees` are real views
/// on the contract (StockLpVault.sol:226, :290) — the page never simulates a mutating call to get them.
export const vaultAbi = parseAbi([
  "function stock() view returns (address)",
  "function base() view returns (address)",
  "function pool() view returns (address)",
  "function oracle() view returns (address)",
  "function keeper() view returns (address)",
  "function stockIs1() view returns (bool)",
  "function tickLower() view returns (int24)",
  "function tickUpper() view returns (int24)",
  "function rangeSet() view returns (bool)",
  "function maxDeviationBps() view returns (uint256)",
  "function performanceFeeBps() view returns (uint16)",
  "function bountyBps() view returns (uint16)",
  "function feeRecipient() view returns (address)",
  "function feeLocked() view returns (bool)",
  "function pendingRecipient() view returns (address)",
  "function pendingPerformanceBps() view returns (uint16)",
  "function pendingBountyBps() view returns (uint16)",
  "function pendingEffectiveTime() view returns (uint256)",
  "function FEE_TIMELOCK() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function totalValueUsd() view returns (uint256)",
  "function pendingFees() view returns (uint256 fee0, uint256 fee1)",
  "function previewWithdraw(uint256 shares) view returns (uint256 stockOut, uint256 baseOut)",
  "function deposit(uint256 stockAmt, uint256 baseAmt, uint256 minShares) returns (uint256 shares)",
  "function withdraw(uint256 shares, uint256 minStock, uint256 minBase) returns (uint256 outStock, uint256 outBase)",
  "function harvest() returns (uint256 fee0, uint256 fee1)",
  "function compound()",
]);

export const tokenAbi = parseAbi([
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);

const oracleAbi = parseAbi([
  "function priceOf(address token) view returns (uint256 price, uint8 decimals, bool inSession)",
]);

const poolAbi = parseAbi([
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 obsIndex, uint16 obsCard, uint16 obsCardNext, uint8 feeProtocol, bool unlocked)",
]);

export const SHARE_DECIMALS = 18; // ERC20 default; the vault declares no override (StockLpVault.sol:45)

const BPS = 10_000n;
const PRICE_SCALE = 10n ** 18n;
const MARK_EXP = 36n;

// ------------------------------------------------------------------ contract math, replayed

/// USD × 1e36 per RAW token unit — `_factor` (StockLpVault.sol:463-467), which multiplies rather than
/// divides so a non-integral feed no longer floors to whole dollars. Null where the contract reverts
/// BadConfig, so the page cannot quote a mark the vault itself would refuse.
export const factorOf = (
  px: bigint,
  feedDec: number,
  tokenDec: number,
): bigint | null => {
  const shift = BigInt(feedDec) + BigInt(tokenDec);
  return shift > MARK_EXP ? null : px * 10n ** (MARK_EXP - shift);
};

/// Floor integer sqrt, the same value OZ's Math.sqrt returns, so the oracle sqrt price derived below is
/// the contract's number and not an approximation of it.
function isqrt(n: bigint): bigint {
  if (n < 2n) return n;
  let x = 1n << ((BigInt(n.toString(2).length) + 1n) >> 1n);
  for (;;) {
    const y = (x + n / x) >> 1n;
    if (y >= x) return x;
    x = y;
  }
}

/// |oracle price ÷ pool spot − 1|, 1e18-scaled — `_requireTradeable` (StockLpVault.sol:469-475) with
/// the same operand order and the same truncating division. This is what decides whether a deposit
/// reverts PriceDeviation, so the UI computes it rather than letting the user find out at signing.
export function deviationOf(
  factorStock: bigint,
  factorBase: bigint,
  stockIs1: boolean,
  spotSqrt: bigint,
): bigint | null {
  if (spotSqrt === 0n || factorBase === 0n || factorStock === 0n) return null;
  const [f0, f1] = stockIs1
    ? [factorBase, factorStock]
    : [factorStock, factorBase];
  const sqrtOracle = isqrt((f0 << 192n) / f1);
  const r = (sqrtOracle * PRICE_SCALE) / spotSqrt;
  const ratio = (r * r) / PRICE_SCALE;
  return ratio > PRICE_SCALE ? ratio - PRICE_SCALE : PRICE_SCALE - ratio;
}

export const withinDeviation = (dev: bigint, maxBps: bigint): boolean =>
  dev <= (maxBps * PRICE_SCALE) / BPS;

/// A tight band truncates to "0 bps" under integer division, which reads as "no drift at all" — so the
/// display keeps the fraction. dev is a 1e18-scaled ratio; 1e14 of it is one basis point.
export const bpsOf = (dev: bigint): number => Number(dev) / 1e14;

/// What the vault KEEPS from a realized fee — `_retained` (StockLpVault.sol:273-275). The bounty is
/// carved from the performance cut, so it does not change the remainder.
export const retainedFee = (fee: bigint, perfBps: number): bigint =>
  fee - (fee * BigInt(perfBps)) / BPS;

// ------------------------------------------------------------------ state

export type TokenMeta = {
  address: Address;
  symbol: string;
  decimals: number;
};

/// Why a deposit is closed. The contract has no status enum — deposit simply reverts — so these are
/// derived from the same three conditions `_requireTradeable` checks, in the order it checks them.
export type Gate =
  | { open: true; deviation: bigint }
  | {
      open: false;
      why: "stale" | "closed" | "deviated";
      deviation: bigint | null;
    };

export type PendingFee = {
  recipient: Address;
  performanceBps: number;
  bountyBps: number;
  effective: bigint;
};

export type VaultState = {
  def: VaultDef;
  stock: TokenMeta;
  base: TokenMeta;
  pool: Address;
  oracle: Address;
  keeper: Address;
  stockIs1: boolean;
  shareSymbol: string;
  totalSupply: bigint;
  tickLower: number;
  tickUpper: number;
  tick: number;
  rangeSet: boolean;
  inRange: boolean;
  performanceFeeBps: number;
  bountyBps: number;
  feeRecipient: Address;
  feeLocked: boolean;
  pendingFee: PendingFee | null;
  feeTimelock: bigint;
  maxDeviationBps: bigint;
  /// USD × 1e18 at the ORACLE mark. Null off equity hours or on a stale feed — totalValueUsd reverts
  /// NotInSession by design (StockLpVault.sol:417→451), and units are the figure that survives that.
  valueUsd18: bigint | null;
  /// GROSS harvestable right now, mapped to (stock, base) rather than (token0, token1).
  fees: { stock: bigint; base: bigint };
  factors: { stock: bigint; base: bigint } | null;
  gate: Gate;
};

export type VaultPosition = {
  shares: bigint;
  /// previewWithdraw(shares) — the trustworthy figure: pro-rata of real holdings, no oracle, always
  /// available even when the USD tile is not.
  outStock: bigint;
  outBase: bigint;
  stockBalance: bigint;
  baseBalance: bigint;
  stockAllowance: bigint;
  baseAllowance: bigint;
};

const readVault = <T>(
  address: Address,
  functionName: string,
  args?: unknown[],
): Promise<T> =>
  mainnetPub.readContract({
    address,
    abi: vaultAbi,
    functionName,
    args,
  } as never) as Promise<T>;

async function tokenMeta(address: Address): Promise<TokenMeta> {
  const [symbol, decimals] = await Promise.all([
    mainnetPub
      .readContract({ address, abi: tokenAbi, functionName: "symbol" })
      .catch(() => "?") as Promise<string>,
    mainnetPub
      .readContract({ address, abi: tokenAbi, functionName: "decimals" })
      .catch(() => 18) as Promise<number>,
  ]);
  return { address, symbol, decimals: Number(decimals) };
}

/// The oracle read the vault itself trusts. `priceOf` reverts on a stale or incomplete feed, so a
/// throw here is a real gate condition and is reported as one, never swallowed into a zero.
async function priceLeg(
  oracle: Address,
  token: Address,
): Promise<{ price: bigint; decimals: number; inSession: boolean } | null> {
  const r = await mainnetPub
    .readContract({
      address: oracle,
      abi: oracleAbi,
      functionName: "priceOf",
      args: [token],
    })
    .catch(() => null);
  if (!r) return null;
  const [price, decimals, inSession] = r as [bigint, number, boolean];
  return { price, decimals: Number(decimals), inSession };
}

export const reads = {
  async vault(def: VaultDef): Promise<VaultState> {
    const v = def.address;
    const [
      stockAddr,
      baseAddr,
      pool,
      oracle,
      keeper,
      stockIs1,
      tickLower,
      tickUpper,
      rangeSet,
      maxDeviationBps,
      performanceFeeBps,
      bountyBps,
      feeRecipient,
      feeLocked,
      feeTimelock,
      totalSupply,
      shareSymbol,
    ] = await Promise.all([
      readVault<Address>(v, "stock"),
      readVault<Address>(v, "base"),
      readVault<Address>(v, "pool"),
      readVault<Address>(v, "oracle"),
      readVault<Address>(v, "keeper"),
      readVault<boolean>(v, "stockIs1"),
      readVault<number>(v, "tickLower"),
      readVault<number>(v, "tickUpper"),
      readVault<boolean>(v, "rangeSet"),
      readVault<bigint>(v, "maxDeviationBps"),
      readVault<number>(v, "performanceFeeBps"),
      readVault<number>(v, "bountyBps"),
      readVault<Address>(v, "feeRecipient"),
      readVault<boolean>(v, "feeLocked"),
      readVault<bigint>(v, "FEE_TIMELOCK"),
      readVault<bigint>(v, "totalSupply"),
      readVault<string>(v, "symbol").catch(() => "shares"),
    ]);

    const [stock, base, slot0, valueUsd18, feeRaw, pendingFee] =
      await Promise.all([
        tokenMeta(stockAddr),
        tokenMeta(baseAddr),
        mainnetPub.readContract({
          address: pool,
          abi: poolAbi,
          functionName: "slot0",
        }) as Promise<
          [bigint, number, number, number, number, number, boolean]
        >,
        readVault<bigint>(v, "totalValueUsd").catch(() => null),
        readVault<[bigint, bigint]>(v, "pendingFees").catch(
          () => [0n, 0n] as [bigint, bigint],
        ),
        pendingFeeChange(v),
      ]);

    const [sLeg, bLeg] = await Promise.all([
      priceLeg(oracle, stockAddr),
      priceLeg(oracle, baseAddr),
    ]);
    const factors = factorsFrom(sLeg, bLeg, stock, base);
    const tick = Number(slot0[1]);
    const dev = factors
      ? deviationOf(factors.stock, factors.base, stockIs1, slot0[0])
      : null;

    return {
      def,
      stock,
      base,
      pool,
      oracle,
      keeper,
      stockIs1,
      shareSymbol,
      totalSupply,
      tickLower: Number(tickLower),
      tickUpper: Number(tickUpper),
      tick,
      rangeSet,
      inRange:
        rangeSet && tick >= Number(tickLower) && tick < Number(tickUpper),
      performanceFeeBps: Number(performanceFeeBps),
      bountyBps: Number(bountyBps),
      feeRecipient,
      feeLocked,
      pendingFee,
      feeTimelock,
      maxDeviationBps,
      valueUsd18,
      fees: mapPair(feeRaw[0], feeRaw[1], stockIs1),
      factors,
      gate: gateFrom(sLeg, dev, maxDeviationBps),
    };
  },

  async position(v: VaultState, owner: Address): Promise<VaultPosition> {
    const shares = await readVault<bigint>(v.def.address, "balanceOf", [owner]);
    const [out, stockBalance, baseBalance, stockAllowance, baseAllowance] =
      await Promise.all([
        shares > 0n
          ? readVault<[bigint, bigint]>(v.def.address, "previewWithdraw", [
              shares,
            ]).catch(() => [0n, 0n] as [bigint, bigint])
          : Promise.resolve([0n, 0n] as [bigint, bigint]),
        balanceOf(v.stock.address, owner),
        balanceOf(v.base.address, owner),
        allowanceOf(v.stock.address, owner, v.def.address),
        allowanceOf(v.base.address, owner, v.def.address),
      ]);
    return {
      shares,
      outStock: out[0],
      outBase: out[1],
      stockBalance,
      baseBalance,
      stockAllowance,
      baseAllowance,
    };
  },

  /// What withdrawing `shares` pays RIGHT NOW. Read fresh at quote time rather than scaled off the
  /// position, because a concurrent harvest or another holder's exit moves it.
  async previewWithdraw(
    v: VaultState,
    shares: bigint,
  ): Promise<[bigint, bigint]> {
    if (shares <= 0n) return [0n, 0n];
    return readVault<[bigint, bigint]>(v.def.address, "previewWithdraw", [
      shares,
    ]).catch(() => [0n, 0n] as [bigint, bigint]);
  },
};

const balanceOf = (token: Address, owner: Address): Promise<bigint> =>
  mainnetPub
    .readContract({
      address: token,
      abi: tokenAbi,
      functionName: "balanceOf",
      args: [owner],
    })
    .catch(() => 0n) as Promise<bigint>;

const allowanceOf = (
  token: Address,
  owner: Address,
  spender: Address,
): Promise<bigint> =>
  mainnetPub
    .readContract({
      address: token,
      abi: tokenAbi,
      functionName: "allowance",
      args: [owner, spender],
    })
    .catch(() => 0n) as Promise<bigint>;

async function pendingFeeChange(v: Address): Promise<PendingFee | null> {
  const effective = await readVault<bigint>(v, "pendingEffectiveTime").catch(
    () => 0n,
  );
  if (effective === 0n) return null;
  const [recipient, performanceBps, bountyBps] = await Promise.all([
    readVault<Address>(v, "pendingRecipient"),
    readVault<number>(v, "pendingPerformanceBps"),
    readVault<number>(v, "pendingBountyBps"),
  ]);
  return {
    recipient,
    performanceBps: Number(performanceBps),
    bountyBps: Number(bountyBps),
    effective,
  };
}

type Leg = Awaited<ReturnType<typeof priceLeg>>;

function factorsFrom(
  sLeg: Leg,
  bLeg: Leg,
  stock: TokenMeta,
  base: TokenMeta,
): { stock: bigint; base: bigint } | null {
  if (!sLeg || !bLeg) return null;
  const fs = factorOf(sLeg.price, sLeg.decimals, stock.decimals);
  const fb = factorOf(bLeg.price, bLeg.decimals, base.decimals);
  return fs === null || fb === null ? null : { stock: fs, base: fb };
}

/// The three deposit-blocking conditions in the order `_requireTradeable` hits them: a reverting feed
/// first (priceOf is fail-closed), then the session flag, then the pool-vs-oracle band.
function gateFrom(
  sLeg: Leg,
  dev: bigint | null,
  maxDeviationBps: bigint,
): Gate {
  if (!sLeg) return { open: false, why: "stale", deviation: null };
  if (!sLeg.inSession) return { open: false, why: "closed", deviation: dev };
  if (dev === null) return { open: false, why: "stale", deviation: null };
  return withinDeviation(dev, maxDeviationBps)
    ? { open: true, deviation: dev }
    : { open: false, why: "deviated", deviation: dev };
}

const mapPair = (
  v0: bigint,
  v1: bigint,
  stockIs1: boolean,
): { stock: bigint; base: bigint } =>
  stockIs1 ? { stock: v1, base: v0 } : { stock: v0, base: v1 };

// ------------------------------------------------------------------ quotes

/// Shares this deposit would mint — `deposit` (StockLpVault.sol:189-190) replayed. The basis folds in
/// the fees a harvest realizes, because deposit harvests BEFORE it prices (`:180`); leaving that out
/// would quote high and hand the user a mint slightly worse than the screen promised.
export function quoteShares(
  v: VaultState,
  stockAmt: bigint,
  baseAmt: bigint,
): bigint | null {
  const f = v.factors;
  if (!f || v.valueUsd18 === null) return null;
  const depositUsd = stockAmt * f.stock + baseAmt * f.base;
  if (v.totalSupply === 0n) return depositUsd / PRICE_SCALE;
  const harvestUsd =
    retainedFee(v.fees.stock, v.performanceFeeBps) * f.stock +
    retainedFee(v.fees.base, v.performanceFeeBps) * f.base;
  const totalBefore = v.valueUsd18 * PRICE_SCALE + harvestUsd;
  return totalBefore === 0n ? null : (depositUsd * v.totalSupply) / totalBefore;
}

/// Shares are minted against the ORACLE mark, which barely moves between the quote and the next block,
/// so minShares can sit tight and still catch a real drift.
export const DEPOSIT_SLIPPAGE_BPS = 50n;

/// The withdraw legs need a MUCH wider band than the deposit, and tightening it is a footgun rather
/// than a safety win. `withdraw` burns liquidity at pool SPOT, so a small price move re-splits the
/// output mix between the two legs — a leg can fall several percent while the position's total value
/// is unchanged. At 50 bps every exit through ordinary volatility would revert Slippage. The floor is
/// still doing its job at 300: it bounds someone shoving the pool to hand you the wrong side of the
/// pair, which is the only value a burn can actually leak.
export const WITHDRAW_SLIPPAGE_BPS = 300n;

export const floorBy = (v: bigint, bps: bigint): bigint =>
  (v * (BPS - bps)) / BPS;

/// The user's slice of the vault at the ORACLE mark, USD × 1e18. Display-only and unavailable off
/// session — the units from previewWithdraw are the figure that is always true.
export const shareValueUsd18 = (
  v: VaultState,
  shares: bigint,
): bigint | null =>
  v.valueUsd18 === null || v.totalSupply === 0n
    ? null
    : (v.valueUsd18 * shares) / v.totalSupply;

/// DERIVED, display-only: 1.0001^tick is the pool's RAW token1/token0 ratio, the decimal shift makes it
/// human units, and stockIs1 flips it into a stock price denominated in the base. It describes where
/// the range sits, never what a share is worth — the oracle mark does that.
export function priceAtTick(v: VaultState, tick: number): number {
  const dec0 = v.stockIs1 ? v.base.decimals : v.stock.decimals;
  const dec1 = v.stockIs1 ? v.stock.decimals : v.base.decimals;
  const ratio = Math.exp(tick * Math.log(1.0001)) * 10 ** (dec0 - dec1);
  return v.stockIs1 ? 1 / ratio : ratio;
}
