import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// Only the snapshot cursor is persisted. Balances are NOT cached: every run re-derives them from the
// token's full Transfer history, so a corrupted or hand-edited cache can never move a root, and a
// verifier reproduces the keeper's numbers from chain data alone.

const FILE = "holder-airdrop-state.json";

export function loadState(dir) {
  try {
    const raw = JSON.parse(readFileSync(join(dir, FILE), "utf8"));
    return {
      prevSnapshotBlock: raw.prevSnapshotBlock === null ? null : BigInt(raw.prevSnapshotBlock),
      lastSnapshotAt: raw.lastSnapshotAt === null ? null : Number(raw.lastSnapshotAt),
      lastEpochPosted: raw.lastEpochPosted === null ? null : BigInt(raw.lastEpochPosted),
    };
  } catch {
    return { prevSnapshotBlock: null, lastSnapshotAt: null, lastEpochPosted: null };
  }
}

export function saveState(dir, state) {
  mkdirSync(dir, { recursive: true });
  const body = JSON.stringify(state, (_, v) => (typeof v === "bigint" ? String(v) : v), 2);
  writeFileSync(join(dir, FILE), `${body}\n`);
}

export function writeManifest(dir, manifest) {
  mkdirSync(dir, { recursive: true });
  const path = join(dir, `root-epoch-${manifest.epoch}.json`);
  writeFileSync(path, `${JSON.stringify(manifest, null, 2)}\n`);
  return path;
}
