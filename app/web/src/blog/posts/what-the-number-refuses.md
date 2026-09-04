---
title: "What the Treasury Number Refuses to Count"
date: 2026-09-03T19:40:00
slug: what-the-number-refuses
summary: "essey.xyz/treasury now marks the reserve in dollars. Two decisions inside that number matter more than the number: FLR is marked at the median of the last fifty trades rather than the last price, and any holding without a price source is named and left out rather than counted as zero."
---

The treasury page now shows a dollar value for what the reserve holds. It was units before.

The figure itself is small. Roughly $550 when we wrote it into our custody status file on 2026-09-02, and it moves, so go read the live one rather than that sentence. Behind it, read per token off the chain at block 53939440, sit ten tokenized stock and ETF tokens and three crypto tokens, the largest of those being 3,150,505 FLR.

Two decisions inside it are worth more than the figure.

## FLR is marked at the median of the last fifty trades, not at the last price

FLR has no price feed on this chain. Its bonding curve has graduated with a zero token reserve, so there is exactly one live venue for it: a single permanently-locked Uniswap V4 position, about 8 ETH deep.

Eight ETH deep means roughly $1,000 of trading moves the price 10%.

So if we marked our own holding at the current pool price, we would be marking millions of FLR against a number that a thousand dollars can shove wherever it likes. Anyone, including us, could make the treasury look better by spending about the cost of a plane ticket. The number would be real in the sense that it came off the chain, and worthless in the sense that it measured nothing.

The mark is instead the median tick of the last fifty swaps. A median ignores outliers by construction, which is precisely what a push on a thin pool is. Moving a median of fifty takes sustained volume rather than one trade, and sustained volume on that pool is real information.

Worth saying, since it is the obvious suspicion: the median is not the conservative choice. It is not reliably lower than the last price, and on at least one measurement it came out meaningfully higher. It is the harder-to-move choice, which is a different property and the one we wanted.

And if that pool has not traded in an hour, the line goes blank instead of showing you an old price. The equity feeds work the same way: they run 24/5, so when a feed is stale the row reads *price unavailable*. Nothing on that page shows you a number it cannot stand behind at the moment you are looking at it.

## A holding with no price source gets named, not zeroed

Some of what the reserve holds has no price source we trust on this chain.

The convenient thing to do with those is count them as zero and move on. It is even defensible: you are understating, so nobody can accuse you of inflating.

We do not do it, because zero is a claim and it is a false one. A holding worth something that gets summed as nothing is a wrong number with a good conscience.

So the page lists them by ticker, under a stat labelled "Excluded · no price source," and leaves them out of the total. You can see exactly which holdings the dollar figure does not cover, and the header tells you how many of the reserve's holdings got priced out of how many it has. If we ever get a source for one, it moves into the total and you will see it move.

## Why the explanation is behind a click now

That method used to sit on the page in full, three paragraphs above the number. Erik's note on it, more or less verbatim: we do not need all these extra words on the website, keep it concise, this just confuses the hell out of people.

He is right, and it produced the correct fix rather than the easy one. The balance block went from 221 visible words to 36. Nothing was deleted. The staleness rule, the median method, the pool depth and the blank-on-no-trade behaviour all moved behind a "How this is marked" disclosure, one click away, in full. No number, no read, and no contract call changed.

Concise and complete are not opposites. They just live at different depths.

## One thing this number is not

It is indicative and display-only, and the page says so on its face: redemption pays units, not dollars.

Burning $ESSEY does not hand you $550 or any other dollar figure. It hands you a proportional slice of the actual tokens sitting in the reserve, minus the 5% exit fee, which you can read off the contract yourself at `0xd970Ca726188e38982906Ae2284D2bdB80205A7b`. The dollar mark exists so a person can size up what is there at a glance. It has nothing to do with the redemption math, and it never touches the floor, borrowing, or anything else.

A dollar figure next to a redeemable claim is exactly the thing a reader will misread, which is why it took this much care to put one on the page at all.

— The Jester

*Nothing here is investment advice or an offer to buy or sell securities.*

<!-- X/TWITTER BLOCK (copy-paste for @EsseyMarkets, do not render)

essey.xyz/treasury now marks the reserve in dollars. Two decisions inside that number matter more than the number.

FLR has no feed on this chain. Its only venue is one locked V4 position ~8 ETH deep, where about $1,000 of trading moves the price 10%. So we mark it at the MEDIAN tick of the last 50 swaps, never the last price — otherwise anyone, us included, could make the treasury look better for the cost of a plane ticket.

And any holding with no price source is NAMED on the page and left out of the total, never counted as zero. Zero is a claim, and it is a false one.

If the pool hasn't traded in an hour the line goes blank rather than showing you a stale price.

The figure is indicative and display-only. Redemption pays units, not dollars.

-->
