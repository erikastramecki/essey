// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EsseyMarkets} from "../EsseyMarkets.sol";
import {EsseyPool} from "../EsseyPool.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {Note} from "./Note.sol";

/// Multiply — leveraged stock exposure as PURE PERIPHERY over the pool's public surface.
///
/// A levered position here is a LADDER of Notes built in one transaction — borrow against the
/// stock, buy more stock with the proceeds, borrow against that, repeat — each rung a plain pool
/// position at or under the market's own LTV. No pool or registry change, no new invariants: every
/// rung is exactly what a user could have opened by hand.
///
/// The ladder used to be justified by "the pool has no borrowMore()", and that premise is now
/// FALSE (EsseyPool.borrowMore). The ladder is kept anyway, on its own merits: each rung carries
/// its own bearer Note, so a holder can sell, transfer or close ONE rung, and partial deleverage is
/// just closing a subset. A single growing position would collapse all of that into one deed.
///
/// Custody is atomic-only. Every Note minted here is transferred to the caller before the
/// transaction ends, and the contract holds no balances between transactions — it is a stateless
/// router plus one config table. Anything sent here outside a call is lost to the next caller;
/// do not send funds directly.
///
/// The close path deliberately reads NO oracle and calls NOTHING but repay() and the swap venue:
/// it must work in every state the pool's own repay works in (market disabled, cap 0, stale
/// feed, off-session). Slippage protection on close is therefore the caller's absolute `minOut`,
/// never an oracle-derived bound that could gate an exit the pool itself allows.
contract EsseyMultiply is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotAdmin();
    error ZeroMarkets();
    error AlreadyListed(address token);
    error NotListed(address token);
    error AdapterNotContract();
    error BadLeverageCap();
    error Expired();
    error ZeroAmount();
    error NoActivePool(address token);
    error WrongPool(address pool);
    error LeverageMissed(uint256 achieved, uint256 target, uint256 tolerance);
    error AboveMaxLeverage(uint256 achieved, uint256 max);
    error SlippageExceeded(uint256 received, uint256 minOut);
    error SeedExceeded(uint256 needed, uint256 seedMax);
    error PositionAlreadyClosed(uint256 id);
    error BadOraclePrice();

    event MarketListed(address indexed token, address adapter, uint256 maxLeverageBps);
    event MultiplyOpened(
        address indexed user,
        address indexed token,
        address pool,
        uint256[] ids,
        uint256 collateralIn,
        uint256 totalDebt,
        uint256 leverageBps
    );
    event MultiplyClosed(
        address indexed user, address indexed pool, uint256[] ids, uint256 seedUsed, uint256 assetOut, uint256 collateralOut
    );

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// open()'s request, as one calldata struct: seven loose parameters plus the ladder's
    /// running totals exceed solc's stack frame, and via_ir is script-profile-only in this repo.
    struct OpenParams {
        address token;
        uint256 collateralIn;
        /// Target leverage in BPS of equity (18_000 = 1.8x). Must exceed BPS and stay within
        /// the market's configured maximum.
        uint256 targetLeverageBps;
        uint256 toleranceBps;
        uint256 maxNotes;
        uint256 maxSlippageBps;
        uint256 deadline;
    }

    struct OpenState {
        EsseyPool pool;
        IERC20 asset;
        uint256 totalValue;
        uint256 need;
        uint256 totalDebt;
        uint256 chunk;
        uint256 n;
    }

    struct CloseState {
        address token;
        ISwapAdapter adapter;
        IERC20 asset;
        Note note;
        uint256 cash;
        uint256 seedUsed;
    }

    /// Per-market entry: listing a stock for Multiply is a config row, never new code. The pair
    /// is append-only (the feed/multiplierSource precedent): a swapped adapter or a raised cap on
    /// a live market is a rug or a risk change with no notice — new venue or new limit means a
    /// new periphery deployment, which is free because this contract is stateless.
    struct MarketConfig {
        ISwapAdapter adapter;
        uint32 maxLeverageBps;
    }

    EsseyMarkets public immutable markets;
    mapping(address => MarketConfig) public config;
    /// Pools this periphery has itself opened rungs in, taken at open time from `markets.activePool`
    /// — the timelocked authority. `close()` accepts the current active pool or one of these, and
    /// nothing else.
    ///
    /// LOW-2: the only binding used to be `pool.markets() == markets`, which any contract satisfies
    /// by returning the right address — after which collateralToken(), asset(), note(), debtOf() and
    /// repay() are all attacker-defined and the approval below lands on an address of their choosing.
    /// No user funds were reachable, but "anything left here is lost to the next caller" had become
    /// "lost to whoever pre-positioned the largest allowance". A superseded pool stays closable
    /// because this map remembers it.
    mapping(address => bool) public openedIn;

    constructor(EsseyMarkets markets_) {
        if (address(markets_) == address(0)) revert ZeroMarkets();
        markets = markets_;
    }

    function listMarket(address token, ISwapAdapter adapter, uint32 maxLeverageBps) external {
        if (msg.sender != markets.admin()) revert NotAdmin();
        if (address(config[token].adapter) != address(0)) revert AlreadyListed(token);
        if (address(adapter).code.length == 0) revert AdapterNotContract();
        if (maxLeverageBps <= BPS) revert BadLeverageCap();
        config[token] = MarketConfig(adapter, maxLeverageBps);
        emit MarketListed(token, address(adapter), maxLeverageBps);
    }

    /// Open a levered position: pull `collateralIn` of `token`, then loop borrow -> buy -> borrow
    /// until the extra debt-funded exposure reaches `targetLeverageBps` (in BPS of equity;
    /// 18_000 = 1.8x). Reverts as a whole — never a partial position — if any rung would exceed
    /// the market or position cap (the pool's own revert aborts everything), if `maxNotes` rungs
    /// cannot reach the target within `toleranceBps`, or if slippage pushes the achieved leverage
    /// past the market's configured maximum. All Notes end up with the caller.
    ///
    /// Caller must have approved this contract for `p.collateralIn` of `p.token`.
    function open(OpenParams calldata p) external nonReentrant returns (uint256[] memory ids) {
        if (block.timestamp > p.deadline) revert Expired();
        MarketConfig memory cfg = config[p.token];
        if (address(cfg.adapter) == address(0)) revert NotListed(p.token);
        if (p.targetLeverageBps <= BPS || p.targetLeverageBps > cfg.maxLeverageBps) {
            revert AboveMaxLeverage(p.targetLeverageBps, cfg.maxLeverageBps);
        }
        OpenState memory s;
        s.pool = EsseyPool(markets.activePool(p.token));
        if (address(s.pool) == address(0)) revert NoActivePool(p.token);
        openedIn[address(s.pool)] = true;
        s.asset = IERC20(s.pool.asset());

        IERC20(p.token).safeTransferFrom(msg.sender, address(this), p.collateralIn);
        (s.totalValue,) = markets.collateralValue(p.token, p.collateralIn);
        // `need` is the debt still to be raised: at target L, D = V0 x (L - 1). Slippage makes the
        // bought value lag the borrowed amount, nudging achieved leverage ABOVE target — which the
        // tolerance and the hard config cap below both bound.
        s.need = (s.totalValue * (p.targetLeverageBps - BPS)) / BPS;
        if (s.need == 0 || p.collateralIn == 0) revert ZeroAmount();

        uint256[] memory tmp = new uint256[](p.maxNotes);
        s.chunk = p.collateralIn;
        while (s.need != 0 && s.n < p.maxNotes) {
            uint256 bi = markets.maxBorrow(p.token, s.chunk);
            if (bi > s.need) bi = s.need;
            if (bi == 0) break;
            IERC20(p.token).forceApprove(address(s.pool), s.chunk);
            tmp[s.n++] = s.pool.borrow(s.chunk, bi);
            s.chunk = _buyStock(cfg.adapter, s.asset, p.token, bi, p.maxSlippageBps);
            (uint256 vOut,) = markets.collateralValue(p.token, s.chunk);
            s.totalValue += vOut;
            s.totalDebt += bi;
            s.need -= bi;
        }

        uint256 achieved = (s.totalValue * BPS) / (s.totalValue - s.totalDebt);
        if (achieved + p.toleranceBps < p.targetLeverageBps || achieved > p.targetLeverageBps + p.toleranceBps) {
            revert LeverageMissed(achieved, p.targetLeverageBps, p.toleranceBps);
        }
        if (achieved > cfg.maxLeverageBps) revert AboveMaxLeverage(achieved, cfg.maxLeverageBps);

        // The final purchase backs no rung of its own (a zero-debt position is unopenable —
        // pool NoDebt). Fold it into the FIRST rung: exposure is unchanged and every share of
        // stock sits as position collateral, lowering rung 1's liquidation risk.
        IERC20(p.token).forceApprove(address(s.pool), s.chunk);
        s.pool.addCollateral(tmp[0], s.chunk);

        Note note_ = s.pool.note();
        ids = new uint256[](s.n);
        for (uint256 i; i < s.n; ++i) {
            ids[i] = tmp[i];
            note_.transferFrom(address(this), msg.sender, tmp[i]);
        }
        emit MultiplyOpened(msg.sender, p.token, address(s.pool), ids, p.collateralIn, s.totalDebt, achieved);
    }

    /// Unwind rungs, in the caller's order. Each repay needs the debt in hand BEFORE the pool
    /// releases collateral, so the FIRST rung is funded from the caller's seed (`seedMax` bounds
    /// what may be pulled) and every later rung cascades from selling the collateral already
    /// released — order the ids smallest-debt-first to minimize the seed. The seed comes back
    /// inside the payout. Closing a SUBSET is partial deleverage; the untouched rungs stay put.
    ///
    /// `toCollateral` = true skips the venue entirely: the caller funds every repay (seed must
    /// cover the whole debt) and takes the collateral back as stock. `minOut` is the absolute
    /// floor on what is returned — stock in that mode, borrow asset (seed refund included)
    /// otherwise. Caller must have approved this contract for the seed and for the Notes.
    ///
    /// `pool` is caller-supplied so rungs in a superseded (no-longer-active) pool stay closable.
    /// It must nevertheless be a pool the REGISTRY named or this periphery itself opened — see
    /// `openedIn`. A caller-supplied address that merely claims the right `markets()` is not one.
    function close(
        EsseyPool pool,
        uint256[] calldata ids,
        uint256 seedMax,
        bool toCollateral,
        uint256 minOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 assetOut, uint256 collateralOut) {
        if (block.timestamp > deadline) revert Expired();
        if (pool.markets() != markets) revert WrongPool(address(pool));
        // A fake pool can return whatever collateralToken() it likes; `activePool` is set only by the
        // registry's timelocked commit, so it can never name one.
        if (!openedIn[address(pool)] && markets.activePool(pool.collateralToken()) != address(pool)) {
            revert WrongPool(address(pool));
        }
        CloseState memory s;
        s.token = pool.collateralToken();
        s.adapter = config[s.token].adapter;
        if (!toCollateral && address(s.adapter) == address(0)) revert NotListed(s.token);
        s.asset = IERC20(pool.asset());
        s.note = pool.note();
        // debtOf is quoted against the stored index, but repay() accrues first — quoting without
        // accruing under-funds every repay by the block's pending interest. One accrue makes every
        // debtOf below exact (repay's own accrue becomes a dt==0 no-op).
        pool.accrue();

        for (uint256 i; i < ids.length; ++i) {
            uint256 owed = pool.debtOf(ids[i]);
            if (owed == 0) revert PositionAlreadyClosed(ids[i]);
            if (owed > s.cash) {
                uint256 shortfall = owed - s.cash;
                if (s.seedUsed + shortfall > seedMax) revert SeedExceeded(s.seedUsed + shortfall, seedMax);
                s.seedUsed += shortfall;
                s.asset.safeTransferFrom(msg.sender, address(this), shortfall);
                s.cash = owed;
            }
            s.note.transferFrom(msg.sender, address(this), ids[i]);
            // EXACTLY `owed`, which repay pulls in full — so nothing survives the call and there is
            // no zeroing to do afterwards. An over-approval here is what LOW-2 leaves behind, and
            // the binding check above is what stops a caller-chosen address from receiving one.
            s.asset.forceApprove(address(pool), owed);
            uint256 collBefore = IERC20(s.token).balanceOf(address(this));
            pool.repay(ids[i], owed);
            uint256 received = IERC20(s.token).balanceOf(address(this)) - collBefore;
            s.cash -= owed;
            _forwardEscrowedNote(pool, s.note, ids[i]);
            if (toCollateral) {
                collateralOut += received;
            } else if (received != 0) {
                s.cash += _swapExactIn(s.adapter, IERC20(s.token), address(s.asset), received, 0);
            }
        }

        assetOut = s.cash;
        uint256 got = toCollateral ? collateralOut : assetOut;
        if (got < minOut) revert SlippageExceeded(got, minOut);
        if (collateralOut != 0) IERC20(s.token).safeTransfer(msg.sender, collateralOut);
        if (assetOut != 0) s.asset.safeTransfer(msg.sender, assetOut);
        emit MultiplyClosed(msg.sender, address(pool), ids, s.seedUsed, assetOut, collateralOut);
    }

    /// A collateral-token pause makes the pool ESCROW the collateral instead of returning it
    /// (EsseyPool.claimCollateral), and the Note then survives as the claim ticket. This periphery
    /// holds nothing between transactions, so a surviving Note goes straight back to the caller —
    /// otherwise their collateral claim would be lost to whoever called next.
    function _forwardEscrowedNote(EsseyPool pool, Note note, uint256 id) internal {
        (address stillOpen,,,,) = pool.positions(id);
        if (stillOpen != address(0)) note.transferFrom(address(this), msg.sender, id);
    }

    /// Open-path swap: borrow asset -> stock, floored against the ORACLE price so a manipulated
    /// venue cannot quietly eat the loop (the open path is already oracle-gated by canBorrow, so
    /// this adds no new liveness dependency). minOut = oracle-implied output x (1 - maxSlippageBps).
    function _buyStock(ISwapAdapter adapter, IERC20 asset_, address token, uint256 amountIn, uint256 maxSlippageBps)
        internal
        returns (uint256 out)
    {
        (uint256 unitValue,) = markets.collateralValue(token, WAD);
        if (unitValue == 0) revert BadOraclePrice();
        uint256 expected = (amountIn * WAD) / unitValue;
        out = _swapExactIn(adapter, asset_, token, amountIn, (expected * (BPS - maxSlippageBps)) / BPS);
    }

    /// Delivery is measured by OUR balance delta, never the adapter's return value or its own
    /// minOut handling — the venue is outside the trust boundary.
    function _swapExactIn(ISwapAdapter adapter, IERC20 tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 out)
    {
        tokenIn.forceApprove(address(adapter), amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        adapter.swapExactIn(address(tokenIn), tokenOut, amountIn, minOut, address(this));
        out = IERC20(tokenOut).balanceOf(address(this)) - before;
        if (out < minOut) revert SlippageExceeded(out, minOut);
    }
}
