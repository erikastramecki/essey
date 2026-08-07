// Essey Private — shielded-pool RELAYER (Vercel serverless function).
//
// A user builds a withdraw/transfer proof client-side, sets the relayer + a fee in the (proof-bound) extData,
// and POSTs it here. The relayer submits the `transact` tx and pays gas; the contract pays it `fee` from the
// pool. The relayer is TRUSTLESS: extDataHash binds recipient/relayer/fee into the zk proof, so this service
// can only submit the exact transaction or refuse — it cannot alter the fee, redirect funds, or steal. Its
// value is that the tx originates from the relayer, not the user's wallet — hiding the user's tx-origin, and
// letting withdrawals land at a fresh address the user never has to fund with gas.
//
// Config (Vercel env): RELAYER_PK — the relayer wallet's private key (a DEDICATED key, never a privileged one).
import { createWalletClient, createPublicClient, http, defineChain, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC = "https://rpc.testnet.chain.robinhood.com";
const CHAIN = defineChain({ id: 46630, name: "Robinhood Chain Testnet", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
// The shielded pools this relayer will submit to. An ALLOWLIST, not a free target: the caller names the pool
// (USDG / AAPL / NVDA / supply) but can only pick one of ours, so the relayer can never be pointed at an
// arbitrary contract. All expose the same `transact(proof, extData)` withdrawal/transfer entrypoint.
const ALLOWED_POOLS: Record<string, `0x${string}`> = {
  "0xcd7953960bbc1276f0856dad5e502fc01ce629ab": "0xcD7953960bbc1276F0856Dad5E502fc01cE629aB", // shielded USDG
  "0xef52251672d073fdd22f996d8665112be005eecc": "0xeF52251672d073fDD22f996D8665112BE005EecC", // shielded supply
  "0x49f1c16fede8f6099dc39d3b3c41b9890d51ae53": "0x49f1C16FeDe8f6099Dc39d3b3C41B9890D51Ae53", // shielded AAPL
  "0x8e358964666153cd604cf15be575e75a34fe9cb3": "0x8e358964666153cd604Cf15be575e75a34fE9cB3", // shielded NVDA
};
const MIN_FEE = 0n; // testnet: relayer eats gas from its funded wallet; production sets a gas-covering minimum.

const poolAbi = parseAbi([
  "function transact((uint256[2] a, uint256[2][2] b, uint256[2] c, bytes32 root, bytes32[2] inputNullifiers, bytes32[2] outputCommitments, uint256 publicAmount, bytes32 extDataHash) args, (address recipient, int256 extAmount, address relayer, uint256 fee, bytes encryptedOutput1, bytes encryptedOutput2) extData)",
]);

// The wire format: every uint256/int256 is a decimal string; bytes32/address/bytes are 0x-hex.
type WireProof = {
  a: [string, string];
  b: [[string, string], [string, string]];
  c: [string, string];
  root: `0x${string}`;
  inputNullifiers: [`0x${string}`, `0x${string}`];
  outputCommitments: [`0x${string}`, `0x${string}`];
  publicAmount: string;
  extDataHash: `0x${string}`;
};
type WireExt = { recipient: `0x${string}`; extAmount: string; relayer: `0x${string}`; fee: string; encryptedOutput1: `0x${string}`; encryptedOutput2: `0x${string}` };

function toProof(p: WireProof) {
  return {
    a: [BigInt(p.a[0]), BigInt(p.a[1])] as const,
    b: [[BigInt(p.b[0][0]), BigInt(p.b[0][1])], [BigInt(p.b[1][0]), BigInt(p.b[1][1])]] as const,
    c: [BigInt(p.c[0]), BigInt(p.c[1])] as const,
    root: p.root,
    inputNullifiers: p.inputNullifiers,
    outputCommitments: p.outputCommitments,
    publicAmount: BigInt(p.publicAmount),
    extDataHash: p.extDataHash,
  };
}
function toExt(e: WireExt) {
  return { recipient: e.recipient, extAmount: BigInt(e.extAmount), relayer: e.relayer, fee: BigInt(e.fee), encryptedOutput1: e.encryptedOutput1, encryptedOutput2: e.encryptedOutput2 };
}

// Vercel Node serverless handler.
export default async function handler(req: { method?: string; body?: unknown }, res: { status: (n: number) => { json: (b: unknown) => void } }) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  const pk = process.env.RELAYER_PK;
  if (!pk) return res.status(500).json({ error: "relayer not configured" });

  try {
    const account = privateKeyToAccount((pk.startsWith("0x") ? pk : "0x" + pk) as `0x${string}`);
    const body = (typeof req.body === "string" ? JSON.parse(req.body) : req.body) as { pool?: string; proof?: WireProof; extData?: WireExt };
    if (!body?.proof || !body?.extData) return res.status(400).json({ error: "missing proof/extData" });
    // Resolve + allowlist the target pool (default to the USDG pool for older clients that omit it). Guard with
    // hasOwn so prototype keys ("__proto__"/"constructor") can't slip past the allowlist check.
    const poolKey = (body.pool ?? "0xcD7953960bbc1276F0856Dad5E502fc01cE629aB").toLowerCase();
    if (!Object.hasOwn(ALLOWED_POOLS, poolKey)) return res.status(400).json({ error: "unknown pool" });
    const pool = ALLOWED_POOLS[poolKey];
    const proof = toProof(body.proof);
    const extData = toExt(body.extData);

    // Only relay WITHDRAWALS/TRANSFERS (extAmount <= 0). A deposit (extAmount > 0) would pull the pool token
    // from the RELAYER's own wallet (it's msg.sender) — never relay those; deposits are always self-submitted.
    if (extData.extAmount > 0n) return res.status(400).json({ error: "relay handles withdrawals/transfers only" });
    // Only relay txs that pay THIS relayer (so we can't be made to relay for a fee that goes elsewhere).
    if (extData.relayer.toLowerCase() !== account.address.toLowerCase()) return res.status(400).json({ error: "extData.relayer is not this relayer" });
    // testnet: MIN_FEE=0 (funded wallet subsidizes gas). Production MUST set a gas-covering fee + rate-limit.
    if (extData.fee < MIN_FEE) return res.status(400).json({ error: "fee below minimum" });

    const pub = createPublicClient({ chain: CHAIN, transport: http(RPC) });
    // Simulate first — never spend gas on a tx that would revert.
    await pub.simulateContract({ address: pool, abi: poolAbi, functionName: "transact", args: [proof, extData], account });

    const w = createWalletClient({ account, chain: CHAIN, transport: http(RPC) });
    const hash = await w.writeContract({ address: pool, abi: poolAbi, functionName: "transact", args: [proof, extData], chain: CHAIN, gas: 4_000_000n });
    return res.status(200).json({ hash });
  } catch (e) {
    return res.status(400).json({ error: (e as Error)?.message ?? String(e) });
  }
}
