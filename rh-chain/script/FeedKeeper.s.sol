// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// TESTNET feed keeper — the mock Chainlink feeds go stale after ~25h (FEED_HEARTBEAT+GRACE), which
// makes the converter revert (stock payouts fail open to USDG), Cases sell-back revert, and degen buy
// revert. This re-stamps each feed with its CURRENT price + a fresh timestamp (MockFeed.set is
// unguarded), so run it on a cron. Running it DURING a US market session also refreshes the stock
// feeds' updatedAt past the session open, keeping stock-leg payouts valid for that session.
//
//   forge script script/FeedKeeper.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
import {Script, console} from "forge-std/Script.sol";

interface IMockFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function set(int256 a, uint256 u) external;
}

contract FeedKeeper is Script {
    function run() external {
        address[7] memory feeds = [
            0x6ac94CAb7302415A9a29d9746Fb6051523592E3b, // USDG/USD — converter + Cases base leg
            0xc9ff487ba1F5b4EEDbEcEF96Da6D0184FE9cb392, // converter AAPL
            0x25CEEE7Af98bB2CD736eE573e7c17E4901C80b78, // converter NVDA
            0x0A226ffe69D6B51c15FfbA5413F32B2383961854, // degen AAPL
            0x01F40F92A83A2184b7C69eCE9a870A5f1420c08f, // Cases AAPL
            0x8Fe3f8BCC2450a4c63e61ABDD93A17f8783319B9, // Cases NVDA
            0x64c3599454FE31A14814ab86C3f0863dE990fe36  // ETH/USD — DonFeeRouter flushEth leg
        ];
        vm.startBroadcast();
        for (uint256 i = 0; i < feeds.length; i++) {
            (, int256 ans,,,) = IMockFeed(feeds[i]).latestRoundData();
            if (ans > 0) IMockFeed(feeds[i]).set(ans, block.timestamp); // preserve price, bump freshness
        }
        vm.stopBroadcast();
        console.log("refreshed feeds:", feeds.length, "at ts", block.timestamp);
    }
}
