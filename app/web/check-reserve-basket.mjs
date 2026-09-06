// Reconciles the reserve's ACTUAL inbound tokens against the basket the page knows to look up.
//
// Erik, 2026-09-05: sent AMZN to the reserve and bet that we would not notice. He was right. BASKET in
// src/reserve.ts is a hand-maintained allowlist, so a deposit of anything not already listed is invisible
// to the treasury page — the balance is not stale, the token is simply never queried. Reading every token
// the reserve has ever touched is NOT the fix: anyone can airdrop junk, and auto-listing it would let a
// stranger inflate published backing. So the allowlist stays, and this reconciles it against the chain.
//
// The severity split is the whole design:
//   FAIL  a token whose EIP-1967 beacon matches the issuer's — real tokenized equity we are omitting.
//   WARN  anything else — an airdrop or a meme token. Needs a human ruling, never an automatic listing.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { getAddress } from "viem";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const RPC = "https://rpc.mainnet.chain.robinhood.com";
const RESERVE = "0xd970Ca726188e38982906Ae2284D2bdB80205A7b";
const TRANSFER =
  "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const BEACON_SLOT =
  "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50";
const RH_BEACON = "e10b6f6b275de231345c20d14ab812db62151b00";

// Non-equity tokens already seen and deliberately left off the page. Adding one here is a decision:
// it says "we looked, and this is not backing." Never add a beacon-matching token to this list.
const ACKNOWLEDGED = new Set([]);

const rpc = async (method, params) => {
  for (let i = 0; i < 6; i++) {
    try {
      const r = await fetch(RPC, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      });
      const j = await r.json();
      if (j.result !== undefined) return j.result;
    } catch {}
    await new Promise((r) => setTimeout(r, 1_500 + 2_000 * i));
  }
  return null;
};

const basket = () => {
  const src = readFileSync(join(HERE, "src", "reserve.ts"), "utf8");
  const block = src.match(/BASKET:\s*Address\[\]\s*=\s*\[([\s\S]*?)\]/);
  if (!block) throw new Error("could not locate BASKET in src/reserve.ts");
  return new Set(
    [...block[1].matchAll(/0x[a-fA-F0-9]{40}/g)].map((m) => m[0].toLowerCase()),
  );
};

const decodeString = (hex) => {
  if (!hex || hex.length < 130) return "?";
  const b = Buffer.from(hex.slice(2), "hex");
  return b
    .subarray(
      64,
      64 + Number(BigInt("0x" + b.subarray(32, 64).toString("hex"))),
    )
    .toString("utf8")
    .trim();
};

const raw = readFileSync(join(HERE, "src", "reserve.ts"), "utf8");
const listed = [
  ...(
    raw.match(/BASKET:\s*Address\[\]\s*=\s*\[([\s\S]*?)\]/)?.[1] || ""
  ).matchAll(/"(0x[a-fA-F0-9]{40})"/g),
].map((m) => m[1]);
const miscased = listed.filter((a) => {
  try {
    return getAddress(a) !== a;
  } catch {
    return true;
  }
});

if (miscased.length) {
  console.error(
    `\nreserve-basket: FAIL — ${miscased.length} BASKET address(es) fail viem's checksum.`,
  );
  for (const a of miscased)
    console.error(`  ${a}  should be  ${getAddress(a.toLowerCase())}`);
  console.error(
    "  viem throws at encode time, so the page cannot read this token at all.\n",
  );
  process.exit(1);
}

const known = basket();
const logs = await rpc("eth_getLogs", [
  {
    fromBlock: "0x0",
    toBlock: "latest",
    topics: [
      TRANSFER,
      null,
      `0x${"0".repeat(24)}${RESERVE.slice(2).toLowerCase()}`,
    ],
  },
]);

if (logs === null) {
  console.log(
    "reserve-basket: SKIP (RPC unreachable — this check needs the real chain)",
  );
  process.exit(0);
}

const seen = [...new Set(logs.map((l) => l.address.toLowerCase()))];
const missing = seen.filter((t) => !known.has(t) && !ACKNOWLEDGED.has(t));

const equities = [];
const others = [];
for (const t of missing) {
  const slot = await rpc("eth_getStorageAt", [t, BEACON_SLOT, "latest"]);
  (slot && slot.toLowerCase().endsWith(RH_BEACON) ? equities : others).push(t);
}

console.log(
  `reserve-basket: ${seen.length} token(s) ever received, ${known.size} in BASKET, ` +
    `${equities.length} unlisted equity, ${others.length} unlisted other`,
);

for (const t of others) {
  const sym = decodeString(
    await rpc("eth_call", [{ to: t, data: "0x95d89b41" }, "latest"]),
  );
  console.log(
    `  WARN  ${t} ("${sym}") is held but not shown, and is not a tokenized equity.`,
  );
  console.log(
    "        Rule on it: add to BASKET to publish it, or to ACKNOWLEDGED to keep it off.",
  );
}

if (equities.length) {
  console.error(
    `\nreserve-basket: FAIL — ${equities.length} tokenized equity(s) in the reserve are not on the page.`,
  );
  for (const t of equities)
    console.error(
      `  ${t}  (EIP-1967 beacon matches the issuer — this is real backing)`,
    );
  console.error(
    "  Published backing understates the reserve. Add to BASKET in src/reserve.ts.\n",
  );
  process.exit(1);
}
