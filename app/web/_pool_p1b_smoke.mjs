// On-chain smoke for the NEW shielded pools: a real deposit→withdraw round-trip on the AAPL STOCK pool and a
// real supply→redeem round-trip on the SUPPLY pool, driven by the SAME poolsdk prover the /private UI calls.
// Proves the deployed contracts + client proof-building work end-to-end. Run from app/web with DEPLOYER_PK set.
import { build } from "esbuild";
import { createPublicClient, createWalletClient, http, defineChain, parseAbi, parseAbiItem, maxUint256, numberToHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { unlink } from "fs/promises";

const RPC = "https://rpc.testnet.chain.robinhood.com/rpc";
const CHAIN = defineChain({ id: 46630, name: "RH", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const USDG = "0x7461E670d44FF4397A3E48030C5b06f6163a5De2", AAPL = "0xaC6cd493e69eb82e8f113E33De8e5542F313B731", LENDING = "0x283a4891458180f502E82E40470d3e06321ba748";
const R = "0x000000000000000000000000000000000000dead"; // a fresh recipient, so the withdrawal delta is unambiguous
const MSG = "Essey Private — unlock my shielded balance.\n\nSigning this derives the private keys for your shielded USDG. It costs no gas and grants no approvals. Only sign this on essey.xyz.\n\nVersion: 1";

const poolAbi = parseAbi([
  "function transact((uint256[2] a, uint256[2][2] b, uint256[2] c, bytes32 root, bytes32[2] inputNullifiers, bytes32[2] outputCommitments, uint256 publicAmount, bytes32 extDataHash) args, (address recipient, int256 extAmount, address relayer, uint256 fee, bytes encryptedOutput1, bytes encryptedOutput2) extData)",
  "function supply(uint256 usdgAmount, (uint256[2] a, uint256[2][2] b, uint256[2] c, bytes32 root, bytes32[2] inputNullifiers, bytes32[2] outputCommitments, uint256 publicAmount, bytes32 extDataHash) args, (address recipient, int256 extAmount, address relayer, uint256 fee, bytes encryptedOutput1, bytes encryptedOutput2) extData)",
]);
const erc20 = parseAbi(["function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)", "function mint(address,uint256)"]);
const erc4626 = parseAbi(["function previewDeposit(uint256) view returns (uint256)"]);
const ncItem = parseAbiItem("event NewCommitment(bytes32 commitment, uint256 index, bytes encryptedOutput)");

await build({ entryPoints: ["src/poolsdk.ts"], bundle: true, format: "esm", platform: "node", outfile: "_sdk_p1b.mjs", external: ["viem", "@noble/*", "circomlibjs", "snarkjs"] });
const S = await import("./_sdk_p1b.mjs");
const pk = (process.env.DEPLOYER_PK.startsWith("0x") ? "" : "0x") + process.env.DEPLOYER_PK;
const acct = privateKeyToAccount(pk);
const pub = createPublicClient({ chain: CHAIN, transport: http(RPC) });
const w = createWalletClient({ account: acct, chain: CHAIN, transport: http(RPC) });
const opts = { wasmUrl: process.cwd() + "/public/pool/transaction2.wasm", zkeyUrl: process.cwd() + "/public/pool/transaction2.zkey" };
const log = (...a) => console.log(...a);
const p2t = (p) => ({ a: [p.a[0], p.a[1]], b: [[p.b[0][0], p.b[0][1]], [p.b[1][0], p.b[1][1]]], c: [p.c[0], p.c[1]], root: numberToHex(p.root, { size: 32 }), inputNullifiers: [numberToHex(p.inputNullifiers[0], { size: 32 }), numberToHex(p.inputNullifiers[1], { size: 32 })], outputCommitments: [numberToHex(p.outputCommitments[0], { size: 32 }), numberToHex(p.outputCommitments[1], { size: 32 })], publicAmount: p.publicAmount, extDataHash: numberToHex(p.extDataHash, { size: 32 }) });
const e2t = (e) => ({ recipient: e.recipient, extAmount: e.extAmount, relayer: e.relayer, fee: e.fee, encryptedOutput1: e.encryptedOutput1, encryptedOutput2: e.encryptedOutput2 });
const bal = (t, who) => pub.readContract({ address: t, abi: erc20, functionName: "balanceOf", args: [who] });
const send = async (to, abi, fn, args) => { const h = await w.writeContract({ address: to, abi, functionName: fn, args, gas: 4_000_000n }); const r = await pub.waitForTransactionReceipt({ hash: h }); if (r.status !== "success") throw new Error(fn + " reverted"); return h; };
async function chainOf(pool, deploy) { const head = await pub.getBlockNumber(); const res = []; for (let f = deploy; f <= head; f += 45001n) { const t = f + 45000n > head ? head : f + 45000n; const logs = await pub.getLogs({ address: pool, event: ncItem, fromBlock: f, toBlock: t }); for (const l of logs) res.push({ commitment: BigInt(l.args.commitment), index: Number(l.args.index), encryptedOutput: l.args.encryptedOutput ?? "0x" }); } res.sort((x, y) => x.index - y.index); return res; }

try {
  await S.initPool();
  const sig = await acct.signMessage({ message: MSG });
  const A = { spend: S.deriveKeypair(sig), enc: S.deriveEncKeypair(sig) };
  const EXPL = "https://explorer.testnet.chain.robinhood.com/tx/";

  // ---------- 1) AAPL STOCK POOL: deposit 100 AAPL -> withdraw 100 AAPL to a fresh address ----------
  {
    const POOL = "0x49f1C16FeDe8f6099Dc39d3b3C41B9890D51Ae53", DEPLOY = 97832310n, AMT = 100n * 10n ** 18n;
    log("\n=== AAPL shielded stock pool", POOL, "===");
    const rBefore = await bal(AAPL, R);
    const leaves0 = (await chainOf(POOL, DEPLOY)).map((c) => c.commitment);
    const dep = await S.buildDepositProof(A.spend, A.enc, AMT, leaves0, opts);
    await send(AAPL, erc20, "approve", [POOL, maxUint256]);
    const dh = await send(POOL, poolAbi, "transact", [p2t(dep.proof), e2t(dep.ext)]);
    log("  shielded 100 AAPL  tx:", EXPL + dh);
    const leaves1 = [...leaves0, dep.proof.outputCommitments[0], dep.proof.outputCommitments[1]];
    const wd = await S.buildWithdrawProof(A.spend, A.enc, dep.note, AMT, R, leaves1, opts);
    const wh = await send(POOL, poolAbi, "transact", [p2t(wd.proof), e2t(wd.ext)]);
    log("  unshielded 100 AAPL -> " + R + "  tx:", EXPL + wh);
    const rAfter = await bal(AAPL, R);
    log("  recipient AAPL: before", rBefore.toString(), "after", rAfter.toString(), "delta", (rAfter - rBefore).toString());
    if (rAfter - rBefore !== AMT) throw new Error("AAPL withdrawal delta != 100e18");
    log("  ✅ AAPL round-trip: recipient received exactly 100 AAPL from a hidden note.");
  }

  // ---------- 2) SUPPLY POOL: supply 100 USDG (shield shares) -> redeem -> receive USDG+yield ----------
  {
    const POOL = "0xeF52251672d073fDD22f996D8665112BE005EecC", DEPLOY = 97808037n, USDG_IN = 100n * 10n ** 18n;
    log("\n=== USDG shielded SUPPLY pool", POOL, "===");
    const shares = await pub.readContract({ address: LENDING, abi: erc4626, functionName: "previewDeposit", args: [USDG_IN] });
    log("  previewDeposit(100 USDG) =", shares.toString(), "shares (the shielded note value)");
    const rBefore = await bal(USDG, R);
    const leaves0 = (await chainOf(POOL, DEPLOY)).map((c) => c.commitment);
    const dep = await S.buildDepositProof(A.spend, A.enc, shares, leaves0, opts); // note value = SHARES
    await send(USDG, erc20, "approve", [POOL, maxUint256]);
    const dh = await send(POOL, poolAbi, "supply", [USDG_IN, p2t(dep.proof), e2t(dep.ext)]);
    log("  supplied 100 USDG (shielded as shares)  tx:", EXPL + dh);
    const leaves1 = [...leaves0, dep.proof.outputCommitments[0], dep.proof.outputCommitments[1]];
    const wd = await S.buildWithdrawProof(A.spend, A.enc, dep.note, shares, R, leaves1, opts); // redeem the shares
    const wh = await send(POOL, poolAbi, "transact", [p2t(wd.proof), e2t(wd.ext)]);
    log("  withdrew (redeemed shares -> USDG) -> " + R + "  tx:", EXPL + wh);
    const rAfter = await bal(USDG, R);
    const got = rAfter - rBefore;
    log("  recipient USDG: before", rBefore.toString(), "after", rAfter.toString(), "delta", got.toString());
    if (got < 99n * 10n ** 18n) throw new Error("USDG redeemed < 99 (expected ~100)");
    log("  ✅ SUPPLY round-trip: recipient received", (got / 10n ** 16n).toString(), "/100 * 1e-2 USDG (principal + any accrued yield) from a hidden share-note.");
  }

  log("\nALL ROUND-TRIPS PASSED — both new pools work end-to-end on-chain with the real UI prover.");
} finally {
  await unlink("./_sdk_p1b.mjs").catch(() => {});
}
