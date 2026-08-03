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
  connect: () => Promise<void>;
  error: string | null;
};

const Ctx = createContext<WalletState>({ address: null, chainOk: false, hasProvider: false, connect: async () => {}, error: null });
export const useWallet = () => useContext(Ctx);

export function WalletProvider({ children }: { children: ReactNode }) {
  const [address, setAddress] = useState<string | null>(null);
  const [chainOk, setChainOk] = useState(false);
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

  const connect = async () => {
    setError(null);
    const p = injected();
    if (!p) { setError("No wallet found — install a browser wallet to connect."); return; }
    try {
      const accounts = (await p.request({ method: "eth_requestAccounts" })) as string[];
      setAddress(accounts[0] ?? null);
      const chain = (await p.request({ method: "eth_chainId" })) as string;
      if (chain.toLowerCase() !== RH_CHAIN.chainId) {
        try {
          await p.request({ method: "wallet_switchEthereumChain", params: [{ chainId: RH_CHAIN.chainId }] });
        } catch {
          // 4902 = unknown chain: offer to add it. Any other failure falls through to chainOk=false,
          // which the UI reports honestly rather than pretending.
          await p.request({ method: "wallet_addEthereumChain", params: [RH_CHAIN] }).catch(() => {});
        }
        const now = (await p.request({ method: "eth_chainId" })) as string;
        setChainOk(now.toLowerCase() === RH_CHAIN.chainId);
      } else {
        setChainOk(true);
      }
    } catch (e) {
      setError((e as { message?: string })?.message ?? "Connection rejected.");
    }
  };

  return <Ctx.Provider value={{ address, chainOk, hasProvider: !!eth, connect, error }}>{children}</Ctx.Provider>;
}

const short = (a: string) => a.slice(0, 6) + "…" + a.slice(-4);

/// The connect control. Honest states: no provider, wrong chain, connected.
export function ConnectButton() {
  const w = useWallet();
  if (w.address) {
    return (
      <span className="wallet-chip num" title={w.chainOk ? "Connected to Robinhood Chain" : "Wrong network"}>
        <span className="dot" style={{ background: w.chainOk ? "var(--good)" : "var(--warn)" }} />
        {short(w.address)}{!w.chainOk && " · wrong chain"}
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
