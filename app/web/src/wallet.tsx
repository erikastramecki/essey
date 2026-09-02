// Wallet connect — a deliberately small EVM connector built on EIP-6963 (Multi Injected Provider
// Discovery), no wallet SDK. One picker's worth of functionality doesn't justify 300KB of
// wagmi + multi-chain adapters; when the app pages grow real transaction flows, this is the seam
// where wagmi/viem slots in. CoinVoyage is the planned acquisition ONRAMP (API-driven, buy-crypto)
// and rides on top of this connection, not inside it — its PayKit connector is a wagmi + Solana/Sui
// wallet-adapter stack aimed at its own PayButton payment flow and does not hand back a raw
// EIP-1193 provider for our deep custom viem calls (mint / borrow / stealth sweeps), so we own the
// connection ourselves and keep it viem-only.
//
// Why EIP-6963 and not `window.ethereum`: a blind `window.ethereum` grab is "last-wallet-wins", so
// with multiple extensions (or a Solana-first wallet like Phantom) it can resolve to a NON-EVM
// provider and surface a Solana prompt. EIP-6963 instead has every wallet ANNOUNCE its EIP-1193
// provider on a dedicated event channel; we collect them all and let the user PICK. Phantom is not
// excluded — it announces its EVM provider here and shows up as a selectable wallet; picking it
// connects EVM on Robinhood Chain like any other.
import {
  createContext, useContext, useEffect, useRef, useState, useSyncExternalStore, type ReactNode,
} from "react";
import { createPortal } from "react-dom";

// The chain the app targets. TESTNET while the playground is live; flips to mainnet (4663) with
// the real deployment. 46630 = 0xB626.
export const RH_CHAIN = {
  chainId: "0xb626", // 46630
  chainName: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: ["https://rpc.testnet.chain.robinhood.com"],
  blockExplorerUrls: ["https://explorer.testnet.chain.robinhood.com"],
};

export type Eip1193 = {
  request: (a: { method: string; params?: unknown[] }) => Promise<unknown>;
  on?: (e: string, cb: (x: unknown) => void) => void;
  removeListener?: (e: string, cb: (x: unknown) => void) => void;
};

// EIP-6963 provider announcement shape.
type ProviderInfo = { uuid: string; name: string; icon: string; rdns: string };
export type ProviderDetail = { info: ProviderInfo; provider: Eip1193 };

const LEGACY_RDNS = "legacy.injected"; // synthetic id for a pre-6963 window.ethereum fallback
const SEL_KEY = "essey.wallet.rdns"; // persisted selection so refreshes re-bind the same wallet

// ---------------------------------------------------------------------------------------------
// EIP-6963 discovery store (module-level singleton — one per tab, shared by every consumer).
// ---------------------------------------------------------------------------------------------
const discovered = new Map<string, ProviderDetail>(); // keyed by rdns; dedupes re-announcements
const storeSubs = new Set<() => void>();
let storeSnapshot: ProviderDetail[] = []; // cached array so useSyncExternalStore stays stable
const rebuildSnapshot = () => { storeSnapshot = [...discovered.values()]; };
const emitStore = () => { rebuildSnapshot(); storeSubs.forEach((s) => s()); };

if (typeof window !== "undefined") {
  window.addEventListener("eip6963:announceProvider", (e: Event) => {
    const detail = (e as CustomEvent<ProviderDetail>).detail;
    if (!detail?.info?.rdns || !detail.provider) return;
    discovered.set(detail.info.rdns, detail);
    emitStore();
  });
  // Ask any wallet that loaded before us to (re)announce.
  window.dispatchEvent(new Event("eip6963:requestProvider"));
}

const subscribeStore = (cb: () => void) => { storeSubs.add(cb); return () => { storeSubs.delete(cb); }; };
const getStoreSnapshot = () => storeSnapshot;
/// React hook: the live list of announced EIP-6963 providers, re-rendering as wallets announce.
const useProviders = () => useSyncExternalStore(subscribeStore, getStoreSnapshot, getStoreSnapshot);

const legacyInjected = (): Eip1193 | null => (window as { ethereum?: Eip1193 }).ethereum ?? null;

/// Does a provider answer `eth_chainId`? This is our only Solana guard: a genuine EVM provider
/// returns a hex chainId; a non-EVM one throws or returns junk. We never name-match wallets — we
/// verify the capability. (EIP-6963's EVM channel already only carries EVM providers; this backstops
/// the legacy `window.ethereum` fallback, where a Solana-first wallet could have installed itself.)
async function isEvm(p: Eip1193): Promise<boolean> {
  try {
    const id = await p.request({ method: "eth_chainId" });
    return typeof id === "string" && id.startsWith("0x");
  } catch { return false; }
}

// ---------------------------------------------------------------------------------------------
// The SELECTED provider — the single app-wide EIP-1193 the whole app signs through. `live.ts`
// (`getSelectedProvider`) and `builder.tsx` (`getEth`) both read this instead of `window.ethereum`,
// so every signing path routes to the wallet the user actually picked.
// ---------------------------------------------------------------------------------------------
let selected: Eip1193 | null = null;
const selSubs = new Set<() => void>();
const emitSel = () => selSubs.forEach((s) => s());

/// The app-wide selected EIP-1193 provider, or null if the user hasn't connected yet.
export function getSelectedProvider(): Eip1193 | null { return selected; }

function setSelected(provider: Eip1193 | null, rdns: string | null) {
  selected = provider;
  try {
    if (rdns) localStorage.setItem(SEL_KEY, rdns);
    else localStorage.removeItem(SEL_KEY);
  } catch { /* private-mode / disabled storage — selection just won't persist */ }
  emitSel();
}

const subscribeSel = (cb: () => void) => { selSubs.add(cb); return () => { selSubs.delete(cb); }; };
/// React hook: the current selected provider, re-rendering when the user picks/switches wallets.
export const useSelectedProvider = () =>
  useSyncExternalStore(subscribeSel, getSelectedProvider, getSelectedProvider);

// ---------------------------------------------------------------------------------------------
// Shared picker bridge. WalletProvider renders ONE picker modal at the app root and registers an
// opener here, so any consumer (the header ConnectButton OR builder.tsx's own connect) can raise
// the same picker and reuse the same wallet selection. `pickProvider` resolves with the chosen
// EIP-1193 provider (already stored as the app-wide selection) or null if dismissed / none EVM.
// ---------------------------------------------------------------------------------------------
let openPickerImpl: (() => Promise<ProviderDetail | null>) | null = null;

export async function pickProvider(): Promise<Eip1193 | null> {
  if (selected) return selected; // already connected — reuse it
  if (openPickerImpl) {
    const detail = await openPickerImpl();
    if (!detail) return null;
    setSelected(detail.provider, detail.info.rdns); // make the pick the app-wide selection
    return detail.provider;
  }
  // Headless fallback (WalletProvider not mounted): auto-pick the sole EVM provider if there is one.
  const list = storeSnapshot;
  if (list.length === 1 && (await isEvm(list[0].provider))) {
    setSelected(list[0].provider, list[0].info.rdns);
    return list[0].provider;
  }
  const legacy = legacyInjected();
  if (list.length === 0 && legacy && (await isEvm(legacy))) {
    setSelected(legacy, LEGACY_RDNS);
    return legacy;
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// Chain plumbing, bound to whichever provider is passed (never a blind global).
// ---------------------------------------------------------------------------------------------
/// Switch (or add) `p` to Robinhood Chain. Extracted so a wrong-chain user can re-trigger it from an
/// inline button, not only inside the initial connect.
async function switchChainOn(p: Eip1193): Promise<boolean> {
  try {
    await p.request({ method: "wallet_switchEthereumChain", params: [{ chainId: RH_CHAIN.chainId }] });
  } catch (e) {
    // 4001 = user rejected — respect it. Otherwise (e.g. 4902 unknown chain) offer to add it.
    if ((e as { code?: number })?.code === 4001) return false;
    await p.request({ method: "wallet_addEthereumChain", params: [RH_CHAIN] }).catch(() => {});
  }
  const now = (await p.request({ method: "eth_chainId" })) as string;
  return String(now).toLowerCase() === RH_CHAIN.chainId;
}

type WalletState = {
  address: string | null;
  chainOk: boolean;
  hasProvider: boolean; // at least one EVM wallet is available to pick
  ready: boolean; // the silent reconnect probe has finished — safe to route on address
  connect: () => Promise<void>; // opens the picker, then connects the chosen wallet
  switchChain: () => Promise<void>;
  error: string | null;
};

const Ctx = createContext<WalletState>({
  address: null, chainOk: false, hasProvider: false, ready: false,
  connect: async () => {}, switchChain: async () => {}, error: null,
});
export const useWallet = () => useContext(Ctx);

export function WalletProvider({ children }: { children: ReactNode }) {
  const providers = useProviders();
  const [address, setAddress] = useState<string | null>(null);
  const [chainOk, setChainOk] = useState(false);
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [hasEvm, setHasEvm] = useState(false); // includes an EVM-capable legacy provider
  const selVersion = useSelectedProvider(); // re-run listener wiring when the selection changes

  // Is there any EVM wallet to offer? EIP-6963 providers count immediately; a lone legacy
  // window.ethereum only counts once it proves it speaks EVM (so we never route to Solana).
  useEffect(() => {
    if (providers.length > 0) { setHasEvm(true); return; }
    let live = true;
    const legacy = legacyInjected();
    if (legacy) isEvm(legacy).then((ok) => { if (live) setHasEvm(ok); });
    else setHasEvm(false);
    return () => { live = false; };
  }, [providers]);

  // Bind accountsChanged / chainChanged to the SELECTED provider (re-bound whenever it changes).
  useEffect(() => {
    const p = getSelectedProvider();
    if (!p?.on) return;
    const onAccounts = (a: unknown) => setAddress(Array.isArray(a) && a[0] ? String(a[0]) : null);
    const onChain = (c: unknown) => setChainOk(String(c).toLowerCase() === RH_CHAIN.chainId);
    p.on("accountsChanged", onAccounts);
    p.on("chainChanged", onChain);
    return () => { p.removeListener?.("accountsChanged", onAccounts); p.removeListener?.("chainChanged", onChain); };
  }, [selVersion]);

  // Silent reconnect: if a prior selection is remembered, wait for that wallet to announce (or fall
  // back to a legacy EVM provider), then read eth_accounts WITHOUT prompting so a returning user
  // stays signed in across refreshes. `ready` gates route decisions until this settles.
  const reconnectedRef = useRef(false);
  useEffect(() => {
    if (reconnectedRef.current) return;
    let rdns: string | null = null;
    try { rdns = localStorage.getItem(SEL_KEY); } catch { /* storage disabled */ }
    if (!rdns) { setReady(true); return; } // never connected here before — nothing to restore

    const finish = () => { if (!reconnectedRef.current) { reconnectedRef.current = true; setReady(true); } };

    const attempt = async () => {
      if (reconnectedRef.current) return true;
      let p: Eip1193 | null = discovered.get(rdns!)?.provider ?? null;
      if (!p && rdns === LEGACY_RDNS) { const l = legacyInjected(); if (l && (await isEvm(l))) p = l; }
      if (!p) return false; // remembered wallet hasn't announced yet — keep waiting
      reconnectedRef.current = true;
      setSelected(p, rdns);
      try {
        const accts = (await p.request({ method: "eth_accounts" })) as string[];
        if (accts?.[0]) {
          setAddress(accts[0]);
          const chain = (await p.request({ method: "eth_chainId" })) as string;
          setChainOk(String(chain).toLowerCase() === RH_CHAIN.chainId);
        }
      } catch { /* not actually authorized — user simply isn't connected */ }
      setReady(true);
      return true;
    };

    let unsub = () => {};
    unsub = subscribeStore(() => { attempt(); });
    attempt();
    // Remembered wallet may be uninstalled / slow to announce — don't hang the UI on it.
    const t = setTimeout(finish, 1200);
    return () => { unsub(); clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /// Run the full connect handshake against a chosen provider: authorize accounts, land on RH chain.
  const connectWith = async (p: Eip1193, rdns: string) => {
    setSelected(p, rdns);
    const accounts = (await p.request({ method: "eth_requestAccounts" })) as string[];
    setAddress(accounts[0] ?? null);
    const chain = (await p.request({ method: "eth_chainId" })) as string;
    if (String(chain).toLowerCase() !== RH_CHAIN.chainId) setChainOk(await switchChainOn(p));
    else setChainOk(true);
  };

  // Picker modal state + the resolver `pickProvider` awaits.
  const [pickerOpen, setPickerOpen] = useState(false);
  const resolverRef = useRef<((d: ProviderDetail | null) => void) | null>(null);

  useEffect(() => {
    openPickerImpl = () => new Promise<ProviderDetail | null>((resolve) => {
      resolverRef.current = resolve;
      setPickerOpen(true);
    });
    return () => { openPickerImpl = null; };
  }, []);

  const resolvePicker = (d: ProviderDetail | null) => {
    setPickerOpen(false);
    const r = resolverRef.current; resolverRef.current = null;
    r?.(d);
  };

  const connect = async () => {
    setError(null);
    // Raise the same shared modal the module-level pickProvider uses, then connect the choice.
    const detail = openPickerImpl ? await openPickerImpl() : null;
    if (!detail) return; // dismissed
    try {
      await connectWith(detail.provider, detail.info.rdns);
    } catch (e) {
      setError((e as { message?: string })?.message ?? "Connection rejected.");
    }
  };

  const switchChain = async () => {
    const p = getSelectedProvider();
    if (!p) return;
    setChainOk(await switchChainOn(p));
  };

  return (
    <Ctx.Provider value={{ address, chainOk, hasProvider: hasEvm, ready, connect, switchChain, error }}>
      {children}
      {pickerOpen && (
        <WalletPicker
          providers={providers}
          onPick={(d) => resolvePicker(d)}
          onClose={() => resolvePicker(null)}
        />
      )}
    </Ctx.Provider>
  );
}

// ---------------------------------------------------------------------------------------------
// The picker modal — one clean list of every announced EVM wallet (name + icon), in the ledger-floor
// design tokens. Legacy window.ethereum appears as a single "Browser Wallet" row only if it proves
// EVM. If nothing EVM is found we say so and point at how to install one — never a Solana prompt.
// ---------------------------------------------------------------------------------------------
function WalletPicker({ providers, onPick, onClose }: {
  providers: ProviderDetail[];
  onPick: (d: ProviderDetail) => void;
  onClose: () => void;
}) {
  // Fallback synthetic row for a pre-6963 injected provider, gated on an EVM capability probe.
  const [legacy, setLegacy] = useState<ProviderDetail | null>(null);
  const [probing, setProbing] = useState(providers.length === 0);
  useEffect(() => {
    if (providers.length > 0) { setProbing(false); return; }
    let live = true;
    const l = legacyInjected();
    if (!l) { setProbing(false); return; }
    setProbing(true);
    isEvm(l).then((ok) => {
      if (!live) return;
      setLegacy(ok ? { info: { uuid: LEGACY_RDNS, name: "Browser Wallet", icon: "", rdns: LEGACY_RDNS }, provider: l } : null);
      setProbing(false);
    });
    return () => { live = false; };
  }, [providers]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const list = providers.length > 0 ? providers : (legacy ? [legacy] : []);

  return createPortal(
    <div className="wallet-modal" onClick={onClose} role="dialog" aria-modal="true" aria-label="Choose a wallet">
      <div className="wallet-sheet" onClick={(e) => e.stopPropagation()}>
        <div className="wallet-sheet-h">
          <span>Connect a wallet</span>
          <button onClick={onClose} aria-label="close">×</button>
        </div>
        <p className="wallet-sheet-sub">Choose your EVM wallet. It connects to Robinhood Chain.</p>
        {list.length > 0 ? (
          <div className="wallet-list">
            {list.map((d) => (
              <button key={d.info.rdns} className="wallet-opt" onClick={() => onPick(d)}>
                {d.info.icon
                  ? <img className="wallet-opt-ic" src={d.info.icon} alt="" width={26} height={26} />
                  : <span className="wallet-opt-ic wallet-opt-ic--blank" aria-hidden />}
                <b>{d.info.name}</b>
              </button>
            ))}
          </div>
        ) : probing ? (
          <p className="wallet-empty">Looking for wallets…</p>
        ) : (
          <p className="wallet-empty">
            No EVM wallet found. Install{" "}
            <a href="https://metamask.io/download/" target="_blank" rel="noreferrer">MetaMask</a>,{" "}
            <a href="https://rabby.io/" target="_blank" rel="noreferrer">Rabby</a>, or another EVM wallet,
            then reload this page.
          </p>
        )}
      </div>
    </div>,
    document.body,
  );
}

const short = (a: string) => a.slice(0, 6) + "…" + a.slice(-4);

/// The connect control. Honest states: no provider, wrong chain (with a working switch), connected.
export function ConnectButton() {
  const w = useWallet();
  if (w.address && !w.chainOk) {
    // Connected but on the wrong network — give them a button that actually fixes it (not a dead chip).
    return <button className="btn btn-gold wallet-switch" onClick={w.switchChain}>Switch to Robinhood Chain</button>;
  }
  if (w.address) {
    return (
      <span className="wallet-chip num" title="Connected to Robinhood Chain">
        <span className="dot" style={{ background: "var(--good)" }} />
        {short(w.address)}
      </span>
    );
  }
  // No EVM wallet available at all (most tweet/mobile-Safari traffic) — don't dead-end at a Connect
  // button that just errors; point them at how to get one. Wallets inject on load, so reload after.
  if (w.ready && !w.hasProvider) {
    return (
      <span className="wallet-wrap">
        <a className="btn btn-gold" href="https://metamask.io/download/" target="_blank" rel="noreferrer">Install a wallet ↗</a>
        <i className="wallet-err">You'll need a crypto wallet like MetaMask. Install it, then reload this page.</i>
      </span>
    );
  }
  return (
    <span className="wallet-wrap">
      <button className="btn btn-ghost" onClick={w.connect}>Connect wallet</button>
      {w.error && <i className="wallet-err">{w.error}</i>}
    </span>
  );
}
