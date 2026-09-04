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
//
// G-LEND R7 LOW-1: that downgrade was granted on the WORD "unreadable" and nothing else — any
// duration, any of the four reverts. A negative-price aggregator for a fortnight read as Saturday
// and exited 0. Bounded on both axes below.

/// The ONE revert that means "the exchange is shut". `priceOf` also refuses PriceNotPositive
/// (StaleFeedGuard.sol:127), RoundIncomplete (:130) and FeedNotConfigured (:120) — a silent or
/// misconfigured aggregator, the failure that file exists to catch. The feed is APPEND-ONLY per
/// market (`commitMarket` reverts FeedIsImmutable), so relisting behind a 2-day timelock is the only
/// remedy and this alarm is the whole of the operator's warning.
const SCHEDULE_REVERT = "PriceStale";

/// How long unreadable may still BE the schedule. Four days, measured rather than chosen: the worst
/// gap either listed feed has produced is 79.74h AAPL / 76.09h NVDA, both the same 2026-07-02 ->
/// 07-06 Independence Day weekend — the longest closure the calendar makes, against 52-58h for an
/// ordinary one (`measure-feed-volatility.mjs` prints the five worst, dated). The ceiling has to
/// clear that: one red on every holiday weekend is R6 LOW-1 again, and infinity is R7 LOW-1.
export const MAX_DARK_AGE = 345_600n;

/// Which registry error a failed read carried, or null when nothing decodable did — fatal below,
/// the safe direction for a revert nobody has classified. Structural rather than a string match:
/// viem fills `data.errorName` only when the ABI passed to the read declares the error, so
/// `check-liveness-keeper.mjs` must keep declaring them.
export function revertName(err) {
  if (typeof err?.walk !== "function") return null;
  return err.walk((e) => e?.name === "ContractFunctionRevertedError")?.data?.errorName ?? null;
}

/// Is the registry willing to price this market right now, and if not, WHY not?
///
/// A revert means the registry itself refuses, and `priceOf` reverting past the market's own
/// `maxStaleness` is the ordinary weekend. A TRANSPORT failure means we know nothing — and answering
/// "not readable" to that would downgrade BREAKER BLIND on an RPC hiccup, which is a fail-OPEN on the
/// one check this file exists to keep honest. So a throw counts as a revert only once a second read
/// on the same contract proves the node is still answering; otherwise it propagates and the
/// supervisor dies loudly, which is what every other read here already does.
export async function priceState(readPrice, probeSameContract) {
  try {
    await readPrice();
    return { readable: true, revert: null };
  } catch (err) {
    await probeSameContract();
    return { readable: false, revert: revertName(err) };
  }
}

/// One market's findings, each `{ fatal, line }`. Pure: every input is read on chain by the caller.
export function classifyMarket({ token, confirmedAt, seenAt, now, delay, maxAge, maxBaseline, maxDark, price }) {
  // Comparing against `undefined` is silently false forever — the exact fail-open R7 LOW-1 is about.
  if (typeof maxDark !== "bigint") throw new Error("classifyMarket: maxDark (seconds, bigint) is required");
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
  if (price.readable) {
    say(true, `BREAKER BLIND  baseline is ${baseAge}s old, MAX_BASELINE_AGE ${maxBaseline}s, and the price READS — a split leg will not arm the breaker`);
    return out;
  }
  // Unreadable is the schedule only for the schedule's REASON and for no longer than it can last.
  // Either half alone leaves a broken aggregator indistinguishable from Saturday (R7 LOW-1).
  if (price.revert !== SCHEDULE_REVERT) {
    say(true, `FEED BROKEN  priceOf refuses with ${price.revert ?? "no decodable registry error"}, not ${SCHEDULE_REVERT} — that is a silent or misconfigured aggregator, not the session calendar`);
  } else if (baseAge > maxDark) {
    say(true, `FEED DARK TOO LONG  the price has been unreadable for ${baseAge}s, past the ${maxDark}s the exchange calendar can account for — the feed is APPEND-ONLY, so relisting behind the 2-day timelock is the only remedy`);
  } else if (observing) {
    say(false, `FEED DARK  the price is unreadable and the baseline is ${baseAge}s old — the keeper IS calling (corroborated observation ${confAge}s old), so this is the 24/5 feed's own schedule, and every gate behind it is already closed`);
  } else {
    say(false, `FEED DARK  baseline is ${baseAge}s old, price unreadable — the stopped keeper UNOBSERVED already names is the finding here`);
  }
  return out;
}
