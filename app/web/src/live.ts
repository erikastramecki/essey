// Live-chain layer: the deployed TESTNET contracts and the transaction flows the app pages run.
// Everything here is testnet (46630) until mainnet ships; the addresses come from
// docs/DEPLOYMENT-testnet.md and the UI wears a TESTNET banner the whole time.
import { createPublicClient, createWalletClient, custom, http, parseAbi, parseAbiItem, maxUint256, type Address, type Hex } from "viem";

export const NET = {
  chainIdHex: "0xb626", // 46630
  chainId: 46630,
  name: "Robinhood Chain Testnet",
  rpc: "https://rpc.testnet.chain.robinhood.com",
  explorer: "https://explorer.testnet.chain.robinhood.com",
  faucet: "https://faucet.testnet.chain.robinhood.com",
};

export const ADDR = {
  // Stock-payout stack — redeployed 2026-08-04 (converter-wired Bell; stock payouts proven on-chain).
  seat: "0x7bcc821cdf7e3ad9e43188d0f0b24049db0b1bee" as Address,
  essey: "0x0659eca47665da545e1157ede11fcb4c8222879f" as Address,
  usdg: "0x7461E670d44FF4397A3E48030C5b06f6163a5De2" as Address,
  bell: "0x31115d449f359a05298295415665af18fd708d0d" as Address,
  exchange: "0x57864a956a13d42837f121790715713cbaa7df09" as Address,
  cases: "0x97ad3b44d0B362F70460c90993E9eF79b9D2D749" as Address, // keeper-enabled (1-sign reveal)
  faucet: "0x11c696cf869c1caace32e7ea6d1d2074c452ded2" as Address,
  aapl: "0xaC6cd493e69eb82e8f113E33De8e5542F313B731" as Address,
  nvda: "0x8393cc99FAC1CF79E3bEceA56f344159ddFd91E9" as Address,
  // Lending stack (unchanged)
  pool: "0x283a4891458180f502E82E40470d3e06321ba748" as Address,
  markets: "0x6dAE0540bcC78756BB7b2e936ACBFA9cA5439732" as Address,
  quest: "0x3DD40673665e13bD4A8A7B1D6e27Cb43EDfE0427" as Address,
  lens: "0xaAC27dBbDF85096fe0481F8E194ac2ffef146df3" as Address,
  // Stock-payout converter (Bell claim-edge → real stock into the Vault).
  converter: "0x3c6a57b21c000caecc61655568eabb6cfbb67fb0" as Address,
  // Degen (multiplier) case + its testnet entropy keeper.
  degenCases: "0x96d5CE89fB10044882F144430EDeC2Eb412Af42d" as Address,
  degenEntropy: "0xb9b82A4900642A98e29F59B937FDE6B2DDaF1E6F" as Address,
};

// The BundleConverter's BUNDLE sentinel (address(0xB0B1)) — the "pay me the basket" payout target.
// Matches BundleConverter.BUNDLE; used as the Seat payout preference for the default mix.
export const BUNDLE = "0x000000000000000000000000000000000000B0B1" as Address;

// Whitelist raffle size — 2,222 mint spots (the Seat supply).
export const WHITELIST_SPOTS = 2222;

// Collateral markets open after the 2-day parameter timelock (a real safety feature, not a knob).
export const BORROW_OPENS = new Date("2026-08-05T18:55:00Z");

// Launch parameters as deployed (18-dec mock USDG on testnet).
export const PRICE = { seat: 500n * 10n ** 18n, swapFee: 10n * 10n ** 18n, snipeFee: 15n * 10n ** 18n, sellFee: 8n * 10n ** 18n, casePrice: 100n * 10n ** 18n, caseFee: 5n * 10n ** 18n };

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
]);
export const exchangeAbi = parseAbi([
  "function inventoryCount() view returns (uint256)",
  "function inventoryAt(uint256) view returns (uint256)",
  "function esseyReserve() view returns (uint256)",
  "function buy() returns (uint256)",
  "function snipe(uint256)",
  "function sell(uint256)",
  "event Bought(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee)",
  "event Sniped(uint256 indexed id, address indexed buyer, uint256 price, uint256 fee)",
]);
export const casesAbi = parseAbi([
  "function buy() returns (uint256)",
  "function open(uint256) returns (address, uint256)",
  "function inventoryCount() view returns (uint256)",
  "event CaseBought(uint256 indexed caseId, address indexed buyer, uint64 drawBlock)",
  "event CaseOpened(uint256 indexed caseId, address indexed buyer, address indexed token, uint256 amount)",
]);
export const bellAbi = parseAbi([
  "function pot() view returns (uint256)",
  "function tierCount() view returns (uint256)",
  "function tierFees(uint256) view returns (uint256)",
  "function tierWeights(uint256) view returns (uint256)",
  "function seats(uint256) view returns (uint8 tier, uint248 weight, uint256 rewardDebt, uint256 pendingStored)",
  "function pendingOf(uint256) view returns (uint256)",
  "function activate(uint256 id, uint8 tier)",
  "function upgrade(uint256 id, uint8 newTier)",
  "function ring()",
  "function claim(uint256 id) returns (uint256)",
  "function setPayoutToken(uint256 id, address token)",
  "function payoutTokenOf(uint256) view returns (address)",
  "function defaultPayout() view returns (address)",
  "function converter() view returns (address)",
  "event ClaimConverted(uint256 indexed id, address token, uint256 amountOut)",
  "event ClaimFellBack(uint256 indexed id, address token)",
]);
// The stock-payout converter (inventory BundleConverter). Supports single stocks + the BUNDLE basket.
export const converterAbi = parseAbi([
  "function isSupported(address) view returns (bool)",
  "function bundleSize() view returns (uint256)",
  "function bundleAt(uint256) view returns (address)",
  "function reserveOf(address) view returns (uint256)",
]);
export const seatAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function ownerOf(uint256) view returns (address)",
  "function approve(address,uint256)",
  "function tokenURI(uint256) view returns (string)",
  "function vaultOf(uint256) view returns (address)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
]);
const DEPLOY_BLOCK = 96_550_000n; // Seat deployed ~here; owned-Seat scan starts from this
export const faucetAbi = parseAbi([
  "function drip()",
  "function lastDrip(address) view returns (uint256)",
]);
export const poolAbi = parseAbi([
  "function totalAssets() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function convertToAssets(uint256) view returns (uint256)",
  "function maxWithdraw(address) view returns (uint256)",
  "function borrowRateBps() view returns (uint256)",
  "function utilizationBps() view returns (uint256)",
  "function reserveBps() view returns (uint256)",
  "function deposit(uint256 assets, address receiver) returns (uint256)",
  "function withdraw(uint256 assets, address receiver, address owner) returns (uint256)",
  "function borrow(address token, uint256 collateralRaw, uint256 debt) returns (uint256)",
  "function repay(uint256 id, uint256 amount)",
  "function debtOf(uint256 id) view returns (uint256)",
  "function positions(uint256) view returns (address token, uint256 collateralRaw, uint256 principal, uint256 indexSnapshot)",
  "function nextPositionId() view returns (uint256)",
  "function note() view returns (address)",
]);
export const marketsAbi = parseAbi([
  "function canBorrow(address) view returns (bool)",
  "function maxBorrow(address token, uint256 rawAmount) view returns (uint256)",
]);
export const noteAbi = parseAbi(["function ownerOf(uint256) view returns (address)"]);
export const questAbi = parseAbi([
  "function registered(address) view returns (bool)",
  "function referralCount(address) view returns (uint256)",
  "function totalRegistered() view returns (uint256)",
  "function register(address referrer)",
  "event Registered(address indexed participant, address indexed referrer)",
]);
export const lensAbi = parseAbi([
  "function qualified(address) view returns (bool)",
  "function qualifiedMany(address[]) view returns (bool[])",
  "function status(address) view returns ((bool registered, bool ownsSeat, bool supplied, bool wonStock, uint256 referrals))",
]);
// Cases sell-back — approve the stock unit, then sell it back at oracle value minus the spread.
export const casesSellAbi = parseAbi([
  "function sellBack(address token) returns (uint256 paid)",
  "function stocks(address) view returns (uint256 unitAmount, uint8 tokenDecimals, bool listed)",
]);

// Degen (multiplier) case — a provably-fair+solvent gacha: buy (payable, entropy fee), a keeper
// settles the roll, then withdraw the won stock. Ladder odds are on-chain (multiplierBps/cumPpm).
export const degenAbi = parseAbi([
  "function buy() payable returns (uint64)",
  "function withdraw() returns (uint256)",
  "function reclaim(uint64 seq)",
  "function owed(address) view returns (uint256)",
  "function freeReserve() view returns (uint256)",
  "function reservedShares() view returns (uint256)",
  "function maxMultiplierBps() view returns (uint256)",
  "function referenceUsd() view returns (uint256)",
  "function tierCount() view returns (uint256)",
  "function multiplierBps(uint256) view returns (uint256)",
  "function cumPpm(uint256) view returns (uint256)",
  "function entropyFee() view returns (uint256)",
  "event CaseBought(uint64 indexed seq, address indexed buyer, uint256 worstShares)",
  "event CaseOpened(uint64 indexed seq, address indexed buyer, uint256 multiplierBps, uint256 payoutShares)",
]);
// Testnet MockEntropy keeper — anyone can settle a pending request.
export const mockEntropyAbi = parseAbi(["function fulfill(uint64 seq)"]);
const caseOpenedItem = parseAbiItem("event CaseOpened(uint64 indexed seq, address indexed buyer, uint256 multiplierBps, uint256 payoutShares)");
const fairCaseOpenedItem = parseAbiItem("event CaseOpened(uint256 indexed caseId, address indexed buyer, address indexed token, uint256 amount)");

export const pub = createPublicClient({ transport: http(NET.rpc) });

type Eip1193 = { request: (a: { method: string; params?: unknown[] }) => Promise<unknown> };
const eth = () => (window as { ethereum?: Eip1193 }).ethereum;

function wallet(account: Address) {
  const provider = eth();
  if (!provider) throw new Error("No wallet");
  return createWalletClient({ account, chain: undefined, transport: custom(provider) });
}

/// Send + wait, with the Orbit gas cushion (estimation under-shoots intrinsic gas on this stack).
async function send(account: Address, to: Address, abi: readonly unknown[], functionName: string, args: unknown[] = [], value?: bigint): Promise<Hex> {
  const w = wallet(account);
  const hash = await w.writeContract({
    address: to, abi: abi as never, functionName: functionName as never, args: args as never,
    account, chain: null, gas: 3_000_000n, ...(value !== undefined ? { value } : {}),
  });
  const rcpt = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  if (rcpt.status !== "success") throw new Error("Transaction reverted");
  return hash;
}

/// Approve `spender` for `token` if the current allowance is below `need`. Approves the max so it is a
/// genuine one-time step — repeat plays never re-prompt for the same token/spender.
async function ensureAllowance(account: Address, token: Address, spender: Address, need: bigint) {
  const have = await pub.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [account, spender] });
  if (have >= need) return;
  await send(account, token, erc20Abi, "approve", [spender, maxUint256]);
}

// ---------------------------------------------------------------- reads
export const reads = {
  floatCount: () => pub.readContract({ address: ADDR.exchange, abi: exchangeAbi, functionName: "inventoryCount" }),
  caseUnits: () => pub.readContract({ address: ADDR.cases, abi: casesAbi, functionName: "inventoryCount" }),
  pot: () => pub.readContract({ address: ADDR.bell, abi: bellAbi, functionName: "pot" }),
  balances: async (a: Address) => {
    const [essey, usdg, seats] = await Promise.all([
      pub.readContract({ address: ADDR.essey, abi: erc20Abi, functionName: "balanceOf", args: [a] }),
      pub.readContract({ address: ADDR.usdg, abi: erc20Abi, functionName: "balanceOf", args: [a] }),
      pub.readContract({ address: ADDR.seat, abi: seatAbi, functionName: "balanceOf", args: [a] }),
    ]);
    return { essey, usdg, seats };
  },
  floatIds: async (): Promise<bigint[]> => {
    const n = await reads.floatCount();
    const count = Number(n > 12n ? 12n : n);
    return Promise.all(Array.from({ length: count }, (_, i) =>
      pub.readContract({ address: ADDR.exchange, abi: exchangeAbi, functionName: "inventoryAt", args: [BigInt(i)] })));
  },

  /// Seats the address currently owns — computed from Transfer events (Seat isn't Enumerable), which
  /// is exact and honest: in minus out. Bounded to the collection's lifetime so the scan stays cheap.
  ownedSeats: async (a: Address): Promise<bigint[]> => {
    const [inLogs, outLogs] = await Promise.all([
      pub.getLogs({ address: ADDR.seat, event: seatAbi[5], args: { to: a }, fromBlock: DEPLOY_BLOCK, toBlock: "latest" }),
      pub.getLogs({ address: ADDR.seat, event: seatAbi[5], args: { from: a }, fromBlock: DEPLOY_BLOCK, toBlock: "latest" }),
    ]);
    const owned = new Set<string>();
    // Order across the two lists by block then logIndex so the latest movement of each id wins.
    const evts = [...inLogs.map((l) => ({ l, dir: "in" as const })), ...outLogs.map((l) => ({ l, dir: "out" as const }))]
      .sort((x, y) => x.l.blockNumber === y.l.blockNumber ? Number(x.l.logIndex - y.l.logIndex) : Number(x.l.blockNumber - y.l.blockNumber));
    for (const { l, dir } of evts) {
      const id = (l.args as { tokenId?: bigint }).tokenId?.toString();
      if (id === undefined) continue;
      if (dir === "in") owned.add(id); else owned.delete(id);
    }
    return [...owned].map(BigInt).sort((x, y) => (x < y ? -1 : 1));
  },

  seatState: async (id: bigint): Promise<{ tier: number; pending: bigint; vault: Address }> => {
    const [state, pending, vault] = await Promise.all([
      pub.readContract({ address: ADDR.bell, abi: bellAbi, functionName: "seats", args: [id] }),
      pub.readContract({ address: ADDR.bell, abi: bellAbi, functionName: "pendingOf", args: [id] }),
      pub.readContract({ address: ADDR.seat, abi: seatAbi, functionName: "vaultOf", args: [id] }),
    ]);
    return { tier: Number((state as readonly unknown[])[0]), pending: pending as bigint, vault: vault as Address };
  },

  tierFee: (tierIndex: number) => // cumulative $ESSEY to reach tier (tierIndex is 0-based)
    pub.readContract({ address: ADDR.bell, abi: bellAbi, functionName: "tierFees", args: [BigInt(tierIndex)] }),

  vaultBalance: (vault: Address) =>
    pub.readContract({ address: ADDR.usdg, abi: erc20Abi, functionName: "balanceOf", args: [vault] }),

  /// Stock held in a Seat's Vault — what a stock Payout lands as (and what you'd borrow against).
  vaultStocks: async (vault: Address): Promise<{ aapl: bigint; nvda: bigint }> => {
    const [aapl, nvda] = await Promise.all([
      pub.readContract({ address: ADDR.aapl, abi: erc20Abi, functionName: "balanceOf", args: [vault] }),
      pub.readContract({ address: ADDR.nvda, abi: erc20Abi, functionName: "balanceOf", args: [vault] }),
    ]);
    return { aapl, nvda };
  },

  /// A Seat's payout preference: 0x0 = the default bundle, else the chosen stock. Only meaningful once
  /// a converter is wired (address(0) converter ⇒ everything pays base USDG regardless).
  payoutPref: (id: bigint) =>
    pub.readContract({ address: ADDR.bell, abi: bellAbi, functionName: "payoutTokenOf", args: [id] }) as Promise<Address>,

  gasBalance: (a: Address) => pub.getBalance({ address: a }),

  stockWins: async (a: Address): Promise<{ aapl: bigint; nvda: bigint }> => {
    const [aapl, nvda] = await Promise.all([
      pub.readContract({ address: ADDR.aapl, abi: erc20Abi, functionName: "balanceOf", args: [a] }),
      pub.readContract({ address: ADDR.nvda, abi: erc20Abi, functionName: "balanceOf", args: [a] }),
    ]);
    return { aapl, nvda };
  },

  /// Pool state: TVL, this address's supplied value, the live rates. Supply APY is derived — borrow
  /// APR × utilization × (1 − reserve cut) — the standard ERC-4626 lending identity.
  poolState: async (a: Address | null) => {
    const [tvl, borrowBps, utilBps, reserveBps, shares] = await Promise.all([
      pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "totalAssets" }),
      pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "borrowRateBps" }),
      pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "utilizationBps" }),
      pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "reserveBps" }),
      a ? pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "balanceOf", args: [a] }) : Promise.resolve(0n),
    ]);
    const mine = shares > 0n ? await pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "convertToAssets", args: [shares] }) : 0n;
    const borrowApr = Number(borrowBps) / 100;
    const supplyApy = (borrowApr * (Number(utilBps) / 10_000) * (1 - Number(reserveBps) / 10_000));
    return { tvl, mine, shares, borrowApr, supplyApy, utilPct: Number(utilBps) / 100 };
  },

  canBorrow: (token: Address) => pub.readContract({ address: ADDR.markets, abi: marketsAbi, functionName: "canBorrow", args: [token] }),
  maxBorrow: (token: Address, collateralRaw: bigint) =>
    pub.readContract({ address: ADDR.markets, abi: marketsAbi, functionName: "maxBorrow", args: [token, collateralRaw] }),

  /// Open loan positions held by `a`, found by scanning the Note collection's Transfer events (same
  /// approach as Seats) and keeping the ones still owned with live debt.
  myLoans: async (a: Address): Promise<{ id: bigint; token: Address; collateralRaw: bigint; debt: bigint }[]> => {
    const note = await pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "note" }) as Address;
    const logs = await pub.getLogs({ address: note, event: seatAbi[5], args: { to: a }, fromBlock: DEPLOY_BLOCK, toBlock: "latest" });
    const ids = [...new Set(logs.map((l) => (l.args as { tokenId?: bigint }).tokenId).filter((x): x is bigint => x !== undefined))];
    const out: { id: bigint; token: Address; collateralRaw: bigint; debt: bigint }[] = [];
    for (const id of ids) {
      const owner = await pub.readContract({ address: note, abi: noteAbi, functionName: "ownerOf", args: [id] }).catch(() => null);
      if (owner?.toLowerCase() !== a.toLowerCase()) continue; // closed (burned) or transferred away
      const [pos, debt] = await Promise.all([
        pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "positions", args: [id] }) as Promise<readonly [Address, bigint, bigint, bigint]>,
        pub.readContract({ address: ADDR.pool, abi: poolAbi, functionName: "debtOf", args: [id] }) as Promise<bigint>,
      ]);
      out.push({ id, token: pos[0], collateralRaw: pos[1], debt });
    }
    return out;
  },

  /// The referral leaderboard, scored on-chain. Reads the quest's Registered events (bounded window,
  /// like the Tape), then ONE qualifiedMany call scores every referred wallet — so this scales to
  /// hundreds of testers in a couple of RPC round-trips, not hundreds of reads.
  leaderboard: async (): Promise<{ board: { addr: Address; qualified: number; total: number }[]; totalQuesters: number }> => {
    const head = await pub.getBlockNumber();
    const from = head > 400_000n ? head - 400_000n : 0n;
    const logs = await pub.getLogs({ address: ADDR.quest, event: questAbi[4], fromBlock: from, toBlock: head }).catch(() => []);
    const referredBy = new Map<string, string[]>(); // referrer -> [referred]
    const questers = new Set<string>();
    for (const l of logs) {
      const p = (l.args as { participant?: string }).participant;
      const r = (l.args as { referrer?: string }).referrer;
      if (p) questers.add(p.toLowerCase());
      if (p && r && r !== "0x0000000000000000000000000000000000000000") {
        const key = r.toLowerCase();
        (referredBy.get(key) ?? referredBy.set(key, []).get(key)!).push(p);
      }
    }
    const referrers = [...referredBy.keys()];
    if (referrers.length === 0) return { board: [], totalQuesters: questers.size };
    // Batch-qualify every referred wallet in one call.
    const allReferred = [...new Set([...referredBy.values()].flat())] as Address[];
    const flags = await pub.readContract({ address: ADDR.lens, abi: lensAbi, functionName: "qualifiedMany", args: [allReferred] }) as boolean[];
    const isQual = new Map(allReferred.map((w, i) => [w.toLowerCase(), flags[i]]));
    const board = referrers.map((r) => {
      const refs = referredBy.get(r)!;
      return { addr: r as Address, total: refs.length, qualified: refs.filter((w) => isQual.get(w.toLowerCase())).length };
    }).filter((row) => row.qualified > 0 || row.total > 0)
      .sort((x, y) => y.qualified - x.qualified || y.total - x.total);
    return { board, totalQuesters: questers.size };
  },

  /// Degen case: the disclosed ladder + the caller's account (owed winnings, reserve, entropy fee).
  degen: async (a: Address | null) => {
    const n = Number(await pub.readContract({ address: ADDR.degenCases, abi: degenAbi, functionName: "tierCount" }));
    const [mults, cums] = await Promise.all([
      Promise.all(Array.from({ length: n }, (_, i) => pub.readContract({ address: ADDR.degenCases, abi: degenAbi, functionName: "multiplierBps", args: [BigInt(i)] }) as Promise<bigint>)),
      Promise.all(Array.from({ length: n }, (_, i) => pub.readContract({ address: ADDR.degenCases, abi: degenAbi, functionName: "cumPpm", args: [BigInt(i)] }) as Promise<bigint>)),
    ]);
    const [maxMult, free, reserved, fee, owed] = await Promise.all([
      pub.readContract({ address: ADDR.degenCases, abi: degenAbi, functionName: "maxMultiplierBps" }) as Promise<bigint>,
      pub.readContract({ address: ADDR.degenCases, abi: degenAbi, functionName: "freeReserve" }) as Promise<bigint>,
      pub.readContract({ address: ADDR.degenCases, abi: degenAbi, functionName: "reservedShares" }) as Promise<bigint>,
      pub.readContract({ address: ADDR.degenCases, abi: degenAbi, functionName: "entropyFee" }) as Promise<bigint>,
      a ? pub.readContract({ address: ADDR.degenCases, abi: degenAbi, functionName: "owed", args: [a] }) as Promise<bigint> : Promise.resolve(0n),
    ]);
    const ladder = mults.map((m, i) => ({ multBps: Number(m), pct: (Number(cums[i]) - (i > 0 ? Number(cums[i - 1]) : 0)) / 10_000 }));
    return { ladder, maxMultBps: Number(maxMult), free, reserved, fee, owed };
  },

  quest: async (a: Address | null) => {
    const total = await pub.readContract({ address: ADDR.quest, abi: questAbi, functionName: "totalRegistered" }) as bigint;
    if (!a) return { registered: false, referrals: 0n, total };
    const [registered, referrals] = await Promise.all([
      pub.readContract({ address: ADDR.quest, abi: questAbi, functionName: "registered", args: [a] }) as Promise<boolean>,
      pub.readContract({ address: ADDR.quest, abi: questAbi, functionName: "referralCount", args: [a] }) as Promise<bigint>,
    ]);
    return { registered, referrals, total };
  },

  /// Everything the Portfolio and the guided journey need, in one pass: balances, each owned Seat
  /// with its tier + claimable + Vault balance, Case winnings, pool position, and quest status.
  portfolio: async (a: Address) => {
    const [gas, bal, ids, wins, pool, loans, quest] = await Promise.all([
      reads.gasBalance(a), reads.balances(a), reads.ownedSeats(a), reads.stockWins(a), reads.poolState(a), reads.myLoans(a), reads.quest(a),
    ]);
    const seats = await Promise.all(ids.map(async (id) => {
      const st = await reads.seatState(id);
      const [vaultUsdg, vaultStock] = await Promise.all([reads.vaultBalance(st.vault), reads.vaultStocks(st.vault)]);
      return { id, ...st, vaultUsdg, vaultAapl: vaultStock.aapl, vaultNvda: vaultStock.nvda };
    }));
    return { gas, ...bal, seats, wins, pool, loans, quest };
  },
};

export type Portfolio = Awaited<ReturnType<typeof reads.portfolio>>;

// The four launch tiers EXACTLY as deployed by DeployMarket._ladder (cumulative $ESSEY fee, payout
// weight). tier N = arrays[N-1]. Verified against chain via reads.tierFee at render time.
export const TIERS = [
  { tier: 1, name: "Tier I", fee: 1_000n * 10n ** 18n, weight: 100 },
  { tier: 2, name: "Tier II", fee: 1_600n * 10n ** 18n, weight: 160 },
  { tier: 3, name: "Tier III", fee: 2_000n * 10n ** 18n, weight: 200 },
  { tier: 4, name: "Tier IV", fee: 3_330n * 10n ** 18n, weight: 333 },
];

// ---------------------------------------------------------------- flows
export const flows = {
  drip: (a: Address) => send(a, ADDR.faucet, faucetAbi, "drip"),

  buySeat: async (a: Address): Promise<{ id: bigint; tx: Hex }> => {
    await ensureAllowance(a, ADDR.essey, ADDR.exchange, PRICE.seat);
    await ensureAllowance(a, ADDR.usdg, ADDR.exchange, PRICE.swapFee);
    const tx = await send(a, ADDR.exchange, exchangeAbi, "buy");
    const rcptLogs = await pub.getTransactionReceipt({ hash: tx });
    // The Bought id is topic[1] of the exchange's own log in this receipt.
    const log = rcptLogs.logs.find((l) => l.address.toLowerCase() === ADDR.exchange.toLowerCase());
    const id = log ? BigInt(log.topics[1] ?? "0x0") : 0n;
    return { id, tx };
  },

  snipeSeat: async (a: Address, id: bigint): Promise<Hex> => {
    await ensureAllowance(a, ADDR.essey, ADDR.exchange, PRICE.seat);
    await ensureAllowance(a, ADDR.usdg, ADDR.exchange, PRICE.snipeFee);
    return send(a, ADDR.exchange, exchangeAbi, "snipe", [id]);
  },

  sellSeat: async (a: Address, id: bigint): Promise<Hex> => {
    await ensureAllowance(a, ADDR.usdg, ADDR.exchange, PRICE.sellFee);
    await send(a, ADDR.seat, seatAbi, "approve", [ADDR.exchange, id]);
    return send(a, ADDR.exchange, exchangeAbi, "sell", [id]);
  },

  /// Stake $ESSEY to activate a Seat at `tier` (or upgrade if already active). Half the fee burns,
  /// half goes to treasury; the Seat starts earning payout weight from the next ring.
  setTier: async (a: Address, id: bigint, tier: number): Promise<Hex> => {
    const cur = Number((await pub.readContract({ address: ADDR.bell, abi: bellAbi, functionName: "seats", args: [id] }) as readonly unknown[])[0]);
    const fee = await reads.tierFee(tier - 1); // cumulative; activate/upgrade pull the right delta
    await ensureAllowance(a, ADDR.essey, ADDR.bell, fee);
    return cur === 0
      ? send(a, ADDR.bell, bellAbi, "activate", [id, tier])
      : send(a, ADDR.bell, bellAbi, "upgrade", [id, tier]);
  },

  ringBell: (a: Address): Promise<Hex> => send(a, ADDR.bell, bellAbi, "ring"),

  /// Join the quest, crediting a referrer (0x0 if none). One-shot per wallet.
  registerQuest: (a: Address, referrer: Address): Promise<Hex> => send(a, ADDR.quest, questAbi, "register", [referrer]),

  /// Sell a won stock unit back to the Cases contract for USDG (oracle value minus the spread).
  /// Approves the exact unit size, then sells. Session-gated on chain (US market hours + fresh feed).
  sellCaseStock: async (a: Address, token: Address): Promise<Hex> => {
    const [unit] = await pub.readContract({ address: ADDR.cases, abi: casesSellAbi, functionName: "stocks", args: [token] }) as readonly [bigint, number, boolean];
    await ensureAllowance(a, token, ADDR.cases, unit);
    return send(a, ADDR.cases, casesSellAbi, "sellBack", [token]);
  },

  /// Claim a Seat's accrued Payout — it lands in that Seat's Vault (permissionless, but the funds go
  /// to the Vault the Seat owner controls, never the caller).
  claimPayout: (a: Address, id: bigint): Promise<Hex> => send(a, ADDR.bell, bellAbi, "claim", [id]),

  /// Set how a Seat's Payouts are delivered: BUNDLE (the default basket), a single stock, or 0x0 to
  /// reset to the default. Owner-only on-chain; clears on Seat transfer.
  setPayoutToken: (a: Address, id: bigint, token: Address): Promise<Hex> =>
    send(a, ADDR.bell, bellAbi, "setPayoutToken", [id, token]),

  // ---- lending ----
  supply: async (a: Address, amount: bigint): Promise<Hex> => {
    await ensureAllowance(a, ADDR.usdg, ADDR.pool, amount);
    return send(a, ADDR.pool, poolAbi, "deposit", [amount, a]);
  },
  withdrawSupply: (a: Address, amount: bigint): Promise<Hex> => send(a, ADDR.pool, poolAbi, "withdraw", [amount, a, a]),

  /// Borrow USDG against stock collateral: approve the stock, then borrow — mints a Note, sends USDG.
  borrow: async (a: Address, token: Address, collateralRaw: bigint, debt: bigint): Promise<Hex> => {
    await ensureAllowance(a, token, ADDR.pool, collateralRaw);
    return send(a, ADDR.pool, poolAbi, "borrow", [token, collateralRaw, debt]);
  },
  repay: async (a: Address, id: bigint, owed: bigint): Promise<Hex> => {
    await ensureAllowance(a, ADDR.usdg, ADDR.pool, owed + owed / 100n); // headroom for a second of interest
    return send(a, ADDR.pool, poolAbi, "repay", [id, (owed * 1001n) / 1000n]); // repay accepts >= owed, refunds change
  },

  /// The degen (multiplier) case: buy (pays the entropy fee), settle the roll via the keeper, decode
  /// the multiplier + payout. On testnet the frontend triggers the MockEntropy keeper; on mainnet the
  /// real Dice keeper settles automatically (this would just poll instead of calling fulfill).
  degenOpen: async (a: Address, onStage?: (s: string) => void): Promise<{ multBps: number; payoutShares: bigint; seq: bigint }> => {
    const fee = await pub.readContract({ address: ADDR.degenCases, abi: degenAbi, functionName: "entropyFee" }) as bigint;
    onStage?.("approving");
    await ensureAllowance(a, ADDR.essey, ADDR.degenCases, PRICE.casePrice); // case price, sunk to treasury (one-time)
    await ensureAllowance(a, ADDR.usdg, ADDR.degenCases, PRICE.caseFee); // buy fee, feeds the Bell pot (one-time)
    onStage?.("buying");
    // The ONLY per-roll signature: buy requests the roll. Settlement is permissionless — a keeper (or,
    // on mainnet, the real Dice oracle) calls fulfill and the roll credits the stored buyer, not the caller.
    const buyTx = await send(a, ADDR.degenCases, degenAbi, "buy", [], fee);
    const buyRcpt = await pub.getTransactionReceipt({ hash: buyTx });
    const bought = buyRcpt.logs.find((l) => l.address.toLowerCase() === ADDR.degenCases.toLowerCase());
    const seq = bought ? BigInt(bought.topics[1] ?? "0x0") : 0n; // CaseBought: topic[1] = seq

    // Read the settlement event once it lands (whoever settles it — keeper or the fallback below).
    const readOpened = async (): Promise<{ multBps: number; payoutShares: bigint; seq: bigint } | null> => {
      const logs = await pub.getLogs({ address: ADDR.degenCases, event: caseOpenedItem, args: { seq }, fromBlock: buyRcpt.blockNumber });
      if (!logs.length) return null;
      const { multiplierBps, payoutShares } = logs[0].args as { multiplierBps: bigint; payoutShares: bigint };
      return { multBps: Number(multiplierBps), payoutShares, seq };
    };

    // Wait for the keeper to settle (the reel keeps spinning meanwhile). ~24s budget.
    onStage?.("sealing");
    for (let i = 0; i < 12; i++) {
      await new Promise((r) => setTimeout(r, 2_000));
      const r = await readOpened();
      if (r) return r;
    }
    // No keeper answered — settle it ourselves so the roll always finishes (a rare extra signature).
    onStage?.("revealing");
    await send(a, ADDR.degenEntropy, mockEntropyAbi, "fulfill", [seq]);
    const r = await readOpened();
    if (r) return r;
    throw new Error("settled but no CaseOpened event found");
  },
  degenWithdraw: (a: Address): Promise<Hex> => send(a, ADDR.degenCases, degenAbi, "withdraw"),

  /// The whole gacha: buy, wait out the draw commitment (parent-chain blocks tick ~12s wall-clock
  /// on this stack), open, decode the winner. onStage lets the arcade narrate honestly.
  openCase: async (a: Address, onStage: (s: string) => void): Promise<{ token: Address; amount: bigint; tx: Hex }> => {
    onStage("approving");
    await ensureAllowance(a, ADDR.essey, ADDR.cases, PRICE.casePrice); // one-time
    await ensureAllowance(a, ADDR.usdg, ADDR.cases, PRICE.caseFee); // one-time
    onStage("buying");
    // The buy is the only signature the buyer needs. The keeper reveals (open delivers to the buyer);
    // a self-open fallback keeps it working — well within the 256-block window — if no keeper answers.
    const buyTx = await send(a, ADDR.cases, casesAbi, "buy");
    const buyRcpt = await pub.getTransactionReceipt({ hash: buyTx });
    const bought = buyRcpt.logs.find((l) => l.address.toLowerCase() === ADDR.cases.toLowerCase());
    const caseId = bought ? BigInt(bought.topics[1] ?? "0x0") : 0n;

    const readOpened = async (): Promise<{ token: Address; amount: bigint; tx: Hex } | null> => {
      const logs = await pub.getLogs({ address: ADDR.cases, event: fairCaseOpenedItem, args: { caseId }, fromBlock: buyRcpt.blockNumber });
      if (!logs.length) return null;
      const { token, amount } = logs[0].args as { token: Address; amount: bigint };
      return { token, amount, tx: logs[0].transactionHash as Hex };
    };

    // Wait for the keeper to reveal (this also waits out the one-block draw commit). ~24s budget.
    onStage("sealing");
    for (let i = 0; i < 12; i++) {
      await new Promise((r) => setTimeout(r, 2_000));
      const r = await readOpened();
      if (r) return r;
    }
    // No keeper answered — open it ourselves (a rare extra signature). If it reverts AlreadyOpened, the
    // keeper beat us to it, so re-read rather than surfacing an error.
    onStage("opening");
    try {
      await send(a, ADDR.cases, casesAbi, "open", [caseId]);
    } catch (e) {
      const r = await readOpened();
      if (r) return r;
      throw e;
    }
    const r = await readOpened();
    if (r) return r;
    throw new Error("open succeeded but no CaseOpened event found");
  },
};

/// Turn a raw wallet/RPC error into something a first-timer can act on. Falls back to a trimmed
/// message rather than a bare revert selector.
export function niceError(e: unknown): string {
  const m = String((e as { shortMessage?: string; message?: string })?.shortMessage ?? (e as Error)?.message ?? e);
  const s = m.toLowerCase();
  if (s.includes("user rejected") || s.includes("user denied") || s.includes("rejected the request")) return "You cancelled the transaction.";
  if (s.includes("insufficient funds") || s.includes("intrinsic gas")) return "Not enough gas ETH — grab some from the chain faucet on the Start page.";
  if (s.includes("toosoon") || s.includes("cooldown")) return "Faucet cooldown — 8h between drips.";
  if (s.includes("chain") && s.includes("match")) return "Wrong network — switch to Robinhood Chain testnet.";
  if (s.includes("insufficientallowance") || s.includes("allowance")) return "Approval needed first — try again and confirm both wallet popups.";
  if (s.includes("marketclosed") || s.includes("notinsession")) return "Only open during US market hours — try again while the stock market is open (weekdays, ~9:30am–4pm ET).";
  if (s.includes("soldout") || s.includes("emptyinventory")) return "Sold out — no inventory left right now.";
  if (s.includes("notseatowner") || s.includes("notborrower")) return "That isn't yours to act on.";
  if (s.includes("alreadyactive")) return "That Seat is already staked — use upgrade instead.";
  if (s.includes("potbelowminimum") || s.includes("noactiveseats")) return "The pot isn't ringable yet — trade a bit to grow it, or wait for an active Seat.";
  // Otherwise: strip the noisy viem wrapper, keep the first human line.
  return m.split("\n")[0].replace(/^(Error|ContractFunctionExecutionError):?\s*/i, "").slice(0, 150);
}

export const fmt = (n: bigint, dp = 0) => {
  const whole = n / 10n ** 18n;
  if (dp === 0) return whole.toLocaleString();
  const frac = ((n % 10n ** 18n) * 10n ** BigInt(dp)) / 10n ** 18n;
  return `${whole.toLocaleString()}.${frac.toString().padStart(dp, "0")}`;
};
