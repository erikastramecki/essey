// Round-trip test: encode representative events exactly as the contracts would emit them, decode with
// the poller's ABIs, and check the normalized Tape rows — proves the vocabulary matches the contracts
// without needing a chain.
import assert from "node:assert";
import { encodeEventTopics, encodeAbiParameters, decodeEventLog } from "viem";
import { CONTRACT_EVENTS, toTapeRow } from "./events.mjs";

const FAKE = { blockNumber: 123n, transactionHash: "0x" + "ab".repeat(32), logIndex: 0 };
const addr = (n) => "0x" + String(n).padStart(40, "0");

function roundTrip(contract, eventName, args, data) {
  const abi = CONTRACT_EVENTS[contract];
  const topics = encodeEventTopics({ abi, eventName, args });
  const decoded = decodeEventLog({ abi, eventName, topics, data });
  return toTapeRow(contract, decoded.eventName, decoded.args, FAKE);
}

// Bell.Rang(ringer indexed; pot, tip, distributed in data)
{
  const row = roundTrip("bell", "Rang", { ringer: addr(1) },
    encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }],
      [7000000000000000000n, 70000000000000000n, 6930000000000000000n]));
  assert.equal(row.kind, "bell_rung");
  assert.equal(row.proven, true);
  assert.equal(row.distributed, "6930000000000000000");
}

// Seat.Transfer mint (from == 0) vs transfer
{
  const mint = roundTrip("seat", "Transfer", { from: addr(0), to: addr(2), tokenId: 17n }, "0x");
  assert.equal(mint.kind, "seat_minted");
  assert.equal(mint.id, "17");
  const move = roundTrip("seat", "Transfer", { from: addr(2), to: addr(3), tokenId: 17n }, "0x");
  assert.equal(move.kind, "seat_transfer");
  assert.equal(move.proven, false);
}

// Exchange.Sniped(id, buyer indexed; price, fee in data)
{
  const row = roundTrip("exchange", "Sniped", { id: 197n, buyer: addr(4) },
    encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [500000000000000000000n, 15000000000000000000n]));
  assert.equal(row.kind, "exchange_snipe");
  assert.equal(row.price, "500000000000000000000");
}

// Cases.CaseOpened(caseId, buyer, token indexed; amount in data)
{
  const row = roundTrip("cases", "CaseOpened", { caseId: 5n, buyer: addr(6), token: addr(7) },
    encodeAbiParameters([{ type: "uint256" }], [800000000000000000n]));
  assert.equal(row.kind, "case_opened");
  assert.equal(row.proven, true);
  assert.equal(row.amount, "800000000000000000");
}

// Distributor.Claimed(stage, account indexed; allocation, firstId in data)
{
  const row = roundTrip("distributor", "Claimed", { stage: 0n, account: addr(8) },
    encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [2n, 41n]));
  assert.equal(row.kind, "whitelist_claimed");
  assert.equal(row.allocation, "2");
}

console.log("decode round-trip: 6 event shapes OK");
