import assert from "node:assert/strict";
import { test } from "node:test";
import { getAddress } from "viem";
import { describe, loadConfig } from "../holder-airdrop/config.mjs";

const ok = {
  ESSEY_TOKEN: "0x315790B57C19141B34C4653a91b096Cf3f071610",
  HOLDER_DISTRIBUTOR: "0x00000000000000000000000000000000000D1547",
  BASKET_REGISTRY: "0x0000000000000000000000000000000000000123",
  USDG: "0x00000000000000000000000000000000000005d6",
  ESSEY_TOKEN_FIRST_BLOCK: "49634440",
};

test("loads with the required addresses and defaults to the founder-locked 10 bps bar", () => {
  const cfg = loadConfig({ ...ok });
  assert.equal(cfg.barBps, 10);
  assert.equal(cfg.barWei, null);
  assert.equal(cfg.chainId, 4663);
  assert.equal(cfg.epochSeconds, 43_200);
  assert.equal(cfg.tokenFirstBlock, 49_634_440n);
});

test("every required address is required — none of them has a built-in fallback", () => {
  for (const key of Object.keys(ok)) {
    const env = { ...ok };
    delete env[key];
    assert.throws(() => loadConfig(env), new RegExp(`missing ${key}`), `${key} silently defaulted`);
  }
});

test("a malformed address is rejected rather than checksum-coerced", () => {
  assert.throws(() => loadConfig({ ...ok, HOLDER_DISTRIBUTOR: "0xdeadbeef" }), /not an address/);
});

test("the bar is a knob: BAR_WEI wins over BAR_BPS", () => {
  const cfg = loadConfig({ ...ok, HOLDER_BAR_WEI: "123", HOLDER_BAR_BPS: "50" });
  assert.equal(cfg.barWei, 123n);
});

test("a zero bar is refused", () => {
  assert.throws(() => loadConfig({ ...ok, HOLDER_BAR_WEI: "0" }), /must be positive/);
});

test("EXECUTE without a key is refused — it would look armed and silently do nothing", () => {
  assert.throws(() => loadConfig({ ...ok, EXECUTE: "1" }), /needs KEEPER_PRIVKEY/);
  assert.equal(loadConfig({ ...ok, EXECUTE: "1", KEEPER_PRIVKEY: "0x01" }).execute, true);
});

test("execute is OFF unless EXECUTE is exactly 1", () => {
  for (const v of [undefined, "", "0", "true", "yes", "TRUE"]) {
    assert.equal(loadConfig({ ...ok, EXECUTE: v, KEEPER_PRIVKEY: "0x01" }).execute, false, `EXECUTE=${v} armed it`);
  }
});

test("describe() never leaks the signing key", () => {
  const text = describe(loadConfig({ ...ok, EXECUTE: "1", KEEPER_PRIVKEY: "0xdeadbeefcafe" }));
  assert.equal(text.includes("deadbeefcafe"), false);
  assert.equal(text.includes("privateKey"), false);
  assert.equal(text.includes("HolderDistributor") || text.includes("distributor"), true);
});

test("exclusions parse into a checksummed list and tolerate whitespace", () => {
  const cfg = loadConfig({
    ...ok,
    EXCLUSIONS: " 0x0000000000000000000000000000000000000999 ,0x0000000000000000000000000000000000000aaa ",
  });
  assert.deepEqual(cfg.exclusions, [getAddress("0x0000000000000000000000000000000000000999"), getAddress("0x0000000000000000000000000000000000000aaa")]);
});
