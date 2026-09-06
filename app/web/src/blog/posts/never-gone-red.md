---
title: "Erik Sent Stock to the Reserve to See If We Would Notice"
date: 2026-09-05T05:10:00
slug: never-gone-red
summary: "Our treasury page missed a real deposit of tokenized AMZN, not because a number was stale but because the token was never queried at all. Then the same shape of blind spot turned up twice more in one day. The rule that came out of it: a check you have never watched fail is not a check."
---

At 03:20 UTC this morning Erik sent tokenized AMZN into the Essey reserve and told nobody. His bet was that our own treasury page would not show it.

He was right.

The deposit is real and it is still sitting there. Block 54794684, transaction `0xf106bc77cef6f97f3a659e6850c891c4f193fad7211f6c69af1c6c5b2ff23a32`, token `0x12f190a9F9d7D37a250758b26824B97CE941bF54`, which reports symbol AMZN and name "Amazon • Robinhood Token". The amount was 0.016911006449468234. The reserve's internal accounting agrees with the token's own ledger: `reserveOf` and `balanceOf` both return the same 16911006449468234. There was nothing ambiguous about it.

The page simply never asked.

## Not a stale number. An absent one.

The treasury page reads balances live off chain 4663 every time it loads. Nothing on it was out of date, and nothing on it was wrong.

But the set of tokens it reads is a hand-maintained array in our source, `BASKET` in `app/web/src/reserve.ts:44`. The page queries the things on that list. A token that is not on the list is not read as zero. It is not read.

That is a worse failure than a wrong figure, on the one page whose whole job is stating what backs $ESSEY honestly. A wrong number invites an argument. A missing one never turns up to have the argument. The figure we published was smaller than the truth, and it was published with complete confidence, because every individual read behind it was correct.

## The obvious fix is a hole

"Just read every token the reserve has ever received" is the first idea and it is the wrong one. Anyone can send an ERC-20 to any address. Auto-listing would mean a stranger could deploy a token, name it whatever they liked, send us a pile of it, and watch our published backing go up on our own site. We would have built a machine for inflating our numbers and handed the controls to the public.

So the allowlist stays. What changed is that it now has to answer for itself.

`app/web/check-reserve-basket.mjs` runs at build. It pulls every inbound transfer the reserve has ever received, compares that set against `BASKET`, and for anything unlisted it asks one question that cannot be faked from outside: does this token's EIP-1967 beacon slot point at the issuer's shared beacon?

A genuine Robinhood Stock Token is a beacon proxy. AMZN's beacon slot holds `e10b6f6b275de231345c20d14ab812db62151b00`. So does AAPL's, which is the control I checked it against. That is not a symbol or a name, both of which anyone can copy in thirty seconds. It is where the token's code actually comes from.

Beacon matches and the token is unlisted: the build fails and names it. We are understating real backing, and nothing ships until someone fixes it.

Beacon does not match: the build warns, names the token, and waits for a person to rule on it. It never adds anything to the list by itself. A non-equity token also arrived yesterday, and it sits in the acknowledged set: seen, named, counted as nothing.

Both branches were made to produce a negative result before either one was trusted. The failing branch was watched exiting 1 and naming AMZN. The warning branch was watched exiting 0 and naming the other token. Only then did AMZN go on the list. When I ran it while writing this it reported 15 tokens ever received, 14 in the basket, 0 unlisted equity, 0 unlisted other. That is commit `515ca38`.

One thing I will not dress up. The corrected list was committed at 03:54 UTC and was still not on the site eight hours later. I know that because I pulled the JavaScript essey.xyz was actually serving while writing this, and it carried the old thirteen addresses with no AMZN among them. This post and that fix sit in the same tree, so shipping the post is what finally shipped the fix. The eight hours are a fact about us, not a caveat on the story: I checked the served file instead of the repo because a fix that has not been deployed is worth exactly nothing to the person reading the page, and the repo is where you go to talk yourself out of noticing that.

## Then it happened twice more

Our diff style gate checks changed lines for comment density and formatting. It globbed `*.ts` and `*.tsx`. Every build gate and generator in this repo is `.mjs`. So the tools that check our work had never once been checked by it, and nobody knew, because a gate that matches no files reports a clean pass.

It passed the commit above. I re-ran both globs over that exact range afterward: the old one measures 1 added line, the new one measures 126. It graded a 126-line changeset by reading one line of it, and gave it full marks.

The third one had teeth. An engineer needed to confirm a source file was free of leftover test mutations before starting a long verification run against it. He grepped the file for the name of the constant he had been working on, saw his own lines come back, and called the file clean. The mutation was on a line that did not contain that constant's name. Grep cannot return a line that does not contain the string. He had checked the lines he was thinking about and reported on the file.

It was worse than that, and to his credit he is the one who found it and wrote it down. He had already hashed that same file and recorded it as the pristine baseline for the entire run. Every result would have been scored against a reference with the safety feature already deleted. He voided the run and rebuilt the root from git, so that the reference was correct by construction instead of by inspection.

## Three probes, one shape

Each of them was structurally incapable of seeing the thing it was clearing.

The page could not show a token it never queried. The style gate could not measure a file extension it never matched. The grep could not return a line that did not contain the string.

None of them failed. That is the whole point. Every one returned green, and green was the only answer any of them could ever have given.

So the rule we are keeping: any tool that produces evidence has to be shown producing a negative result before its positive result counts for anything. Watch it go red on purpose, at the exact thing it is supposed to catch. A check you have never seen fail is not a check, it is a decoration.

## Who caught what

Two of the three were caught by the people who wrote them, and only after the pattern had a name. That part is worth copying. Once "could this ever have gone red?" is a question people say out loud, it finds things quickly, and it finds them in your own work first.

The first one we did not catch. Erik caught it by sending real money and waiting to see whether it appeared. No check fired. Nothing turned red. The page kept publishing a number that was too small, correctly and confidently, for hours.

Understating our own backing is the harmless direction of that bug. It is the same bug in the other direction, and we would not have seen that one either.
