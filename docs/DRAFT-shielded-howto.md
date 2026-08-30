# Essey Private — "How to use it, in steps" (DRAFT, mainnet framing)

Ready-to-drop-in explainer for the top of the `/private` page (essey.xyz), after the
"What this is" intro and before the functional panels. NOT yet in the app — hold until the
shielded contracts are deployed to Robinhood Chain **mainnet** and `/private` is re-wired.

Framing: real shielded transfers on Robinhood Chain, real assets (USDG / AAPL / NVDA), real
gas. No "testnet", no "Experimental", no free-faucet step.

Naming is verbatim from the live page's existing scope: **Essey Private**, **shielded**
(pools / balance — hides amounts), **stealth addresses** (hides identity), **Shield**,
**Register to receive**, **Send in-pool**, **Withdraw** (via relayer), **Set up private
address**, **Pay privately**, **Sweep**. Each step maps to a real control — the
`app/web/src/private.tsx:line` is the HEAD version at time of drafting.

---

## Send a shielded transfer — hide the amount

Move tokens into a shielded pool. Inside, your balance and your transfers are invisible, and
deposits can't be linked to withdrawals.

1. **Connect your wallet** on Robinhood Chain. — `ConnectButton` (private.tsx:276)
2. **Choose what to make private** — USDG, a stock (AAPL / NVDA), or yield-bearing supply —
   then **Unlock shielded balance** (one signature, nothing spent). — pool selector
   "Choose what to make private:" (private.tsx:288, options private.tsx:290–295); "Unlock
   shielded balance" button (private.tsx:305)
3. Enter an amount and **Shield** it (deposit into the pool). Your balance is now hidden. —
   "Shield … →" / "Supply USDG →" button (private.tsx:376); `shield` handler (private.tsx:180)
4. To be paid by someone else, tap **Register to receive** once (a small tx). Not needed to
   move your own funds. — "Register to receive" button + copy (private.tsx:341–342)
5. Move it with **Send in-pool** to another shielded user, or take it out with **Withdraw**.
   Leave **via relayer** checked so it's gasless and the transaction doesn't come from your
   wallet. — "Send in-pool →" button (private.tsx:386), in-pool note (private.tsx:388);
   "via relayer" checkbox (private.tsx:348–349); "Withdraw →" / "Unshield →" button
   (private.tsx:400)

> Your balance is made of separate deposits ("notes"), and each transfer spends one at a
> time — so send or withdraw large amounts in a few steps. — (private.tsx:329)

---

## Get paid privately — hide who you are

Receive at a fresh one-time address nobody can link to you. Amounts stay public here; what's
hidden is the link to your identity.

1. **Set up private address** (one signature), then share your meta-address — or just give
   senders your wallet address, which resolves to it. — "Set up private address" button
   (private.tsx:425); "Your private address" section + share copy (private.tsx:416, 430);
   "copy meta-address" (private.tsx:433)
2. The sender taps **Pay privately**; the funds land at a fresh one-time address only you can
   find. — "Pay privately →" button (private.tsx:454); one-time-address result copy
   (private.tsx:241)
3. **Sweep** the funds to your real wallet whenever you're ready. — "Sweep received funds
   to:" + "sweep →" (private.tsx:466, 492); amounts-public framing (private.tsx:270)

---

## Drop-in notes (for whoever places this into private.tsx later)

- Insert as a `pf-block` after the "What this is" `live-card` (private.tsx:265–272), before
  the connect gate (private.tsx:274). Reuse only existing classes: `pf-block`, `pf-block-h`,
  `live-card`, `live-note`, `pf-note`, `preview-chip`, `pf-link gold`; number each step with
  `.num` + the `--gold` token (mirrors the site's `.step .no` treatment). No new primitives.
- The mainnet cut drops the old testnet-only step ("grab free gas ETH + play tokens on the
  Quest page", private.tsx:281) — on mainnet gas and assets are real.
- Re-verify every `private.tsx:line` after the re-wire; line numbers will move.
- Two labels differ from the coordinator's brief and MUST use the code's real text: the
  in-pool transfer button is **"Send in-pool →"** (private.tsx:386), and the stealth-payment
  button is **"Pay privately →"** (private.tsx:454) under the **"Send privately"** section
  header (private.tsx:442). Do not relabel controls to match the prose.
