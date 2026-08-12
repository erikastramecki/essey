// Essey Private — SHIELDED STOCK adminBurn HAIRCUT E2E, proven on-chain with a real depth-20 Groth16 proof.
//
// WHY A THROWAWAY POOL: the LIVE shielded AAPL/NVDA pools (live.ts ADDR.shieldedStockAapl/Nvda) are wired to
// the testnet stock tokens at 0xaC6c…/0x8393…, which are plain `ERC20Mock` (name "ERC20Mock", symbol "E20M")
// with NO burn function of any kind — so the issuer-burn impairment simply cannot be triggered against the
// live pools (verified: adminBurn/burn/burnFrom all absent). This script therefore deploys a FRESH
// EsseyShieldedStock of IDENTICAL BYTECODE (from forge out/) reusing the SAME depth-20 verifier + Poseidon
// hasher the live AAPL pool uses, backed by a BurnableStock mock that DOES expose the issuer `adminBurn`
// hazard. The haircut accounting under test (totalShielded / quoteHaircut / isImpaired) is the deployed
// contract's, unchanged. Drives the SAME poolsdk.ts prover the /private UI calls.
//
// Flow: deposit 100 -> issuer adminBurn(pool, 40) -> withdraw the full 100-note -> recipient receives the
//       pro-rata haircut (60), the note is CONSUMED not FROZEN, isImpaired()==true, payout==previewWithdrawable.
// Run from app/web with DEPLOYER_PK set.
import { build } from "esbuild";
import { createPublicClient, createWalletClient, http, defineChain, parseAbi, maxUint256, numberToHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { unlink, readFile } from "fs/promises";

const RPC = "https://rpc.testnet.chain.robinhood.com";
const CHAIN = defineChain({ id: 46630, name: "RH", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const EXPL = "https://explorer.testnet.chain.robinhood.com/tx/";
const OUT = "/Users/erikastramecki/Developer/assay/rh-chain/out";
// The live AAPL pool's deployed verifier + Poseidon hasher — reused so the throwaway pool is circuit-identical.
const VERIFIER = "0x0BAe595c86EAF9C75F32f4b79C4CfA842f56EffA";
const HASHER = "0xA0744039c7Cab439016337c753eb61A44C9c7dbb";
const R = "0x000000000000000000000000000000000000dEaD";
const POOL_MSG = "Essey Private — unlock my shielded balance.\n\nSigning this derives the private keys for your shielded USDG. It costs no gas and grants no approvals. Only sign this on essey.xyz.\n\nVersion: 1";

const poolAbi = parseAbi([
  "function transact((uint256[2] a, uint256[2][2] b, uint256[2] c, bytes32 root, bytes32[2] inputNullifiers, bytes32[2] outputCommitments, uint256 publicAmount, bytes32 extDataHash) args, (address recipient, int256 extAmount, address relayer, uint256 fee, bytes encryptedOutput1, bytes encryptedOutput2) extData)",
  "function totalShielded() view returns (uint256)",
  "function isImpaired() view returns (bool)",
  "function previewWithdrawable(uint256) view returns (uint256)",
]);
const stockAbi = parseAbi(["function mint(address,uint256)", "function adminBurn(address,uint256)", "function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)"]);

async function artifact(path) { const j = JSON.parse(await readFile(path, "utf8")); return { abi: j.abi, bytecode: j.bytecode.object }; }

await build({ entryPoints: ["src/poolsdk.ts"], bundle: true, format: "esm", platform: "node", outfile: "_sdk_hc.mjs", external: ["viem", "@noble/*", "circomlibjs", "snarkjs"] });
const S = await import("./_sdk_hc.mjs");
const pk = (process.env.DEPLOYER_PK.startsWith("0x") ? "" : "0x") + process.env.DEPLOYER_PK;
const acct = privateKeyToAccount(pk);
const pub = createPublicClient({ chain: CHAIN, transport: http(RPC) });
const w = createWalletClient({ account: acct, chain: CHAIN, transport: http(RPC) });
const opts = { wasmUrl: process.cwd() + "/public/pool/transaction2.wasm", zkeyUrl: process.cwd() + "/public/pool/transaction2.zkey" };
const log = (...a) => console.log(...a);
const p2t = (p) => ({ a: [p.a[0], p.a[1]], b: [[p.b[0][0], p.b[0][1]], [p.b[1][0], p.b[1][1]]], c: [p.c[0], p.c[1]], root: numberToHex(p.root, { size: 32 }), inputNullifiers: [numberToHex(p.inputNullifiers[0], { size: 32 }), numberToHex(p.inputNullifiers[1], { size: 32 })], outputCommitments: [numberToHex(p.outputCommitments[0], { size: 32 }), numberToHex(p.outputCommitments[1], { size: 32 })], publicAmount: p.publicAmount, extDataHash: numberToHex(p.extDataHash, { size: 32 }) });
const e2t = (e) => ({ recipient: e.recipient, extAmount: e.extAmount, relayer: e.relayer, fee: e.fee, encryptedOutput1: e.encryptedOutput1, encryptedOutput2: e.encryptedOutput2 });
const send = async (to, abi, fn, args) => { const h = await w.writeContract({ address: to, abi, functionName: fn, args, gas: 4_000_000n }); const r = await pub.waitForTransactionReceipt({ hash: h }); if (r.status !== "success") throw new Error(fn + " reverted"); return h; };
const deploy = async (art, args) => { const h = await w.deployContract({ abi: art.abi, bytecode: art.bytecode.startsWith("0x") ? art.bytecode : "0x" + art.bytecode, args, gas: 6_000_000n }); const r = await pub.waitForTransactionReceipt({ hash: h }); if (r.status !== "success") throw new Error("deploy reverted"); return r.contractAddress; };
const now = () => Date.now(), secs = (t0) => ((now() - t0) / 1000).toFixed(1) + "s";

try {
  await S.initPool();
  const AMT = 100n * 10n ** 18n;
  const [stockArt, gateArt, poolArt] = await Promise.all([
    artifact(`${OUT}/EsseyShieldedStock.t.sol/BurnableStock.json`),
    artifact(`${OUT}/EsseyPoolGate.sol/EsseyPoolGate.json`),
    artifact(`${OUT}/EsseyShieldedStock.sol/EsseyShieldedStock.json`),
  ]);

  log("=== deploying throwaway BurnableStock + Gate + EsseyShieldedStock (identical bytecode, live verifier+hasher) ===");
  const stock = await deploy(stockArt, []);
  log("  BurnableStock:", stock);
  const gate = await deploy(gateArt, [acct.address, true]); // openMode
  log("  EsseyPoolGate:", gate);
  const pool = await deploy(poolArt, [VERIFIER, 20, HASHER, stock, gate, acct.address, maxUint256]);
  log("  EsseyShieldedStock:", pool);

  const sig = await acct.signMessage({ message: POOL_MSG });
  const A = { spend: S.deriveKeypair(sig), enc: S.deriveEncKeypair(sig) };

  // fresh pool -> no commitments yet, so leaves start empty (race-free, no scan needed)
  let t0 = now();
  const dep = await S.buildDepositProof(A.spend, A.enc, AMT, [], opts);
  const tDep = secs(t0);
  await send(stock, stockAbi, "mint", [acct.address, AMT]);
  await send(stock, stockAbi, "approve", [pool, maxUint256]);
  const dh = await send(pool, poolAbi, "transact", [p2t(dep.proof), e2t(dep.ext)]);
  log("\n  deposit 100 (proof " + tDep + ")  tx:", EXPL + dh);

  // issuer burns 40% of the pool's backing
  const poolBalPre = await pub.readContract({ address: stock, abi: stockAbi, functionName: "balanceOf", args: [pool] });
  const burnAmt = (poolBalPre * 40n) / 100n;
  const bh = await send(stock, stockAbi, "adminBurn", [pool, burnAmt]);
  log("  issuer adminBurn(" + (burnAmt / 10n ** 18n) + ") from pool  tx:", EXPL + bh);

  const impaired = await pub.readContract({ address: pool, abi: poolAbi, functionName: "isImpaired" });
  const total = await pub.readContract({ address: pool, abi: poolAbi, functionName: "totalShielded" });
  const expectPay = await pub.readContract({ address: pool, abi: poolAbi, functionName: "previewWithdrawable", args: [AMT] });
  log("  isImpaired:", impaired, "| totalShielded:", total.toString(), "| previewWithdrawable(100e18):", expectPay.toString());
  if (!impaired) throw new Error("pool not impaired after burn");
  if (expectPay >= AMT) throw new Error("no haircut quoted");

  const rBefore = await pub.readContract({ address: stock, abi: stockAbi, functionName: "balanceOf", args: [R] });
  const leaves1 = [dep.proof.outputCommitments[0], dep.proof.outputCommitments[1]];
  t0 = now();
  const wd = await S.buildWithdrawProof(A.spend, A.enc, dep.note, AMT, R, leaves1, opts); // spend the FULL note
  const tWd = secs(t0);
  const wh = await send(pool, poolAbi, "transact", [p2t(wd.proof), e2t(wd.ext)]);
  log("  HAIRCUT withdraw of full 100-note (proof " + tWd + ")  tx:", EXPL + wh);
  const delta = (await pub.readContract({ address: stock, abi: stockAbi, functionName: "balanceOf", args: [R] })) - rBefore;
  const totalAfter = await pub.readContract({ address: pool, abi: poolAbi, functionName: "totalShielded" });
  log("  recipient delta:", delta.toString(), "(expected haircut", expectPay.toString() + ")  | totalShielded after:", totalAfter.toString());
  if (delta !== expectPay) throw new Error("haircut payout mismatch: got " + delta + " expected " + expectPay);
  if (delta >= AMT) throw new Error("payout was not a haircut");
  log("\n  ✅ HAIRCUT PROVEN: note survived the issuer burn and paid EXACTLY its pro-rata solvency share (" +
      (delta * 100n / AMT) + "% of par) — the holder is NOT frozen out. Same accounting the live AAPL/NVDA pools run.");
  log("\nJSON:", JSON.stringify({ flow: "(b) shielded STOCK adminBurn haircut", pool, stock, proof: tDep + " / " + tWd, deposit: dh, adminBurn: bh, withdraw: wh, paid: delta.toString() + " of " + AMT.toString(), status: "VERIFIED (throwaway instance, identical bytecode)" }, null, 2));
} finally {
  await unlink("./_sdk_hc.mjs").catch(() => {});
}
