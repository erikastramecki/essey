// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Chainlink feed addresses on Ink mainnet (chainId 57073), pulled from Chainlink's feed
/// directory (feeds-ethereum-mainnet-ink-1.json, read 2026-08-26), not transcribed from docs.
/// Every equity feed: Calculated, 3600s heartbeat, 0.1% deviation — they price Backed's WRAPPED
/// xStocks directly, so the rebasing multiplier is already in the price (ConstantMultiplier).
///
/// Each address was cross-checked by cast against Ink the day it was recorded (description(),
/// decimals(), fresh latestRoundData; USDG.decimals() == 6).
///
/// TODO-VERIFY-AT-DEPLOY, every address: the directory proves these existed when recorded, not
/// that they are live and correct at broadcast time. On-deploy re-verification by cast is
/// mandatory. DeployMarkets refuses to use these constants alone — the INK_* env vars must be
/// set AND match them, so a moved feed forces a conscious edit here and a typo'd env cannot ship.
library InkFeeds {
    address internal constant WNVDAX_USD = 0x2328B6602e93d07f69099a8b120846409B9D3047; // dec=8 heartbeat=3600s dev=0.1%
    address internal constant WSPYX_USD = 0x713e7F6f38779DC38a64B26862f2CfF1C10cADbf; // dec=8 heartbeat=3600s dev=0.1%
    address internal constant WQQQX_USD = 0x36E2BeFa7Ec599Bd30536c5F0f699818FDFE1Dd7; // dec=8 heartbeat=3600s dev=0.1%

    /// Paxos USDG on Ink (AD-3: venues quote in USDG; USDC would add a hop inside the S budget).
    /// Decimals are re-read from the chain at deploy, never trusted from here (the 1e12 lesson).
    address internal constant USDG = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;

    /// The PROXY, not the aggregator: the directory's contractAddress 0x71fb32E6e8AA18d1626F215A
    /// 742e957cc964A490 is the current aggregator BEHIND this proxy, and reading an aggregator
    /// directly goes dark on rotation. Consumers read proxies; the scope doc recorded the wrong one.
    address internal constant SEQUENCER_UPTIME = 0xFB6acA74A4069b69C4383e8BE8f7D34e4aFeC3Fb;

    uint32 internal constant HEARTBEAT = 3_600;
    uint32 internal constant RECOMMENDED_MAX_STALENESS = 7_200; // heartbeat + StaleFeedGuard.STALENESS_GRACE
}
