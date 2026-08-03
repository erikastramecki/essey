// Live-chain layer: the deployed TESTNET contracts and the transaction flows the app pages run.
// Everything here is testnet (46630) until mainnet ships; the addresses come from
// docs/DEPLOYMENT-testnet.md and the UI wears a TESTNET banner the whole time.
import { createPublicClient, createWalletClient, custom, http, parseAbi, type Address, type Hex } from "viem";

export const NET = {
  chainIdHex: "0xb626", // 46630
  chainId: 46630,
  name: "Robinhood Chain Testnet",
  rpc: "https://rpc.testnet.chain.robinhood.com",
  explorer: "https://explorer.testnet.chain.robinhood.com",
  faucet: "https://faucet.testnet.chain.robinhood.com",
};

export const ADDR = {
  seat: "0x0Fd7889F09B1846388240B08Acc60723b17022d6" as Address,
  essey: "0xC253674DA4347BFa2E6A14d6a6F78166803D14B5" as Address,
  usdg: "0x7461E670d44FF4397A3E48030C5b06f6163a5De2" as Address,
  bell: "0x9E760482877C6139C32Da745aa2a8116d86a14D0" as Address,
  exchange: "0x6C4b1EcC2903f12796c3909547Def413353ac43f" as Address,
  cases: "0xf8B6D4a83c5afe6c1339390947cb8dbf9AF2D8bd" as Address,
  faucet: "0xFF9866C43BbaeDD143AF7224c49ba7681beD0eAA" as Address,
  aapl: "0xaC6cd493e69eb82e8f113E33De8e5542F313B731" as Address,
  nvda: "0x8393cc99FAC1CF79E3bEceA56f344159ddFd91E9" as Address,
  // Lending stack
  pool: "0x283a4891458180f502E82E40470d3e06321ba748" as Address,
  markets: "0x6dAE0540bcC78756BB7b2e936ACBFA9cA5439732" as Address,
};

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

export const pub = createPublicClient({ transport: http(NET.rpc) });

type Eip1193 = { request: (a: { method: string; params?: unknown[] }) => Promise<unknown> };
const eth = () => (window as { ethereum?: Eip1193 }).ethereum;

function wallet(account: Address) {
  const provider = eth();
  if (!provider) throw new Error("No wallet");
  return createWalletClient({ account, chain: undefined, transport: custom(provider) });
}

/// Send + wait, with the Orbit gas cushion (estimation under-shoots intrinsic gas on this stack).
async function send(account: Address, to: Address, abi: readonly unknown[], functionName: string, args: unknown[] = []): Promise<Hex> {
  const w = wallet(account);
  const hash = await w.writeContract({
    address: to, abi: abi as never, functionName: functionName as never, args: args as never,
    account, chain: null, gas: 3_000_000n,
  });
  const rcpt = await pub.waitForTransactionReceipt({ hash, timeout: 120_000 });
  if (rcpt.status !== "success") throw new Error("Transaction reverted");
  return hash;
}

/// Approve `spender` for `token` if the current allowance is below `need`.
async function ensureAllowance(account: Address, token: Address, spender: Address, need: bigint) {
  const have = await pub.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [account, spender] });
  if (have >= need) return;
  await send(account, token, erc20Abi, "approve", [spender, need * 100n]); // headroom: fewer approvals
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

  /// Everything the Portfolio and the guided journey need, in one pass: balances, each owned Seat
  /// with its tier + claimable + Vault balance, Case winnings, and pool position.
  portfolio: async (a: Address) => {
    const [gas, bal, ids, wins, pool, loans] = await Promise.all([
      reads.gasBalance(a), reads.balances(a), reads.ownedSeats(a), reads.stockWins(a), reads.poolState(a), reads.myLoans(a),
    ]);
    const seats = await Promise.all(ids.map(async (id) => ({ id, ...(await reads.seatState(id)), vaultUsdg: 0n as bigint })));
    for (const s of seats) s.vaultUsdg = await reads.vaultBalance(s.vault);
    return { gas, ...bal, seats, wins, pool, loans };
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

  /// Claim a Seat's accrued Payout — it lands in that Seat's Vault (permissionless, but the funds go
  /// to the Vault the Seat owner controls, never the caller).
  claimPayout: (a: Address, id: bigint): Promise<Hex> => send(a, ADDR.bell, bellAbi, "claim", [id]),

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

  /// The whole gacha: buy, wait out the draw commitment (parent-chain blocks tick ~12s wall-clock
  /// on this stack), open, decode the winner. onStage lets the arcade narrate honestly.
  openCase: async (a: Address, onStage: (s: string) => void): Promise<{ token: Address; amount: bigint; tx: Hex }> => {
    onStage("approving");
    await ensureAllowance(a, ADDR.essey, ADDR.cases, PRICE.casePrice);
    await ensureAllowance(a, ADDR.usdg, ADDR.cases, PRICE.caseFee);
    onStage("buying");
    const buyTx = await send(a, ADDR.cases, casesAbi, "buy");
    const buyRcpt = await pub.getTransactionReceipt({ hash: buyTx });
    const bought = buyRcpt.logs.find((l) => l.address.toLowerCase() === ADDR.cases.toLowerCase());
    const caseId = bought ? BigInt(bought.topics[1] ?? "0x0") : 0n;
    onStage("sealing"); // the draw block must pass on the parent chain — the suspense is real
    // Poll by simulating open until it stops reverting (~15-40s), then send for real.
    for (let i = 0; i < 30; i++) {
      await new Promise((r) => setTimeout(r, 5_000));
      try {
        await pub.simulateContract({ address: ADDR.cases, abi: casesAbi, functionName: "open", args: [caseId], account: a });
        break;
      } catch { /* draw not ready yet */ }
    }
    onStage("opening");
    const openTx = await send(a, ADDR.cases, casesAbi, "open", [caseId]);
    const rcpt = await pub.getTransactionReceipt({ hash: openTx });
    // CaseOpened: topics = [sig, caseId, buyer, token]; amount in data.
    const opened = rcpt.logs.find((l) => l.address.toLowerCase() === ADDR.cases.toLowerCase() && l.topics.length === 4);
    if (!opened) throw new Error("open succeeded but no CaseOpened event found");
    const token = ("0x" + (opened.topics[3] as string).slice(26)) as Address;
    const amount = BigInt(opened.data);
    return { token, amount, tx: openTx };
  },
};

export const fmt = (n: bigint, dp = 0) => {
  const whole = n / 10n ** 18n;
  if (dp === 0) return whole.toLocaleString();
  const frac = ((n % 10n ** 18n) * 10n ** BigInt(dp)) / 10n ** 18n;
  return `${whole.toLocaleString()}.${frac.toString().padStart(dp, "0")}`;
};
