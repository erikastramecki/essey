// Display-only USD marks for the reserve basket, RH mainnet 4663. Nothing here feeds the floor, a NAV,
// a borrow limit or any solvency figure — the reserve pays redemption in UNITS. Freshness fails CLOSED,
// the same rule the lending core enforces (StockConverter.sol:48): a stale or negative read renders
// "unavailable", never a number and never $0.
import {
  encodeAbiParameters,
  keccak256,
  parseAbi,
  parseAbiParameters,
  type Address,
  type PublicClient,
} from "viem";

/// Aggregator per basket token, keyed by lowercased token address; anything absent renders units-only.
/// GLD/NFLX/DJT have no Robinhood feed in Chainlink's 4663 directory (57 feeds, checked 2026-09-02) and
/// CASHCAT/PONS none either. MSTR postdates RobinhoodFeeds.sol:10-18 and is verified live below.
const FEEDS: Record<string, Address> = {
  "0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec":
    "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15", // NVDA
  "0xaf3d76f1834a1d425780943c99ea8a608f8a93f9":
    "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0", // AAPL
  "0x2e0847e8910a9732eb3fb1bb4b70a580adad4fe3":
    "0xF6f373a037c30F0e5010d854385cA89185AE638b", // GOOGL
  "0x322f0929c4625ed5bad873c95208d54e1c003b2d":
    "0x4A1166a659A55625345e9515b32adECea5547C38", // TSLA
  "0x117cc2133c37b721f49de2a7a74833232b3b4c0c":
    "0x319724394D3A0e3669269846abE664Cd621f9f6A", // SPY
  "0xec262a75e413fafd0df80480274532c79d42da09":
    "0x396118bdFB181e6240E74D243F266B061c0edc3D", // MSTR
  "0xd5f3879160bc7c32ebb4dc785f8a4f505888de68":
    "0x80901d846d5D7B030F26B480776EE3b29374C2ae", // QQQ
};

const ETH_USD = "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9" as Address;

/// Heartbeat 86400s (RobinhoodFeeds.sol:20) plus the contracts' hour of grace (StaleFeedGuard.sol:50),
/// so "fresh" here means exactly what it means on chain.
const MAX_STALENESS = 86_400 + 3_600;

export const FLR = "0x8aD25c65587979533fa1cA0d2194A76D5bAE305d" as Address;

/// $FLR has no Chainlink feed on 4663 and its Pons bonding curve is graduated with a zero token reserve,
/// so the only live venue is one permanently-locked Uniswap V4 position. The poolId is DERIVED from the
/// PoolKey rather than pasted: a wrong key returns zero logs and the line renders unavailable.
const POOL_MANAGER = "0x8366a39CC670B4001A1121B8F6A443A643e40951" as Address;
const FLR_POOL_ID = keccak256(
  encodeAbiParameters(
    parseAbiParameters("address, address, uint24, int24, address"),
    [
      "0x0000000000000000000000000000000000000000",
      FLR,
      0,
      200,
      "0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044",
    ],
  ),
);
const SWAP_TOPIC =
  "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f";

/// The pool is ~8 ETH deep — roughly $921 of notional moves spot 10% — so the mark is the MEDIAN tick of
/// the last 50 swaps and never slot0, which is exactly the number that push would move. 60k blocks is
/// ~1.7h at the chain's ~0.1 s/block, comfortably wider than the age we are willing to display.
const SWAP_WINDOW_BLOCKS = 60_000n;
const SWAP_SAMPLE = 50;
const SWAP_MAX_AGE = 3_600;

const aggregatorAbi = parseAbi([
  "function decimals() view returns (uint8)",
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);

/// "pool" marks come from a thin venue and every surface showing one must say so on screen.
export type PriceSource = "feed" | "pool";

export type Price =
  | {
      ok: true;
      usd8: bigint;
      updatedAt: number;
      ageSec: number;
      src: PriceSource;
    }
  | { ok: false; why: "no-feed" | "stale" | "unreadable" };

export const NO_FEED: Price = { ok: false, why: "no-feed" };

/// Never "$0.00": a reader must be able to tell "we cannot price this" from "this is worth nothing".
export const unpricedReason = (p: Price): string =>
  p.ok
    ? ""
    : p.why === "stale"
      ? "price stale"
      : p.why === "unreadable"
        ? "price unavailable"
        : "no feed · units only";

/// Chain time, not the browser's: a skewed local clock would move lines between live and unavailable.
export const chainNow = async (client: PublicClient): Promise<number> =>
  Number((await client.getBlock()).timestamp);

const rescale = (v: bigint, from: number, to: number): bigint =>
  from === to
    ? v
    : from > to
      ? v / 10n ** BigInt(from - to)
      : v * 10n ** BigInt(to - from);

/// 1e8 USD scale. Null — never zero — with no usable price, so a caller cannot sum a missing line in.
export const valueOf = (
  units: bigint,
  tokenDecimals: number,
  price: Price,
): bigint | null =>
  price.ok ? (units * price.usd8) / 10n ** BigInt(tokenDecimals) : null;

async function feedPrice(
  client: PublicClient,
  feed: Address,
  now: number,
): Promise<Price> {
  try {
    const [decimals, round] = await Promise.all([
      client.readContract({
        address: feed,
        abi: aggregatorAbi,
        functionName: "decimals",
      }),
      client.readContract({
        address: feed,
        abi: aggregatorAbi,
        functionName: "latestRoundData",
      }),
    ]);
    const [roundId, answer, , updatedAt, answeredInRound] = round;
    if (answer <= 0n) return { ok: false, why: "unreadable" };
    // A round that never completed, or an answer carried over from an earlier one, is not a price.
    if (updatedAt === 0n || answeredInRound < roundId)
      return { ok: false, why: "unreadable" };
    const ageSec = now - Number(updatedAt);
    if (ageSec > MAX_STALENESS) return { ok: false, why: "stale" };
    return {
      ok: true,
      usd8: rescale(answer, Number(decimals), 8),
      updatedAt: Number(updatedAt),
      ageSec,
      src: "feed",
    };
  } catch {
    return { ok: false, why: "unreadable" };
  }
}

type SwapLog = {
  data: `0x${string}`;
  blockNumber: `0x${string}`;
  blockTimestamp?: `0x${string}`;
};

/// Uniswap V4 Swap payload: amount0, amount1, sqrtPriceX96, liquidity, tick, fee.
const word = (data: string, i: number): bigint =>
  BigInt(`0x${data.slice(2 + i * 64, 66 + i * 64)}`);

const asInt = (w: bigint): bigint => (w >> 255n ? w - (1n << 256n) : w);

/// blockTimestamp is a non-standard log field. RH mainnet returns the KEY but leaves it "0x0", which is
/// truthy — trusting its presence aged every mark to 1970 and blanked the line. Zero means absent here.
const swapTime = async (
  client: PublicClient,
  log: SwapLog,
): Promise<number> => {
  const stamped = log.blockTimestamp ? Number(BigInt(log.blockTimestamp)) : 0;
  if (stamped > 0) return stamped;
  const b = await client.getBlock({ blockNumber: BigInt(log.blockNumber) });
  return Number(b.timestamp);
};

export async function flrPrice(
  client: PublicClient,
  now: number,
): Promise<Price> {
  // ETH/USD is the other half of the cross, so a stale ETH feed takes FLR down with it rather than
  // silently marking the reserve's largest line against a price hours out of date.
  const eth = await feedPrice(client, ETH_USD, now);
  if (!eth.ok) return eth;
  try {
    const head = await client.getBlockNumber();
    const logs = (await client.request({
      method: "eth_getLogs",
      params: [
        {
          address: POOL_MANAGER,
          topics: [SWAP_TOPIC, FLR_POOL_ID],
          fromBlock: `0x${(head - SWAP_WINDOW_BLOCKS).toString(16)}`,
          toBlock: `0x${head.toString(16)}`,
        },
      ],
    } as never)) as unknown as SwapLog[];
    if (logs.length === 0) return { ok: false, why: "unreadable" };
    const updatedAt = await swapTime(client, logs[logs.length - 1]);
    const ageSec = now - updatedAt;
    if (ageSec > SWAP_MAX_AGE) return { ok: false, why: "stale" };
    // Median-LOW, so the mark is a sqrtPrice the pool actually printed rather than an average of two.
    const recent = logs
      .slice(-SWAP_SAMPLE)
      .sort((a, b) =>
        asInt(word(a.data, 4)) < asInt(word(b.data, 4)) ? -1 : 1,
      );
    const sq = word(recent[(recent.length - 1) >> 1].data, 2);
    if (sq === 0n) return { ok: false, why: "unreadable" };
    // currency0 is native ETH, currency1 is FLR, both 18-dec: ETH per FLR = 2**192 / sqrtPriceX96**2.
    return {
      ok: true,
      usd8: (2n ** 192n * eth.usd8) / (sq * sq),
      updatedAt,
      ageSec,
      src: "pool",
    };
  } catch {
    return { ok: false, why: "unreadable" };
  }
}

export async function priceOf(
  client: PublicClient,
  token: Address,
  now: number,
): Promise<Price> {
  const key = token.toLowerCase();
  if (key === FLR.toLowerCase()) return flrPrice(client, now);
  const feed = FEEDS[key];
  return feed ? feedPrice(client, feed, now) : NO_FEED;
}
