---
title: "The Only Real $ESSEY Contract"
date: 2026-09-01T19:33:00
slug: only-real-essey-contract
summary: "There is one $ESSEY on Robinhood Chain mainnet, at one address, and it is the only one that is a claim on the reserve. The game runs on a separate chain with a play-money token that also displays as ESSEY. Here is how to tell them apart in under a minute."
---

A short, straight heads-up from the desk. This post was corrected on 2026-09-04; the note is at the bottom, and the correction is the reason the checking instructions below changed.

There is one official $ESSEY, on Robinhood Chain mainnet (chainId 4663). This is its address:

**`0x315790B57C19141B34C4653a91b096Cf3f071610`**

That is the only $ESSEY that is a claim on the reserve. On mainnet there is no other one. If an address doesn't match those characters exactly, on that chain, it isn't the token I'm talking about.

Say the chain out loud, every time, because that is where people get robbed: **one contract, chain 4663, `0x3157…071610`.** Any token calling itself $ESSEY on any other chain is not this token and is not a claim on the reserve. That includes our own game's play money, which I explain below.

Every token that will ever exist, all 8,888,888,888 of them, currently sits in one treasury wallet, `0x93e6e42CcC676614FB3635b0983d60F35dDE4B9E`. None has been sold to anyone. You can read that balance yourself.

## One thing to be clear about

$ESSEY is not tradable at this time. No market has been seeded against it. There is no pool, no price, no place to buy or sell it right now.

So if you see something trading as "$ESSEY" on a DEX or an exchange, it is not ours. Treat it as a scam and walk away. I would rather tell you that plainly now than clean it up later.

The reserve the token redeems against, the adminless floor that holds the backing, is here:

**`0xd970Ca726188e38982906Ae2284D2bdB80205A7b`**

That's a backing ledger, not a price. It has no owner and no admin keys. It holds what it holds, and you can read it.

## The game runs play money that also says ESSEY

This is the part I got wrong the first time, so I want it stated properly.

The D.O.N. game does not run on mainnet. It runs on a separate chain, chainId 46630, and the token it uses there is play money. That play-money token reports its symbol as `ESSEY` and its name as `Essey`, exactly like the real one. It lives at `0x32a860B1Eaa02A07c0b8a9eB6E3c51B7ce823d1F`, and at that same address on mainnet there is no contract at all.

Three things about it, plainly:

- **It is free.** A faucet hands out 500,000 of it to any address that asks, once every eight hours. Anything you can print half a million of before lunch is not an asset.
- **It moves inside the game.** It prices Dons in the game's own market there, so it does change hands. What it does not have is a market outside the game, a price, or a buyer.
- **It is not a claim on anything.** The reserve does not know it exists. Burning it gets you nothing.

It is a scoreboard for a game on its own chain. It is not the mainnet token, it is not worth money, and if anyone offers to buy it from you, that is the whole tell.

## How to check it yourself

The old version of this post told you to confirm the name reads Essey, the symbol reads ESSEY, and the supply is 8,888,888,888. All three of those match on both tokens, which makes it a test that nothing can fail. My mistake, and it is now fixed. What actually separates them is two things:

1. **The chain.** Real one: Robinhood Chain mainnet, chainId 4663. The game's play money is on 46630. If your wallet or explorer is not on 4663, whatever it is showing you is not the token that redeems against the reserve.
2. **The address.** `0x315790B57C19141B34C4653a91b096Cf3f071610`, character for character. Not the leading four, not the trailing four. All of it.

Then, on mainnet, confirm the reserve address above is the one the token points at. Name and symbol prove nothing. Anyone can name a token anything.

The contract block is live right now on **essey.xyz/treasury**, with a copy button and a direct explorer link, so you have one canonical place to grab the real address and check it against whatever's in front of you.

## Correction, 2026-09-04

The original version of this post said there was "no second contract, no v2, no bridge, no pre-sale address." I wrote that as an absolute, about every chain everywhere, and in that form it was wrong. On the one page whose whole job is protecting people, that is the worst place to be loose with a word.

To be exact about what was wrong, because the exactness is the point: **on mainnet 4663 nothing has changed. There is one $ESSEY there, at the address above, and there never was a second one.** What I denied too broadly was the play-money token on chainId 46630, which our own code comment calls v2, and which this site hands out from a faucet. So a reader could take that token from us and then read a post from us saying it didn't exist. That is on me, and the fix is to say which chain I mean every time instead of saying "never" and hoping.

I also dropped the "no bridge" claim rather than restate it. I can prove what is deployed; I cannot prove a universal negative about every contract on every chain, and the imprecision in that sentence is exactly what produced the error. The claims left standing are the ones I read off the chain myself.

Nothing about the warning changed: one $ESSEY on mainnet 4663, at that address, and anything trading as "$ESSEY" anywhere is still not ours.

— The Jester

<!-- X/TWITTER BLOCK (copy-paste for @EsseyMarkets, do not render)

Corrected, and the correction makes the warning sharper.

There is one official $ESSEY, on Robinhood Chain mainnet (chainId 4663):

0x315790B57C19141B34C4653a91b096Cf3f071610

It is the only one that is a claim on the reserve. All 8,888,888,888 tokens still sit in the treasury wallet. None sold.

The D.O.N. game runs on a separate chain (46630) with play money that also displays as ESSEY. A faucet gives away 500,000 of it every 8 hours. It is not the mainnet token and it is not worth anything.

So do NOT check the name and symbol. They match on both. Check the CHAIN (4663) and the full address.

Anything trading as "$ESSEY" on a DEX or exchange is not ours.

essey.xyz/blog/only-real-essey-contract

-->
