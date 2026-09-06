// The EsseyReserve read layer — Robinhood Chain MAINNET (4663). A separate read-only viem client from
// live.ts, which is the testnet game (46630). The reserve holds the tokenized-stock backing under
// $ESSEY; this file reads its live on-chain state so the Treasury page shows exactly what backs the
// token and lets anyone verify it. No wallet, no writes: a transparency ledger is a read.
//
// The reserve is FULLY ADMINLESS with no on-chain token registry — it backs $ESSEY with whatever is
// sent to it, and redemption is pro-rata across every token it holds. So this page cannot ask the
// contract "what tokens back you"; instead it enumerates the known basket and reads the reserve's live
// balance of each (a token the treasury adds later gets added here). The reliable-vs-upside split is
// NOT a hand-label: it is the on-chain BEACON check — a genuine Robinhood Stock Token is a beacon proxy
// pointing at the issuer's shared beacon; a memecoin/launchpad token is not, and counts as upside only.
import {
  createPublicClient,
  defineChain,
  http,
  parseAbi,
  type Address,
  type PublicClient,
} from "viem";
import { chainNow, NO_FEED, priceOf, valueOf, type Price } from "./prices";

export const MAINNET = {
  chainId: 4663,
  name: "Robinhood Chain",
  rpc: "https://rpc.mainnet.chain.robinhood.com",
  explorer: "https://robinhoodchain.blockscout.com",
};

const ZERO = "0x0000000000000000000000000000000000000000" as Address;

/// LIVE on RH mainnet since 2026-08-29 (DeployEsseyFoundation, verified on chain). `deployed()` still
/// gates the page, so if these are ever reset to zero it renders the "deploys soon" state rather than
/// a broken read.
export const RESERVE = {
  reserve: "0xd970Ca726188e38982906Ae2284D2bdB80205A7b" as Address,
  essey: "0x315790B57C19141B34C4653a91b096Cf3f071610" as Address,
};

export const deployed = (): boolean => RESERVE.reserve !== ZERO;

/// The known basket, live on RH mainnet 4663. The reserve's real holdings are read per token below; this
/// list is only what the page KNOWS to look up (and a symbol fallback). Any token in here that the reserve
/// does not hold simply reads zero.
export const BASKET: Address[] = [
  "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", // NVDA
  "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9", // AAPL
  "0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3", // GOOGL
  "0x322F0929c4625eD5bAd873c95208D54E1c003b2d", // TSLA
  "0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e", // GLD
  "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C", // SPY
  "0xec262a75e413fAfD0dF80480274532C79D42da09", // MSTR
  "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68", // QQQ
  "0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8", // NFLX
  "0x1D11f0496982706C5e14A514D4E79F2e6BdE4516", // DJT
  "0x020bfC650A365f8BB26819deAAbF3E21291018b4", // CASHCAT
  "0x39dBED3a2bd333467115dE45665cC57F813C4571", // PONS
  "0x8aD25c65587979533fa1cA0d2194A76D5bAE305d", // FLR
  "0x12f190a9F9d7D37a250758b26824B97CE941bF54", // AMZN
  "0x8FA1248C3ec58F733e778B89c30526716Cd70893", // Supercycle
];

/// Non-forgeable legitimacy gate: every real Robinhood Stock Token is an EIP-1967 beacon proxy whose
/// beacon slot points at the issuer's shared beacon. A token that matches is a genuine tokenized equity
/// (reliable floor); anything else is volatile upside. This is exactly the reserve's NAV-integrity rule,
/// enforced by reading storage, not by trusting a symbol.
const RH_STOCK_BEACON = "e10b6f6b275de231345c20d14ab812db62151b00";
const EIP1967_BEACON_SLOT =
  "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50" as `0x${string}`;

export type TokenKind = "equity" | "crypto";

/// Canonical CREATE2 Multicall3, verified live on 4663 (getBlockNumber answers, aggregate3 returns
/// per-call success). Without it viem's batching silently does nothing.
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as Address;

export const mainnetChain = defineChain({
  id: MAINNET.chainId,
  name: MAINNET.name,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [MAINNET.rpc] } },
  blockExplorers: { default: { name: "Explorer", url: MAINNET.explorer } },
  contracts: { multicall3: { address: MULTICALL3 } },
});

export const mainnetPub = createPublicClient({
  chain: mainnetChain,
  // Two layers because they cover different calls: aggregate3 folds the per-token eth_calls, and
  // JSON-RPC array batching folds what it cannot reach (13 eth_getStorageAt). 142 POSTs → 7 per load,
  // and the burst — not the chain — is why reads were dropping.
  transport: http(MAINNET.rpc, { batch: true }),
  batch: { multicall: true },
});

const erc20 = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
]);

/// Only the views this page reads. reserveOf/floorOf/circulatingSupply are the honest backing figures;
/// floorOf is deliberately UNITS of the token per 1e18 $ESSEY, never a dollar mark. claimBase is the
/// fixed denominator every redemption divides by.
export const reserveAbi = parseAbi([
  "function circulatingSupply() view returns (uint256)",
  "function reserveOf(address) view returns (uint256)",
  "function floorOf(address) view returns (uint256)",
  "function claimBase() view returns (uint256)",
  "function EXIT_FEE_BPS() view returns (uint256)",
  "function essey() view returns (address)",
]);

/// Decimals-aware formatter — live.ts's fmt takes only a display precision and assumes 18-dec, but the
/// basket mixes token decimals (a Stock Token is not 18), so backing amounts need the token's own scale.
export const fmt = (v: bigint, decimals = 18, dp = 2): string => {
  const neg = v < 0n;
  const abs = neg ? -v : v;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  const frac = ((abs % base) * 10n ** BigInt(dp)) / base;
  const s = `${whole.toLocaleString("en-US")}.${frac.toString().padStart(dp, "0")}`;
  return neg ? `-${s}` : s;
};

/// Display-only, so the Treasury page and the explorer's balance bar cannot drift apart on precision.
export const usd = (v: bigint): string => `$${fmt(v, 8, 2)}`;

/// A read error here is a mainnet RPC/decode failure, not a game revert — live.ts's niceError is
/// game-flavored (faucet, Dons), so keep a plain surface: the custom-error name where viem gives one.
export const readError = (e: unknown): string => {
  const raw = e instanceof Error ? e.message : String(e);
  const sig = raw.match(/\b([A-Z][A-Za-z0-9]*)\(\s*(?:[a-z]|\))/);
  if (sig) return sig[1];
  return raw.split("\n")[0].slice(0, 160);
};

export type TokenRow = {
  address: Address;
  /// null when symbol() could not be read — a "?" fallback leaked into the excluded-tickers list and
  /// read there as a ticker.
  symbol: string | null;
  /// The issuer's own on-chain name(), never a hand-kept map — so the display cannot drift from the
  /// token it is describing.
  name: string;
  /// Only meaningful while `reserve` is non-null: a token whose decimals() we could not read has no
  /// scale, so its balance is reported unreadable rather than printed at a guessed magnitude.
  decimals: number;
  /// THE RULE prices.ts:88 states for marks, applied to balances: null is "we could not read this",
  /// 0n is "the reserve holds none". Coercing the first to the second is how /explorer once rendered
  /// $10.66 against a true $645 with a live badge and no error.
  reserve: bigint | null; // units of the token the reserve holds right now
  floor: bigint | null; // units of the token backing 1e18 $ESSEY — only ratchets up
  kind: TokenKind;
  price: Price;
  valueUsd8: bigint | null; // display-only mark of `reserve` at `price`, 1e8 USD; null when unpriced
};

/// A row without a symbol still has an address, which is the thing a reader can check anyway.
export const tokenLabel = (t: TokenRow): string =>
  t.symbol ?? `${t.address.slice(0, 6)}…${t.address.slice(-4)}`;

export const UNREADABLE = "unreadable";

export type TreasuryState = {
  esseyTotal: bigint;
  circulating: bigint;
  claimBase: bigint;
  exitFeeBps: bigint;
  tokens: TokenRow[];
  /// Priced lines only, 1e8 USD — a floor on the marked value, never the whole basket, so any surface
  /// showing it must also say which lines it covers.
  pricedUsd8: bigint;
  /// The same total split by the on-chain beacon check, because a dollar figure dominated by a launchpad
  /// token says something very different from one dominated by equities.
  equityUsd8: bigint;
  upsideUsd8: bigint;
  /// Funded lines, including the ones whose balance would not read — an unreadable line is still a line.
  heldCount: number;
  pricedHeld: number;
  unpricedHeld: number;
  /// Named, not just counted: "excluded" is only honest if a reader can see WHICH holdings it means.
  unpricedSymbols: string[];
  /// Balances that would not read after the retries. While this is non-empty the dollar totals above are
  /// a LOWER BOUND, not the balance, and every surface printing one has to say so.
  unreadableSymbols: string[];
  incomplete: boolean;
  /// True while any marked line comes from a thin AMM pool rather than a Chainlink feed.
  poolMarked: boolean;
  priceAsOf: number;
};

const RETRIES = 2;
const RETRY_MS = 200;

/// A single transient drop must not blank a row, so every chain read gets two short retries before it
/// counts as a failure. Backoff is linear and tiny: this runs on a 20s poll, not a hot loop.
async function retry<T>(fn: () => Promise<T>): Promise<T> {
  for (let i = 0; ; i++) {
    try {
      return await fn();
    } catch (e) {
      if (i >= RETRIES) throw e;
      await new Promise((r) => setTimeout(r, RETRY_MS * (i + 1)));
    }
  }
}

/// Retried, then null — never a fallback value. A `?? 0n` here is the whole bug: it makes a read that
/// failed indistinguishable from a reserve that holds nothing, and the total quietly shrinks.
const soft = <T>(fn: () => Promise<T>): Promise<T | null> =>
  retry(fn).catch(() => null);

const read = <T>(functionName: string, args?: unknown[]): Promise<T> =>
  retry(
    () =>
      mainnetPub.readContract({
        address: RESERVE.reserve,
        abi: reserveAbi,
        functionName,
        args,
      } as never) as Promise<T>,
  );

/// KNOWN-OPEN: a beacon slot that will not read after the retries still falls back to "not a stock",
/// which moves a real equity into the upside bucket rather than saying it could not be checked. Left
/// as-is here because it needs a third `kind` state and a home for a row that belongs to neither table.
async function isRhStock(token: Address): Promise<boolean> {
  const slot = await soft(() =>
    mainnetPub.getStorageAt({ address: token, slot: EIP1967_BEACON_SLOT }),
  );
  return !!slot && slot.toLowerCase().endsWith(RH_STOCK_BEACON);
}

async function tokenRow(token: Address, now: number): Promise<TokenRow> {
  const [symbol, name, decimals, held, floor, stock, price] = await Promise.all(
    [
      soft(
        () =>
          mainnetPub.readContract({
            address: token,
            abi: erc20,
            functionName: "symbol",
          }) as Promise<string>,
      ),
      soft(
        () =>
          mainnetPub.readContract({
            address: token,
            abi: erc20,
            functionName: "name",
          }) as Promise<string>,
      ),
      soft(
        () =>
          mainnetPub.readContract({
            address: token,
            abi: erc20,
            functionName: "decimals",
          }) as Promise<number>,
      ),
      soft(() => read<bigint>("reserveOf", [token])),
      soft(() => read<bigint>("floorOf", [token])),
      isRhStock(token),
      // A price outage must not take the backing ledger down with it: the units are the truth here.
      priceOf(mainnetPub as PublicClient, token, now).catch(() => NO_FEED),
    ],
  );
  // Without decimals() a balance has no scale, so it is unreadable rather than printed at a guess.
  const dec = decimals === null ? null : Number(decimals);
  const reserve = dec === null ? null : held;
  return {
    address: token,
    symbol,
    name: name ?? "",
    decimals: dec ?? 18,
    reserve,
    floor: dec === null ? null : floor,
    kind: stock ? "equity" : "crypto",
    price,
    valueUsd8: reserve === null ? null : valueOf(reserve, dec as number, price),
  };
}

export const reads = {
  async treasury(): Promise<TreasuryState> {
    const [circulating, claimBase, exitFeeBps, esseyAddr, priceAsOf] =
      await Promise.all([
        read<bigint>("circulatingSupply"),
        read<bigint>("claimBase"),
        read<bigint>("EXIT_FEE_BPS"),
        read<Address>("essey"),
        chainNow(mainnetPub as PublicClient),
      ]);
    const esseyTotal = (await retry(
      () =>
        mainnetPub.readContract({
          address: esseyAddr,
          abi: erc20,
          functionName: "totalSupply",
        }) as Promise<bigint>,
    )) as bigint;
    // Reliable equities first, then upside — a stable render order regardless of RPC ordering.
    const tokens = (
      await Promise.all(BASKET.map((t) => tokenRow(t, priceAsOf)))
    ).sort((a, b) => (a.kind === b.kind ? 0 : a.kind === "equity" ? -1 : 1));
    // An unreadable balance stays in `held`: it is a line we cannot rule out, so it keeps its row and
    // its name in the caveat instead of silently leaving the page as though the reserve held none.
    const held = tokens.filter((t) => t.reserve === null || t.reserve > 0n);
    const sum = (rows: TokenRow[]): bigint =>
      rows.reduce((s, t) => s + (t.valueUsd8 ?? 0n), 0n);
    const unreadable = held.filter((t) => t.reserve === null);
    const unpriced = held.filter(
      (t) => t.reserve !== null && t.valueUsd8 === null,
    );
    return {
      esseyTotal,
      circulating,
      claimBase,
      exitFeeBps,
      tokens,
      pricedUsd8: sum(held),
      equityUsd8: sum(held.filter((t) => t.kind === "equity")),
      upsideUsd8: sum(held.filter((t) => t.kind === "crypto")),
      heldCount: held.length,
      pricedHeld: held.length - unpriced.length - unreadable.length,
      unpricedHeld: unpriced.length,
      unpricedSymbols: unpriced.map(tokenLabel),
      unreadableSymbols: unreadable.map(tokenLabel),
      incomplete: unreadable.length > 0,
      poolMarked: held.some((t) => t.price.ok && t.price.src === "pool"),
      priceAsOf,
    };
  },
};
