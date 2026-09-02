import { getAddress, isAddress } from "viem";

// Every address, key and knob comes from the environment. Nothing operational is a literal in this repo:
// a keeper that carries its own signer or its own distributor address is one copy-paste from posting a
// root to the wrong contract on the wrong chain.

const REQUIRED = ["ESSEY_TOKEN", "HOLDER_DISTRIBUTOR", "BASKET_REGISTRY", "USDG", "ESSEY_TOKEN_FIRST_BLOCK"];

export function loadConfig(env = process.env) {
  const missing = REQUIRED.filter((k) => !env[k]);
  if (missing.length > 0) throw new Error(`config: missing ${missing.join(", ")}`);

  const cfg = {
    rpc: env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com",
    chainId: Number(env.CHAIN_ID || 4663),
    token: address(env.ESSEY_TOKEN, "ESSEY_TOKEN"),
    distributor: address(env.HOLDER_DISTRIBUTOR, "HOLDER_DISTRIBUTOR"),
    registry: address(env.BASKET_REGISTRY, "BASKET_REGISTRY"),
    usdg: address(env.USDG, "USDG"),
    tokenFirstBlock: BigInt(env.ESSEY_TOKEN_FIRST_BLOCK),
    logWindow: BigInt(env.LOG_WINDOW || 100_000),

    // The founder-locked eligibility bar, adjustable without a redeploy: 0.1% of supply = 10 bps of
    // 8_888_888_888e18 = 8_888_888.888 $ESSEY (totalSupply read from chain 2026-09-02). Set BAR_WEI to
    // pin an exact figure instead — BAR_WEI wins when both are present.
    barWei: env.HOLDER_BAR_WEI ? BigInt(env.HOLDER_BAR_WEI) : null,
    barBps: env.HOLDER_BAR_BPS ? Number(env.HOLDER_BAR_BPS) : 10,

    epochSeconds: Number(env.EPOCH_SECONDS || 43_200),
    confirmations: BigInt(env.SNAPSHOT_CONFIRMATIONS || 30),
    minPotUsdg: BigInt(env.MIN_POT_USDG || 1_000_000), // EsseyPOL.MIN_COMPOUND_USDG precedent: 1e6 = $1
    defaultBasketId: Number(env.DEFAULT_BASKET_ID || 0),
    exclusions: parseList(env.EXCLUSIONS),
    preferencesFile: env.PREFERENCES_FILE || null,
    stateDir: env.STATE_DIR || "./keeper-state",

    execute: env.EXECUTE === "1",
    privateKey: env.KEEPER_PRIVKEY || null,
  };

  if (cfg.epochSeconds <= 0) throw new Error("config: EPOCH_SECONDS must be positive");
  if (cfg.barWei !== null && cfg.barWei <= 0n) throw new Error("config: HOLDER_BAR_WEI must be positive");
  if (cfg.execute && !cfg.privateKey) throw new Error("config: EXECUTE=1 needs KEEPER_PRIVKEY");
  return cfg;
}

function address(value, name) {
  if (!isAddress(value)) throw new Error(`config: ${name} is not an address`);
  return getAddress(value);
}

function parseList(value) {
  if (!value) return [];
  return value
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => address(s, "EXCLUSIONS"));
}

/// Safe to log: never includes the signing key.
export function describe(cfg) {
  const { privateKey, ...rest } = cfg;
  return JSON.stringify(rest, (_, v) => (typeof v === "bigint" ? String(v) : v));
}
