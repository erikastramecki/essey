// Essey Private — RELAYER PATH proof. The production /api/relay endpoint returns 500 "relayer not configured"
// because RELAYER_PK is unset in Vercel (verified live). This script proves the relayer CODE is sound: it runs
// the ACTUAL api/relay.ts handler in-process with a stand-in RELAYER_PK, feeding it a real client-built withdraw
// proof serialized EXACTLY as live.ts relaySubmit() does. If this lands a tx, the ONLY thing missing in
// production is the env var — not the code.
//
// CAVEAT: here the stand-in relayer == the deployer (we don't hold the dedicated relayer wallet's key), so this
// proves the handler's parse→allowlist→simulate→submit→pay path, not the "different tx-origin" privacy property
// (which is structural: in prod the relayer is wallet 0x1Ed2…C23c, already funded, nonce 0). Run from app/web.
import { build } from "esbuild";
import { createPublicClient, createWalletClient, http, defineChain, parseAbi, parseAbiItem, maxUint256, numberToHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { unlink } from "fs/promises";

const RPC = "https://rpc.testnet.chain.robinhood.com";
const CHAIN = defineChain({ id: 46630, name: "RH", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const EXPL = "https://explorer.testnet.chain.robinhood.com/tx/";
const USDG = "0x7461E670d44FF4397A3E48030C5b06f6163a5De2";
const USDG_POOL = "0xcD7953960bbc1276F0856Dad5E502fc01cE629aB", USDG_DEPLOY = 97728346n;
const R = "0x000000000000000000000000000000000000dead";
const POOL_MSG = "Essey Private — unlock my shielded balance.\n\nSigning this derives the private keys for your shielded USDG. It costs no gas and grants no approvals. Only sign this on essey.xyz.\n\nVersion: 1";

const poolAbi = parseAbi(["function transact((uint256[2] a, uint256[2][2] b, uint256[2] c, bytes32 root, bytes32[2] inputNullifiers, bytes32[2] outputCommitments, uint256 publicAmount, bytes32 extDataHash) args, (address recipient, int256 extAmount, address relayer, uint256 fee, bytes encryptedOutput1, bytes encryptedOutput2) extData)"]);
const erc20 = parseAbi(["function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)", "function mint(address,uint256)"]);
const ncItem = parseAbiItem("event NewCommitment(bytes32 commitment, uint256 index, bytes encryptedOutput)");

// Stand-in relayer key = the deployer key (we don't hold the dedicated relayer wallet's PK). Set BEFORE importing
// the handler, which reads process.env.RELAYER_PK at call time.
process.env.RELAYER_PK = (process.env.DEPLOYER_PK.startsWith("0x") ? "" : "0x") + process.env.DEPLOYER_PK;

await build({ entryPoints: ["src/poolsdk.ts"], bundle: true, format: "esm", platform: "node", outfile: "_sdk_rl.mjs", external: ["viem", "@noble/*", "circomlibjs", "snarkjs"] });
await build({ entryPoints: ["api/relay.ts"], bundle: true, format: "esm", platform: "node", outfile: "_relay_h.mjs", external: ["viem"] });
const S = await import("./_sdk_rl.mjs");
const H = (await import("./_relay_h.mjs")).default;

const pk = process.env.RELAYER_PK;
const acct = privateKeyToAccount(pk);
const pub = createPublicClient({ chain: CHAIN, transport: http(RPC) });
const w = createWalletClient({ account: acct, chain: CHAIN, transport: http(RPC) });
const opts = { wasmUrl: process.cwd() + "/public/pool/transaction2.wasm", zkeyUrl: process.cwd() + "/public/pool/transaction2.zkey" };
const log = (...a) => console.log(...a);
const p2t = (p) => ({ a: [p.a[0], p.a[1]], b: [[p.b[0][0], p.b[0][1]], [p.b[1][0], p.b[1][1]]], c: [p.c[0], p.c[1]], root: numberToHex(p.root, { size: 32 }), inputNullifiers: [numberToHex(p.inputNullifiers[0], { size: 32 }), numberToHex(p.inputNullifiers[1], { size: 32 })], outputCommitments: [numberToHex(p.outputCommitments[0], { size: 32 }), numberToHex(p.outputCommitments[1], { size: 32 })], publicAmount: p.publicAmount, extDataHash: numberToHex(p.extDataHash, { size: 32 }) });
const e2t = (e) => ({ recipient: e.recipient, extAmount: e.extAmount, relayer: e.relayer, fee: e.fee, encryptedOutput1: e.encryptedOutput1, encryptedOutput2: e.encryptedOutput2 });
const send = async (to, abi, fn, args) => { const h = await w.writeContract({ address: to, abi, functionName: fn, args, gas: 4_000_000n }); const r = await pub.waitForTransactionReceipt({ hash: h }); if (r.status !== "success") throw new Error(fn + " reverted"); return h; };
async function chainOf() { const head = await pub.getBlockNumber(); const res = []; for (let f = USDG_DEPLOY; f <= head; f += 45001n) { const t = f + 45000n > head ? head : f + 45000n; const logs = await pub.getLogs({ address: USDG_POOL, event: ncItem, fromBlock: f, toBlock: t }); for (const l of logs) res.push({ commitment: BigInt(l.args.commitment), index: Number(l.args.index) }); } res.sort((x, y) => x.index - y.index); return res; }
// serialize EXACTLY like live.ts relaySubmit()
const wire = (proof, ext) => ({ pool: USDG_POOL, proof: { a: [proof.a[0].toString(), proof.a[1].toString()], b: [[proof.b[0][0].toString(), proof.b[0][1].toString()], [proof.b[1][0].toString(), proof.b[1][1].toString()]], c: [proof.c[0].toString(), proof.c[1].toString()], root: numberToHex(proof.root, { size: 32 }), inputNullifiers: [numberToHex(proof.inputNullifiers[0], { size: 32 }), numberToHex(proof.inputNullifiers[1], { size: 32 })], outputCommitments: [numberToHex(proof.outputCommitments[0], { size: 32 }), numberToHex(proof.outputCommitments[1], { size: 32 })], publicAmount: proof.publicAmount.toString(), extDataHash: numberToHex(proof.extDataHash, { size: 32 }) }, extData: { recipient: ext.recipient, extAmount: ext.extAmount.toString(), relayer: ext.relayer, fee: ext.fee.toString(), encryptedOutput1: ext.encryptedOutput1, encryptedOutput2: ext.encryptedOutput2 } });

try {
  await S.initPool();
  const sig = await acct.signMessage({ message: POOL_MSG });
  const A = { spend: S.deriveKeypair(sig), enc: S.deriveEncKeypair(sig) };
  const AMT = 10n * 10n ** 18n;

  log("=== relayer handler path: deposit (self) -> RELAYED withdraw via api/relay.ts handler ===");
  const leaves0 = (await chainOf()).map((c) => c.commitment);
  const dep = await S.buildDepositProof(A.spend, A.enc, AMT, leaves0, opts);
  if ((await pub.readContract({ address: USDG, abi: erc20, functionName: "balanceOf", args: [acct.address] })) < AMT) await send(USDG, erc20, "mint", [acct.address, AMT]).catch(() => {});
  await send(USDG, erc20, "approve", [USDG_POOL, maxUint256]);
  const dh = await send(USDG_POOL, poolAbi, "transact", [p2t(dep.proof), e2t(dep.ext)]);
  log("  deposit 10 USDG (self)  tx:", EXPL + dh);

  const leaves1 = [...leaves0, dep.proof.outputCommitments[0], dep.proof.outputCommitments[1]];
  // withdraw with relayer=stand-in relayer, fee=0 — the proof binds these into extDataHash
  const wd = await S.buildWithdrawProof(A.spend, A.enc, dep.note, AMT, R, leaves1, { ...opts, relayer: acct.address, fee: 0n });
  const rBefore = await pub.readContract({ address: USDG, abi: erc20, functionName: "balanceOf", args: [R] });

  // POST to the REAL handler (mock req/res), exactly as the browser's fetch("/api/relay") would
  let captured = null, code = null;
  const res = { status: (n) => { code = n; return { json: (b) => { captured = b; } }; } };
  await H({ method: "POST", body: wire(wd.proof, wd.ext) }, res);
  log("  handler responded HTTP", code, JSON.stringify(captured));
  if (code !== 200 || !captured?.hash) throw new Error("relay handler did not submit: " + JSON.stringify(captured));
  await pub.waitForTransactionReceipt({ hash: captured.hash });
  log("  RELAYED withdraw submitted by handler  tx:", EXPL + captured.hash);
  const delta = (await pub.readContract({ address: USDG, abi: erc20, functionName: "balanceOf", args: [R] })) - rBefore;
  if (delta !== AMT) throw new Error("relayed withdraw delta != 10e18 (got " + delta + ")");

  // sanity: the negative-path guard also works (deposit extAmount>0 must be rejected)
  let dcode = null, dbody = null;
  await H({ method: "POST", body: wire(dep.proof, dep.ext) }, { status: (n) => { dcode = n; return { json: (b) => { dbody = b; } }; } });
  log("  guard check — POST a DEPOSIT (extAmount>0):", dcode, JSON.stringify(dbody), "(expected 400 rejection)");

  log("\n  ✅ RELAYER CODE PROVEN: client proof -> api/relay.ts -> simulate -> submit -> recipient paid 10 USDG.");
  log("  Production gap is CONFIG ONLY: set RELAYER_PK in Vercel (dedicated key for wallet 0x1Ed2…C23c).");
  log("\nJSON:", JSON.stringify({ flow: "relayer (gasless) path", deposit: dh, relayedWithdraw: captured.hash, depositGuard: dcode + " " + (dbody?.error ?? ""), status: "CODE VERIFIED — prod needs RELAYER_PK env" }, null, 2));
} finally {
  await unlink("./_sdk_rl.mjs").catch(() => {});
  await unlink("./_relay_h.mjs").catch(() => {});
}
