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

**VERDICT: ACCEPTED-RISK — recorded 2026-09-03 by Claude, pending founder confirmation.**
Round 1 came back CLEAN on the money (receipt `~/.claude/gate-receipts/audit-esseyreserve-r1`), but that
is an internal receipt, not a published report, and rounds 2 and 3 have not run. So the honest state is
not "audited" — it is "one clean round, carried deliberately." What is being accepted: n=1, three
unpatchable residuals (R-1, R-2, R-3), and an exit path never exercised on mainnet (`receiptCount()` = 0).
This converts to CLEAN when a redacted report is published to `docs/audits/` and the founder signs it off.

- **Status 2026-09-03: ROUND 1 CLEAN on the money.** It was UNAUDITED at the time value was
  deposited — that remains the fact this file was created over — and the first round came back
  2026-09-02. Receipt: `~/.claude/gate-receipts/audit-esseyreserve-r1`, over
  `rh-chain/src/market/EsseyReserve.sol` sha256 `079ec296…4ccfd1`, git `bf5b3cd`.
- **Verdict:** clean on custody, solvency, authority, rounding, reentrancy and paused-token
  isolation. **No fund-loss finding. No patchable defect.** Evidence: a 13-test adversarial suite
  plus a 10-mutant campaign; baseline 39/39.
- **Deployed bytecode VERIFIED against source.** `cast code` on the address is byte-identical to
  `solc 0.8.28` (optimizer disabled, legacy pipeline) after masking the 11 immutable slots and the
  53-byte metadata trailer. On-chain immutables read back as `essey=0x315790b5…071610`,
  `claimBase=8.888e27`. `EsseyToken` likewise. **This is the first Essey contract proven to be the
  source we publish.**
- **Three non-blocking findings, open:** R-1 self-backing is not enforced and `circulatingSupply` is
  manipulable; R-2 a 5% terminal strand; **R-3 a test gap — the CEI-removal mutant (MUT4) survived
  both suites** while 9 of 10 others were killed.
- **The two risks that dominate contract risk are operational, not code:** the treasury EOA is a
  single key over 100% of redemption rights, and issuer pause/upgrade on the stock legs is
  unrecoverable inside an adminless vault.
- **Holds:** real tokenized stock plus ~3,150,505 FLR. Marked ≈ $550 at the time of writing.
  ⚠️ **"13 tokens" was wrong and is corrected here.** `app/web/src/reserve.ts:44-58` lists **13
  addresses**, and its own comment (`:41-43`) says that list is *"only what the page KNOWS to look
  up… Any token in here that the reserve does not hold simply reads zero"* — **a lookup list, not a
  holdings count.** Of the 13, three are not equities at all (CASHCAT, PONS, FLR), so "13 tokenized
  stocks" over-counts twice over. `MAINNET-ACTIVATION.md` separately records a *"re-derived on-chain
  basket of six."* **The only honest holdings figure is a live per-token read of the reserve
  address** — cite that, never the BASKET length.
- **Cannot be patched.** Adminless: no owner, no admin, no upgrade path. R-1 and R-2 are therefore
  permanent residuals, not a to-do list. The remedy for any future defect is to stop adding and
  migrate — not to fix it in place.
- **Untested exit:** `receiptCount()` reads `0`. No redemption has ever been executed against this
  contract on mainnet. The way *out* is unproven in production — that is unchanged by the audit.
- **Not yet published to `docs/audits/`.** Deliberate, not forgotten: R-1 and R-2 are unpatchable
  residuals on a live immutable contract holding real value, and the fix-first policy
  (`audits/README.md`) publishes exploit detail only after a fix lands. A public report needs a
  redaction pass and founder sign-off. **Queued.**
- **Rounds 2 and 3 have not run.** One clean round is one clean round. Any public copy saying
  "repeated audits" is still false at n=1.

## Essey ($ESSEY token) — `0x315790B57C19141B34C4653a91b096Cf3f071610` (chain 4663)

**VERDICT: ACCEPTED-RISK — recorded 2026-09-03 by Claude, pending founder confirmation.**
No audit document names the token contract. It is carried because it holds no third-party value today:
fixed supply, fully minted, 100% in the treasury wallet, exactly one Transfer event on chain, nothing
circulating. Nobody outside is exposed. **This acceptance expires the moment $ESSEY circulates or a
market is seeded** — audit before either, not after.

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

## What this gate does NOT do (found 2026-09-03, do not mistake it for coverage)

`app/web/check-custody-audit.mjs:52-53` tests only that the contract's **name appears** in this file
(`new RegExp(\`\\b${c.name}\\b\`).test(status)`). It cannot read a verdict. **A stale line saying
"UNAUDITED, accepted by nobody yet" passes the build exactly as well as a clean receipt does** —
which is precisely what happened: this file carried that line for a full day after round 1 came back
clean, and the build stayed green throughout.

The gate proves the question was **asked**. It cannot prove it was **answered**. Re-read the entries,
do not trust the green.
