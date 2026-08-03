// The Tape indexer — a deliberately small service: poll getLogs for the market contracts, decode into
// normalized rows, keep a ring buffer, serve JSON. No database, no websockets, no framework — the Tape
// is a feed of receipts, and a receipt printer should be simple enough to trust.
//
// Honesty contract (mirrors the site's): /health reports exactly how far behind we are; an unconfigured
// contract is skipped, never faked; when nothing has happened, /tape returns an empty list and the site
// says "quiet", not a fabricated pulse.
//
// Config (env): RPC_URL (required), ADDR_SEAT / ADDR_BELL / ADDR_EXCHANGE / ADDR_CASES /
// ADDR_DISTRIBUTOR (each optional), START_BLOCK, POLL_MS (default 3000), PORT (default 8790),
// MAX_ROWS (default 500), CHUNK (default 5000 blocks per getLogs backfill window).
import { createServer } from "node:http";
import { createPublicClient, http as viemHttp } from "viem";
import { CONTRACT_EVENTS, toTapeRow } from "./events.mjs";

const env = (k, d) => process.env[k] ?? d;
const RPC_URL = env("RPC_URL");
const POLL_MS = Number(env("POLL_MS", 3000));
const PORT = Number(env("PORT", 8790));
const MAX_ROWS = Number(env("MAX_ROWS", 500));
const CHUNK = BigInt(env("CHUNK", 5000));

const CONTRACTS = Object.entries({
  seat: env("ADDR_SEAT"), bell: env("ADDR_BELL"), exchange: env("ADDR_EXCHANGE"),
  cases: env("ADDR_CASES"), distributor: env("ADDR_DISTRIBUTOR"),
}).filter(([, addr]) => !!addr);

const state = {
  rows: [], // newest first, capped at MAX_ROWS
  lastBlock: null, // last fully-indexed block
  lastPollAt: null,
  lastError: null,
  counts: {}, // kind -> total seen (survives ring-buffer eviction)
};

function push(row, blockTs) {
  state.counts[row.kind] = (state.counts[row.kind] ?? 0) + 1;
  state.rows.unshift({ ...row, ts: blockTs });
  if (state.rows.length > MAX_ROWS) state.rows.pop();
}

async function poll(client) {
  const head = await client.getBlockNumber();
  let from = state.lastBlock !== null ? BigInt(state.lastBlock) + 1n : BigInt(env("START_BLOCK", String(head)));
  if (from > head) return;
  const tsCache = new Map();
  const tsOf = async (bn) => {
    if (!tsCache.has(bn)) tsCache.set(bn, Number((await client.getBlock({ blockNumber: bn })).timestamp));
    return tsCache.get(bn);
  };
  while (from <= head) {
    const to = from + CHUNK - 1n > head ? head : from + CHUNK - 1n;
    const batch = [];
    for (const [name, address] of CONTRACTS) {
      const logs = await client.getLogs({ address, events: CONTRACT_EVENTS[name], fromBlock: from, toBlock: to });
      for (const log of logs) {
        const row = toTapeRow(name, log.eventName, log.args, log);
        if (row) batch.push({ row, bn: log.blockNumber, li: log.logIndex });
      }
    }
    // Chain order within the window, then push (ring is newest-first).
    batch.sort((a, b) => (a.bn === b.bn ? a.li - b.li : a.bn < b.bn ? -1 : 1));
    for (const { row, bn } of batch) push(row, await tsOf(bn));
    state.lastBlock = Number(to);
    from = to + 1n;
  }
}

function serve() {
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://x");
    const send = (code, body) => {
      res.writeHead(code, {
        "content-type": "application/json",
        "access-control-allow-origin": "*", // public read-only feed
        "cache-control": "no-store",
      });
      res.end(JSON.stringify(body));
    };
    if (url.pathname === "/health") {
      return send(200, {
        ok: !state.lastError, configured: CONTRACTS.map(([n]) => n),
        lastBlock: state.lastBlock, lastPollAt: state.lastPollAt, lastError: state.lastError,
      });
    }
    if (url.pathname === "/tape") {
      const limit = Math.min(Number(url.searchParams.get("limit") ?? 50), MAX_ROWS);
      const kinds = url.searchParams.get("kinds")?.split(",");
      const provenOnly = url.searchParams.get("proven") === "1";
      let rows = state.rows;
      if (kinds?.length) rows = rows.filter((r) => kinds.includes(r.kind));
      if (provenOnly) rows = rows.filter((r) => r.proven);
      return send(200, { rows: rows.slice(0, limit), lastBlock: state.lastBlock, counts: state.counts });
    }
    if (url.pathname === "/stats") return send(200, { counts: state.counts, lastBlock: state.lastBlock });
    send(404, { error: "not found" });
  });
  server.listen(PORT, () => console.log(`tape-indexer listening :${PORT} — contracts: ${CONTRACTS.map(([n]) => n).join(", ") || "(none configured)"}`));
}

async function main() {
  serve();
  if (!RPC_URL) {
    // Honest unconfigured state: serve /health with the truth rather than refusing to start —
    // deploys can come up before the chain config does.
    state.lastError = "RPC_URL not configured";
    return;
  }
  const client = createPublicClient({ transport: viemHttp(RPC_URL) });
  for (;;) {
    try {
      await poll(client);
      state.lastPollAt = Date.now();
      state.lastError = null;
    } catch (e) {
      state.lastError = String(e?.message ?? e);
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

main();
