// Wallet connect — a deliberately small injected-provider connector (EIP-1193), no wallet SDK.
// One button's worth of functionality doesn't justify 300KB of dependency; when the app pages grow
// real transaction flows, this is the seam where wagmi/viem slots in. CoinVoyage is the planned
// acquisition onramp (API-driven) and rides on top of this connection, not inside it.
import { createContext, useContext, useEffect, useState, type ReactNode } from "react";

// The chain the app targets. TESTNET while the playground is live; flips to mainnet (4663) with
// the real deployment. 46630 = 0xB626.
export const RH_CHAIN = {
  chainId: "0xb626", // 46630
  chainName: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: ["https://rpc.testnet.chain.robinhood.com"],
  blockExplorerUrls: ["https://explorer.testnet.chain.robinhood.com"],
};

type Eip1193 = { request: (a: { method: string; params?: unknown[] }) => Promise<unknown>; on?: (e: string, cb: (x: unknown) => void) => void; removeListener?: (e: string, cb: (x: unknown) => void) => void };
const injected = (): Eip1193 | null => (window as { ethereum?: Eip1193 }).ethereum ?? null;

type WalletState = {
  address: string | null;
  chainOk: boolean;
  hasProvider: boolean;
  ready: boolean; // the silent reconnect probe has finished — safe to route on address
  connect: () => Promise<void>;
  switchChain: () => Promise<void>;
  error: string | null;
};

const Ctx = createContext<WalletState>({ address: null, chainOk: false, hasProvider: false, ready: false, connect: async () => {}, switchChain: async () => {}, error: null });
export const useWallet = () => useContext(Ctx);

export function WalletProvider({ children }: { children: ReactNode }) {
  const [address, setAddress] = useState<string | null>(null);
  const [chainOk, setChainOk] = useState(false);
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const eth = injected();

  useEffect(() => {
    if (!eth?.on) return;
    const onAccounts = (a: unknown) => setAddress(Array.isArray(a) && a[0] ? String(a[0]) : null);
    const onChain = (c: unknown) => setChainOk(String(c).toLowerCase() === RH_CHAIN.chainId);
    eth.on("accountsChanged", onAccounts);
    eth.on("chainChanged", onChain);
    return () => { eth.removeListener?.("accountsChanged", onAccounts); eth.removeListener?.("chainChanged", onChain); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Silent reconnect: eth_accounts returns already-authorized accounts WITHOUT prompting, so a user who
  // connected before stays signed in across refreshes. `ready` gates route decisions until this settles.
  useEffect(() => {
    const p = injected();
    if (!p) { setReady(true); return; }
    (async () => {
      try {
        const accts = (await p.request({ method: "eth_accounts" })) as string[];
        if (accts?.[0]) {
          setAddress(accts[0]);
          const chain = (await p.request({ method: "eth_chainId" })) as string;
          setChainOk(chain.toLowerCase() === RH_CHAIN.chainId);
        }
      } catch { /* ignore — user simply isn't connected */ }
      finally { setReady(true); }
    })();
  }, []);

  // Switch (or add) to Robinhood Chain testnet. Extracted so a wrong-chain user can re-trigger it
  // from an inline button, not only inside the initial connect.
  const switchChain = async (): Promise<boolean> => {
    const p = injected();
    if (!p) return false;
    try {
      await p.request({ method: "wallet_switchEthereumChain", params: [{ chainId: RH_CHAIN.chainId }] });
    } catch {
      // 4902 = unknown chain: offer to add it. Any other failure falls through to a false result,
      // which the UI reports honestly rather than pretending.
      await p.request({ method: "wallet_addEthereumChain", params: [RH_CHAIN] }).catch(() => {});
    }
    const now = (await p.request({ method: "eth_chainId" })) as string;
    const ok = now.toLowerCase() === RH_CHAIN.chainId;
    setChainOk(ok);
    return ok;
  };

  const connect = async () => {
    setError(null);
    const p = injected();
    if (!p) { setError("No wallet found — install a browser wallet to connect."); return; }
    try {
      const accounts = (await p.request({ method: "eth_requestAccounts" })) as string[];
      setAddress(accounts[0] ?? null);
      const chain = (await p.request({ method: "eth_chainId" })) as string;
      if (chain.toLowerCase() !== RH_CHAIN.chainId) await switchChain();
      else setChainOk(true);
    } catch (e) {
      setError((e as { message?: string })?.message ?? "Connection rejected.");
    }
  };

  return <Ctx.Provider value={{ address, chainOk, hasProvider: !!eth, ready, connect, switchChain: async () => { await switchChain(); }, error }}>{children}</Ctx.Provider>;
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
      <span className="wallet-chip num" title="Connected to Robinhood Chain testnet">
        <span className="dot" style={{ background: "var(--good)" }} />
        {short(w.address)}
      </span>
    );
  }
  // No injected wallet at all (most tweet/mobile-Safari traffic) — don't dead-end at a Connect button that just
  // errors; point them at how to get one. MetaMask injects on load, so they must reload after installing.
  if (w.ready && !w.hasProvider) {
    return (
      <span className="wallet-wrap">
        <a className="btn btn-gold" href="https://metamask.io/download/" target="_blank" rel="noreferrer">Install a wallet ↗</a>
        <i className="wallet-err">You'll need a crypto wallet like MetaMask — install it, then reload this page.</i>
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
