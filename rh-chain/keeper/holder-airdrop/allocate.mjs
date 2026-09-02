import { getAddress } from "viem";

export const BPS = 10_000n;

/// Split `total` across `parts` by weight with largest-remainder, so the integer pieces sum EXACTLY to
/// `total` and never one wei more. The exactness is the point: HolderDistributor._settle caps every claim
/// at reserved-minus-claimed (src/market/HolderDistributor.sol:265-266), so a root that over-attributes
/// does not overpay — it turns the epoch into a race where whoever claims last is refused.
export function apportion(total, parts) {
  if (parts.length === 0) return [];
  const sum = parts.reduce((s, p) => s + p.w, 0n);
  const out = parts.map((p) => ({ key: p.key, amount: 0n, rem: 0n }));
  if (sum === 0n || total === 0n) return out.map(({ key, amount }) => ({ key, amount }));
  for (let i = 0; i < parts.length; i++) {
    const num = total * parts[i].w;
    out[i].amount = num / sum;
    out[i].rem = num % sum;
  }
  let leftover = total - out.reduce((s, o) => s + o.amount, 0n);
  const byRemainder = [...out].sort((a, b) => (a.rem === b.rem ? cmpKey(a.key, b.key) : a.rem > b.rem ? -1 : 1));
  for (let i = 0; leftover > 0n; i++, leftover--) byRemainder[i].amount += 1n;
  return out.map(({ key, amount }) => ({ key, amount }));
}

// Must return 0 on equality: the leaf sort chains `cmpKey(token) || cmpKey(holder)`, and a comparator
// that answered 1 for equal tokens would short-circuit and never order holders at all.
function cmpKey(a, b) {
  const x = String(a).toLowerCase();
  const y = String(b).toLowerCase();
  return x < y ? -1 : x > y ? 1 : 0;
}

/// A holder's basket is their signed preference when it names a committed basket, else the default.
/// An unknown or retired id silently falls back rather than dropping the holder — a bad preference must
/// never cost someone their airdrop.
export function resolveBaskets({ holders, preferences = new Map(), baskets, defaultBasketId }) {
  if (!baskets.has(defaultBasketId)) throw new Error(`allocate: default basket ${defaultBasketId} is not committed`);
  const assigned = new Map();
  for (const { holder } of holders) {
    const wanted = preferences.get(holder);
    assigned.set(holder, wanted !== undefined && baskets.has(wanted) ? wanted : defaultBasketId);
  }
  return assigned;
}

/// How much USDG each (basket, token) leg should buy. Pro-rata by basket weight, then by basket bps.
export function planBuys({ holders, assigned, baskets, usdgPot }) {
  const weightOf = new Map();
  for (const { holder, weight } of holders) {
    const id = assigned.get(holder);
    weightOf.set(id, (weightOf.get(id) ?? 0n) + weight);
  }
  const ids = [...weightOf.keys()].sort((a, b) => Number(a) - Number(b));
  const perBasket = apportion(BigInt(usdgPot), ids.map((id) => ({ key: id, w: weightOf.get(id) })));

  const contributions = new Map(); // token => Map(basketId => usdg)
  for (const { key: id, amount } of perBasket) {
    const basket = baskets.get(id);
    const legs = apportion(amount, basket.tokens.map((t, i) => ({ key: getAddress(t), w: BigInt(basket.bps[i]) })));
    for (const { key: token, amount: usdg } of legs) {
      if (usdg === 0n) continue;
      if (!contributions.has(token)) contributions.set(token, new Map());
      const perToken = contributions.get(token);
      perToken.set(id, (perToken.get(id) ?? 0n) + usdg);
    }
  }
  const buys = [...contributions.entries()]
    .map(([token, m]) => ({ token, usdg: [...m.values()].reduce((s, v) => s + v, 0n) }))
    .sort((a, b) => cmpKey(a.token, b.token));
  return { basketWeight: weightOf, contributions, buys };
}

/// Turn what was ACTUALLY bought (reserved[epoch][token], read from chain) into per-holder leaves.
/// Received stock is split back to baskets by the USDG each basket contributed to that token, then to
/// holders by weight within the basket. Zero-amount legs are dropped: _settle reverts on amount == 0
/// (src/market/HolderDistributor.sol:261), and the dust they leave stays sweepable to the floor sink.
export function allocate({ epoch, holders, assigned, contributions, reserved }) {
  const membersOf = new Map();
  for (const h of holders) {
    const id = assigned.get(h.holder);
    if (!membersOf.has(id)) membersOf.set(id, []);
    membersOf.get(id).push(h);
  }
  const leaves = [];
  for (const token of [...reserved.keys()].map(getAddress).sort(cmpKey)) {
    const received = BigInt(reserved.get(token) ?? reserved.get(token.toLowerCase()) ?? 0n);
    if (received === 0n) continue;
    const perBasket = contributions.get(token) ?? new Map();
    const ids = [...perBasket.keys()].sort((a, b) => Number(a) - Number(b));
    const shares = apportion(received, ids.map((id) => ({ key: id, w: perBasket.get(id) })));
    for (const { key: id, amount: share } of shares) {
      const members = membersOf.get(id) ?? [];
      const cuts = apportion(share, members.map((m) => ({ key: m.holder, w: m.weight })));
      for (const { key: holder, amount } of cuts) {
        if (amount === 0n) continue;
        leaves.push({ epoch: BigInt(epoch), holder, token, amount });
      }
    }
  }
  leaves.sort((a, b) => cmpKey(a.token, b.token) || cmpKey(a.holder, b.holder));
  return leaves;
}

/// K1, the keeper's one solvency duty: no token may be attributed beyond what the epoch actually holds.
export function assertWithinReserved(leaves, reserved) {
  const owed = new Map();
  for (const l of leaves) owed.set(l.token, (owed.get(l.token) ?? 0n) + l.amount);
  for (const [token, total] of owed) {
    const have = BigInt(reserved.get(token) ?? reserved.get(token.toLowerCase()) ?? 0n);
    if (total > have) throw new Error(`allocate: root over-attributes ${token} — ${total} owed vs ${have} reserved`);
  }
  return owed;
}
