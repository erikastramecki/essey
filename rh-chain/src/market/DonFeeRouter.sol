// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// Minimal Uniswap-V3 single-hop swap surface (same shape StockConverter uses on RH-chain).
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
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
/// On a permissionless `flush()` it swaps the accumulated ETH (via WETH) and $ESSEY into **USDG** (the Bell's
/// reward token) on the chain's Uniswap-V3 router, then forwards the USDG to the **Bell** — growing the pot that
/// pays out as Robinhood tokenized stock to the staked+activated Dons on the next ring. So primary-market and
/// trading activity literally buy stock for the seated holders.
///
/// Mirrors the existing FeeRouter's shape: idempotent, permissionless flush, no custody beyond the in-flight
/// balance. Swaps use a `minOut` slippage guard; an oracle-fair min-out (as in StockConverter) is the planned
/// refinement. Route params (WETH, router, pool fee) are wired at deploy; `admin` (a multisig) can retune them
/// and the slippage bound, but can NEVER redirect funds — `flush` only ever sends USDG to the fixed `bell`.
contract DonFeeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable essey;
    IERC20 public immutable usdg; // the Bell's reward token
    IWETH public immutable weth;
    address public immutable bell; // fixed sink for the produced USDG — never changes
    address public immutable admin; // may retune route params + slippage; cannot move funds

    ISwapRouter public router; // the chain's Uniswap-V3 router
    uint24 public ethPoolFee; // WETH/USDG pool fee tier
    uint24 public esseyPoolFee; // $ESSEY/USDG pool fee tier
    uint256 public minOutBps; // slippage floor as bps of a caller-supplied quote (see flush)

    uint256 internal constant BPS = 10_000;

    event Flushed(uint256 ethIn, uint256 esseyIn, uint256 usdgToBell);
    event RouteSet(address router, uint24 ethPoolFee, uint24 esseyPoolFee, uint256 minOutBps);

    error NotAdmin();
    error ZeroAddress();
    error BadBps();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(
        IERC20 essey_,
        IERC20 usdg_,
        IWETH weth_,
        address bell_,
        address admin_,
        ISwapRouter router_,
        uint24 ethPoolFee_,
        uint24 esseyPoolFee_,
        uint256 minOutBps_
    ) {
        if (
            address(essey_) == address(0) || address(usdg_) == address(0) || address(weth_) == address(0)
                || bell_ == address(0) || admin_ == address(0) || address(router_) == address(0)
        ) revert ZeroAddress();
        if (minOutBps_ > BPS) revert BadBps();
        essey = essey_;
        usdg = usdg_;
        weth = weth_;
        bell = bell_;
        admin = admin_;
        router = router_;
        ethPoolFee = ethPoolFee_;
        esseyPoolFee = esseyPoolFee_;
        minOutBps = minOutBps_;
    }

    receive() external payable {} // accept mint-fee ETH

    /// Convert everything held (ETH + $ESSEY) to USDG and forward it to the Bell. Permissionless. `deadline`
    /// and the per-leg `quote`s (expected USDG out, e.g. from an off-chain/oracle read) come from the caller;
    /// each swap enforces `amountOutMinimum = quote * minOutBps / 10000`, so a stale/thin pool can't be
    /// sandwiched past the slippage bound. Passing 0 for a leg's quote skips that leg.
    function flush(uint256 deadline, uint256 ethUsdgQuote, uint256 esseyUsdgQuote)
        external
        nonReentrant
        returns (uint256 usdgOut)
    {
        uint256 ethBal = address(this).balance;
        uint256 esseyBal = essey.balanceOf(address(this));

        if (ethBal > 0 && ethUsdgQuote > 0) {
            weth.deposit{value: ethBal}();
            weth.approve(address(router), ethBal);
            router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(weth),
                    tokenOut: address(usdg),
                    fee: ethPoolFee,
                    recipient: address(this),
                    deadline: deadline,
                    amountIn: ethBal,
                    amountOutMinimum: (ethUsdgQuote * minOutBps) / BPS,
                    sqrtPriceLimitX96: 0
                })
            );
        }
        if (esseyBal > 0 && esseyUsdgQuote > 0) {
            essey.forceApprove(address(router), esseyBal);
            router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(essey),
                    tokenOut: address(usdg),
                    fee: esseyPoolFee,
                    recipient: address(this),
                    deadline: deadline,
                    amountIn: esseyBal,
                    amountOutMinimum: (esseyUsdgQuote * minOutBps) / BPS,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        usdgOut = usdg.balanceOf(address(this));
        if (usdgOut > 0) usdg.safeTransfer(bell, usdgOut); // grows the Bell pot → stock to staked Dons
        emit Flushed(ethBal, esseyBal, usdgOut);
    }

    /// Retune the swap route + slippage bound (admin/multisig). Cannot move funds — `bell` is immutable.
    function setRoute(ISwapRouter router_, uint24 ethPoolFee_, uint24 esseyPoolFee_, uint256 minOutBps_)
        external
        onlyAdmin
    {
        if (address(router_) == address(0)) revert ZeroAddress();
        if (minOutBps_ > BPS) revert BadBps();
        router = router_;
        ethPoolFee = ethPoolFee_;
        esseyPoolFee = esseyPoolFee_;
        minOutBps = minOutBps_;
        emit RouteSet(address(router_), ethPoolFee_, esseyPoolFee_, minOutBps_);
    }
}
