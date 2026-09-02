import { getAddress, verifyTypedData } from "viem";

// Basket preference is a GASLESS signed message the keeper reads off-chain — BasketRegistry deliberately
// stores no per-holder preference (src/market/BasketRegistry.sol:13-14). This domain/type pair is the
// keeper's proposal and is NOT YET RATIFIED: the holder UI must sign exactly this or every preference
// falls back to the default basket. Flagged for the founder + web-designer before the hub ships.

export const DOMAIN_NAME = "EsseyHolderAirdrop";
export const DOMAIN_VERSION = "1";

export const TYPES = {
  BasketPreference: [
    { name: "holder", type: "address" },
    { name: "basketId", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};

export function domainFor({ chainId, distributor }) {
  return { name: DOMAIN_NAME, version: DOMAIN_VERSION, chainId: Number(chainId), verifyingContract: getAddress(distributor) };
}

async function isValid(entry, { domain, asOf }) {
  if (BigInt(entry.deadline) < BigInt(asOf)) return false;
  return verifyTypedData({
    address: getAddress(entry.holder),
    domain,
    types: TYPES,
    primaryType: "BasketPreference",
    message: {
      holder: getAddress(entry.holder),
      basketId: BigInt(entry.basketId),
      nonce: BigInt(entry.nonce),
      deadline: BigInt(entry.deadline),
    },
    signature: entry.signature,
  });
}

/// Highest valid nonce per holder wins. A bad signature, an expired deadline, or a lower nonce is
/// DROPPED, never applied — a holder whose preference cannot be verified keeps the default basket.
export async function resolvePreferences(entries, { chainId, distributor, asOf }) {
  const domain = domainFor({ chainId, distributor });
  const best = new Map();
  for (const entry of entries) {
    if (!(await isValid(entry, { domain, asOf }))) continue;
    const holder = getAddress(entry.holder);
    const nonce = BigInt(entry.nonce);
    const seen = best.get(holder);
    if (seen && seen.nonce >= nonce) continue;
    best.set(holder, { nonce, basketId: Number(entry.basketId) });
  }
  return new Map([...best.entries()].map(([holder, v]) => [holder, v.basketId]));
}
