// Essey Private — comprehensive on-chain E2E smoke for the shielded/private money flows NOT already covered by
// _pool_p1b_smoke.mjs (AAPL deposit→withdraw + SUPPLY supply→redeem) or _pool_p2_smoke.mjs (USDG deposit + private
// transfer + cross-recovery). This script drives the SAME modules the /private UI imports:
//   - poolsdk.ts  (buildDepositProof / buildWithdrawProof — identical to live.ts shieldDeposit/shieldWithdraw)
//   - stealth.ts  (deriveStealthKeys / generateStealthAddress / checkAnnouncement / computeStealthPrivKey —
//                  identical to live.ts registerStealth/payPrivate/scanPrivateInbox/sweepStealth)
// Every leg broadcasts a real testnet tx and logs the explorer link. Proving is SLOW (30–120s/proof); be patient.
//
// Flows proven here:
//   (a) shielded USDG pool  deposit → withdraw
//   (b) shielded AAPL       deposit → issuer adminBurn → withdraw with pro-rata HAIRCUT (note survives, not frozen)
//   (c) shielded NVDA       deposit → withdraw
//   (e) stealth pay         register → pay to one-time stealth addr → view-key scan → sweep round-trip
//
// Run from app/web with DEPLOYER_PK set (see rh-chain/.env TESTNET_DEPLOYER_PK).
//
// RESULTS OF THE VERIFICATION RUN (see docs/TESTNET-PRIVATE-E2E.md):
//   (a) USDG deposit→withdraw ............. VERIFIED here.
//   (c) NVDA deposit→withdraw ............. VERIFIED here.
//   (b) AAPL adminBurn haircut ............ CANNOT run against the LIVE pool: its backing token (0xaC6c… =
//       "ERC20Mock"/"E20M") has NO burn function, so the pool can't be impaired. The haircut is proven instead
//       against a THROWAWAY EsseyShieldedStock of identical bytecode in `_private_haircut_smoke.mjs`.
//   (e) stealth pay round-trip ............ the scan below fails intermittently on RPC getLogs lag (it scans
//       ONCE); the crypto is correct. The full round-trip WITH scan-retry + sweep is in `_stealth_smoke.mjs`.
import { build } from "esbuild";
import { createPublicClient, createWalletClient, http, defineChain, parseAbi, parseAbiItem, maxUint256, numberToHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { unlink } from "fs/promises";

const RPC = "https://rpc.testnet.chain.robinhood.com";
const CHAIN = defineChain({ id: 46630, name: "RH", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const EXPL = "https://explorer.testnet.chain.robinhood.com/tx/";

const USDG = "0x7461E670d44FF4397A3E48030C5b06f6163a5De2";
const AAPL = "0xaC6cd493e69eb82e8f113E33De8e5542F313B731";
const NVDA = "0x8393cc99FAC1CF79E3bEceA56f344159ddFd91E9";
const USDG_POOL = "0xcD7953960bbc1276F0856Dad5E502fc01cE629aB", USDG_DEPLOY = 97728346n;
const AAPL_POOL = "0x49f1C16FeDe8f6099Dc39d3b3C41B9890D51Ae53", AAPL_DEPLOY = 97832310n;
const NVDA_POOL = "0x8e358964666153cd604Cf15be575e75a34fE9cB3", NVDA_DEPLOY = 97832416n;
const STEALTH_PAY = "0x36B750Ac415DC1f05E39C6D13A05FDbC29567403";
const STEALTH_REGISTRY = "0x7f28EbFfC1310849f4Cb5612e1Ff892fd892880f";
const STEALTH_ANNOUNCER = "0xe386345BB307166F59A191130230bA445F05F402";
const STEALTH_DEPLOY = 97690338n;
const R = "0x000000000000000000000000000000000000dead"; // fresh sink so deltas are unambiguous
const POOL_MSG = "Essey Private — unlock my shielded balance.\n\nSigning this derives the private keys for your shielded USDG. It costs no gas and grants no approvals. Only sign this on essey.xyz.\n\nVersion: 1";
const STEALTH_MSG = "Essey Private — derive my stealth keys.\n\nSigning this proves wallet control and generates the private keys for your shielded balance. It costs no gas and grants no approvals. Only sign this on essey.xyz.\n\nVersion: 1";

const poolAbi = parseAbi([
  "function transact((uint256[2] a, uint256[2][2] b, uint256[2] c, bytes32 root, bytes32[2] inputNullifiers, bytes32[2] outputCommitments, uint256 publicAmount, bytes32 extDataHash) args, (address recipient, int256 extAmount, address relayer, uint256 fee, bytes encryptedOutput1, bytes encryptedOutput2) extData)",
]);
const stockAbi = parseAbi([
  "function totalShielded() view returns (uint256)",
  "function isImpaired() view returns (bool)",
  "function previewWithdrawable(uint256) view returns (uint256)",
]);
const erc20 = parseAbi(["function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)", "function mint(address,uint256)", "function transfer(address,uint256) returns (bool)"]);
const stockMock = parseAbi(["function mint(address,uint256)", "function adminBurn(address,uint256)"]);
const registryAbi = parseAbi(["function registerKeys(uint256 schemeId, bytes stealthMetaAddress)"]);
const stealthPayAbi = parseAbi(["function pay(address token, address stealthAddress, uint256 amount, bytes ephemeralPubKey, bytes metadata)"]);
const ncItem = parseAbiItem("event NewCommitment(bytes32 commitment, uint256 index, bytes encryptedOutput)");
const annItem = parseAbiItem("event Announcement(uint256 indexed schemeId, address indexed stealthAddress, address indexed caller, bytes ephemeralPubKey, bytes metadata)");

await build({ entryPoints: ["src/poolsdk.ts"], bundle: true, format: "esm", platform: "node", outfile: "_sdk_priv.mjs", external: ["viem", "@noble/*", "circomlibjs", "snarkjs"] });
await build({ entryPoints: ["src/stealth.ts"], bundle: true, format: "esm", platform: "node", outfile: "_stealth_priv.mjs", external: ["viem", "@noble/*"] });
const S = await import("./_sdk_priv.mjs");
const St = await import("./_stealth_priv.mjs");

const pk = (process.env.DEPLOYER_PK.startsWith("0x") ? "" : "0x") + process.env.DEPLOYER_PK;
const acct = privateKeyToAccount(pk);
const pub = createPublicClient({ chain: CHAIN, transport: http(RPC) });
const w = createWalletClient({ account: acct, chain: CHAIN, transport: http(RPC) });
const opts = { wasmUrl: process.cwd() + "/public/pool/transaction2.wasm", zkeyUrl: process.cwd() + "/public/pool/transaction2.zkey" };
const log = (...a) => console.log(...a);
const p2t = (p) => ({ a: [p.a[0], p.a[1]], b: [[p.b[0][0], p.b[0][1]], [p.b[1][0], p.b[1][1]]], c: [p.c[0], p.c[1]], root: numberToHex(p.root, { size: 32 }), inputNullifiers: [numberToHex(p.inputNullifiers[0], { size: 32 }), numberToHex(p.inputNullifiers[1], { size: 32 })], outputCommitments: [numberToHex(p.outputCommitments[0], { size: 32 }), numberToHex(p.outputCommitments[1], { size: 32 })], publicAmount: p.publicAmount, extDataHash: numberToHex(p.extDataHash, { size: 32 }) });
const e2t = (e) => ({ recipient: e.recipient, extAmount: e.extAmount, relayer: e.relayer, fee: e.fee, encryptedOutput1: e.encryptedOutput1, encryptedOutput2: e.encryptedOutput2 });
const bal = (t, who) => pub.readContract({ address: t, abi: erc20, functionName: "balanceOf", args: [who] });
const send = async (to, abi, fn, args, extra = {}) => { const h = await w.writeContract({ address: to, abi, functionName: fn, args, gas: 4_000_000n, ...extra }); const r = await pub.waitForTransactionReceipt({ hash: h }); if (r.status !== "success") throw new Error(fn + " reverted"); return { h, r }; };
async function chainOf(pool, deploy) { const head = await pub.getBlockNumber(); const res = []; for (let f = deploy; f <= head; f += 45001n) { const t = f + 45000n > head ? head : f + 45000n; const logs = await pub.getLogs({ address: pool, event: ncItem, fromBlock: f, toBlock: t }); for (const l of logs) res.push({ commitment: BigInt(l.args.commitment), index: Number(l.args.index), encryptedOutput: l.args.encryptedOutput ?? "0x" }); } res.sort((x, y) => x.index - y.index); return res; }
const now = () => Date.now();
const secs = (t0) => ((now() - t0) / 1000).toFixed(1) + "s";

const results = [];
const AMT = 100n * 10n ** 18n;

try {
  await S.initPool();
  const sig = await acct.signMessage({ message: POOL_MSG });
  const A = { spend: S.deriveKeypair(sig), enc: S.deriveEncKeypair(sig) };

  // ---------- (a) shielded USDG pool: deposit 100 -> withdraw 100 ----------
  try {
    log("\n=== (a) shielded USDG pool", USDG_POOL, "deposit -> withdraw ===");
    const rBefore = await bal(USDG, R);
    const leaves0 = (await chainOf(USDG_POOL, USDG_DEPLOY)).map((c) => c.commitment);
    let t0 = now();
    const dep = await S.buildDepositProof(A.spend, A.enc, AMT, leaves0, opts);
    const tDep = secs(t0);
    if ((await bal(USDG, acct.address)) < AMT) await send(USDG, erc20, "mint", [acct.address, AMT]).catch(() => {});
    await send(USDG, erc20, "approve", [USDG_POOL, maxUint256]);
    const dh = (await send(USDG_POOL, poolAbi, "transact", [p2t(dep.proof), e2t(dep.ext)])).h;
    log("  deposit(proof " + tDep + ")  tx:", EXPL + dh);
    const leaves1 = [...leaves0, dep.proof.outputCommitments[0], dep.proof.outputCommitments[1]];
    t0 = now();
    const wd = await S.buildWithdrawProof(A.spend, A.enc, dep.note, AMT, R, leaves1, opts);
    const tWd = secs(t0);
    const wh = (await send(USDG_POOL, poolAbi, "transact", [p2t(wd.proof), e2t(wd.ext)])).h;
    log("  withdraw(proof " + tWd + ")  tx:", EXPL + wh);
    const delta = (await bal(USDG, R)) - rBefore;
    log("  recipient USDG delta:", delta.toString());
    if (delta !== AMT) throw new Error("USDG withdraw delta != 100e18 (got " + delta + ")");
    log("  ✅ USDG deposit->withdraw round-trip OK");
    results.push({ flow: "(a) USDG deposit→withdraw", proof: tDep + " / " + tWd, dep: dh, wd: wh, status: "VERIFIED" });
  } catch (e) { log("  ❌ USDG flow FAILED:", e.message); results.push({ flow: "(a) USDG deposit→withdraw", status: "FAIL", err: e.message }); }

  // ---------- (b) shielded AAPL: deposit -> issuer adminBurn -> withdraw (pro-rata haircut) ----------
  try {
    log("\n=== (b) shielded AAPL", AAPL_POOL, "deposit -> adminBurn -> HAIRCUT withdraw ===");
    const rBefore = await bal(AAPL, R);
    const leaves0 = (await chainOf(AAPL_POOL, AAPL_DEPLOY)).map((c) => c.commitment);
    let t0 = now();
    const dep = await S.buildDepositProof(A.spend, A.enc, AMT, leaves0, opts);
    const tDep = secs(t0);
    if ((await bal(AAPL, acct.address)) < AMT) await send(AAPL, stockMock, "mint", [acct.address, AMT]);
    await send(AAPL, erc20, "approve", [AAPL_POOL, maxUint256]);
    const dh = (await send(AAPL_POOL, poolAbi, "transact", [p2t(dep.proof), e2t(dep.ext)])).h;
    log("  deposit 100 AAPL (proof " + tDep + ")  tx:", EXPL + dh);
    // Issuer burns 40% of the pool's backing -> pool now holds less than the outstanding note value.
    const poolBalPre = await bal(AAPL, AAPL_POOL);
    const burnAmt = (poolBalPre * 40n) / 100n;
    const bh = (await send(AAPL, stockMock, "adminBurn", [AAPL_POOL, burnAmt])).h;
    log("  issuer adminBurn(" + (burnAmt / 10n ** 18n) + " AAPL) from pool  tx:", EXPL + bh);
    const impaired = await pub.readContract({ address: AAPL_POOL, abi: stockAbi, functionName: "isImpaired" });
    const total = await pub.readContract({ address: AAPL_POOL, abi: stockAbi, functionName: "totalShielded" });
    const expectPay = await pub.readContract({ address: AAPL_POOL, abi: stockAbi, functionName: "previewWithdrawable", args: [AMT] });
    log("  isImpaired:", impaired, "| totalShielded:", total.toString(), "| previewWithdrawable(100):", expectPay.toString());
    if (!impaired) throw new Error("pool not impaired after burn");
    if (expectPay >= AMT) throw new Error("no haircut quoted (expectPay " + expectPay + " >= 100e18)");
    const leaves1 = [...leaves0, dep.proof.outputCommitments[0], dep.proof.outputCommitments[1]];
    t0 = now();
    // Withdraw the FULL note value (100) — the proof still spends the whole note; the contract pays the haircut.
    const wd = await S.buildWithdrawProof(A.spend, A.enc, dep.note, AMT, R, leaves1, opts);
    const tWd = secs(t0);
    const wh = (await send(AAPL_POOL, poolAbi, "transact", [p2t(wd.proof), e2t(wd.ext)])).h;
    log("  haircut withdraw (proof " + tWd + ")  tx:", EXPL + wh);
    const delta = (await bal(AAPL, R)) - rBefore;
    log("  recipient AAPL delta:", delta.toString(), "(expected haircut", expectPay.toString() + ")");
    if (delta !== expectPay) throw new Error("haircut payout mismatch: got " + delta + " expected " + expectPay);
    if (delta >= AMT) throw new Error("payout was not haircut");
    log("  ✅ AAPL adminBurn HAIRCUT: note survived the burn, paid exactly the pro-rata solvency share (not frozen out)");
    results.push({ flow: "(b) AAPL adminBurn haircut", proof: tDep + " / " + tWd, dep: dh, burn: bh, wd: wh, note: "paid " + delta + " of 100e18 (haircut)", status: "VERIFIED" });
  } catch (e) { log("  ❌ AAPL haircut flow FAILED:", e.message); results.push({ flow: "(b) AAPL adminBurn haircut", status: "FAIL", err: e.message }); }

  // ---------- (c) shielded NVDA: deposit -> withdraw ----------
  try {
    log("\n=== (c) shielded NVDA", NVDA_POOL, "deposit -> withdraw ===");
    const rBefore = await bal(NVDA, R);
    const leaves0 = (await chainOf(NVDA_POOL, NVDA_DEPLOY)).map((c) => c.commitment);
    let t0 = now();
    const dep = await S.buildDepositProof(A.spend, A.enc, AMT, leaves0, opts);
    const tDep = secs(t0);
    if ((await bal(NVDA, acct.address)) < AMT) await send(NVDA, stockMock, "mint", [acct.address, AMT]);
    await send(NVDA, erc20, "approve", [NVDA_POOL, maxUint256]);
    const dh = (await send(NVDA_POOL, poolAbi, "transact", [p2t(dep.proof), e2t(dep.ext)])).h;
    log("  deposit 100 NVDA (proof " + tDep + ")  tx:", EXPL + dh);
    const leaves1 = [...leaves0, dep.proof.outputCommitments[0], dep.proof.outputCommitments[1]];
    t0 = now();
    const wd = await S.buildWithdrawProof(A.spend, A.enc, dep.note, AMT, R, leaves1, opts);
    const tWd = secs(t0);
    const wh = (await send(NVDA_POOL, poolAbi, "transact", [p2t(wd.proof), e2t(wd.ext)])).h;
    log("  withdraw 100 NVDA (proof " + tWd + ")  tx:", EXPL + wh);
    const delta = (await bal(NVDA, R)) - rBefore;
    log("  recipient NVDA delta:", delta.toString());
    if (delta !== AMT) throw new Error("NVDA withdraw delta != 100e18 (got " + delta + ")");
    log("  ✅ NVDA deposit->withdraw round-trip OK");
    results.push({ flow: "(c) NVDA deposit→withdraw", proof: tDep + " / " + tWd, dep: dh, wd: wh, status: "VERIFIED" });
  } catch (e) { log("  ❌ NVDA flow FAILED:", e.message); results.push({ flow: "(c) NVDA deposit→withdraw", status: "FAIL", err: e.message }); }

  // ---------- (e) stealth pay: register -> pay one-time stealth addr -> view-key scan -> sweep ----------
  try {
    log("\n=== (e) stealth pay round-trip (ERC-5564/6538) ===");
    const SAMT = 5n * 10n ** 18n;
    const ssig = await acct.signMessage({ message: STEALTH_MSG });
    const keys = St.deriveStealthKeys(ssig);
    // register the meta-address (so others can look me up) — mirrors live.ts registerStealth
    const regH = (await send(STEALTH_REGISTRY, registryAbi, "registerKeys", [1n, keys.metaAddress])).h;
    log("  registerKeys  tx:", EXPL + regH);
    // sender computes a fresh one-time stealth address + pays USDG to it (mirrors live.ts payPrivate)
    const p = St.generateStealthAddress(keys.metaAddress);
    if ((await bal(USDG, acct.address)) < SAMT) await send(USDG, erc20, "mint", [acct.address, SAMT]).catch(() => {});
    await send(USDG, erc20, "approve", [STEALTH_PAY, maxUint256]);
    const { h: payH, r: payRcpt } = await send(STEALTH_PAY, stealthPayAbi, "pay", [USDG, p.stealthAddress, SAMT, p.ephemeralPubKey, p.metadata]);
    log("  pay 5 USDG -> stealth", p.stealthAddress, " tx:", EXPL + payH);
    const paidBal = await bal(USDG, p.stealthAddress);
    if (paidBal < SAMT) throw new Error("stealth addr did not receive the payment (bal " + paidBal + ")");
    // recipient scans the announcer with VIEW KEY only (mirrors live.ts scanPrivateInbox), from a recent window
    let fromB = payRcpt.blockNumber > 50n ? payRcpt.blockNumber - 50n : STEALTH_DEPLOY;
    const head = await pub.getBlockNumber();
    let owned = null;
    for (let f = fromB; f <= head; f += 45001n) {
      const t = f + 45000n > head ? head : f + 45000n;
      const logs = await pub.getLogs({ address: STEALTH_ANNOUNCER, event: annItem, args: { schemeId: 1n }, fromBlock: f, toBlock: t });
      for (const l of logs) {
        const hit = St.checkAnnouncement({ stealthAddress: l.args.stealthAddress, ephemeralPubKey: l.args.ephemeralPubKey, metadata: l.args.metadata }, keys.viewPriv, keys.spendPub);
        if (hit.owned && l.args.stealthAddress.toLowerCase() === p.stealthAddress.toLowerCase()) owned = { sScalar: hit.sScalar, stealthAddress: l.args.stealthAddress };
      }
    }
    if (!owned) throw new Error("view-key scan did NOT detect the payment");
    log("  ✓ view-key scan detected the payment at", owned.stealthAddress);
    // sweep: derive the stealth private key, fund it with gas, transfer the USDG out (mirrors live.ts sweepStealth)
    const stealthPk = St.computeStealthPrivKey(keys.spendPriv, owned.sScalar);
    const sAcct = privateKeyToAccount(stealthPk);
    if (sAcct.address.toLowerCase() !== p.stealthAddress.toLowerCase()) throw new Error("derived stealth key does not control the stealth address!");
    const SINK = "0x00000000000000000000000000000000DEADBeef";
    const sinkBefore = await bal(USDG, SINK);
    const gasPrice = await pub.getGasPrice();
    const need = gasPrice * 200_000n * 2n;
    const fundH = await w.sendTransaction({ to: sAcct.address, value: need, gas: 100_000n });
    await pub.waitForTransactionReceipt({ hash: fundH });
    log("  gas-funded the stealth addr  tx:", EXPL + fundH);
    const sw = createWalletClient({ account: sAcct, chain: CHAIN, transport: http(RPC) });
    const sweepH = await sw.writeContract({ address: USDG, abi: erc20, functionName: "transfer", args: [SINK, paidBal], gas: 200_000n, gasPrice, type: "legacy" });
    const swRcpt = await pub.waitForTransactionReceipt({ hash: sweepH });
    if (swRcpt.status !== "success") throw new Error("sweep reverted");
    log("  swept to", SINK, " tx:", EXPL + sweepH);
    const sinkDelta = (await bal(USDG, SINK)) - sinkBefore;
    if (sinkDelta !== paidBal) throw new Error("sweep delta mismatch: " + sinkDelta + " != " + paidBal);
    log("  ✅ stealth round-trip: paid -> detected by view key -> spent with derived key (", (sinkDelta / 10n ** 18n), "USDG )");
    results.push({ flow: "(e) stealth pay round-trip", proof: "n/a (secp256k1)", reg: regH, pay: payH, fund: fundH, sweep: sweepH, status: "VERIFIED" });
  } catch (e) { log("  ❌ stealth flow FAILED:", e.message); results.push({ flow: "(e) stealth pay round-trip", status: "FAIL", err: e.message }); }

  log("\n================ SUMMARY ================");
  for (const r of results) log(r.status === "VERIFIED" ? "✅" : "❌", r.flow, "-", r.status, r.err ? "(" + r.err + ")" : "");
  log("\nJSON:", JSON.stringify(results, null, 2));
} finally {
  await unlink("./_sdk_priv.mjs").catch(() => {});
  await unlink("./_stealth_priv.mjs").catch(() => {});
}
