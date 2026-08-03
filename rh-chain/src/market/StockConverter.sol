// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StaleFeedGuard} from "../StaleFeedGuard.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IConverter, ISwapRouter} from "./IConverter.sol";

/// StockConverter — the Bell's claim-edge converter: base reward asset (e.g. USDG) → a Robinhood
/// Stock Token, on-chain via the Uniswap route live on Robinhood Chain, priced against the same
/// Chainlink feeds the lending core uses.
///
/// Fairness is enforced here, not trusted to the pool: output must be at least the ORACLE-implied
/// amount minus `maxSlippageBps`, with all of StaleFeedGuard's fail-closed discipline (silent-feed
/// check, holiday check, session gating). Off-hours there is no verifiable equity price, so
/// conversion refuses (`NotInSession`) — the Bell catches the revert and pays base instead. Declining
/// is always safe; overpaying never is.
///
/// Custody: none at rest. Base is pulled from the caller only inside `convert`, and the router
/// delivers the stock DIRECTLY to the recipient (the Seat's Vault).
///
/// Admin surface (deliberate, minimal): an append-only stock registry. `registrar` (the deployer /
/// treasury ops) can ADD payout targets but can never modify or remove one — so a token users
/// already opted into cannot have its feed or pool swapped underneath them. A bad addition only
/// affects Seats that explicitly opt into that token, and the worst it can do is fail their
/// conversion (→ base fallback). The registrar holds no power over funds.
contract StockConverter is IConverter, StaleFeedGuard, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct StockConfig {
        uint24 uniFee; // Uniswap pool fee tier for base->stock
        uint8 tokenDecimals;
        bool listed;
    }

    ISwapRouter public immutable router;
    IERC20 public immutable base;
    uint8 public immutable baseDecimals;
    uint256 public immutable maxSlippageBps;
    address public immutable registrar;

    mapping(address => StockConfig) public stocks;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_SLIPPAGE_BPS = 500; // 5% hard ceiling on the config

    event StockListed(address indexed token, address feed, uint24 uniFee);
    event Converted(address indexed caller, address indexed token, uint256 amountIn, uint256 amountOut, address recipient);

    error BadConfig();
    error NotRegistrar();
    error AlreadyListed();
    error NotListed();
    error NotInSession();
    error ZeroAmount();

    constructor(
        ISwapRouter router_,
        IERC20 base_,
        AggregatorV3Interface baseFeed_,
        AggregatorV3Interface sequencerUptimeFeed_,
        uint256 maxSlippageBps_,
        address registrar_
    ) StaleFeedGuard(sequencerUptimeFeed_) {
        if (
            address(router_) == address(0) || address(base_) == address(0) || address(baseFeed_) == address(0)
                || registrar_ == address(0) || maxSlippageBps_ == 0 || maxSlippageBps_ > MAX_SLIPPAGE_BPS
        ) revert BadConfig();
        router = router_;
        base = base_;
        baseDecimals = IERC20Metadata(address(base_)).decimals();
        maxSlippageBps = maxSlippageBps_;
        registrar = registrar_;
        // Base priced through the same guard machinery (USDG/USD is a 24/7 crypto-style feed; the
        // session flag it returns is ignored for the base leg).
        uint8 bfd = baseFeed_.decimals();
        if (bfd > 18) revert BadConfig(); // normalization assumes <= 18 (Chainlink uses 8)
        _setFeed(address(base_), baseFeed_, FEED_HEARTBEAT + STALENESS_GRACE, bfd);
    }

    /// Append-only: list a stock as a payout target. Configs are immutable once listed.
    function listStock(address token, AggregatorV3Interface feed, uint24 uniFee) external {
        if (msg.sender != registrar) revert NotRegistrar();
        if (token == address(0) || address(feed) == address(0) || token == address(base)) revert BadConfig();
        if (stocks[token].listed) revert AlreadyListed();
        uint8 fd = feed.decimals();
        if (fd > 18) revert BadConfig(); // normalization assumes <= 18 (Chainlink uses 8)
        stocks[token] = StockConfig(uniFee, IERC20Metadata(token).decimals(), true);
        _setFeed(token, feed, FEED_HEARTBEAT + STALENESS_GRACE, fd);
        emit StockListed(token, address(feed), uniFee);
    }

    function isSupported(address token) external view returns (bool) {
        return stocks[token].listed;
    }

    /// Pull `amountIn` base from the caller, swap to `targetToken`, deliver directly to `recipient`.
    /// Reverts (never under-delivers) if the equity session is closed, a feed fails any StaleFeedGuard
    /// check, or the pool can't beat the oracle-implied minimum.
    function convert(uint256 amountIn, address targetToken, address recipient)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        StockConfig memory cfg = stocks[targetToken];
        if (!cfg.listed) revert NotListed();

        uint256 minOut = _oracleMinOut(amountIn, targetToken, cfg.tokenDecimals);

        base.safeTransferFrom(msg.sender, address(this), amountIn);
        base.forceApprove(address(router), amountIn);
        amountOut = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(base),
                tokenOut: targetToken,
                fee: cfg.uniFee,
                recipient: recipient, // straight to the Vault — no custody here
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        base.forceApprove(address(router), 0);
        emit Converted(msg.sender, targetToken, amountIn, amountOut, recipient);
    }

    /// Oracle-fair minimum output. Both legs go through StaleFeedGuard: silent feeds, incomplete
    /// rounds, and holiday gaps all revert (fail closed -> the Bell pays base). The stock leg
    /// additionally requires a live US session — there is no verifiable equity price off-hours.
    function _oracleMinOut(uint256 amountIn, address targetToken, uint8 tgtDecimals)
        internal
        view
        returns (uint256)
    {
        (uint256 basePx, uint8 baseFeedDec,) = priceOf(address(base));
        (uint256 stockPx, uint8 stockFeedDec, bool inSession) = priceOf(targetToken);
        if (!inSession) revert NotInSession();

        // Normalize both prices to 1e18: usd = in * basePx / 10^baseDec; out = usd * 10^tgtDec / stockPx.
        uint256 usdValue18 = (amountIn * (basePx * 10 ** (18 - baseFeedDec))) / 10 ** baseDecimals;
        uint256 fairOut = (usdValue18 * 10 ** tgtDecimals) / (stockPx * 10 ** (18 - stockFeedDec));
        return (fairOut * (BPS - maxSlippageBps)) / BPS;
    }
}
