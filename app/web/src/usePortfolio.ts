// Portfolio polling hook — the connected wallet's live on-chain positions, refreshed on an interval.
// (Replaces the old journey/quest hook; the guided-quest funnel was retired for the mainnet Dons launch.)
import { useCallback, useEffect, useState } from "react";
import type { Address } from "viem";
import { useWallet } from "./wallet";
import { reads, type Portfolio } from "./live";

/// Live portfolio, polled every 20s. Returns the connected wallet's balances, Seats, Vaults, loans, etc.
export function usePortfolio() {
  const w = useWallet();
  const a = w.address as Address | null;
  const connected = !!a && w.chainOk;
  const [p, setP] = useState<Portfolio | null>(null);
  const [loading, setLoading] = useState(false);

  const refresh = useCallback(() => {
    if (!a) { setP(null); return; }
    setLoading(true);
    reads.portfolio(a).then(setP).catch(() => {}).finally(() => setLoading(false));
  }, [a]);

  useEffect(() => { refresh(); const t = setInterval(refresh, 20_000); return () => clearInterval(t); }, [refresh]);

  return { portfolio: p, connected, loading, refresh };
}
