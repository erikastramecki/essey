// Dons v3 — on-chain config for the builder mint + Don flows. TESTNET addresses (RH chainId 46630),
// deployed + rehearsed 2026-08-11 (see docs/DEPLOYMENT-testnet.md). Mainnet swaps this table at #81.
import { parseAbi } from "viem";

export const DON_NET = {
  chainId: 46630,
  rpc: "https://rpc.testnet.chain.robinhood.com/rpc",
  explorer: "https://explorer.testnet.chain.robinhood.com",
  essey: "0x32a860B1Eaa02A07c0b8a9eB6E3c51B7ce823d1F",
  distributor: "0x2Bbc39AcB8A1A76909759f7B2f31D57f1535601d",
  don: "0x0C30ccbf727c5f9803A81e64873C6898a1e15771",
  reserve: "0xD4aC7ADD2A790B9916367c35F9F892b6D92F24D6",
  bell: "0x5f2Df783437b5383f8E96196Bb92A0c22527a289",
  exchange: "0x10c22bC22B4deE66a7DE2f790a2678e622441753",
  loan: "0x2Fd14544c53071D0Fef29A51C0DfdF176Ac36bC7",
  feeRouter: "0x6EC22ab8442de2F780477d9A56926e0BA0382032",
} as const;

export const distributorAbi = parseAbi([
  "function mintCustom(bytes32 combo) payable returns (uint256 id)",
  "function reroll(uint256 id, bytes32 newCombo) payable",
  "function claimWL(uint256 stage, uint256 allocation, bytes32[] proof, bytes32[] combos) returns (uint256 firstId)",
  "function customFee() view returns (uint256)",
  "function rerollFee() view returns (uint256)",
  "function usedCombo(bytes32) view returns (bool)",
  "function publicOpen() view returns (bool)",
  "function claimed(uint256 stage, address account) view returns (bool)",
]);

export const donAbi = parseAbi([
  "function ownerOf(uint256 id) view returns (address)",
  "function totalMinted() view returns (uint256)",
  "function traits(uint256 id) view returns (bytes32)",
  "function locked(uint256 id) view returns (bool)",
  "function liened(uint256 id) view returns (bool)",
  "function balanceOf(address) view returns (uint256)",
]);

/// WL proofs ship as a static asset (public/allowlist/proofs.json, gitignored like the art —
/// uploaded by the vercel deploy). Shape: { [walletLowercase]: { stage, allocation, proof: hex[] } }.
export async function fetchWlProof(wallet: string): Promise<{ stage: number; allocation: number; proof: `0x${string}`[] } | null> {
  try {
    const all = await fetch("/allowlist/proofs.json").then((r) => (r.ok ? r.json() : null));
    return all?.[wallet.toLowerCase()] ?? null;
  } catch {
    return null;
  }
}
