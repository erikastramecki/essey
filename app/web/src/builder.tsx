import { useEffect, useRef, useState, useMemo, useCallback } from "react";
import type { BuilderData, Resolved } from "./pfp-resolve";
import { resolveSelection, catOptions, blockedCats, unavailableOptions } from "./pfp-resolve";
import { composite } from "./pfp-compositor";
import {
  createPublicClient, createWalletClient, custom, http, keccak256, toHex, formatEther,
  parseEventLogs, BaseError, ContractFunctionRevertedError,
} from "viem";
import { DON_NET, donChain, distributorAbi, donAbi, fetchWlProof, WL_STAGE0_COMMIT_ETA_MS } from "./don-config";

type G = "male" | "female";
// [categoryId, label, optional] — the panels the user picks from, in order.
const SELECT: Record<G, [string, string, boolean][]> = {
  male: [
    ["4 Body", "Bloodline", false], ["5 Suit", "Suit", false], ["13 Hair", "Hair", false],
    ["17 Face Mod", "Face Mod", true], ["15 Eye Mod", "Eye Mod", true], ["16 Glasses", "Glasses", true],
    ["22 Hat", "Hat", true], ["23 Ceasar", "Crown", true], ["24 Laser Eye", "Laser", true],
    ["19 Hand Grip", "Hand", true], ["18 Canes", "Cane", true], ["25 Snake", "Snake", true],
    ["20 Rings", "Ring", false], ["21 Wrist", "Wrist", false], ["26 AR", "AR Screen", true],
    ["2 The hawk", "Hawk", true], ["1 Background", "Background", false], ["3 Chair", "Chair", false],
  ],
  female: [
    ["3 Body", "Bloodline", false], ["4 Suits", "Suit", false], ["9 Hair", "Hair", false],
    ["8 Necklace", "Necklace", false], ["10 Hat", "Hat", true], ["11 Devilish", "Devilish", true],
    ["16 Neko", "Neko Mask", true], ["15 Earing", "Earring", false], ["13 Hand Grip", "Hand", true],
    ["14 Ring", "Ring", false], ["12 Wrist dec", "Wrist", false], ["17 AR", "AR Screen", true],
    ["18 phoenix eyes", "Phoenix Eyes", true], ["1 Chairs", "Chair", false],
  ],
};
// Strip a rarity suffix (#13.3) and a category-number prefix ("16 Glasses" -> "Glasses").
// Require whitespace after the prefix number so option names like "3D" keep their leading digit.
const clean = (v: string) => v.replace(/#\d+/g, "").replace(/^[\d.]+\s+/, "").trim();

// ---------------------------------------------------------------------------- chain plumbing
// Self-contained on don-config (live.ts is owned by a parallel workstream). One public client per page.
const pub = createPublicClient({ chain: donChain, transport: http(DON_NET.rpc) });
const ZERO32 = "0x0000000000000000000000000000000000000000000000000000000000000000";

const getEth = (): any => (window as any).ethereum;

/// keccak of the resolver key — the exact bytes32 the DonDistributor usedCombo ledger (and the
/// /api/reserve service) is keyed by.
const comboHash = (key: string): `0x${string}` => keccak256(toHex(key));

/// Switch the wallet to RH testnet, adding the chain first if the wallet doesn't know it (4902).
async function ensureChain(eth: any): Promise<void> {
  const hexId = "0x" + DON_NET.chainId.toString(16);
  try {
    await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
  } catch (e: any) {
    if (e?.code === 4001) throw e; // user said no — don't silently add the chain
    await eth.request({
      method: "wallet_addEthereumChain",
      params: [{
        chainId: hexId, chainName: donChain.name,
        nativeCurrency: donChain.nativeCurrency,
        rpcUrls: [DON_NET.rpc], blockExplorerUrls: [DON_NET.explorer],
      }],
    });
    await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
  }
}

/// Decoded custom-error name from a viem revert (ABI errors are in don-config), else null.
function revertName(e: unknown): string | null {
  if (e instanceof BaseError) {
    const r = e.walk((err) => err instanceof ContractFunctionRevertedError);
    if (r instanceof ContractFunctionRevertedError) return r.data?.errorName ?? null;
  }
  return null;
}

/// Map any tx failure to copy a builder can act on.
function friendly(e: any): string {
  const name = revertName(e) ?? "";
  const msg = String(e?.shortMessage || e?.message || "");
  const has = (n: string) => name === n || msg.includes(n);
  if (e?.code === 4001 || /rejected|denied/i.test(msg)) return "Transaction rejected in wallet.";
  if (has("ComboTaken")) return "Someone got this exact 1-of-1 first — tweak a trait for a fresh combo.";
  if (has("PublicClosed")) return "Public custom minting isn't open yet.";
  if (has("WrongFee")) return "The fee changed on-chain — retry to re-read it.";
  if (has("StakedNoReroll") || has("TraitsLocked")) return "Staked art is locked — staking freezes a Don's look forever.";
  if (has("BadProof")) return "Allowlist root isn't committed on-chain yet — claims open soon.";
  if (has("StageClosed")) return "This claim stage isn't open yet.";
  if (has("AlreadyClaimed")) return "This wallet already claimed its allocation.";
  if (has("LienActive")) return "This Don has an active loan lien — repay first.";
  if (has("NotOwner")) return "You don't own that Don.";
  return msg ? msg.slice(0, 140) : "Transaction failed.";
}

const short = (a: string) => a.slice(0, 6) + "…" + a.slice(-4);
const fmtEth = (wei?: bigint) => (wei === undefined ? "…" : formatEther(wei));
const txUrl = (hash: string) => `${DON_NET.explorer}/tx/${hash}`;

type TxState =
  | { status: "idle" }
  | { status: "busy"; note?: string }
  | { status: "pending"; hash: `0x${string}` }
  | { status: "success"; hash: `0x${string}`; id?: number; note?: string }
  | { status: "error"; msg: string };

type WlState = { stage: number; allocation: number; proof: `0x${string}`[]; claimed: boolean; rootLive: boolean; open: boolean };

export function BuilderPage() {
  const [gender, setGender] = useState<G>("male");
  const [data, setData] = useState<Partial<Record<G, BuilderData>>>({});
  const [picks, setPicks] = useState<Record<string, string>>({});
  const [seed, setSeed] = useState<number>(() => Math.floor(Math.random() * 1e9));
  const [res, setRes] = useState<Resolved | null>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    (["male", "female"] as G[]).forEach((g) => {
      if (!data[g]) fetch(`/builder/data_${g}.json`).then((r) => r.json()).then((d: BuilderData) => setData((p) => ({ ...p, [g]: d }))).catch(() => {});
    });
  }, []); // eslint-disable-line

  const [rsv, setRsv] = useState<{ status: "idle" | "busy" | "reserved" | "taken" | "offline" | "error"; by?: string }>({ status: "idle" });
  const d = data[gender];
  const opts = useMemo(() => (d ? catOptions(d) : {}), [d]);
  const blocked = useMemo(() => (d ? blockedCats(d, picks) : new Set<string>()), [d, picks]);
  // effective selection = picks minus anything a conflict blocked (preview == what the rules allow)
  const eff = useMemo(() => {
    const e: Record<string, string> = {};
    for (const [k, v] of Object.entries(picks)) if (!blocked.has(k)) e[k] = v;
    return e;
  }, [picks, blocked]);

  // Per-option availability, computed by the SAME resolver the preview uses (eff + seed): every option
  // here would be suppressed/conflicted-away if picked, so it's greyed out. Never drifts from the render.
  const unavail = useMemo(() => (d ? unavailableOptions(d, eff, seed) : new Map<string, Map<string, string>>()), [d, eff, seed]);
  // A category is fully dead when every selectable (non-None) option is inert -> collapse its row.
  const deadCats = useMemo(() => {
    const s = new Map<string, string>(); // cat -> representative reason
    for (const [cat] of SELECT[gender]) {
      const sel = (opts[cat] || []).filter((o) => o && o.toLowerCase() !== "none");
      const u = unavail.get(cat);
      if (sel.length > 0 && u && sel.every((o) => u.has(o))) s.set(cat, u.get(sel[0]) || "");
    }
    return s;
  }, [unavail, opts, gender]);
  // Manual expand-overrides survive only while a row stays dead; once it's live again it auto-expands.
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  useEffect(() => {
    setExpanded((prev) => {
      const next = new Set([...prev].filter((c) => deadCats.has(c)));
      return next.size === prev.size ? prev : next;
    });
  }, [deadCats]);
  const toggleExpand = useCallback((cat: string) => {
    setExpanded((prev) => { const n = new Set(prev); n.has(cat) ? n.delete(cat) : n.add(cat); return n; });
  }, []);

  const genRef = useRef(0);
  useEffect(() => {
    const cv = canvasRef.current; if (!d || !cv) return;
    const gen = ++genRef.current; // latest-wins: a slower earlier render must not clobber this one
    const r = resolveSelection(d, eff, seed);
    setRes(r); composite(cv, d, r.render, () => genRef.current === gen);
  }, [d, eff, seed]);

  // LIVE on RH testnet (chainId 46630) against the deployed DonDistributor — see don-config.ts.
  const MINT_LIVE = true;

  // -------------------------------------------------------------------------- wallet + chain reads
  const [wallet, setWallet] = useState<`0x${string}` | null>(null);
  const [fees, setFees] = useState<{ customFee?: bigint; rerollFee?: bigint; publicOpen?: boolean }>({});
  const [mint, setMint] = useState<TxState>({ status: "idle" });
  const [wl, setWl] = useState<WlState | null>(null);
  const [wlTx, setWlTx] = useState<TxState>({ status: "idle" });
  const [owned, setOwned] = useState<number[]>([]);
  const [rerollSel, setRerollSel] = useState<number | null>(null);
  const [rerollTx, setRerollTx] = useState<TxState>({ status: "idle" });

  // token changed -> reset reservation + settled tx states (a pending tx keeps its panel)
  useEffect(() => {
    setRsv({ status: "idle" });
    setMint((m) => (m.status === "error" || m.status === "success" ? { status: "idle" } : m));
    setRerollTx((m) => (m.status === "error" || m.status === "success" ? { status: "idle" } : m));
  }, [res?.key]);

  useEffect(() => { // fees + gate are public reads — no wallet needed
    if (!MINT_LIVE) return;
    Promise.all([
      pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "customFee" }),
      pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "rerollFee" }),
      pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "publicOpen" }),
    ]).then(([customFee, rerollFee, publicOpen]) => setFees({ customFee, rerollFee, publicOpen })).catch(() => {});
  }, [MINT_LIVE]);

  const loadOwned = useCallback(async (addr: `0x${string}`) => {
    try {
      const bal = await pub.readContract({ address: DON_NET.don, abi: donAbi, functionName: "balanceOf", args: [addr] });
      if (bal === 0n) { setOwned([]); return; }
      // Supply is tiny on testnet — scan ownerOf over ids 1..totalMinted (Don ids start at 1).
      const total = Number(await pub.readContract({ address: DON_NET.don, abi: donAbi, functionName: "totalMinted" }));
      const ids = Array.from({ length: Math.min(total, 500) }, (_, i) => BigInt(i + 1));
      const owners = await Promise.all(ids.map((id) =>
        pub.readContract({ address: DON_NET.don, abi: donAbi, functionName: "ownerOf", args: [id] }).catch(() => null)));
      setOwned(ids.filter((_, i) => owners[i]?.toLowerCase() === addr.toLowerCase()).map((id) => Number(id)));
    } catch { setOwned([]); }
  }, []);

  const loadWl = useCallback(async (addr: `0x${string}`) => {
    const p = await fetchWlProof(addr);
    if (!p) { setWl(null); return; }
    try {
      const stage = BigInt(p.stage);
      const [claimed, root, open] = await Promise.all([
        pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "claimed", args: [stage, addr] }),
        pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "stageRoot", args: [stage] }),
        pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "stageOpen", args: [stage] }),
      ]);
      setWl({ stage: p.stage, allocation: p.allocation, proof: p.proof, claimed, rootLive: root !== ZERO32, open });
    } catch {
      setWl({ stage: p.stage, allocation: p.allocation, proof: p.proof, claimed: false, rootLive: false, open: false });
    }
  }, []);

  const connect = useCallback(async (): Promise<`0x${string}`> => {
    const eth = getEth();
    if (!eth) throw new Error("No wallet found — install MetaMask or Rabby to mint.");
    const [addr] = (await eth.request({ method: "eth_requestAccounts" })) as `0x${string}`[];
    await ensureChain(eth);
    setWallet(addr);
    loadWl(addr); loadOwned(addr); // fire-and-forget context loads
    return addr;
  }, [loadWl, loadOwned]);

  const connectClick = useCallback(async () => {
    try { await connect(); } catch (e: any) { setMint({ status: "error", msg: friendly(e) }); }
  }, [connect]);

  useEffect(() => { // wallet account switches reset the session context
    const eth = getEth(); if (!eth?.on) return;
    const onAccounts = (accs: string[]) => {
      const a = (accs[0] as `0x${string}`) || null;
      setWallet(a); setWl(null); setOwned([]); setRerollSel(null);
      if (a) { loadWl(a); loadOwned(a); }
    };
    eth.on("accountsChanged", onAccounts);
    return () => { eth.removeListener?.("accountsChanged", onAccounts); };
  }, [loadWl, loadOwned]);

  const walletClient = useCallback(() => {
    if (!wallet) throw new Error("Connect a wallet first.");
    return createWalletClient({ account: wallet, chain: donChain, transport: custom(getEth()) });
  }, [wallet]);

  // -------------------------------------------------------------------------- soft hold (optional)
  const reserve = useCallback(async () => {
    if (!res) return; setRsv({ status: "busy" });
    try {
      const r = await fetch("/api/reserve", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ gender, forced: eff, seed, wallet: wallet ?? undefined }),
      });
      if (!r.ok) { setRsv({ status: "offline" }); return; } // 503 store-not-provisioned etc — never block the mint
      const resp = await r.json();
      if (resp.ok) setRsv({ status: "reserved" });
      else if (resp.taken) setRsv({ status: "taken", by: resp.by });
      else setRsv({ status: "offline" });
    } catch { setRsv({ status: "offline" }); }
  }, [res, gender, eff, seed, wallet]);

  // -------------------------------------------------------------------------- custom mint (~$10)
  const doMint = useCallback(async () => {
    if (!res) return;
    const key = res.key; // pin — picks may change while the tx is in flight
    const combo = comboHash(key);
    setMint({ status: "busy", note: "checking uniqueness…" });
    try {
      const addr = wallet ?? (await connect());
      const [used, open, fee] = await Promise.all([
        pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "usedCombo", args: [combo] }),
        pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "publicOpen" }),
        pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "customFee" }),
      ]);
      if (used) { setMint({ status: "error", msg: "Someone got this exact 1-of-1 first — tweak a trait for a fresh combo." }); return; }
      if (!open) { setMint({ status: "error", msg: "Public custom minting isn't open yet." }); return; }
      setFees((f) => ({ ...f, customFee: fee, publicOpen: open }));
      const { request } = await pub.simulateContract({
        address: DON_NET.distributor, abi: distributorAbi, functionName: "mintCustom",
        args: [combo], value: fee, account: addr,
      });
      const hash = await walletClient().writeContract(request);
      setMint({ status: "pending", hash });
      const rcpt = await pub.waitForTransactionReceipt({ hash });
      if (rcpt.status !== "success") { setMint({ status: "error", msg: "Transaction reverted on-chain." }); return; }
      let id: number | undefined;
      try {
        const logs = parseEventLogs({ abi: distributorAbi, logs: rcpt.logs, eventName: "CustomMinted" });
        if (logs[0]) id = Number(logs[0].args.id);
      } catch {}
      if (id === undefined) {
        try { id = Number(await pub.readContract({ address: DON_NET.don, abi: donAbi, functionName: "totalMinted" })); } catch {}
      }
      setMint({ status: "success", hash, id });
      loadOwned(addr);
    } catch (e: any) { setMint({ status: "error", msg: friendly(e) }); }
  }, [res, wallet, connect, walletClient, loadOwned]);

  // -------------------------------------------------------------------------- WL claim (free)
  const doClaimWl = useCallback(async () => {
    if (!res || !wl || !d || !wallet) return;
    setWlTx({ status: "busy", note: "building combos…" });
    try {
      // N DISTINCT resolver keys: the crafted selection first, then client-side re-rolls (random seeds).
      // If every category is forced, random seeds can't diverge — after a while drop the forced picks.
      const keys = new Set<string>([res.key]);
      let tries = 0;
      while (keys.size < wl.allocation && tries < 600) {
        const s = Math.floor(Math.random() * 1e9);
        keys.add(resolveSelection(d, tries < 300 ? eff : {}, s).key);
        tries++;
      }
      if (keys.size < wl.allocation) { setWlTx({ status: "error", msg: "Couldn't roll enough distinct combos — clear a few picks and retry." }); return; }
      const combos = [...keys].map(comboHash);
      const used = await Promise.all(combos.map((c) =>
        pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "usedCombo", args: [c] })));
      if (used[0]) { setWlTx({ status: "error", msg: "Someone got this exact 1-of-1 first — tweak a trait for a fresh combo." }); return; }
      if (used.some(Boolean)) { setWlTx({ status: "error", msg: "A rolled combo collided — hit claim again for a fresh roll." }); return; }
      const { request } = await pub.simulateContract({
        address: DON_NET.distributor, abi: distributorAbi, functionName: "claimWL",
        args: [BigInt(wl.stage), BigInt(wl.allocation), wl.proof, combos], account: wallet,
      });
      const hash = await walletClient().writeContract(request);
      setWlTx({ status: "pending", hash });
      const rcpt = await pub.waitForTransactionReceipt({ hash });
      if (rcpt.status !== "success") { setWlTx({ status: "error", msg: "Transaction reverted on-chain." }); return; }
      let firstId: number | undefined;
      try {
        const logs = parseEventLogs({ abi: distributorAbi, logs: rcpt.logs, eventName: "ClaimedWL" });
        if (logs[0]) firstId = Number(logs[0].args.firstId);
      } catch {}
      setWlTx({ status: "success", hash, id: firstId, note: `${wl.allocation} Don${wl.allocation > 1 ? "s" : ""} minted` });
      setWl({ ...wl, claimed: true });
      loadOwned(wallet);
    } catch (e: any) { setWlTx({ status: "error", msg: friendly(e) }); }
  }, [res, wl, d, wallet, eff, walletClient, loadOwned]);

  // -------------------------------------------------------------------------- reroll (~$3)
  const doReroll = useCallback(async () => {
    if (!res || rerollSel === null || !wallet) return;
    const combo = comboHash(res.key);
    setRerollTx({ status: "busy", note: "checking…" });
    try {
      const id = BigInt(rerollSel);
      const [used, locked, fee] = await Promise.all([
        pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "usedCombo", args: [combo] }),
        pub.readContract({ address: DON_NET.don, abi: donAbi, functionName: "locked", args: [id] }),
        pub.readContract({ address: DON_NET.distributor, abi: distributorAbi, functionName: "rerollFee" }),
      ]);
      if (used) { setRerollTx({ status: "error", msg: "That exact combo is already minted — tweak a trait first." }); return; }
      if (locked) { setRerollTx({ status: "error", msg: "Staked art is locked — staking freezes a Don's look forever." }); return; }
      setFees((f) => ({ ...f, rerollFee: fee }));
      const { request } = await pub.simulateContract({
        address: DON_NET.distributor, abi: distributorAbi, functionName: "reroll",
        args: [id, combo], value: fee, account: wallet,
      });
      const hash = await walletClient().writeContract(request);
      setRerollTx({ status: "pending", hash });
      const rcpt = await pub.waitForTransactionReceipt({ hash });
      if (rcpt.status !== "success") { setRerollTx({ status: "error", msg: "Transaction reverted on-chain." }); return; }
      setRerollTx({ status: "success", hash, id: rerollSel, note: `Don #${rerollSel} rerolled` });
    } catch (e: any) { setRerollTx({ status: "error", msg: friendly(e) }); }
  }, [res, rerollSel, wallet, walletClient]);

  const setPick = useCallback((cat: string, val: string) => {
    setPicks((p) => { const n = { ...p }; if (n[cat] === val) delete n[cat]; else n[cat] = val; return n; });
  }, []);
  const randomize = () => setSeed(Math.floor(Math.random() * 1e9));
  const clearAll = () => setPicks({});
  const switchGender = (g: G) => { setGender(g); setPicks({}); };

  const wlEtaHrs = Math.max(0, Math.ceil((WL_STAGE0_COMMIT_ETA_MS - Date.now()) / 36e5));
  const busyAny = mint.status === "busy" || mint.status === "pending";

  return (
    <div className="bld">
      <div className="bld-head">
        <h1>The builder</h1>
        <span>pick traits · rules keep it valid · {MINT_LIVE ? "mint your 1-of-1 on testnet" : "your 1-of-1 · minting soon"}</span>
      </div>
      <div className="bld-grid">
        {/* preview + actions (sticky) */}
        <div className="bld-stage">
          <div className="bld-canvas">
            <canvas ref={canvasRef} />
          </div>
          <div className="bld-row">
            {(["male", "female"] as G[]).map((g) => <button key={g} className={"bld-chip" + (gender === g ? " on" : "")} onClick={() => switchGender(g)}>{g}</button>)}
            <button className="bld-chip" onClick={randomize} style={{ marginLeft: "auto" }}>🎲 Shuffle rest</button>
            <button className="bld-chip" onClick={clearAll}>Clear</button>
          </div>
          <div className="bld-key">
            <span>Uniqueness key</span><br />
            <code>{res?.key.slice(0, 40)}…</code>
          </div>
          {MINT_LIVE ? (<>
            {/* wallet */}
            {wallet ? (
              <div className="bld-wallet">
                <span className="ok">● {short(wallet)}</span>
                <span>Robinhood testnet · {DON_NET.chainId}</span>
              </div>
            ) : (
              <button className="bld-chip" style={{ padding: 11, fontSize: 13 }} onClick={connectClick}>Connect wallet</button>
            )}

            {/* soft hold — optional, never blocks the mint */}
            <button onClick={reserve} disabled={rsv.status === "busy" || rsv.status === "reserved"}
              className={"bld-chip" + (rsv.status === "reserved" ? " good" : rsv.status === "taken" ? " taken" : "")}
              style={{ padding: 11, fontSize: 13 }}>
              {rsv.status === "reserved" ? "✓ Held for 30 min — mint below"
                : rsv.status === "taken" ? "✗ Held by someone — change a trait"
                : rsv.status === "busy" ? "Holding…"
                : rsv.status === "offline" ? "Holds offline — mint is still first-come"
                : "Hold this combo (optional, 30 min)"}
            </button>
            {rsv.status === "taken" && <div className="bld-hint">This exact combination is on hold or already minted. Change any trait for a fresh 1-of-1.</div>}
            {rsv.status === "offline" && <div className="bld-hint">The soft-hold service is offline — nothing is lost; minting stays first-come-first-served on-chain.</div>}

            {/* custom mint */}
            <div className="bld-hint">
              This exact combination is checked against the on-chain uniqueness ledger — once you mint it, no other Don
              can ever share it. Custom mint costs {fmtEth(fees.customFee)} ETH, and 100% of the fee buys stock for staked holders.
            </div>
            <button onClick={doMint} disabled={busyAny}
              className={"btn bld-mint " + (mint.status === "success" ? "bld-chip good" : "btn-gold")}
              style={{ opacity: busyAny ? 0.7 : 1, borderRadius: 999 }}>
              {mint.status === "busy" ? (mint.note || "Preparing…")
                : mint.status === "pending" ? "Minting — confirm in wallet / waiting for chain…"
                : mint.status === "success" ? `✓ Minted${mint.id !== undefined ? ` Don #${mint.id}` : ""}`
                : wallet ? `Mint this 1-of-1 — ${fmtEth(fees.customFee)} ETH`
                : "Connect & mint this 1-of-1"}
            </button>
            {fees.publicOpen === false && mint.status === "idle" && <div className="bld-hint">Public custom minting isn't open yet — the button will preflight again when you try.</div>}
            {(mint.status === "pending" || mint.status === "success") && (
              <div className="bld-hint">
                {mint.status === "success" && mint.id !== undefined && <>Don #{mint.id} is yours — this combo is retired forever. </>}
                <a href={txUrl(mint.hash)} target="_blank" rel="noreferrer">View on explorer ↗</a>
              </div>
            )}
            {mint.status === "error" && <div className="bld-hint err">{mint.msg}</div>}

            {/* WL claim */}
            {wallet && wl && (
              <div className="bld-panel">
                <div className="bld-panel-h">Allowlist</div>
                {wl.claimed ? (
                  <div className="bld-hint">✓ This wallet already claimed its {wl.allocation} free Don{wl.allocation > 1 ? "s" : ""}.</div>
                ) : !wl.rootLive || !wl.open ? (
                  <div className="bld-hint">
                    You're on the list — {wl.allocation} free Don{wl.allocation > 1 ? "s" : ""}. Claims open once the
                    allowlist root commits on-chain{wlEtaHrs > 0 ? ` (~${wlEtaHrs}h, after the 2-day timelock)` : " (any moment now)"}.
                  </div>
                ) : (<>
                  <div className="bld-hint">
                    You're on the list — {wl.allocation} free Don{wl.allocation > 1 ? "s" : ""}. Your whitelist allocation mints
                    for gas only — the first uses your crafted combo, the rest roll random traits. You can reroll the look as
                    many times as you like before you stake; staking locks it forever.
                  </div>
                  <button onClick={doClaimWl} disabled={wlTx.status === "busy" || wlTx.status === "pending" || wlTx.status === "success"}
                    className={"bld-chip " + (wlTx.status === "success" ? "good" : "on")} style={{ padding: 11, fontSize: 13 }}>
                    {wlTx.status === "busy" ? (wlTx.note || "Preparing…")
                      : wlTx.status === "pending" ? "Claiming — waiting for chain…"
                      : wlTx.status === "success" ? `✓ ${wlTx.note}${wlTx.id !== undefined ? ` — first is #${wlTx.id}` : ""}`
                      : `Claim ${wl.allocation} free Don${wl.allocation > 1 ? "s" : ""} (gas only)`}
                  </button>
                  {(wlTx.status === "pending" || wlTx.status === "success") && (
                    <div className="bld-hint"><a href={txUrl(wlTx.hash)} target="_blank" rel="noreferrer">View on explorer ↗</a></div>
                  )}
                  {wlTx.status === "error" && <div className="bld-hint err">{wlTx.msg}</div>}
                </>)}
              </div>
            )}

            {/* reroll an owned Don */}
            {wallet && owned.length > 0 && (
              <div className="bld-panel">
                <div className="bld-panel-h">Reroll one of your Dons</div>
                <div className="bld-hint">
                  Re-randomize this Don's traits for {fmtEth(fees.rerollFee)} ETH — unlimited, until it's staked. Your old
                  combo is released back to the pool and the fee buys stock for staked holders, all of it. The current
                  preview becomes the Don's new look.
                </div>
                <div className="bld-opts">
                  {owned.map((id) => (
                    <button key={id} className={"bld-opt" + (rerollSel === id ? " on" : "")} onClick={() => setRerollSel(rerollSel === id ? null : id)}>#{id}</button>
                  ))}
                </div>
                {rerollSel !== null && (<>
                  <button onClick={doReroll} disabled={rerollTx.status === "busy" || rerollTx.status === "pending"}
                    className={"bld-chip " + (rerollTx.status === "success" ? "good" : "on")} style={{ padding: 11, fontSize: 13, marginTop: 8 }}>
                    {rerollTx.status === "busy" ? (rerollTx.note || "Preparing…")
                      : rerollTx.status === "pending" ? "Rerolling — waiting for chain…"
                      : rerollTx.status === "success" ? `✓ ${rerollTx.note}`
                      : `Reroll Don #${rerollSel} to this preview — ${fmtEth(fees.rerollFee)} ETH`}
                  </button>
                  {(rerollTx.status === "pending" || rerollTx.status === "success") && (
                    <div className="bld-hint"><a href={txUrl(rerollTx.hash)} target="_blank" rel="noreferrer">View on explorer ↗</a></div>
                  )}
                  {rerollTx.status === "error" && <div className="bld-hint err">{rerollTx.msg}</div>}
                </>)}
              </div>
            )}
          </>) : (
            <button disabled title="Minting opens with the on-chain drop" className="bld-soon">
              ✦ Minting soon — this 1-of-1 will be claimable
            </button>
          )}
        </div>
        {/* category pickers */}
        <div className="bld-cats">
          {SELECT[gender].map(([cat, label, opt]) => {
            const options = (opts[cat] || []).filter((o) => o && o.toLowerCase() !== "none");
            const cur = picks[cat];
            const catUnavail = unavail.get(cat);
            const deadReason = deadCats.get(cat);
            // Fully-dead rows collapse to a compact header (auto-expand when live again; manual peek allowed).
            const collapsed = deadReason !== undefined && !expanded.has(cat);
            const pickHidden = cur !== undefined && cur !== "none" && !!catUnavail?.has(cur);
            if (collapsed) {
              return (
                <div key={cat} className="bld-cat collapsed" onClick={() => toggleExpand(cat)} title="Click to view options">
                  <div className="bld-cat-top">
                    <span className="cn">{label}</span>
                    <span className="cs">{deadReason}{pickHidden ? " · your pick is hidden" : ""} <span className="bld-exp">＋</span></span>
                  </div>
                </div>
              );
            }
            return (
              <div key={cat} className="bld-cat">
                <div className="bld-cat-top">
                  <span className="cn">{label}</span>
                  {deadReason !== undefined
                    ? <span className="cs bld-exp-btn" onClick={() => toggleExpand(cat)}>{deadReason} <span className="bld-exp">－</span></span>
                    : cat === "13 Hair" && res?.drivers.hat ? <span className="cs">under hat — sets beard/brows</span>
                    : catUnavail && catUnavail.size > 0 ? <span className="cs">some options unavailable</span>
                    : null}
                </div>
                <div className="bld-opts">
                  {opt && <button className={"bld-opt" + (cur === "none" ? " on" : "")} onClick={() => setPick(cat, "none")}>∅ None</button>}
                  {options.map((o) => {
                    const reason = o === cur ? undefined : catUnavail?.get(o); // keep the current pick clickable
                    return (
                      <button key={o} disabled={reason !== undefined} title={reason}
                        className={"bld-opt" + ((cur ? cur === o : false) ? " on" : "") + (reason !== undefined ? " unavail" : "")}
                        onClick={reason !== undefined ? undefined : () => setPick(cat, o)}>{clean(o)}</button>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
