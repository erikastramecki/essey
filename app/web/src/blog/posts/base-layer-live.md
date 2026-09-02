---
title: The Base Layer Is Live
date: 2026-08-29
slug: base-layer-live
summary: We minted the full fixed supply of $ESSEY, deployed the adminless EsseyReserve, and put the first real tokenized stock into the floor as a small test deposit. It works end to end, and every holding is on-chain and yours to check.
---

**2026-08-29.**

Today Essey went from a design doc to something you can read on-chain. The base layer, the floor under $ESSEY, is live on Robinhood Chain, and it's holding its first real stock. Here's exactly what we did, and how to check every word of it, down to the balance.

## What we did today

Minted the full supply. The entire fixed supply of $ESSEY, 8,888,888,888 tokens, is minted to the treasury wallet. Fixed means fixed. There's no mint function on the token, so nothing can dilute it later, not us in a weak moment, not anyone. The redemption math under the token keys off this one genesis number and nothing else.

Deployed the EsseyReserve, the adminless floor. This is the reserve that sits under $ESSEY, and it's the reason we built things this way. No owner, no admin, no setter, no withdraw, no pause, no upgrade. Nobody, us included, can pull assets out of it or change how it pays. It does two things: takes a deposit, and pays a holder their pro-rata slice back out. That's the whole surface. The floor can't be moved because we never built a lever to move it.

Put the first real stock into the floor. I sent a small test deposit of real tokenized equities from the treasury wallet into the reserve, and the contract picked it up exactly the way it should. Three tokens right now: a bit of MSTR, a bit of GLD, and a bit of NVDA. And I do mean a bit. These are deliberately tiny amounts, fractions of a single share each. The point was never to fund the thing to the moon on day one. The point was to prove the whole mechanism works end to end with real assets before anything bigger rides on it. Safer than sorry. It worked. The floor took the deposit, the accounting registered it, and you can read the exact holdings yourself.

## The honest size of it

I'm not going to dress this up as more than it is. The floor is real and it is small. Right now it holds roughly 0.0093 MSTR, 0.0146 GLD, and 0.0373 NVDA. That is a proof, not a war chest, and I'd rather you hear that from me than do the math and feel misled. What matters today is that the machine functions with real stock in it, adminlessly, and that the number is a number you can verify instead of a claim you have to swallow. It grows from here, out in the open, one honest deposit and one fee stream at a time.

## How redemption works

Holding $ESSEY is a redeemable claim on that pile. When you redeem you burn your $ESSEY and get a receipt, then you claim your slice of each token, in kind. You collect 95% of your pro-rata share. The other 5%, the exit fee, stays in the reserve and spreads across everyone still holding. It never leaves. So every redemption leaves the token a little more backed for the people who stayed.

## Verify it yourself

You don't have to take any of this on faith. That's sort of the entire idea. Read it on Robinhood Chain (mainnet, chain 4663):

- **$ESSEY:** `0x315790B57C19141B34C4653a91b096Cf3f071610`
- **EsseyReserve:** `0xd970Ca726188e38982906Ae2284D2bdB80205A7b`

Call `EXIT_FEE_BPS()` on the reserve and you get `500`. That's the 5%. Read `claimBase()` and you get the genesis supply the math is pinned to. Look for an owner and the call reverts, because there isn't one. Call `reserveOf()` for MSTR, GLD, or NVDA, or just check the reserve's balance of each token directly, and you'll see the same small numbers I just quoted. The contract's own accounting and the raw token balance agree, because the floor simply holds what it holds.

That's the point. The floor isn't a promise in a blog post. It's a contract with no keys and a balance you can look at whenever you want, whether the balance is big or, like today, honestly small. Solvency you can prove beats solvency you're promised.

More to come. Growing the floor, the redeem path in the UI, then the road toward borrowing and, later, bonds against real surplus. One honest step at a time.

the founder

*Nothing here is financial advice. $ESSEY has no market yet, so there's no price to imply. Tokenized equities are securities. Do your own research.*
