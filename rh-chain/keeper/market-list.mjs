// Which markets the liveness keeper owes an observation to.
//
// G-LEND R4 HIGH-2: this used to be `process.env.MARKET_TOKENS.split(",")` and nothing checked it.
// A list holding one of two committed markets warned nowhere — the only warning fired when the list
// was EMPTY — so the second market's breaker measured drift and its corroborated price aged out,
// and the runbook did not mention the variable at all. The registry's own MarketCommitted log is
// the source of truth; the env var is only ever a cross-check that can raise an alarm.

const lower = (a) => String(a).toLowerCase();

/// `discovered` is every token MarketCommitted has ever named. `configured` is MARKET_TOKENS.
/// Returns the set the keeper OBSERVES, the set a supervisor must INSPECT, and what disagreed — so
/// the caller can say it out loud rather than silently covering whatever the scan happened to return.
export function reconcileMarkets({ discovered, configured }) {
  const seen = new Set();
  const tokens = [];
  for (const t of discovered) {
    if (seen.has(lower(t))) continue;
    seen.add(lower(t));
    tokens.push(t);
  }
  const cfg = (configured || []).filter(Boolean);
  const unknown = cfg.filter((c) => !tokens.some((t) => lower(t) === lower(c)));
  return {
    tokens,
    // Committed on chain, absent from the operator's list: observed anyway. Deriving rather than
    // trusting is the fix; the alarm exists so the config still gets corrected.
    missing: tokens.filter((t) => !cfg.some((c) => lower(c) === lower(t))),
    // Listed by the operator, absent from the scan. Usually a typo or an address from a superseded
    // stack — but it is ALSO what a short scan looks like, and the two are indistinguishable here.
    unknown,
    // G-LEND R5 MED-2: the union, for a caller that must not let the scan decide what it inspects.
    // The supervisor read the same `getLogs` the keeper derives its duty from, so a replica answering
    // SHORT but successfully — the one failure the 10,000-log cap and the 429 do not cover, since
    // both raise — hid the missing market from the control built to catch it.
    inspect: tokens.concat(unknown),
  };
}
