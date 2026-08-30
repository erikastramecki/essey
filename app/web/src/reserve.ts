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
} from "viem";

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
const BASKET: Address[] = [
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
];

/// Non-forgeable legitimacy gate: every real Robinhood Stock Token is an EIP-1967 beacon proxy whose
/// beacon slot points at the issuer's shared beacon. A token that matches is a genuine tokenized equity
/// (reliable floor); anything else is volatile upside. This is exactly the reserve's NAV-integrity rule,
/// enforced by reading storage, not by trusting a symbol.
const RH_STOCK_BEACON = "e10b6f6b275de231345c20d14ab812db62151b00";
const EIP1967_BEACON_SLOT =
  "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50" as `0x${string}`;

export type TokenKind = "equity" | "crypto";

const chain = defineChain({
  id: MAINNET.chainId,
  name: MAINNET.name,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [MAINNET.rpc] } },
  blockExplorers: { default: { name: "Explorer", url: MAINNET.explorer } },
});

export const mainnetPub = createPublicClient({
  chain,
  transport: http(MAINNET.rpc),
});

const erc20 = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
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
  symbol: string;
  decimals: number;
  reserve: bigint; // units of the token the reserve holds right now
  floor: bigint; // units of the token backing 1e18 $ESSEY — only ratchets up
  kind: TokenKind;
};

export type TreasuryState = {
  esseyTotal: bigint;
  circulating: bigint;
  claimBase: bigint;
  exitFeeBps: bigint;
  tokens: TokenRow[];
};

const read = <T>(functionName: string, args?: unknown[]): Promise<T> =>
  mainnetPub.readContract({
    address: RESERVE.reserve,
    abi: reserveAbi,
    functionName,
    args,
  } as never) as Promise<T>;

async function isRhStock(token: Address): Promise<boolean> {
  const slot = await mainnetPub
    .getStorageAt({ address: token, slot: EIP1967_BEACON_SLOT })
    .catch(() => null);
  return !!slot && slot.toLowerCase().endsWith(RH_STOCK_BEACON);
}

async function tokenRow(token: Address): Promise<TokenRow> {
  const [symbol, decimals, reserve, floor, stock] = await Promise.all([
    mainnetPub
      .readContract({ address: token, abi: erc20, functionName: "symbol" })
      .catch(() => "?") as Promise<string>,
    mainnetPub
      .readContract({ address: token, abi: erc20, functionName: "decimals" })
      .catch(() => 18) as Promise<number>,
    read<bigint>("reserveOf", [token]).catch(() => 0n),
    read<bigint>("floorOf", [token]).catch(() => 0n),
    isRhStock(token),
  ]);
  return {
    address: token,
    symbol,
    decimals: Number(decimals),
    reserve,
    floor,
    kind: stock ? "equity" : "crypto",
  };
}

export const reads = {
  async treasury(): Promise<TreasuryState> {
    const [circulating, claimBase, exitFeeBps, esseyAddr] = await Promise.all([
      read<bigint>("circulatingSupply"),
      read<bigint>("claimBase"),
      read<bigint>("EXIT_FEE_BPS"),
      read<Address>("essey"),
    ]);
    const esseyTotal = (await mainnetPub.readContract({
      address: esseyAddr,
      abi: erc20,
      functionName: "totalSupply",
    })) as bigint;
    // Reliable equities first, then upside — a stable render order regardless of RPC ordering.
    const tokens = (await Promise.all(BASKET.map(tokenRow))).sort((a, b) =>
      a.kind === b.kind ? 0 : a.kind === "equity" ? -1 : 1,
    );
    return { esseyTotal, circulating, claimBase, exitFeeBps, tokens };
  },
};
