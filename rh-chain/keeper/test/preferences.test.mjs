import assert from "node:assert/strict";
import { test } from "node:test";
import { privateKeyToAccount } from "viem/accounts";
import { TYPES, domainFor, resolvePreferences } from "../holder-airdrop/preferences.mjs";

const DIST = "0x00000000000000000000000000000000000D1547";
const CHAIN_ID = 4663;
const alice = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000a11");
const mallory = privateKeyToAccount("0x0000000000000000000000000000000000000000000000000000000000000b0b");

async function sign(account, { holder, basketId, nonce, deadline }) {
  const signature = await account.signTypedData({
    domain: domainFor({ chainId: CHAIN_ID, distributor: DIST }),
    types: TYPES,
    primaryType: "BasketPreference",
    message: { holder, basketId: BigInt(basketId), nonce: BigInt(nonce), deadline: BigInt(deadline) },
  });
  return { holder, basketId: String(basketId), nonce: String(nonce), deadline: String(deadline), signature };
}

const resolve = (entries, asOf = 1_000) => resolvePreferences(entries, { chainId: CHAIN_ID, distributor: DIST, asOf });

test("a correctly signed preference is applied", async () => {
  const e = await sign(alice, { holder: alice.address, basketId: 2, nonce: 1, deadline: 9_999 });
  assert.equal((await resolve([e])).get(alice.address), 2);
});

test("a preference signed by someone else for your address is DROPPED", async () => {
  const good = await sign(alice, { holder: alice.address, basketId: 2, nonce: 1, deadline: 9_999 });
  const forged = await sign(mallory, { holder: alice.address, basketId: 7, nonce: 9, deadline: 9_999 });
  const out = await resolve([good, forged]);
  assert.equal(out.get(alice.address), 2);
});

test("a tampered basketId invalidates the signature rather than taking effect", async () => {
  const e = await sign(alice, { holder: alice.address, basketId: 2, nonce: 1, deadline: 9_999 });
  const out = await resolve([{ ...e, basketId: "5" }]);
  assert.equal(out.has(alice.address), false);
});

test("the highest nonce wins regardless of the order the entries arrive in", async () => {
  const first = await sign(alice, { holder: alice.address, basketId: 1, nonce: 1, deadline: 9_999 });
  const second = await sign(alice, { holder: alice.address, basketId: 3, nonce: 2, deadline: 9_999 });
  assert.equal((await resolve([first, second])).get(alice.address), 3);
  assert.equal((await resolve([second, first])).get(alice.address), 3);
});

test("an expired preference is DROPPED, so the holder falls back to the default basket", async () => {
  const e = await sign(alice, { holder: alice.address, basketId: 2, nonce: 1, deadline: 500 });
  assert.equal((await resolve([e], 1_000)).has(alice.address), false);
  assert.equal((await resolve([e], 500)).get(alice.address), 2);
});

test("a signature bound to a different chain or distributor does not carry over", async () => {
  const e = await sign(alice, { holder: alice.address, basketId: 2, nonce: 1, deadline: 9_999 });
  const otherChain = await resolvePreferences([e], { chainId: 1, distributor: DIST, asOf: 1_000 });
  const otherDist = await resolvePreferences([e], {
    chainId: CHAIN_ID,
    distributor: "0x00000000000000000000000000000000DeaDBeef",
    asOf: 1_000,
  });
  assert.equal(otherChain.size, 0);
  assert.equal(otherDist.size, 0);
});
