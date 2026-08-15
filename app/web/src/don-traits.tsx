import { useEffect, useState } from "react";

export type Attr = { trait_type: string; value: string };

// Testers are expected to hold 5-10 Dons each and the pool holds ~83, so the same metadata gets asked
// for repeatedly across the desk, the picker and the filter. Cached at module scope: a combo's traits
// never change, and an in-flight promise is shared rather than refetched.
const cache = new Map<string, Attr[]>();
const inflight = new Map<string, Promise<Attr[]>>();

export function fetchTraits(id: bigint | number): Promise<Attr[]> {
  const key = String(id);
  const hit = cache.get(key);
  if (hit) return Promise.resolve(hit);
  const live = inflight.get(key);
  if (live) return live;
  const p = fetch(`/api/don/${key}`)
    .then((r) => (r.ok ? r.json() : null))
    .then((d) => {
      const attrs: Attr[] = d?.attributes ?? [];
      cache.set(key, attrs);
      return attrs;
    })
    .catch(() => [] as Attr[])
    .finally(() => inflight.delete(key));
  inflight.set(key, p);
  return p;
}

export function useTraits(id: bigint | number | null) {
  const [attrs, setAttrs] = useState<Attr[] | null>(
    id === null ? [] : (cache.get(String(id)) ?? null),
  );
  useEffect(() => {
    if (id === null) return;
    const hit = cache.get(String(id));
    if (hit) return setAttrs(hit);
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
  const [index, setIndex] = useState<Record<string, Attr[]>>({});
  const key = ids.map(String).join(",");
  useEffect(() => {
    let live = true;
    const queue = [...ids];
    const next = async (): Promise<void> => {
      const id = queue.shift();
      if (id === undefined || !live) return;
      const attrs = await fetchTraits(id);
      if (live) setIndex((m) => ({ ...m, [String(id)]: attrs }));
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

export const traitText = (attrs?: Attr[]) =>
  (attrs ?? [])
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
