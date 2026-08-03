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
};

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
export const bellAbi = parseAbi(["function pot() view returns (uint256)"]);
export const seatAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function ownerOf(uint256) view returns (address)",
  "function approve(address,uint256)",
  "function tokenURI(uint256) view returns (string)",
]);
export const faucetAbi = parseAbi([
  "function drip()",
  "function lastDrip(address) view returns (uint256)",
]);

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
};

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
