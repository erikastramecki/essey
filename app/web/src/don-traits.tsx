import { useEffect, useState } from "react";

export type Attr = { trait_type: string; value: string };

/// The stat sheet AffinityRegistry.previewSheet decodes from the Don's trait preimage. Null when the
/// preimage was never recorded or the registry is unreachable — traits still render either way.
export type Stats = {
  rpBps: number;
  hdBps: number;
  hdFlat: number;
  nrvBps: number;
  lckBps: number;
  cmdGarrisonBps: number;
  cmdFactionBps: number;
  cmdCooldownBps: number;
  feeDiscBps: number;
  resHospBps: number;
  resPetrifyBps: number;
  resAmbushBps: number;
  guiTier: number;
  yldCapSteps: number;
  archetype: string;
  flags: number;
};

export type Don = { attrs: Attr[]; stats: Stats | null };

/// What the desk sorts by. bps are probability points, so /100 reads as a percentage.
export const SORTS: { key: string; label: string; of: (s: Stats) => number }[] =
  [
    { key: "rp", label: "attack", of: (s) => s.rpBps },
    { key: "hd", label: "defense", of: (s) => s.hdBps + s.hdFlat * 100 },
    { key: "nrv", label: "nerve", of: (s) => s.nrvBps },
    { key: "lck", label: "luck", of: (s) => s.lckBps },
    { key: "gui", label: "scout", of: (s) => s.guiTier },
    { key: "fee", label: "fee cut", of: (s) => s.feeDiscBps },
  ];

// Testers are expected to hold 5-10 Dons each and the pool holds ~83, so the same metadata gets asked
// for repeatedly across the desk, the picker and the filter. Cached at module scope: a combo's traits
// never change, and an in-flight promise is shared rather than refetched.
const cache = new Map<string, Don>();
const inflight = new Map<string, Promise<Don>>();
const EMPTY: Don = { attrs: [], stats: null };

export function fetchDon(id: bigint | number): Promise<Don> {
  const key = String(id);
  const hit = cache.get(key);
  if (hit) return Promise.resolve(hit);
  const live = inflight.get(key);
  if (live) return live;
  const p = fetch(`/api/don/${key}`)
    .then((r) => (r.ok ? r.json() : null))
    .then((d) => {
      const rec: Don = { attrs: d?.attributes ?? [], stats: d?.stats ?? null };
      cache.set(key, rec);
      return rec;
    })
    .catch(() => EMPTY)
    .finally(() => inflight.delete(key));
  inflight.set(key, p);
  return p;
}

export const fetchTraits = (id: bigint | number) =>
  fetchDon(id).then((d) => d.attrs);

export function useDon(id: bigint | number | null) {
  const [rec, setRec] = useState<Don | null>(
    id === null ? EMPTY : (cache.get(String(id)) ?? null),
  );
  useEffect(() => {
    if (id === null) return;
    const hit = cache.get(String(id));
    if (hit) return setRec(hit);
    let live = true;
    setRec(null);
    void fetchDon(id).then((d) => live && setRec(d));
    return () => {
      live = false;
    };
  }, [id]);
  return rec;
}

export function useTraits(id: bigint | number | null) {
  const [attrs, setAttrs] = useState<Attr[] | null>(
    id === null ? [] : (cache.get(String(id))?.attrs ?? null),
  );
  useEffect(() => {
    if (id === null) return;
    const hit = cache.get(String(id));
    if (hit) return setAttrs(hit.attrs);
    let live = true;
    setAttrs(null);
    void fetchTraits(id).then((a) => live && setAttrs(a));
    return () => {
      live = false;
    };
  }, [id]);
  return attrs;
}

/// Traits for many Dons, resolved progressively so a 400-Don desk paints as it loads rather than
/// blocking on the slowest request. Capped concurrency keeps a big pool from opening 83 sockets.
export function useTraitIndex(ids: (bigint | number)[], limit = 8) {
  const [index, setIndex] = useState<Record<string, Don>>({});
  const key = ids.map(String).join(",");
  useEffect(() => {
    let live = true;
    const queue = [...ids];
    const next = async (): Promise<void> => {
      const id = queue.shift();
      if (id === undefined || !live) return;
      const rec = await fetchDon(id);
      if (live) setIndex((m) => ({ ...m, [String(id)]: rec }));
      return next();
    };
    void Promise.all(
      Array.from({ length: Math.min(limit, queue.length) }, next),
    );
    return () => {
      live = false;
    };
  }, [key, limit]);
  return index;
}

export const traitText = (d?: Don) =>
  (d?.attrs ?? [])
    .map((a) => `${a.trait_type} ${a.value}`)
    .join(" ")
    .toLowerCase();

export function DonTraits({
  id,
  only,
}: {
  id: bigint | number | null;
  only?: number;
}) {
  const attrs = useTraits(id);
  if (id === null) return null;
  if (attrs === null)
    return <div className="don-traits live-note">reading traits…</div>;
  if (!attrs.length)
    return (
      <div className="don-traits live-note">
        Traits unrevealed for this Don.
      </div>
    );
  const shown = only ? attrs.slice(0, only) : attrs;
  return (
    <div className="don-traits">
      {shown.map((t) => (
        <span key={t.trait_type} className="don-trait">
          <em>{t.trait_type}</em>
          {t.value}
        </span>
      ))}
      {only && attrs.length > only ? (
        <span className="don-trait more">+{attrs.length - only}</span>
      ) : null}
    </div>
  );
}

/// The sheet as a player reads it. bps are probability points; the flat defense addend is a raw
/// number rather than a rate, so it is labelled separately instead of being folded into the percent.
export function DonStats({ id }: { id: bigint | number | null }) {
  const stats = useDon(id)?.stats ?? null;
  if (id === null) return null;
  if (!stats)
    return <div className="live-note">No stat sheet — traits unrevealed.</div>;
  const cells: [string, string][] = [
    ["attack", `+${stats.rpBps / 100}%`],
    [
      "defense",
      `+${stats.hdBps / 100}%${stats.hdFlat ? ` +${stats.hdFlat}` : ""}`,
    ],
    ["nerve", `+${stats.nrvBps / 100}pp`],
    ["luck", `+${stats.lckBps / 100}pp`],
    ["scout", `tier ${stats.guiTier}`],
    ["fee cut", `${stats.feeDiscBps / 100}%`],
  ];
  return (
    <div className="don-sheet">
      <div className="don-arch">{stats.archetype}</div>
      <div className="don-stats">
        {cells.map(([k, v]) => (
          <div key={k} className="don-stat">
            <em>{k}</em>
            <b>{v}</b>
          </div>
        ))}
      </div>
    </div>
  );
}
