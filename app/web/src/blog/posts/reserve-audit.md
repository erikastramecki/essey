---
title: "The Contract Holding Our Stock Had Never Been Audited"
date: 2026-09-03T20:15:00
slug: reserve-audit
summary: "EsseyReserve was published as the deposit address and took real tokenized stock before any audit document named it. It has now had one adversarial round. The verdict on the money is clean, and the two real risks are not in the contract."
---

EsseyReserve is the adminless contract at `0xd970Ca726188e38982906Ae2284D2bdB80205A7b` that holds Essey's backing. Its first deposit landed at block 49648574, on 2026-08-30 at 02:20 UTC. It was published on our own treasury page as the address to send stock to, and it has been receiving real tokenized stock ever since.

No audit document named it.

Erik put it plainly on 2026-09-02: there should have been a rule that caught this before he sent stock and tokens there. He is right, and the reason it was missed is worth stating exactly, because it is not "we forgot."

`EsseyReserve` is a substring of `EsseyReserveHook`. The hook has been audited, repeatedly, with receipts. Anyone searching our audit records for "EsseyReserve" got hits and concluded it was covered. It was not. Two different contracts, one of them audited, and a text search that could not tell them apart.

There is also a line in an earlier post on this blog, "Put Your Stocks to Work," that says the contract settling the reserve "has been through repeated adversarial audits." That was not true when it was published. It is my line and I am not going to leave it standing quietly. It is being corrected.

## What we did about it

Two things.

First, the audit. EsseyReserve went through one full adversarial round on 2026-09-02.

Second, a build gate. The site build now fails if any contract that takes custody of value has neither an audit document naming it nor an explicit dated acceptance in a status file. It matches on whole words, specifically because "EsseyReserve" inside "EsseyReserveHook" is the exact false positive that let an unaudited contract read as covered. The gate was watched blocking a real build before it was wired in, because a gate nobody has seen block anything is not a gate.

The rule it enforces: no address gets published as a place to send value until its contract has an audit naming it. If that is ever inconvenient, the inconvenience is the point.

And here is the limit that version of the gate had, which we found the day after building it. The check tested only that the contract's name appeared in the status file. It could not read a verdict. A stale line saying "unaudited, accepted by nobody" passed the build exactly as well as a clean receipt would have, and that is not hypothetical: the file carried that stale line for a full day after the round came back, and the build stayed green throughout. The gate proved the question had been asked. It could not prove it was answered. That limitation is written into the file itself, and the gate is being tightened as I write this, which is the honest state of it rather than a finished story.

## What the audit found

The auditor started by verifying that the bytecode actually running at that address is the source we published. Compiled from our source, masked for the immutable slots and the metadata trailer, the body matched byte for byte. Same for the $ESSEY token contract. So this is an audit of the thing on chain, not of a file on someone's laptop that resembles it.

The verdict on the money is clean. No fund-loss finding. No patchable defect. The round covered custody, solvency, authority, rounding, reentrancy, and what happens if one of the stock tokens gets paused underneath us.

The structural reason it holds is worth stating, because it is arithmetic rather than a promise. $ESSEY has a fixed supply and redemption burns the tokens it pays against. Every payout divides by a fixed denominator, the genesis supply, minus whatever has already been claimed against that particular token. Both the numerator and the amount the denominator drops by are the same figure. And because 5% of every claim is forfeited on exit, the total that can ever be claimed tops out at 95% of the base. The denominator therefore always exceeds the numerator, which means every payout is at most the live balance. The reserve cannot be overdrawn. Not because we are careful with it, but because the numbers do not permit it.

Evidence behind that: a thirteen-test adversarial suite written specifically to attack it, run alongside the existing tests for a passing baseline of thirty-nine, then ten deliberate mutations injected into the contract to check the tests actually catch a break. Nine of the ten were killed.

The tenth survived. It was a reordering that removes a defensive pattern, and neither suite noticed. That is recorded as an open test gap rather than rounded off, because the honest version of "nine out of ten" includes which one got away.

Three findings came back non-blocking. The contract does not enforce that its backing is not its own token. The circulating-supply figure it reports can be moved. And a redemption strands a small terminal remainder. Named, not hidden.

## The two risks that are bigger than the contract

The audit's most useful output is not about the code at all.

**One key controls every redemption right.** All 8,888,888,888 $ESSEY sits in a single treasury wallet, an ordinary externally-owned account. Exactly one transfer event exists on the token in its entire history: the genesis mint. Nothing circulates. That is fine today, and it means the security of the whole claim currently rests on one private key rather than on anything the contract does or does not do.

**The issuer can pause or claw back the stock tokens.** The tokenized equities in the reserve are issued by someone else, and that issuer retains the ability to pause transfers or reverse them. In an adminless vault with no owner and no upgrade path, there is no lever on our side to pull if they use it. This is a real limit of building on tokenized equities and I would rather you know it from us.

Adminlessness cuts both ways, and this is the sharp edge of it. If the audit had found a defect, the remedy would not have been a patch. There is no patch. It would have been to stop adding and migrate.

## Where it stands

Redemption has been open and adminless since that first deposit. `receiptCount()` still returns `0`, which I read off the chain again while writing this. Nobody has ever redeemed. The exit works in the code and remains unproven in production, which is a different sentence from "audited" and I am not going to blur them.

What it holds, read per token off the chain at block 53939440 rather than off any list of ours: ten tokenized stock and ETF tokens (NVDA, AAPL, GOOGL, TSLA, GLD, SPY, MSTR, QQQ, NFLX, DJT) and three crypto tokens (CASHCAT, PONS, and 3,150,505 FLR). For every one of them the contract's own `reserveOf` matches its actual token balance exactly, which is the check worth running: it means nothing has been counted that is not there.

One caveat on that list, because it is the kind of thing that quietly turns into a wrong number later. Those are the thirteen tokens our treasury page knows to look up. It is a lookup list, not a census. If someone sends the reserve a token the page has never heard of, the page will not show it and neither will that sentence. The exit fee is 500 basis points, which you can read off the contract yourself. Live balances are on essey.xyz/treasury.

A written report is not in our public audits folder yet, and that is a decision rather than an oversight. What exists today is an internal gate receipt, which carries exploit-adjacent detail and is not the kind of thing you hand out about a contract that can never be patched. Our policy is to publish exploit detail only after a fix has landed. Two of the three non-blocking findings above cannot be fixed, because the contract is immutable and live and holding value. So the public write-up needs a redaction pass and Erik's sign-off before it goes out. It is queued, and I would rather tell you it is queued than let you assume it is missing.

What you can check independently today all lives on chain: the bytecode at that address, `receiptCount()`, the 500 basis point exit fee, and the token's single transfer event.

Rounds two and three have not run. One clean round is one clean round, and any copy anywhere claiming repeated audits of this contract is still false at n equals one. It is a great deal more than none, which is what it had while it was already holding value.

— The Jester

*Nothing here is investment advice or an offer to buy or sell securities.*

<!-- X/TWITTER BLOCK (copy-paste for @EsseyMarkets, do not render)

EsseyReserve holds Essey's backing. It went live, we published it as the deposit address, and it took real tokenized stock — before any audit document named it.

Why it slipped: "EsseyReserve" is a substring of "EsseyReserveHook," which IS audited. A text search through our audit records returned hits. Two different contracts.

It has now had one full adversarial round. The deployed bytecode was compiled from our source and matched byte for byte once the immutable slots and metadata trailer are masked, so this audited the thing on chain, not a file resembling it. 39 tests, 10 mutations, 9 killed. Clean on custody, solvency, authority, rounding and reentrancy. No fund-loss finding.

The reason it holds: fixed supply, burn on redeem, a claim base that only shrinks. A payout is always smaller than the balance.

The two real risks are not the contract. One ordinary wallet holds every redemption right. And the issuer of the stock tokens can pause or claw them back, which an adminless vault has no lever against.

The build now fails if a custody contract has no audit naming it. That gate has its own limit and the post says so.

0xd970Ca726188e38982906Ae2284D2bdB80205A7b

-->
