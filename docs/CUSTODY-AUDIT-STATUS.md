# Custody audit status

Every contract that holds real value, and where its audit actually stands. Enforced by
`app/web/check-custody-audit.mjs`, which fails the site build if a custody contract is neither
audited nor acknowledged here. Re-affirm this file rather than remembering it.

**Why this file exists.** Erik, 2026-09-02: *"There should have been a rule where you caught that
the reserve was unaudited prior to me sending stock and tokens there. It's going to be a real screw
up if there is a bug in that contract."* He is right. `EsseyReserve` was deployed to mainnet,
published on `/treasury` as the deposit target, and received real tokenized stock and ~3.15M FLR —
and no audit document named it. The rule existed only as intent, so it was skipped. A `grep` for
`EsseyReserve` even *looks* covered, because it is a substring of `EsseyReserveHook`, which IS
audited. The gate matches on word boundaries for exactly that reason.

---

## EsseyReserve — `0xd970Ca726188e38982906Ae2284D2bdB80205A7b` (chain 4663)

- **Status: UNAUDITED at the time value was deposited. First audit commissioned 2026-09-02.**
- **Holds:** real tokenized stock (13 tokens) plus ~3,150,505 FLR. Marked ≈ $550 at the time of writing.
- **Cannot be patched.** Adminless: no owner, no admin, no upgrade path. If the audit finds a defect,
  the remedy is to stop adding and migrate — not to fix it in place.
- **Untested exit:** `receiptCount()` reads `0`. No redemption has ever been executed against this
  contract on mainnet. The way *out* is unproven in production, not just unaudited.
- **Accepted by:** nobody yet. This is an open risk, not an accepted one. It converts to either a
  clean audit receipt or an explicit dated acceptance below.

## Essey ($ESSEY token) — `0x315790B57C19141B34C4653a91b096Cf3f071610` (chain 4663)

- **Status: no audit document names the token contract itself.**
- **Holds:** no third-party value. Fixed supply, fully minted, 100% in the treasury wallet
  (`0x93e6…4B9E`); exactly one Transfer event exists on chain (the genesis mint). Nothing circulates,
  so no outside holder is exposed today.
- **Risk is forward-looking:** it becomes load-bearing the moment $ESSEY circulates or a market is
  seeded. Audit before either.

---

## Rule going forward

**No address is published as a place to send value until its contract has an audit document naming
it, or an explicit dated acceptance in this file.** The build enforces it. If this gate is ever
inconvenient, that is the gate working — the inconvenience is the point.
