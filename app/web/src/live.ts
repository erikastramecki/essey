// Live-chain layer: the deployed TESTNET contracts and the transaction flows the app pages run.
// Everything here is testnet (46630) until mainnet ships; the addresses come from
// docs/DEPLOYMENT-testnet.md and the UI wears a TESTNET banner the whole time.
import { createPublicClient, createWalletClient, custom, defineChain, http, parseAbi, parseAbiItem, maxUint256, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { deriveStealthKeys, generateStealthAddress, checkAnnouncement, computeStealthPrivKey, STEALTH_DERIVE_MESSAGE, type StealthKeys } from "./stealth";
export type { StealthKeys } from "./stealth";
import { numberToHex } from "viem";
import { initPool, deriveKeypair, buildDepositProof, buildWithdrawProof, type ProofCalldata, type PoolExtData, type PoolNote } from "./poolsdk";
export type { PoolNote } from "./poolsdk";

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
  degenCases: "0xA0B438Da1b489748D863C9529D19A29C36309599" as Address, // 24/7, share-denominated (no session gate)
  degenEntropy: "0xb9b82A4900642A98e29F59B937FDE6B2DDaF1E6F" as Address,
  // Essey Private — Phase 0 (stealth-address payments, ERC-5564/6538). Zero custody.
  stealthAnnouncer: "0xe386345BB307166F59A191130230bA445F05F402" as Address,
  stealthRegistry: "0x7f28EbFfC1310849f4Cb5612e1Ff892fd892880f" as Address,
  stealthPay: "0x36B750Ac415DC1f05E39C6D13A05FDbC29567403" as Address,
  // Essey Private — Phase 1 (shielded USDG pool, hides amounts). Depth-20, gate openMode on testnet.
  shieldedPool: "0xcD7953960bbc1276F0856Dad5E502fc01cE629aB" as Address,
  shieldedPoolGate: "0xcBdA12dF938d665fF5752b9C49740A7D47ff5562" as Address,
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
  "function transfer(address,uint256) returns (bool)",
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
  "function cases(uint256) view returns (address buyer, uint64 drawBlock, uint64 boughtAt, bool opened)",
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
  "function referenceShares() view returns (uint256)",
  "function tierCount() view returns (uint256)",
  "function multiplierBps(uint256) view returns (uint256)",
  "function cumPpm(uint256) view returns (uint256)",
  "function entropyFee() view returns (uint256)",
  "event CaseBought(uint64 indexed seq, address indexed buyer, uint256 worstShares)",
  "event CaseOpened(uint64 indexed seq, address indexed buyer, uint256 multiplierBps, uint256 payoutShares)",
]);
// Testnet MockEntropy keeper — anyone can settle a pending request.
export const mockEntropyAbi = parseAbi(["function fulfill(uint64 seq)", "function fulfilled(uint64) view returns (bool)"]);
const caseOpenedItem = parseAbiItem("event CaseOpened(uint64 indexed seq, address indexed buyer, uint256 multiplierBps, uint256 payoutShares)");
const fairCaseOpenedItem = parseAbiItem("event CaseOpened(uint256 indexed caseId, address indexed buyer, address indexed token, uint256 amount)");

// Essey Private — Phase 0 ABIs (ERC-6538 registry + ERC-5564 announcer + private-pay).
export const stealthRegistryAbi = parseAbi([
  "function registerKeys(uint256 schemeId, bytes stealthMetaAddress)",
  "function stealthMetaAddressOf(address,uint256) view returns (bytes)",
]);
export const stealthPayAbi = parseAbi([
  "function pay(address token, address stealthAddress, uint256 amount, bytes ephemeralPubKey, bytes metadata)",
]);
const announcementItem = parseAbiItem(
  "event Announcement(uint256 indexed schemeId, address indexed stealthAddress, address indexed caller, bytes ephemeralPubKey, bytes metadata)",
);
const SECP256K1 = 1n; // ERC-5564 schemeId
// The announcer's deploy block — scan floor. Robinhood Chain block numbers are ~97M, so scanning from 0
// would blow past every RPC getLogs range cap and strand the inbox; start from where the announcer exists.
const STEALTH_DEPLOY_BLOCK = 97_690_338n;

// Essey Private — Phase 1 shielded pool ABI (hides amounts). Nested tuples: the Groth16 proof + the extData.
export const shieldedPoolAbi = parseAbi([
  "function transact((uint256[2] a, uint256[2][2] b, uint256[2] c, bytes32 root, bytes32[2] inputNullifiers, bytes32[2] outputCommitments, uint256 publicAmount, bytes32 extDataHash) args, (address recipient, int256 extAmount, address relayer, uint256 fee, bytes encryptedOutput1, bytes encryptedOutput2) extData)",
  "function isSpent(bytes32) view returns (bool)",
  "event NewCommitment(bytes32 commitment, uint256 index, bytes encryptedOutput)",
  "event NewNullifier(bytes32 nullifier)",
]);
const newCommitmentItem = parseAbiItem("event NewCommitment(bytes32 commitment, uint256 index, bytes encryptedOutput)");
const POOL_DEPLOY_BLOCK = 97_728_346n;
// The known ERC-20s a received stealth address could hold — we read balances directly rather than trust
// event amounts, so the inbox shows what is actually spendable right now.
const KNOWN_TOKENS: { key: string; addr: Address }[] = [
  { key: "USDG", addr: ADDR.usdg }, { key: "AAPL", addr: ADDR.aapl }, { key: "NVDA", addr: ADDR.nvda },
];

export const pub = createPublicClient({ transport: http(NET.rpc) });

// Minimal viem chain for signing sweep txs with a locally-held stealth key (the injected provider only
// knows the user's main account, so the stealth account uses an http transport instead).
const RH_VIEM_CHAIN = defineChain({
  id: NET.chainId, name: NET.name,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [NET.rpc] } },
});

type Eip1193 = { request: (a: { method: string; params?: unknown[] }) => Promise<unknown> };
const eth = () => (window as { ethereum?: Eip1193 }).ethereum;

function wallet(account: Address) {
  const provider = eth();
  if (!provider) throw new Error("No wallet");
  return createWalletClient({ account, chain: undefined, transport: custom(provider) });
}

/// Ask the wallet to sign a message (maps to personal_sign). Deterministic per signer+message on every
/// mainstream EOA wallet, which is what lets us re-derive the same stealth keys on any device.
async function signMsg(account: Address, message: string): Promise<Hex> {
  return wallet(account).signMessage({ account, message });
}

/// Essey Private derives keys from a wallet signature, so recovering already-received funds depends on the
/// wallet reproducing a byte-identical signature. That holds for standard EOAs (MetaMask, Ledger, ...) but
/// NOT for smart-contract wallets (ERC-1271/4337), which have bytecode and may sign differently each time —
/// their already-received funds would become permanently unspendable. Refuse before any can be received.
async function assertDeterministicSigner(a: Address): Promise<void> {
  const code = await pub.getBytecode({ address: a });
  if (code && code !== "0x") {
    throw new Error("Essey Private needs a standard wallet (an EOA like MetaMask or a hardware wallet). Smart-contract wallets can't reliably reproduce the keys, which could make received funds unrecoverable.");
  }
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

    // Reliable "did the keeper settle it" signal: a cheap boolean eth_call (never throws the flow).
    const isSettled = async (): Promise<boolean> => {
      try { return (await pub.readContract({ address: ADDR.degenEntropy, abi: mockEntropyAbi, functionName: "fulfilled", args: [seq] })) as boolean; }
      catch { return false; }
    };
    // The result (multiplier + payout) lives in the CaseOpened event; read it only once settled.
    const readOpened = async (): Promise<{ multBps: number; payoutShares: bigint; seq: bigint } | null> => {
      try {
        const logs = await pub.getLogs({ address: ADDR.degenCases, event: caseOpenedItem, args: { seq }, fromBlock: buyRcpt.blockNumber });
        if (!logs.length) return null;
        const { multiplierBps, payoutShares } = logs[0].args as { multiplierBps: bigint; payoutShares: bigint };
        return { multBps: Number(multiplierBps), payoutShares, seq };
      } catch { return null; }
    };

    // Wait for the keeper to settle (poll the cheap bool; the reel keeps spinning meanwhile). ~30s.
    // Once settled, retry the event read a few times — getLogs can lag a block or two behind state.
    onStage?.("sealing");
    for (let i = 0; i < 15; i++) {
      await new Promise((r) => setTimeout(r, 2_000));
      if (await isSettled()) {
        for (let j = 0; j < 6; j++) { const r = await readOpened(); if (r) return r; await new Promise((res) => setTimeout(res, 1_200)); }
        break;
      }
    }
    // No keeper answered in time — settle it ourselves so the roll always finishes (a rare extra sig).
    onStage?.("revealing");
    try {
      await send(a, ADDR.degenEntropy, mockEntropyAbi, "fulfill", [seq]);
    } catch (e) {
      if (await isSettled()) { const r = await readOpened(); if (r) return r; } // keeper beat us — recover
      throw e;
    }
    const r = await readOpened();
    if (r) return r;
    throw new Error("settled but no CaseOpened event found");
  },
  degenWithdraw: (a: Address): Promise<Hex> => send(a, ADDR.degenCases, degenAbi, "withdraw"),

  // ---- Essey Private (Phase 0): stealth-address payments ----

  /// Register the caller's stealth meta-address so others can pay them privately. Derives the spend/view
  /// keypair from ONE wallet signature and writes the meta-address to the ERC-6538 registry. Returns the
  /// keys so the page can scan/sweep. Gated to EOAs — see assertDeterministicSigner.
  registerStealth: async (a: Address): Promise<StealthKeys> => {
    await assertDeterministicSigner(a);
    const keys = deriveStealthKeys(await signMsg(a, STEALTH_DERIVE_MESSAGE));
    await send(a, ADDR.stealthRegistry, stealthRegistryAbi, "registerKeys", [SECP256K1, keys.metaAddress]);
    return keys;
  },

  /// Re-derive the caller's stealth keys locally (one signature, no on-chain write) — for an already
  /// registered user who just wants to scan their inbox or sweep on a fresh session.
  unlockStealth: async (a: Address): Promise<StealthKeys> => {
    await assertDeterministicSigner(a);
    return deriveStealthKeys(await signMsg(a, STEALTH_DERIVE_MESSAGE));
  },

  /// Pay `amount` of `token` to a fresh one-time stealth address derived from `metaAddress`. One (max,
  /// one-time) approval + the pay tx, which moves funds sender->stealth directly and announces atomically.
  payPrivate: async (a: Address, token: Address, metaAddress: Hex, amount: bigint): Promise<{ tx: Hex; stealthAddress: Address }> => {
    const p = generateStealthAddress(metaAddress);
    await ensureAllowance(a, token, ADDR.stealthPay, amount);
    const tx = await send(a, ADDR.stealthPay, stealthPayAbi, "pay", [token, p.stealthAddress, amount, p.ephemeralPubKey, p.metadata]);
    return { tx, stealthAddress: p.stealthAddress };
  },

  /// Sweep the FULL balance of `token` at an owned stealth address out to `to`. The stealth address holds
  /// no gas, so fund it from the main wallet (1 sig), then sign the ERC-20 transfer locally with the
  /// derived stealth key (no wallet prompt). PRIVACY: funding from the main wallet, and sweeping to `to`,
  /// both write an on-chain edge — pass a FRESH `to` (and accept the gas-funding link) if unlinkability
  /// matters; a relayer/paymaster removes the funding link in a later phase.
  ///
  /// Fees are pinned to LEGACY gasPrice with a realistic gas limit (an ERC-20 transfer is ~50k, not the 3M
  /// blanket the rest of the app uses): a 3M limit under EIP-1559 makes viem reserve 3M×maxFeePerGas for
  /// the balance check and reverts "insufficient funds" on an address funded for the actual ~50k cost.
  sweepStealth: async (a: Address, spendPriv: bigint, sScalar: bigint, token: Address, to: Address): Promise<Hex> => {
    const acct = privateKeyToAccount(computeStealthPrivKey(spendPriv, sScalar));
    const bal = await pub.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [acct.address] }) as bigint;
    if (bal === 0n) throw new Error("nothing to sweep");
    const gasPrice = await pub.getGasPrice();
    const SWEEP_GAS = 200_000n; // ample for one ERC-20 transfer on Orbit
    const need = gasPrice * SWEEP_GAS * 2n; // legacy pricing; 2× covers a gasPrice bump between the two txs
    const have = await pub.getBalance({ address: acct.address });
    if (have < need) {
      const fundHash = await wallet(a).sendTransaction({ account: a, chain: null, to: acct.address, value: need - have, gas: 100_000n });
      await pub.waitForTransactionReceipt({ hash: fundHash, timeout: 120_000 });
    }
    const swc = createWalletClient({ account: acct, chain: RH_VIEM_CHAIN, transport: http(NET.rpc) });
    const tx = await swc.writeContract({ address: token, abi: erc20Abi, functionName: "transfer", args: [to, bal], account: acct, gas: SWEEP_GAS, gasPrice, type: "legacy" });
    const rcpt = await pub.waitForTransactionReceipt({ hash: tx, timeout: 120_000 });
    if (rcpt.status !== "success") throw new Error("sweep reverted");
    return tx;
  },

  // ---- Essey Private (Phase 1): shielded pool — HIDES AMOUNTS ----

  /// Shield `amount` USDG into the pool. Derives the pool keypair from ONE wallet signature, builds a deposit
  /// proof IN THE BROWSER (client-side — private inputs never leave the device), approves + submits, and stores
  /// the resulting note locally (keyed to the wallet). The deposited amount is only visible as the transfer IN;
  /// the shielded balance and any later transfer are hidden.
  shieldDeposit: async (a: Address, amount: bigint, onStage?: (s: string) => void): Promise<Hex> => {
    await assertDeterministicSigner(a); // keys derive from a signature → EOA only, same as the stealth layer
    onStage?.("unlocking");
    await initPool();
    const kp = deriveKeypair(await signMsg(a, POOL_DERIVE_MESSAGE));
    onStage?.("proving"); // a few seconds of client-side Groth16
    const leaves = await poolLeaves();
    const { proof, ext, note } = await buildDepositProof(kp, amount, leaves);
    // Persist the note (with its commitment) BEFORE any funds move: the random blinding lives only here, so an
    // interrupted confirmation wait after the deposit lands would otherwise make the funds unspendable forever.
    // A reverted deposit just leaves a phantom note that shieldedNotes filters out (its commitment isn't on-chain).
    addNote(a, { ...note, commitment: proof.outputCommitments[0].toString() });
    onStage?.("approving");
    await ensureAllowance(a, ADDR.usdg, ADDR.shieldedPool, amount);
    onStage?.("shielding");
    return await send(a, ADDR.shieldedPool, shieldedPoolAbi, "transact", [proofToTuple(proof), extToTuple(ext)]);
  },

  /// Withdraw `amount` from a shielded note out to `recipient`. Builds a withdraw proof client-side (spends the
  /// note through a real merkle path, mints a change note for the remainder), submits, and updates local notes.
  shieldWithdraw: async (a: Address, note: ShieldedNote, amount: bigint, recipient: Address, onStage?: (s: string) => void): Promise<Hex> => {
    await assertDeterministicSigner(a);
    onStage?.("unlocking");
    await initPool();
    const kp = deriveKeypair(await signMsg(a, POOL_DERIVE_MESSAGE));
    onStage?.("proving");
    const leaves = await poolLeaves();
    // Recover the note's REAL leaf index by matching its commitment on-chain — the stored index is a pre-tx
    // guess a concurrent depositor can invalidate. A commitment is index-independent, so this is always safe.
    const realIndex = leaves.findIndex((l) => l === BigInt(note.commitment));
    if (realIndex < 0) throw new Error("This shielded note isn't on-chain yet — wait a few seconds and retry.");
    const { proof, ext, changeNote } = await buildWithdrawProof(kp, { ...note, index: realIndex }, amount, recipient, leaves);
    // Persist the change note (fresh random blinding) BEFORE sending, same reasoning as a deposit.
    if (changeNote) addNote(a, { ...changeNote, commitment: proof.outputCommitments[0].toString() });
    onStage?.("withdrawing");
    const tx = await send(a, ADDR.shieldedPool, shieldedPoolAbi, "transact", [proofToTuple(proof), extToTuple(ext)]);
    // Mark the input note spent (safe direction: if this is missed, a re-spend just reverts on the nullifier).
    markSpent(a, note.commitment);
    return tx;
  },

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

    // Reliable "did the keeper open it" signal: the case's `opened` flag (cheap eth_call, never throws).
    const isOpened = async (): Promise<boolean> => {
      try { const c = await pub.readContract({ address: ADDR.cases, abi: casesAbi, functionName: "cases", args: [caseId] }) as readonly [Address, bigint, bigint, boolean]; return c[3]; }
      catch { return false; }
    };
    // The drawn stock + amount live in the CaseOpened event; read it only once opened.
    const readOpened = async (): Promise<{ token: Address; amount: bigint; tx: Hex } | null> => {
      try {
        const logs = await pub.getLogs({ address: ADDR.cases, event: fairCaseOpenedItem, args: { caseId }, fromBlock: buyRcpt.blockNumber });
        if (!logs.length) return null;
        const { token, amount } = logs[0].args as { token: Address; amount: bigint };
        return { token, amount, tx: logs[0].transactionHash as Hex };
      } catch { return null; }
    };

    // Wait for the keeper to reveal (poll the cheap bool; also waits out the one-block draw commit). ~30s.
    // Once opened, retry the event read a few times — getLogs can lag a block or two behind state.
    onStage("sealing");
    let opened = false;
    for (let i = 0; i < 15; i++) {
      await new Promise((r) => setTimeout(r, 2_000));
      if (await isOpened()) {
        for (let j = 0; j < 6; j++) { const r = await readOpened(); if (r) return r; await new Promise((res) => setTimeout(res, 1_200)); }
        opened = true; break;
      }
    }
    // No keeper answered in time — open it ourselves (a rare extra sig). If it reverts AlreadyOpened the
    // keeper beat us, so re-read rather than surfacing an error.
    if (!opened) onStage("opening");
    try {
      if (!opened) await send(a, ADDR.cases, casesAbi, "open", [caseId]);
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

// ---- Essey Private (Phase 0): read helpers ----

/// A user's registered stealth meta-address (empty `0x` if they have never registered).
export async function lookupStealthMeta(user: Address): Promise<Hex> {
  return await pub.readContract({ address: ADDR.stealthRegistry, abi: stealthRegistryAbi, functionName: "stealthMetaAddressOf", args: [user, SECP256K1] }) as Hex;
}

export interface PrivateHolding {
  stealthAddress: Address;
  sScalar: bigint; // with the spend key, yields the private key that sweeps this address
  balances: { key: string; addr: Address; amount: bigint }[]; // non-zero known-token balances actually present
}

/// Scan the announcer for payments the caller owns (view-key detection is entirely client-side — the view
/// key never leaves the browser and nothing is sent anywhere), then read each owned stealth address's live
/// token balances so the inbox reflects exactly what is spendable now. Dedupes repeat announcements.
export async function scanPrivateInbox(viewPriv: bigint, spendPub: Uint8Array, fromBlock: bigint = STEALTH_DEPLOY_BLOCK): Promise<PrivateHolding[]> {
  const logs = await pub.getLogs({ address: ADDR.stealthAnnouncer, event: announcementItem, args: { schemeId: SECP256K1 }, fromBlock });
  const owned: PrivateHolding[] = [];
  const seen = new Set<string>();
  for (const l of logs) {
    const { stealthAddress, ephemeralPubKey, metadata } = l.args as { stealthAddress?: Address; ephemeralPubKey?: Hex; metadata?: Hex };
    if (!stealthAddress || !ephemeralPubKey || !metadata) continue;
    // The announcer is permissionless — a crafted announcement must never abort the whole scan and hide a
    // user's real funds. Detection is guarded per-entry; a throw just skips that (not-ours) announcement.
    let hit: { owned: boolean; sScalar?: bigint };
    try { hit = checkAnnouncement({ stealthAddress, ephemeralPubKey, metadata }, viewPriv, spendPub); }
    catch { continue; }
    if (!hit.owned || hit.sScalar === undefined) continue;
    const low = stealthAddress.toLowerCase();
    if (seen.has(low)) continue;
    seen.add(low);
    const balances: { key: string; addr: Address; amount: bigint }[] = [];
    for (const t of KNOWN_TOKENS) {
      const bal = await pub.readContract({ address: t.addr, abi: erc20Abi, functionName: "balanceOf", args: [stealthAddress] }) as bigint;
      if (bal > 0n) balances.push({ key: t.key, addr: t.addr, amount: bal });
    }
    owned.push({ stealthAddress, sScalar: hit.sScalar, balances });
  }
  return owned;
}

// ---- Essey Private (Phase 1): shielded pool helpers ----

/// One signature derives the pool spend key (deterministic → the same notes recover on re-sign). Distinct from
/// the stealth message so the two key systems never collide.
const POOL_DERIVE_MESSAGE =
  "Essey Private — unlock my shielded balance.\n\n" +
  "Signing this derives the private keys for your shielded USDG. It costs no gas and grants no approvals. " +
  "Only sign this on essey.xyz.\n\nVersion: 1";

/// All commitment leaves in the pool tree, ordered by insertion index — what the prover needs to rebuild the
/// merkle tree and compute paths. Young testnet chain; scan from the pool's deploy block (block-0 would exceed
/// RPC range caps at ~97M blocks).
async function poolLeaves(): Promise<bigint[]> {
  const head = await pub.getBlockNumber();
  const CHUNK = 45_000n; // stay under RPC getLogs range caps; the merkle path depends on the FULL leaf set,
  // so a silent truncation would produce a wrong root/path — never scan an unbounded range.
  const entries: { index: number; value: bigint }[] = [];
  for (let from = POOL_DEPLOY_BLOCK; from <= head; from += CHUNK + 1n) {
    const to = from + CHUNK > head ? head : from + CHUNK;
    const logs = await pub.getLogs({ address: ADDR.shieldedPool, event: newCommitmentItem, fromBlock: from, toBlock: to });
    for (const l of logs) {
      const { commitment, index } = l.args as { commitment?: Hex; index?: bigint };
      if (commitment !== undefined && index !== undefined) entries.push({ index: Number(index), value: BigInt(commitment) });
    }
  }
  entries.sort((x, y) => x.index - y.index);
  return entries.map((e) => e.value);
}

/// Notes live in THIS browser only (localStorage), keyed to wallet + pool. Enough for shield→balance→unshield;
/// receiving private payments from others / cross-device recovery needs on-chain encrypted-note scanning (Phase 2).
/// A shielded note as the app tracks it: the SDK note (amount/blinding/index) plus its commitment, which is
/// index-independent and how we relocate the note on-chain (the stored index is only a pre-tx guess).
export type ShieldedNote = PoolNote & { commitment: string };
type StoredNote = ShieldedNote & { spent?: boolean };
function noteKey(a: Address): string {
  return `essey.pool.notes.${ADDR.shieldedPool}.${a.toLowerCase()}`;
}
function loadNotes(a: Address): StoredNote[] {
  try { return JSON.parse(localStorage.getItem(noteKey(a)) || "[]") as StoredNote[]; } catch { return []; }
}
/// Throws LOUDLY if storage is unavailable (private mode / quota) — callers persist a note BEFORE moving funds,
/// so a silent failure here would strand the deposit. Aborting before the transfer is the safe outcome.
function saveNotes(a: Address, notes: StoredNote[]): void {
  try { localStorage.setItem(noteKey(a), JSON.stringify(notes)); }
  catch { throw new Error("Couldn't save your shielded note to this browser (private/incognito mode or storage full?). Enable storage and retry — do NOT proceed, or the funds can't be recovered."); }
}
function addNote(a: Address, n: ShieldedNote): void {
  const ns = loadNotes(a);
  if (!ns.some((x) => x.commitment === n.commitment)) ns.push({ ...n }); // dedup by commitment
  saveNotes(a, ns);
}
function markSpent(a: Address, commitment: string): void {
  saveNotes(a, loadNotes(a).map((n) => (n.commitment === commitment ? { ...n, spent: true } : n)));
}

/// Map the SDK's ProofCalldata / ExtData to the on-chain tuple shapes (bytes32 fields as 32-byte hex).
function proofToTuple(p: ProofCalldata) {
  return {
    a: [p.a[0], p.a[1]],
    b: [[p.b[0][0], p.b[0][1]], [p.b[1][0], p.b[1][1]]],
    c: [p.c[0], p.c[1]],
    root: numberToHex(p.root, { size: 32 }),
    inputNullifiers: [numberToHex(p.inputNullifiers[0], { size: 32 }), numberToHex(p.inputNullifiers[1], { size: 32 })],
    outputCommitments: [numberToHex(p.outputCommitments[0], { size: 32 }), numberToHex(p.outputCommitments[1], { size: 32 })],
    publicAmount: p.publicAmount,
    extDataHash: numberToHex(p.extDataHash, { size: 32 }),
  };
}
function extToTuple(e: PoolExtData) {
  return {
    recipient: e.recipient,
    extAmount: e.extAmount,
    relayer: e.relayer,
    fee: e.fee,
    encryptedOutput1: e.encryptedOutput1,
    encryptedOutput2: e.encryptedOutput2,
  };
}

/// The caller's spendable shielded notes + total shielded USDG (base units). Reconciled against the chain:
/// only locally-stored, unspent notes whose commitment is actually in the pool tree count — so a phantom
/// note from a reverted deposit, or one whose tx hasn't landed yet, never inflates the displayed balance.
export async function shieldedNotes(a: Address): Promise<{ notes: ShieldedNote[]; balance: bigint }> {
  const local = loadNotes(a).filter((n) => !n.spent);
  const onChain = new Set((await poolLeaves()).map((l) => l.toString()));
  const notes = local.filter((n) => onChain.has(BigInt(n.commitment).toString()));
  const balance = notes.reduce((s, n) => s + BigInt(n.amount), 0n);
  return { notes, balance };
}

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
  if (s.includes("already spent") || s.includes("input 0 is already spent") || s.includes("input 1 is already spent")) return "That shielded note was already spent — your local balance was stale. Refresh and try again.";
  if (s.includes("invalid merkle root")) return "The pool changed while proving — refresh so your balance is current, then retry.";
  // Otherwise: strip the noisy viem wrapper, keep the first human line.
  return m.split("\n")[0].replace(/^(Error|ContractFunctionExecutionError):?\s*/i, "").slice(0, 150);
}

export const fmt = (n: bigint, dp = 0) => {
  const whole = n / 10n ** 18n;
  if (dp === 0) return whole.toLocaleString();
  const frac = ((n % 10n ** 18n) * 10n ** BigInt(dp)) / 10n ** 18n;
  return `${whole.toLocaleString()}.${frac.toString().padStart(dp, "0")}`;
};
