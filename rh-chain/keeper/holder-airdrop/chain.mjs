import { createPublicClient, createWalletClient, defineChain, getAddress, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";

export const DISTRIBUTOR_ABI = [
  { type: "function", name: "currentBuyEpoch", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "lastRootAt", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "minEpochInterval", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "minBond", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "keeper", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" },
  { type: "function", name: "bond", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  {
    type: "function",
    name: "reserved",
    inputs: [{ type: "uint256" }, { type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "settleBuy",
    inputs: [{ type: "address" }, { type: "uint256" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "postRoot",
    inputs: [{ type: "bytes32" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "nonpayable",
  },
];

export const REGISTRY_ABI = [
  { type: "function", name: "basketCount", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
  {
    type: "function",
    name: "basketOf",
    inputs: [{ type: "uint256" }],
    outputs: [{ type: "string" }, { type: "address[]" }, { type: "uint16[]" }, { type: "bool" }],
    stateMutability: "view",
  },
];

export const ERC20_ABI = [
  { type: "function", name: "balanceOf", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "totalSupply", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
];

export function chainFor(cfg) {
  return defineChain({
    id: cfg.chainId,
    name: `chain-${cfg.chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [cfg.rpc] } },
  });
}

export function publicClientFor(cfg) {
  return createPublicClient({ chain: chainFor(cfg), transport: http(cfg.rpc) });
}

/// Only built when EXECUTE=1; a read-only run never constructs a signer at all.
export function walletClientFor(cfg) {
  if (!cfg.execute) return null;
  const account = privateKeyToAccount(cfg.privateKey);
  return createWalletClient({ account, chain: chainFor(cfg), transport: http(cfg.rpc) });
}

/// Every COMMITTED basket, keyed by id. An uncommitted (still timelocked) basket is skipped — accruing
/// into one would let a basket that is not yet public take a share of the pot.
export async function readBaskets(client, registry) {
  const count = await client.readContract({ address: registry, abi: REGISTRY_ABI, functionName: "basketCount" });
  const baskets = new Map();
  for (let id = 0n; id < count; id++) {
    const [name, tokens, bps, committed] = await client.readContract({
      address: registry,
      abi: REGISTRY_ABI,
      functionName: "basketOf",
      args: [id],
    });
    if (!committed) continue;
    baskets.set(Number(id), { name, tokens: tokens.map(getAddress), bps: bps.map(Number) });
  }
  return baskets;
}

export async function readReserved(client, distributor, epoch, tokens) {
  const reserved = new Map();
  for (const token of tokens) {
    const amount = await client.readContract({
      address: distributor,
      abi: DISTRIBUTOR_ABI,
      functionName: "reserved",
      args: [BigInt(epoch), getAddress(token)],
    });
    reserved.set(getAddress(token), amount);
  }
  return reserved;
}
