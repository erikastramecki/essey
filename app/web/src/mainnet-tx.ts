// The MAINNET (Robinhood Chain 4663) WRITE path — one shared module every mainnet flow signs through.
// reserve.ts is the read half (`mainnetPub`); this is its write twin. Redemption is the first caller;
// Earn, the Borrow rewire, the Holder Hub and Private-on-mainnet are the next, so it stays generic.
//
// It reuses wallet.tsx's EIP-6963 connection WHOLESALE — the picker, the persisted selection, the
// selected-provider store, the silent reconnect. What it adds is the one thing wallet.tsx cannot give
// it: RH_CHAIN there is the TESTNET (wallet.tsx:23-29) and its `chainOk` tracks 46630, so a mainnet
// flow must switch to 4663 and track that itself. Do NOT retarget wallet.tsx — the game wing is still
// a testnet app and would break the moment its chain constant moved.
import { useCallback, useEffect, useState } from "react";
import {
  createWalletClient,
  custom,
  type Address,
  type Hex,
  type TransactionReceipt,
} from "viem";
import { MAINNET, mainnetChain, mainnetPub, readError } from "./reserve";
import {
  getSelectedProvider,
  pickProvider,
  useSelectedProvider,
  useWallet,
  type Eip1193,
} from "./wallet";

export const MAINNET_HEX = `0x${MAINNET.chainId.toString(16)}`; // 4663 -> 0x1237

const ADD_CHAIN = {
  chainId: MAINNET_HEX,
  chainName: MAINNET.name,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: [MAINNET.rpc],
  blockExplorerUrls: [MAINNET.explorer],
};

export const txUrl = (hash: Hex): string => `${MAINNET.explorer}/tx/${hash}`;

/// Land `p` on 4663, adding the network if the wallet doesn't know it. Returns the wallet's ACTUAL
/// chain afterwards rather than assuming the switch took — a rejected switch must not read as success.
async function switchToMainnet(p: Eip1193): Promise<boolean> {
  try {
    await p.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: MAINNET_HEX }],
    });
  } catch (e) {
    if ((e as { code?: number })?.code === 4001) return false;
    await p
      .request({ method: "wallet_addEthereumChain", params: [ADD_CHAIN] })
      .catch(() => {});
  }
  const now = (await p.request({ method: "eth_chainId" })) as string;
  return String(now).toLowerCase() === MAINNET_HEX;
}

/// Connected wallet, authorized account, on 4663 — or a thrown error saying which of the three failed.
/// Every mainnet write goes through here, so no call site can sign against the wrong chain.
export async function ensureMainnet(): Promise<{
  provider: Eip1193;
  account: Address;
}> {
  const provider = await pickProvider();
  if (!provider) throw new Error("Connect a wallet to continue.");
  const accts = (await provider.request({
    method: "eth_requestAccounts",
  })) as string[];
  const account = accts?.[0];
  if (!account) throw new Error("Your wallet did not share an account.");
  if (!(await switchToMainnet(provider)))
    throw new Error(
      `Your wallet is not on ${MAINNET.name} (chain ${MAINNET.chainId}). Switch networks and try again.`,
    );
  return { provider, account: account as Address };
}

export type TxPhase =
  "idle" | "checking" | "signing" | "pending" | "confirmed" | "failed";

export type TxState = {
  phase: TxPhase;
  hash: Hex | null;
  error: string | null;
};

export const TX_IDLE: TxState = { phase: "idle", hash: null, error: null };

export type MainnetCall = {
  address: Address;
  abi: readonly unknown[];
  functionName: string;
  args?: readonly unknown[];
  value?: bigint;
};

/// Simulate → sign → wait, reporting each phase. The simulate is not optional politeness: it surfaces a
/// revert BEFORE the wallet prompt, so an irreversible burn can never be signed into a failing tx. viem
/// pins `chain` from `mainnetPub`, so a wallet that drifted off 4663 between the switch and the signature
/// throws a chain mismatch instead of broadcasting somewhere else.
export async function sendMainnet(
  call: MainnetCall,
  onPhase: (s: TxState) => void,
): Promise<TransactionReceipt> {
  const { provider, account } = await ensureMainnet();
  onPhase({ phase: "checking", hash: null, error: null });
  const { request } = await mainnetPub.simulateContract({
    ...call,
    abi: call.abi as never,
    functionName: call.functionName as never,
    args: call.args as never,
    account,
  } as never);
  onPhase({ phase: "signing", hash: null, error: null });
  const wallet = createWalletClient({
    account,
    chain: mainnetChain,
    transport: custom(provider),
  });
  const hash = await wallet.writeContract(request as never);
  onPhase({ phase: "pending", hash, error: null });
  const rcpt = await mainnetPub.waitForTransactionReceipt({
    hash,
    timeout: 180_000,
  });
  if (rcpt.status !== "success")
    throw new Error("Transaction reverted on chain.");
  onPhase({ phase: "confirmed", hash, error: null });
  return rcpt;
}

/// Wallet errors are the ones a user actually sees, so they get plain sentences rather than a viem
/// stack. Anything unrecognised falls through to reserve.ts's readError (custom-error name where viem
/// gives one) instead of being swallowed into a generic "something went wrong".
export function txErrorText(e: unknown): string {
  const code = (e as { code?: number })?.code;
  const raw = e instanceof Error ? e.message : String(e);
  if (code === 4001 || /user (rejected|denied)|rejected the request/i.test(raw))
    return "You rejected the transaction in your wallet.";
  if (/insufficient funds/i.test(raw))
    return `Not enough ETH on ${MAINNET.name} to pay gas for this transaction.`;
  if (/chain mismatch|does not match the target chain/i.test(raw))
    return `Your wallet left ${MAINNET.name}. Switch back to chain ${MAINNET.chainId} and try again.`;
  const short = (e as { shortMessage?: string })?.shortMessage;
  return short ?? readError(e);
}

/// One transaction's lifecycle as component state. Call sites render `state.phase` and never juggle
/// their own booleans; `run` resolves to the receipt (so callers can parse events) or null on failure.
export function useMainnetTx() {
  const [state, setState] = useState<TxState>(TX_IDLE);
  const run = useCallback(
    async (call: MainnetCall): Promise<TransactionReceipt | null> => {
      try {
        return await sendMainnet(call, setState);
      } catch (e) {
        setState((s) => ({
          phase: "failed",
          hash: s.hash,
          error: txErrorText(e),
        }));
        return null;
      }
    },
    [],
  );
  const reset = useCallback(() => setState(TX_IDLE), []);
  return { state, run, reset };
}

export type MainnetWallet = {
  address: Address | null;
  chainOk: boolean; // on 4663 specifically — NOT wallet.tsx's testnet chainOk
  hasProvider: boolean;
  ready: boolean;
  error: string | null;
  connect: () => Promise<void>;
  switchChain: () => Promise<void>;
};

/// The mainnet counterpart of `useWallet()`. It leans on that hook for provider discovery and for
/// `ready` (its silent reconnect is what settles whether a returning visitor is signed in), and layers
/// a 4663-specific chain probe on top. Reads are silent — `eth_accounts`, never `eth_requestAccounts` —
/// so simply opening a page never raises a wallet prompt.
export function useMainnetWallet(): MainnetWallet {
  const base = useWallet();
  const provider = useSelectedProvider();
  const [address, setAddress] = useState<Address | null>(null);
  const [chainOk, setChainOk] = useState(false);
  const [probed, setProbed] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!provider) {
      setAddress(null);
      setChainOk(false);
      setProbed(true);
      return;
    }
    let live = true;
    const sync = async () => {
      const accts = (await provider
        .request({ method: "eth_accounts" })
        .catch(() => [])) as string[];
      const id = (await provider
        .request({ method: "eth_chainId" })
        .catch(() => "")) as string;
      if (!live) return;
      setAddress((accts?.[0] as Address) ?? null);
      setChainOk(String(id).toLowerCase() === MAINNET_HEX);
      setProbed(true);
    };
    sync();
    const onAccounts = (a: unknown) =>
      setAddress(Array.isArray(a) && a[0] ? (String(a[0]) as Address) : null);
    const onChain = (c: unknown) =>
      setChainOk(String(c).toLowerCase() === MAINNET_HEX);
    provider.on?.("accountsChanged", onAccounts);
    provider.on?.("chainChanged", onChain);
    return () => {
      live = false;
      provider.removeListener?.("accountsChanged", onAccounts);
      provider.removeListener?.("chainChanged", onChain);
    };
  }, [provider]);

  const connect = useCallback(async () => {
    setError(null);
    try {
      const { account } = await ensureMainnet();
      setAddress(account);
      setChainOk(true);
    } catch (e) {
      setError(txErrorText(e));
    }
  }, []);

  const switchChain = useCallback(async () => {
    setError(null);
    const p = getSelectedProvider();
    if (!p) return connect();
    try {
      setChainOk(await switchToMainnet(p));
    } catch (e) {
      setError(txErrorText(e));
    }
  }, [connect]);

  return {
    address,
    chainOk,
    hasProvider: base.hasProvider,
    ready: base.ready && probed,
    error,
    connect,
    switchChain,
  };
}
