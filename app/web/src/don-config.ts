// Dons — on-chain config for the builder mint + Don flows. TESTNET addresses (RH chainId 46630),
// deployed + rehearsed 2026-08-11 (see docs/DEPLOYMENT-testnet.md). Mainnet swaps this table at #81.
import { parseAbi, defineChain } from "viem";

export const DON_NET = {
  chainId: 46630,
  rpc: "https://rpc.testnet.chain.robinhood.com/rpc",
  explorer: "https://explorer.testnet.chain.robinhood.com",
  essey: "0x32a860B1Eaa02A07c0b8a9eB6E3c51B7ce823d1F",
  distributor: "0x9F9928E1FDa97f67d54A9E7b7fFedC003C669103",
  don: "0x582E4B8E3A783B1FE09409AEDa3C6533782dB53c",
  reserve: "0xD54FeD45840FA4E64dC04C36dD119d256BCEd679",
  bell: "0x8a7749e47E79964B265B6ee6216FD5d017701552",
  exchange: "0x9Cec219bCdA1a901D4a7154B55648bdAE5433582",
  loan: "0x764525bE0e90cB02afFB93ccA63bB94333c43EEF",
  feeRouter: "0x0000000000000000000000000000000000000000",
  affinity: "0x2d9CC510D464977F0Eb597237F467b453CB3e484",
} as const;

/// The RH testnet as a viem chain, for createPublicClient/createWalletClient anywhere Don flows run.
export const donChain = defineChain({
  id: DON_NET.chainId,
  name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [DON_NET.rpc] } },
  blockExplorers: { default: { name: "RH Explorer", url: DON_NET.explorer } },
});

/// Stage-0 WL root is PROPOSED on-chain but commits only after the 2-day timelock. Until stageRoot(0)
/// is nonzero every claim reverts BadProof — the UI shows "claims open soon" against this ETA.
export const WL_STAGE0_COMMIT_ETA_MS = Date.UTC(2026, 7, 13, 19, 0, 0); // ~2026-08-13 19:00 UTC

export const distributorAbi = parseAbi([
  "function mintCustom(bytes32 combo) payable returns (uint256 id)",
  "function reroll(uint256 id, bytes32 newCombo) payable",
  "function claimWL(uint256 stage, uint256 allocation, bytes32[] proof, bytes32[] combos) returns (uint256 firstId)",
  "function customFee() view returns (uint256)",
  "function rerollFee() view returns (uint256)",
  "function usedCombo(bytes32) view returns (bool)",
  "function publicOpen() view returns (bool)",
  "function claimed(uint256 stage, address account) view returns (bool)",
  "function stageRoot(uint256 stage) view returns (bytes32)",
  "function stageOpen(uint256 stage) view returns (bool)",
  // events the builder parses out of receipts
  "event CustomMinted(address indexed to, uint256 indexed id, bytes32 combo, uint256 fee)",
  "event ClaimedWL(uint256 indexed stage, address indexed account, uint256 allocation, uint256 firstId)",
  "event Rerolled(uint256 indexed id, bytes32 oldCombo, bytes32 newCombo, uint256 fee)",
  // custom errors so viem can decode reverts into names the UI maps to friendly copy
  "error ComboTaken()",
  "error PublicClosed()",
  "error WrongFee()",
  "error StakedNoReroll()",
  "error BadProof()",
  "error StageClosed()",
  "error AlreadyClaimed()",
  "error AllocationMismatch()",
  "error ZeroAllocation()",
  "error NotOwner()",
  "error DonNotSet()",
  "error SinksUnset()",
  "error TransferFailed()",
]);

export const donAbi = parseAbi([
  "function ownerOf(uint256 id) view returns (address)",
  "function totalMinted() view returns (uint256)",
  "function traits(uint256 id) view returns (bytes32)",
  "function locked(uint256 id) view returns (bool)",
  "function liened(uint256 id) view returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "error TraitsLocked()",
  "error LienActive()",
  "error NonexistentToken()",
]);

/// WL proofs ship as a static asset (public/allowlist/proofs.json, gitignored like the art —
/// uploaded by the vercel deploy). Shape: { [walletLowercase]: { stage, allocation, proof: hex[] } }.
export async function fetchWlProof(wallet: string): Promise<{
  stage: number;
  allocation: number;
  proof: `0x${string}`[];
} | null> {
  try {
    const all = await fetch("/allowlist/proofs.json").then((r) =>
      r.ok ? r.json() : null,
    );
    return all?.[wallet.toLowerCase()] ?? null;
  } catch {
    return null;
  }
}
