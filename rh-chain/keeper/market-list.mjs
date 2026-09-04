// Which markets the liveness keeper owes an observation to.
//
// G-LEND R4 HIGH-2: this used to be `process.env.MARKET_TOKENS.split(",")` and nothing checked it.
// A list holding one of two committed markets warned nowhere — the only warning fired when the list
// was EMPTY — so the second market's breaker measured drift and its corroborated price aged out,
// and the runbook did not mention the variable at all. The registry's own MarketCommitted log is
// the source of truth; the env var is only ever a cross-check that can raise an alarm.

const lower = (a) => String(a).toLowerCase();

/// `discovered` is every token MarketCommitted has ever named. `configured` is MARKET_TOKENS.
/// Returns the set to observe plus what disagreed, so the caller can say it out loud.
export function reconcileMarkets({ discovered, configured }) {
  const seen = new Set();
  const tokens = [];
  for (const t of discovered) {
    if (seen.has(lower(t))) continue;
    seen.add(lower(t));
    tokens.push(t);
  }
  const cfg = (configured || []).filter(Boolean);
  return {
    tokens,
    // Committed on chain, absent from the operator's list: observed anyway. Deriving rather than
    // trusting is the fix; the alarm exists so the config still gets corrected.
    missing: tokens.filter((t) => !cfg.some((c) => lower(c) === lower(t))),
    // Listed by the operator, never committed: dropped, and worth saying — it is usually a typo or
    // an address from a superseded stack.
    unknown: cfg.filter((c) => !tokens.some((t) => lower(t) === lower(c))),
  };
}
