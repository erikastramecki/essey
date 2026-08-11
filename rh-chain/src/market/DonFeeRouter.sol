// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StaleFeedGuard} from "../StaleFeedGuard.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// Minimal Uniswap-V3 single-hop swap surface (same shape StockConverter uses on RH-chain).
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

/// DonFeeRouter — the `feeSink` that mint & AMM fees flow into, converting them to stock for the staked Dons.
///
/// Inputs it accumulates:
///   • ETH — 100% of every reroll/custom mint fee (from DonDistributor).
///   • $ESSEY — 70% of every AMM trade fee (from DonExchange).
///
/// Two flush legs, each ending with the produced USDG (the Bell's reward token) forwarded to the immutable
/// `bell` — growing the pot that pays out as Robinhood tokenized stock to the staked+activated Dons on the
/// next ring. So primary-market and trading activity literally buy stock for the seated holders.
///
///   • `flushEth` — PERMISSIONLESS. The minimum output is computed ON-CHAIN from the same Chainlink feed
///     machinery the lending core trusts (StaleFeedGuard: ETH/USD × USDG/USD, silent-feed + round checks,
///     fail-closed). No caller-supplied number participates, so an arbitrary caller cannot rig the bound
///     and sandwich the swap. Both feeds are 24/7 crypto feeds — the session flag doesn't apply.
///   • `flushEssey` — KEEPER-ONLY. $ESSEY has no oracle (it's the protocol token), so an honest bound
///     cannot be derived on-chain; a permissionless caller-quoted bound would be a sandwich invitation
///     (quote 1 wei → minOut ~0 → extract the whole leg). The keeper (protocol ops, admin-rotatable)
///     supplies its off-chain fair-value quote and the swap enforces `quote × minOutBps / 10000`.
///
/// Mirrors the existing FeeRouter's shape: idempotent, no custody beyond the in-flight balance. `admin`
/// (a multisig) can retune route params / slippage / keeper, but can NEVER redirect funds — both legs
/// only ever send USDG to the fixed `bell`.
contract DonFeeRouter is StaleFeedGuard, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable essey;
    IERC20 public immutable usdg; // the Bell's reward token
    IWETH public immutable weth;
    address public immutable bell; // fixed sink for the produced USDG — never changes
    address public immutable admin; // may retune route params + slippage + keeper; cannot move funds
    uint8 public immutable usdgDecimals;

    ISwapRouter public router; // the chain's Uniswap-V3 router
    uint24 public ethPoolFee; // WETH/USDG pool fee tier
    uint24 public esseyPoolFee; // $ESSEY/USDG pool fee tier
    uint256 public minOutBps; // bps of fair value each swap must deliver (both legs)
    address public keeper; // the only caller allowed to quote + flush the oracle-less $ESSEY leg

    uint256 internal constant BPS = 10_000;
    /// minOutBps below this would tolerate >10% slippage — indistinguishable from a sandwich allowance.
    uint256 internal constant MIN_OUT_FLOOR_BPS = 9_000;

    /// Everything the router needs at deploy, one struct (the legacy pipeline runs out of stack otherwise).
    struct Config {
        IERC20 essey;
        IERC20 usdg;
        IWETH weth;
        address bell;
        address admin;
        ISwapRouter router;
        uint24 ethPoolFee;
        uint24 esseyPoolFee;
        uint256 minOutBps;
        AggregatorV3Interface ethFeed; // ETH/USD (24/7 crypto feed)
        AggregatorV3Interface usdgFeed; // USDG/USD (24/7 crypto feed)
        AggregatorV3Interface sequencerUptimeFeed; // address(0) on RH-chain — see StaleFeedGuard
    }

    event FlushedEth(uint256 ethIn, uint256 usdgToBell);
    event FlushedEssey(uint256 esseyIn, uint256 usdgToBell);
    event RouteSet(address router, uint24 ethPoolFee, uint24 esseyPoolFee, uint256 minOutBps);
    event KeeperSet(address indexed keeper);

    error NotAdmin();
    error Expired();
    error NotKeeper();
    error ZeroAddress();
    error BadBps();
    error ZeroQuote();
    error ApproveFailed();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(Config memory c) StaleFeedGuard(c.sequencerUptimeFeed) {
        if (
            address(c.essey) == address(0) || address(c.usdg) == address(0) || address(c.weth) == address(0)
                || c.bell == address(0) || c.admin == address(0) || address(c.router) == address(0)
                || address(c.ethFeed) == address(0) || address(c.usdgFeed) == address(0)
        ) revert ZeroAddress();
        if (c.minOutBps < MIN_OUT_FLOOR_BPS || c.minOutBps > BPS) revert BadBps();
        essey = c.essey;
        usdg = c.usdg;
        weth = c.weth;
        bell = c.bell;
        admin = c.admin;
        usdgDecimals = IERC20Metadata(address(c.usdg)).decimals();
        router = c.router;
        ethPoolFee = c.ethPoolFee;
        esseyPoolFee = c.esseyPoolFee;
        minOutBps = c.minOutBps;
        keeper = c.admin; // rotatable via setKeeper
        // Both feeds are 24/7 crypto feeds on the standard RH-chain heartbeat; the guard's silent-feed and
        // incomplete-round checks apply, the equity-session flag does not.
        uint8 efd = c.ethFeed.decimals();
        uint8 ufd = c.usdgFeed.decimals();
        if (efd > 18 || ufd > 18) revert BadBps(); // normalization assumes <= 18 (Chainlink uses 8)
        _setFeed(address(c.weth), c.ethFeed, FEED_HEARTBEAT + STALENESS_GRACE, efd);
        _setFeed(address(c.usdg), c.usdgFeed, FEED_HEARTBEAT + STALENESS_GRACE, ufd);
    }

    receive() external payable {} // accept mint-fee ETH

    /// Swap all held ETH → USDG and forward it to the Bell. Permissionless: the slippage bound comes from
    /// the ETH/USD and USDG/USD oracles, not the caller, so triggering it can only ever help the pot.
    /// Fails closed — a stale/silent feed reverts and the ETH simply waits.
    function flushEth(uint256 deadline) external nonReentrant returns (uint256 usdgOut) {
        // Router02 carries no deadline field — the staleness bound is OURS to enforce.
        if (block.timestamp > deadline) revert Expired();
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) {
            uint256 minOut = (_ethFairUsdgOut(ethBal) * minOutBps) / BPS;
            weth.deposit{value: ethBal}();
            if (!weth.approve(address(router), ethBal)) revert ApproveFailed();
            router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(weth),
                    tokenOut: address(usdg),
                    fee: ethPoolFee,
                    recipient: address(this),
                    amountIn: ethBal,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }
        usdgOut = _sweepToBell();
        emit FlushedEth(ethBal, usdgOut);
    }

    /// Swap all held $ESSEY → USDG and forward it to the Bell. Keeper-only: $ESSEY has no oracle, so the
    /// fair-value quote (expected USDG out for the WHOLE held balance) must come from a caller we trust
    /// not to low-ball it; the swap still enforces `quote × minOutBps / 10000`.
    function flushEssey(uint256 deadline, uint256 usdgQuote) external nonReentrant returns (uint256 usdgOut) {
        if (block.timestamp > deadline) revert Expired();
        if (msg.sender != keeper) revert NotKeeper();
        uint256 esseyBal = essey.balanceOf(address(this));
        if (esseyBal > 0) {
            if (usdgQuote == 0) revert ZeroQuote();
            essey.forceApprove(address(router), esseyBal);
            router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(essey),
                    tokenOut: address(usdg),
                    fee: esseyPoolFee,
                    recipient: address(this),
                    amountIn: esseyBal,
                    amountOutMinimum: (usdgQuote * minOutBps) / BPS,
                    sqrtPriceLimitX96: 0
                })
            );
            essey.forceApprove(address(router), 0);
        }
        usdgOut = _sweepToBell();
        emit FlushedEssey(esseyBal, usdgOut);
    }

    /// Oracle-fair USDG for `ethIn` wei: ETH→USD on the ETH feed, USD→USDG on the USDG feed, both through
    /// StaleFeedGuard's fail-closed checks. Same normalization as StockConverter._oracleMinOut.
    function _ethFairUsdgOut(uint256 ethIn) internal view returns (uint256) {
        (uint256 ethPx, uint8 ethFd,) = priceOf(address(weth));
        (uint256 usdgPx, uint8 usdgFd,) = priceOf(address(usdg));
        uint256 usdValue18 = (ethIn * (ethPx * 10 ** (18 - ethFd))) / 1e18; // ETH is 18-decimals native
        return (usdValue18 * 10 ** usdgDecimals) / (usdgPx * 10 ** (18 - usdgFd));
    }

    /// Forward every USDG held to the Bell — the only place funds can ever leave to.
    function _sweepToBell() internal returns (uint256 amount) {
        amount = usdg.balanceOf(address(this));
        if (amount > 0) usdg.safeTransfer(bell, amount);
    }

    /// Retune the swap route + slippage bound (admin/multisig). Cannot move funds — `bell` is immutable.
    function setRoute(ISwapRouter router_, uint24 ethPoolFee_, uint24 esseyPoolFee_, uint256 minOutBps_)
        external
        onlyAdmin
    {
        if (address(router_) == address(0)) revert ZeroAddress();
        if (minOutBps_ < MIN_OUT_FLOOR_BPS || minOutBps_ > BPS) revert BadBps();
        router = router_;
        ethPoolFee = ethPoolFee_;
        esseyPoolFee = esseyPoolFee_;
        minOutBps = minOutBps_;
        emit RouteSet(address(router_), ethPoolFee_, esseyPoolFee_, minOutBps_);
    }

    /// Rotate the $ESSEY-leg keeper (admin/multisig).
    function setKeeper(address keeper_) external onlyAdmin {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }
}
