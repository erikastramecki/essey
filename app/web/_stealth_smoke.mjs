// Essey Private — STEALTH PAY (ERC-5564/6538) full round-trip, on-chain. Mirrors the /private UI path exactly:
//   registerStealth  -> stealth.ts deriveStealthKeys + registry.registerKeys
//   payPrivate       -> stealth.ts generateStealthAddress + EsseyStealthPay.pay (transfer + announce, atomic)
//   scanPrivateInbox -> stealth.ts checkAnnouncement over the announcer's Announcement logs (VIEW key only)
//   sweepStealth     -> stealth.ts computeStealthPrivKey, gas-fund the stealth addr, ERC-20 transfer out
// No zk proof here — the stealth layer is secp256k1 ECDH, so every leg is fast. Run from app/web with DEPLOYER_PK.
//
// NOTE vs _private_e2e_smoke.mjs: that script's stealth leg scanned the announcer ONCE and hit RPC getLogs lag
// (the log wasn't indexed the instant after the pay receipt), so detection spuriously failed. Here the scan
// POLLS with retry — the same pattern the pool smokes use — which is what the UI's async scan effectively does.
import { build } from "esbuild";
import { createPublicClient, createWalletClient, http, defineChain, parseAbi, parseAbiItem, maxUint256 } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { unlink } from "fs/promises";

const RPC = "https://rpc.testnet.chain.robinhood.com";
const CHAIN = defineChain({ id: 46630, name: "RH", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const EXPL = "https://explorer.testnet.chain.robinhood.com/tx/";
const USDG = "0x7461E670d44FF4397A3E48030C5b06f6163a5De2";
const STEALTH_PAY = "0x36B750Ac415DC1f05E39C6D13A05FDbC29567403";
const STEALTH_REGISTRY = "0x7f28EbFfC1310849f4Cb5612e1Ff892fd892880f";
const STEALTH_ANNOUNCER = "0xe386345BB307166F59A191130230bA445F05F402";
const STEALTH_MSG = "Essey Private — derive my stealth keys.\n\nSigning this proves wallet control and generates the private keys for your shielded balance. It costs no gas and grants no approvals. Only sign this on essey.xyz.\n\nVersion: 1";
const SINK = "0x00000000000000000000000000000000deadbeef";

const erc20 = parseAbi(["function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)", "function mint(address,uint256)", "function transfer(address,uint256) returns (bool)"]);
const registryAbi = parseAbi(["function registerKeys(uint256 schemeId, bytes stealthMetaAddress)"]);
const payAbi = parseAbi(["function pay(address token, address stealthAddress, uint256 amount, bytes ephemeralPubKey, bytes metadata)"]);
const annItem = parseAbiItem("event Announcement(uint256 indexed schemeId, address indexed stealthAddress, address indexed caller, bytes ephemeralPubKey, bytes metadata)");

await build({ entryPoints: ["src/stealth.ts"], bundle: true, format: "esm", platform: "node", outfile: "_st_sm.mjs", external: ["viem", "@noble/*"] });
const St = await import("./_st_sm.mjs");
const pk = (process.env.DEPLOYER_PK.startsWith("0x") ? "" : "0x") + process.env.DEPLOYER_PK;
const acct = privateKeyToAccount(pk);
const pub = createPublicClient({ chain: CHAIN, transport: http(RPC) });
const w = createWalletClient({ account: acct, chain: CHAIN, transport: http(RPC) });
const log = (...a) => console.log(...a);
const bal = (who) => pub.readContract({ address: USDG, abi: erc20, functionName: "balanceOf", args: [who] });
const send = async (to, abi, fn, args) => { const h = await w.writeContract({ address: to, abi, functionName: fn, args, gas: 1_500_000n }); const r = await pub.waitForTransactionReceipt({ hash: h }); if (r.status !== "success") throw new Error(fn + " reverted"); return { h, r }; };

try {
  const SAMT = 5n * 10n ** 18n;
  const sig = await acct.signMessage({ message: STEALTH_MSG });
  const keys = St.deriveStealthKeys(sig);

  const reg = (await send(STEALTH_REGISTRY, registryAbi, "registerKeys", [1n, keys.metaAddress])).h;
  log("registerKeys  tx:", EXPL + reg);

  const p = St.generateStealthAddress(keys.metaAddress);
  if ((await bal(acct.address)) < SAMT) await send(USDG, erc20, "mint", [acct.address, SAMT]).catch(() => {});
  await send(USDG, erc20, "approve", [STEALTH_PAY, maxUint256]);
  const { h: payH, r: payRcpt } = await send(STEALTH_PAY, payAbi, "pay", [USDG, p.stealthAddress, SAMT, p.ephemeralPubKey, p.metadata]);
  log("pay 5 USDG -> one-time stealth", p.stealthAddress, "\n  tx:", EXPL + payH);
  if ((await bal(p.stealthAddress)) < SAMT) throw new Error("stealth addr didn't receive payment");

  // recipient scans with VIEW KEY only — POLL to beat getLogs indexing lag
  const fromB = payRcpt.blockNumber > 5n ? payRcpt.blockNumber - 5n : 0n;
  let owned = null;
  for (let i = 0; i < 15 && !owned; i++) {
    const head = await pub.getBlockNumber();
    for (let f = fromB; f <= head && !owned; f += 45001n) {
      const t = f + 45000n > head ? head : f + 45000n;
      const logs = await pub.getLogs({ address: STEALTH_ANNOUNCER, event: annItem, args: { schemeId: 1n }, fromBlock: f, toBlock: t });
      for (const l of logs) {
        if (l.args.stealthAddress.toLowerCase() !== p.stealthAddress.toLowerCase()) continue;
        const hit = St.checkAnnouncement({ stealthAddress: l.args.stealthAddress, ephemeralPubKey: l.args.ephemeralPubKey, metadata: l.args.metadata }, keys.viewPriv, keys.spendPub);
        if (hit.owned) owned = { sScalar: hit.sScalar };
      }
    }
    if (!owned) await new Promise((r) => setTimeout(r, 2500));
  }
  if (!owned) throw new Error("view-key scan did NOT detect the payment (after retries)");
  log("view-key scan DETECTED the payment (ownership proven from the announcement alone)");

  // sweep: derive the controlling key, gas-fund, transfer out
  const stealthPk = St.computeStealthPrivKey(keys.spendPriv, owned.sScalar);
  const sAcct = privateKeyToAccount(stealthPk);
  if (sAcct.address.toLowerCase() !== p.stealthAddress.toLowerCase()) throw new Error("derived key does NOT control the stealth address");
  log("derived stealth private key controls", sAcct.address, "✓");
  const sinkBefore = await bal(SINK);
  const gasPrice = await pub.getGasPrice();
  const need = gasPrice * 200_000n * 2n;
  const fundH = await w.sendTransaction({ to: sAcct.address, value: need, gas: 100_000n });
  await pub.waitForTransactionReceipt({ hash: fundH });
  log("gas-funded stealth addr  tx:", EXPL + fundH);
  const sw = createWalletClient({ account: sAcct, chain: CHAIN, transport: http(RPC) });
  const amt = await bal(p.stealthAddress);
  const sweepH = await sw.writeContract({ address: USDG, abi: erc20, functionName: "transfer", args: [SINK, amt], gas: 200_000n, gasPrice, type: "legacy" });
  const swR = await pub.waitForTransactionReceipt({ hash: sweepH });
  if (swR.status !== "success") throw new Error("sweep reverted");
  log("swept", (amt / 10n ** 18n), "USDG ->", SINK, "\n  tx:", EXPL + sweepH);
  const sinkDelta = (await bal(SINK)) - sinkBefore;
  if (sinkDelta !== amt) throw new Error("sweep delta mismatch");
  log("\n✅ STEALTH ROUND-TRIP PROVEN: register -> pay to one-time addr -> view-key detect -> spend with derived key");
  log("\nJSON:", JSON.stringify({ flow: "(e) stealth pay round-trip", stealthAddress: p.stealthAddress, register: reg, pay: payH, fund: fundH, sweep: sweepH, status: "VERIFIED" }, null, 2));
} finally {
  await unlink("./_st_sm.mjs").catch(() => {});
}
