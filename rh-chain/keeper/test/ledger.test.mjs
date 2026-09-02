import assert from "node:assert/strict";
import { test } from "node:test";
import { getAddress } from "viem";
import { applyTransfers, balanceOf, emptyLedger, snapshotAt } from "../holder-airdrop/ledger.mjs";

const A = getAddress("0x1111111111111111111111111111111111111111");
const B = getAddress("0x2222222222222222222222222222222222222222");
const ZERO = getAddress("0x0000000000000000000000000000000000000000");

const xfer = (block, logIndex, from, to, value) => ({
  blockNumber: BigInt(block),
  logIndex,
  args: { from, to, value: BigInt(value) },
});

test("a mint credits the recipient and shows as a debit against the zero address", () => {
  const l = applyTransfers(emptyLedger(1n), [xfer(10, 0, ZERO, A, 100n)], 10n);
  assert.equal(balanceOf(snapshotAt(l), A), 100n);
  assert.equal(l.balances.get(ZERO), -100n);
});

test("a self-transfer nets to zero", () => {
  const l = applyTransfers(
    emptyLedger(1n),
    [xfer(10, 0, ZERO, A, 100n), xfer(11, 0, A, A, 40n), xfer(11, 1, A, A, 100n)],
    11n,
  );
  assert.equal(balanceOf(snapshotAt(l), A), 100n);
});

test("logs are folded in (block, logIndex) order regardless of arrival order", () => {
  const logs = [xfer(11, 1, A, B, 30n), xfer(10, 0, ZERO, A, 100n), xfer(11, 0, A, B, 20n)];
  const l = applyTransfers(emptyLedger(1n), logs, 11n);
  const s = snapshotAt(l);
  assert.equal(balanceOf(s, A), 50n);
  assert.equal(balanceOf(s, B), 50n);
});

test("replaying an already-folded block THROWS instead of double-counting", () => {
  const l = applyTransfers(emptyLedger(1n), [xfer(10, 0, ZERO, A, 100n)], 10n);
  assert.throws(() => applyTransfers(l, [xfer(10, 0, ZERO, A, 100n)], 11n), /not after head/);
  assert.equal(balanceOf(snapshotAt(l), A), 100n);
});

test("a log past the requested head THROWS — a snapshot may not include the future", () => {
  assert.throws(() => applyTransfers(emptyLedger(1n), [xfer(20, 0, ZERO, A, 100n)], 15n), /past the requested head/);
});

test("the head advances to the requested block even when the window held no transfers", () => {
  const l = applyTransfers(emptyLedger(1n), [], 500n);
  assert.equal(l.block, 500n);
  assert.equal(snapshotAt(l).block, 500n);
});

test("the head cannot be rewound", () => {
  const l = applyTransfers(emptyLedger(1n), [], 500n);
  assert.throws(() => applyTransfers(l, [], 400n), /cannot rewind/);
});

test("a fully spent balance leaves the snapshot rather than sitting at zero", () => {
  const l = applyTransfers(emptyLedger(1n), [xfer(10, 0, ZERO, A, 100n), xfer(11, 0, A, B, 100n)], 11n);
  const s = snapshotAt(l);
  assert.equal(s.balances.has(A), false);
  assert.equal(balanceOf(s, A), 0n);
});

test("snapshotAt refuses a ledger that has folded nothing", () => {
  assert.throws(() => snapshotAt(emptyLedger(1n)), /nothing folded/);
});

test("addresses are checksum-normalised, so a lowercase log and a checksummed query agree", () => {
  const l = applyTransfers(emptyLedger(1n), [xfer(10, 0, ZERO.toLowerCase(), A.toLowerCase(), 100n)], 10n);
  assert.equal(balanceOf(snapshotAt(l), A.toLowerCase()), 100n);
});
