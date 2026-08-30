// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Minimal Chainlink-shaped price feed for testnet. `set` re-stamps price and timestamp together,
/// because StaleFeedGuard rejects any answer older than the market's maxStaleness — a feed that is
/// never re-stamped silently disables borrowing rather than failing loudly.
contract MockFeed {
    int256 private _answer;
    uint256 private _updatedAt;
    uint8 public immutable decimals;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}
