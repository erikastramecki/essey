// What one market's on-chain state says about the KEEPER — which is not what it says about the FEED.
//
// G-LEND R6 LOW-1: `BREAKER BLIND` fired on `seenPriceAt` alone, which advances only through a
// READABLE price — so on a 24/5 feed, dark ~40h of every 168h, the check exited 1 for a quarter of
// every week on a keeper doing everything right. This is the control R4 HIGH-2 was closed with and
// R5 MED-2 was spent hardening, and it announces R6 MED-1's precondition: the last thing that
// should be noise, because a muted alarm IS the "market nobody observes" blind spot.
//
// The two are separable without guessing. `confirmedObservedAt` advances on every CALL, warmed or
// not, so it answers "is the keeper observing" and is already fatal on its own ceiling. Readability
// is the registry's own `priceOf` answering rather than reverting — the contract's bound, not a
// timestamp heuristic. Stale baseline while the price READS is the keeper failing to read a feed
// that answers: fatal. Stale baseline while it does not read is the feed's own schedule, every gate
// behind it already closed. Reported, not alarmed.

/// Is the registry willing to price this market right now?
///
/// A revert means the registry itself refuses, and `priceOf` reverting past the market's own
/// `maxStaleness` is the ordinary weekend. A TRANSPORT failure means we know nothing — and answering
/// "not readable" to that would downgrade BREAKER BLIND on an RPC hiccup, which is a fail-OPEN on the
/// one check this file exists to keep honest. So a throw counts as a revert only once a second read
/// on the same contract proves the node is still answering; otherwise it propagates and the
/// supervisor dies loudly, which is what every other read here already does.
export async function priceReadable(readPrice, probeSameContract) {
  try {
    await readPrice();
    return true;
  } catch {
    await probeSameContract();
    return false;
  }
}

/// One market's findings, each `{ fatal, line }`. Pure: every input is read on chain by the caller.
export function classifyMarket({ token, confirmedAt, seenAt, now, delay, maxAge, maxBaseline, priceReadable }) {
  const out = [];
  const say = (fatal, line) => out.push({ fatal, line: `${token}  ${line}` });

  if (confirmedAt === 0n) {
    say(true, "UNCORROBORATED  the delay line has never filled — liquidation is refused");
    return out;
  }
  const confAge = now - confirmedAt;
  // Too old is the keeper having stopped observing; too young means the ring is running ahead of its
  // own cadence, which should be impossible and is worth seeing if it ever happens.
  const observing = confAge <= maxAge;
  if (!observing) {
    say(true, `UNOBSERVED  corroborated observation is ${confAge}s old, ceiling ${maxAge}s — liquidation is refused`);
  } else if (confAge < delay) {
    say(true, `PREMATURE  corroborated observation is only ${confAge}s old, floor ${delay}s`);
  }

  const baseAge = now - seenAt;
  if (baseAge <= maxBaseline) return out;
  if (priceReadable) {
    say(true, `BREAKER BLIND  baseline is ${baseAge}s old, MAX_BASELINE_AGE ${maxBaseline}s, and the price READS — a split leg will not arm the breaker`);
  } else if (observing) {
    say(false, `FEED DARK  the price is unreadable and the baseline is ${baseAge}s old — the keeper IS calling (corroborated observation ${confAge}s old), so this is the 24/5 feed's own schedule, and every gate behind it is already closed`);
  } else {
    say(false, `FEED DARK  baseline is ${baseAge}s old, price unreadable — the stopped keeper UNOBSERVED already names is the finding here`);
  }
  return out;
}
