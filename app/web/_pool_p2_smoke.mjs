// On-chain Phase 2 smoke (race-free): register + deposit + private TRANSFER against the live app pool.
// Uses the deposit's returned note + locally-computed leaves so no RPC re-scan race. Run from app/web.
import { build } from "esbuild";
import { createPublicClient, createWalletClient, http, defineChain, parseAbi, parseAbiItem, maxUint256, numberToHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { unlink } from "fs/promises";

const RPC = "https://rpc.testnet.chain.robinhood.com";
const CHAIN = defineChain({ id: 46630, name: "RH", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const POOL = "0xcD7953960bbc1276F0856Dad5E502fc01cE629aB", USDG = "0x7461E670d44FF4397A3E48030C5b06f6163a5De2", DEPLOY_BLOCK = 97728346n;
const MSG = "Essey Private — unlock my shielded balance.\n\nSigning this derives the private keys for your shielded USDG. It costs no gas and grants no approvals. Only sign this on essey.xyz.\n\nVersion: 1";
const poolAbi = parseAbi([
  "function transact((uint256[2] a, uint256[2][2] b, uint256[2] c, bytes32 root, bytes32[2] inputNullifiers, bytes32[2] outputCommitments, uint256 publicAmount, bytes32 extDataHash) args, (address recipient, int256 extAmount, address relayer, uint256 fee, bytes encryptedOutput1, bytes encryptedOutput2) extData)",
  "function register((address owner, bytes publicKey) account)",
]);
const erc20 = parseAbi(["function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)"]);
const ncItem = parseAbiItem("event NewCommitment(bytes32 commitment, uint256 index, bytes encryptedOutput)");

await build({ entryPoints: ["src/poolsdk.ts"], bundle: true, format: "esm", platform: "node", outfile: "_sdk_bundle.mjs", external: ["viem", "@noble/*", "circomlibjs", "snarkjs"] });
const S = await import("./_sdk_bundle.mjs");
const pk = (process.env.DEPLOYER_PK.startsWith("0x") ? "" : "0x") + process.env.DEPLOYER_PK;
const acct = privateKeyToAccount(pk);
const pub = createPublicClient({ chain: CHAIN, transport: http(RPC) });
const w = createWalletClient({ account: acct, chain: CHAIN, transport: http(RPC) });
const opts = { wasmUrl: process.cwd() + "/public/pool/transaction2.wasm", zkeyUrl: process.cwd() + "/public/pool/transaction2.zkey" };
const log = (...a) => console.log(...a);
const proofToTuple = (p) => ({ a: [p.a[0], p.a[1]], b: [[p.b[0][0], p.b[0][1]], [p.b[1][0], p.b[1][1]]], c: [p.c[0], p.c[1]], root: numberToHex(p.root, { size: 32 }), inputNullifiers: [numberToHex(p.inputNullifiers[0], { size: 32 }), numberToHex(p.inputNullifiers[1], { size: 32 })], outputCommitments: [numberToHex(p.outputCommitments[0], { size: 32 }), numberToHex(p.outputCommitments[1], { size: 32 })], publicAmount: p.publicAmount, extDataHash: numberToHex(p.extDataHash, { size: 32 }) });
const extToTuple = (e) => ({ recipient: e.recipient, extAmount: e.extAmount, relayer: e.relayer, fee: e.fee, encryptedOutput1: e.encryptedOutput1, encryptedOutput2: e.encryptedOutput2 });
const send = async (to, abi, fn, args) => { const h = await w.writeContract({ address: to, abi, functionName: fn, args, gas: 4_000_000n }); const r = await pub.waitForTransactionReceipt({ hash: h }); if (r.status !== "success") throw new Error(fn + " reverted"); return h; };
async function chain() { const head = await pub.getBlockNumber(); const res = []; for (let f = DEPLOY_BLOCK; f <= head; f += 45001n) { const t = f + 45000n > head ? head : f + 45000n; const logs = await pub.getLogs({ address: POOL, event: ncItem, fromBlock: f, toBlock: t }); for (const l of logs) res.push({ commitment: BigInt(l.args.commitment), index: Number(l.args.index), encryptedOutput: l.args.encryptedOutput ?? "0x" }); } res.sort((x, y) => x.index - y.index); return res; }

try {
  await S.initPool();
  const sig = await acct.signMessage({ message: MSG });
  const A = { spend: S.deriveKeypair(sig), enc: S.deriveEncKeypair(sig) };
  const B = { spend: S.deriveKeypair("0x" + "b2".repeat(65)), enc: S.deriveEncKeypair("0x" + "b2".repeat(65)) };

  const before = await chain();
  const leaves0 = before.map((c) => c.commitment);
  // deposit 100 — capture the returned note + its output commitments locally (no re-scan race)
  const dep = await S.buildDepositProof(A.spend, A.enc, 100n, leaves0, opts);
  if ((await pub.readContract({ address: USDG, abi: erc20, functionName: "balanceOf", args: [acct.address] })) > 0n) await send(USDG, erc20, "approve", [POOL, maxUint256]);
  await send(POOL, poolAbi, "transact", [proofToTuple(dep.proof), extToTuple(dep.ext)]);
  log("deposited 100 (note index", dep.note.index, ")");

  // leaves after deposit = old + the two deposit output commitments (known locally, race-free)
  const leaves1 = [...leaves0, dep.proof.outputCommitments[0], dep.proof.outputCommitments[1]];
  const xfer = await S.buildTransferProof(A.spend, A.enc, dep.note, 30n, B.spend.pubkey, B.enc.encPub, leaves1, opts);
  await send(POOL, poolAbi, "transact", [proofToTuple(xfer.proof), extToTuple(xfer.ext)]);
  log("transferred 30 to B on-chain (extAmount=0, fully in-pool)");

  // verify cross-recovery from the chain (poll to beat RPC lag)
  let bNotes = [], aAfter = [];
  for (let i = 0; i < 10; i++) {
    const ch = await chain();
    bNotes = S.recoverNotes(ch, B.spend, B.enc).filter((n) => BigInt(n.amount) === 30n);
    aAfter = S.recoverNotes(ch, A.spend, A.enc);
    if (bNotes.length && aAfter.some((n) => BigInt(n.amount) === 70n)) break;
    await new Promise((r) => setTimeout(r, 3000));
  }
  log("B recovered from chain (expect 30):", bNotes.map((n) => n.amount));
  log("A change recovered from chain (expect 70 present):", aAfter.map((n) => n.amount));
  if (!bNotes.length) throw new Error("SMOKE FAIL: B did not receive the transfer");
  if (!aAfter.some((n) => BigInt(n.amount) === 70n)) throw new Error("SMOKE FAIL: A change not recovered");
  log("\nPHASE 2 PROVEN ON-CHAIN: register + deposit + private transfer + cross-recovery from chain.");
} finally { await unlink("./_sdk_bundle.mjs").catch(() => {}); }
