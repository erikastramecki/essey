import { getAddress, parseAbiItem, parseEventLogs } from "viem";

export const TRANSFER_EVENT = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 value)");
export const ZERO = "0x0000000000000000000000000000000000000000";

// The public RH RPC keeps state for roughly 6k-8k blocks only (probed 2026-09-02: balanceOf at head-6000
// answers, head-8000 returns "metadata is not found"), so a snapshot 12h old CANNOT be read with an
// archive eth_call. Balances are therefore reconstructed by replaying Transfer logs from the token's
// first block. Mint and burn are left in the ledger against ZERO and excluded at eligibility time, which
// makes the fold a pure sum and makes a self-transfer net to nothing without a special case.

export function emptyLedger(fromBlock = 0n) {
  return { from: BigInt(fromBlock), block: null, balances: new Map() };
}

function credit(balances, account, delta) {
  const next = (balances.get(account) ?? 0n) + delta;
  if (next === 0n) balances.delete(account);
  else balances.set(account, next);
}

/// Fold decoded Transfer logs into `ledger` and advance its head to `throughBlock`. Logs at or below the
/// current head are rejected rather than skipped — replaying a window silently would double-count, and a
/// double-counted balance is a wrong root that still verifies.
export function applyTransfers(ledger, logs, throughBlock) {
  const through = BigInt(throughBlock);
  const floor = ledger.block === null ? ledger.from - 1n : ledger.block;
  if (through < floor) throw new Error(`ledger: cannot rewind head ${floor} to ${through}`);
  const ordered = [...logs].sort((a, b) => cmp(a.blockNumber, b.blockNumber) || cmp(a.logIndex, b.logIndex));
  for (const log of ordered) {
    const block = BigInt(log.blockNumber);
    if (block <= floor) throw new Error(`ledger: log at block ${block} is not after head ${floor}`);
    if (block > through) throw new Error(`ledger: log at block ${block} is past the requested head ${through}`);
    const value = BigInt(log.args.value);
    credit(ledger.balances, getAddress(log.args.from), -value);
    credit(ledger.balances, getAddress(log.args.to), value);
  }
  ledger.block = through;
  return ledger;
}

function cmp(a, b) {
  return BigInt(a) < BigInt(b) ? -1 : BigInt(a) > BigInt(b) ? 1 : 0;
}

/// Freeze the ledger into a snapshot at its current head: address => balance, canonically ordered.
export function snapshotAt(ledger) {
  if (ledger.block === null) throw new Error("ledger: nothing folded yet");
  const entries = [...ledger.balances.entries()]
    .filter(([, v]) => v > 0n)
    .sort(([a], [b]) => (a.toLowerCase() < b.toLowerCase() ? -1 : 1));
  return { block: ledger.block, balances: new Map(entries) };
}

export function balanceOf(snapshot, account) {
  return snapshot.balances.get(getAddress(account)) ?? 0n;
}

/// Pull every Transfer log for `token` in [fromBlock, toBlock] in bounded windows. The server is asked by
/// ADDRESS ONLY and topics are matched client-side: this RPC has been observed to answer topic-filtered
/// eth_getLogs unreliably (docs/MAINNET-ACTIVATION.md, intern grounding note), and a silently-short log
/// set produces a wrong root that still verifies against itself.
export async function fetchTransfers(client, { token, fromBlock, toBlock, window = 100_000n }) {
  const raw = [];
  for (let start = BigInt(fromBlock); start <= BigInt(toBlock); start += window) {
    const last = start + window - 1n;
    const end = last > BigInt(toBlock) ? BigInt(toBlock) : last;
    const logs = await client.getLogs({ address: token, fromBlock: start, toBlock: end });
    for (const log of logs) raw.push(log);
  }
  return parseEventLogs({ abi: [TRANSFER_EVENT], logs: raw, eventName: "Transfer", strict: true });
}
