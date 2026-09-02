// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath, FixedPoint96, IUniV3PoolMin} from "./EsseyLadderSeeder.sol";

/// Oracle surface the vault trusts: the deployed StockConverter's inherited StaleFeedGuard read.
/// `priceOf` fails CLOSED on a silent/stale/incomplete feed; `inSession` is the equity-hours flag.
interface IStockOracle {
    function priceOf(address token) external view returns (uint256 price, uint8 decimals, bool inSession);
}

/// The V3 fee-growth accumulators, read ONLY by the pendingFees view. tokensOwed lags real yield until
/// a poke, so an honest "harvestable now" must derive the un-poked term from feeGrowthInside deltas.
interface IUniV3PoolFees {
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
}

/// StockLpVault — single-sided concentrated-LP earn vault (Phase 1 MVP). Shares are valued at the
/// CHAINLINK ORACLE mark, never pool spot, so spot manipulation cannot move the share price. Withdraw
/// is pure pro-rata of real holdings (24/7); deposit/rebalance are session + deviation gated. The
/// keeper can only rebalance/compound — no path to receive funds. One PERFORMANCE fee (governor-tunable
/// behind a timelock, hard-capped) with a bounty carved from it; rates are PLACEHOLDERS pending founder.
/// V3 plumbing is lifted from EsseyLadderSeeder; see the commit for the full rationale + invariants.
/// L-2 deploy-config: deposit credits the requested amount and pro-rata reads balanceOf — do NOT list a fee-on-transfer or rebasing token here.
contract StockLpVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniV3PoolMin public immutable pool;
    IStockOracle public immutable oracle;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    IERC20 public immutable stock;
    IERC20 public immutable base; // USDG
    bool public immutable stockIs1;
    uint8 internal immutable stockDec;
    uint8 internal immutable baseDec;
    int24 public immutable tickSpacing;
    uint256 public immutable maxDeviationBps;
    address public immutable keeper;

    // ---- fee governor: STORAGE behind rails + timelock + one-way lock (rates PENDING-FOUNDER)
    // _splitFee bare-transfers the in-kind fee here (no fund() call), so feeRecipient MUST credit bare
    // transfers as backing — EsseyReserve does (reserveOf = raw balanceOf); a splitter that ignores them loses it.
    address public feeRecipient;
    uint16 public performanceFeeBps; // cut of realized trading fees
    uint16 public bountyBps; // carved FROM performanceFeeBps to the harvest cranker
    address public governor;
    bool public feeLocked;
    address public pendingRecipient;
    uint16 public pendingPerformanceBps;
    uint16 public pendingBountyBps;
    uint256 public pendingEffectiveTime; // 0 = no pending change

    // ---- active range
    int24 public tickLower;
    int24 public tickUpper;
    bool public rangeSet;

    // ---- rails: a fee can never be set to skim everything
    uint256 internal constant MAX_PERFORMANCE_FEE_BPS = 2_000; // 20% of yield — hard ceiling
    uint256 internal constant MAX_DEVIATION_CEIL_BPS = 500; // 5% pool-vs-oracle
    uint256 internal constant BPS = 10_000;
    uint256 public constant FEE_TIMELOCK = 48 hours;
    uint256 internal constant Q128 = 1 << 128; // V3 fee-growth accumulators are Q128.128 fixed point
    /// Round-up on mint can owe a wei or two above the liquidity math's floor; deploy leaves this
    /// much idle unspent so the pool's round-up is always payable (the Seeder's AMOUNT_MARGIN).
    uint256 internal constant AMOUNT_MARGIN = 1e3;

    event Deposited(address indexed who, uint256 stockIn, uint256 baseIn, uint256 shares);
    event Withdrawn(address indexed who, uint256 shares, uint256 stockOut, uint256 baseOut);
    event Harvested(uint256 fee0, uint256 fee1);
    event Rebalanced(int24 tickLower, int24 tickUpper, uint128 liquidity);
    event FeeProposed(address recipient, uint16 performanceBps, uint16 bountyBps, uint256 effectiveTime);
    event FeeExecuted(address recipient, uint16 performanceBps, uint16 bountyBps);
    event FeeFrozen();
    event FeeRetained(address indexed token, uint256 amount);

    error ZeroAddress();
    error BadConfig();
    error ZeroAmount();
    error NotKeeper();
    error NotPool();
    error NotInSession();
    error PriceDeviation();
    error TickNotAligned();
    error TickOrder();
    error Slippage();
    error LiquidityOverflow();
    error NotGovernor();
    error FeeFrozenError();
    error BadFee();
    error NothingPending();
    error TimelockPending();

    struct VaultConfig {
        IUniV3PoolMin pool;
        IStockOracle oracle;
        IERC20 stock;
        IERC20 base;
        address keeper;
        address governor;
        address feeRecipient;
        uint256 maxDeviationBps;
        uint16 performanceFeeBps;
        uint16 bountyBps;
        string name;
        string symbol;
    }

    constructor(VaultConfig memory c) ERC20(c.name, c.symbol) {
        if (
            address(c.pool) == address(0) || address(c.oracle) == address(0) || address(c.stock) == address(0)
                || address(c.base) == address(0) || c.keeper == address(0) || c.governor == address(0)
                || c.feeRecipient == address(0)
        ) revert ZeroAddress();
        if (c.maxDeviationBps == 0 || c.maxDeviationBps > MAX_DEVIATION_CEIL_BPS) revert BadConfig();
        if (!_feeWithinRails(c.performanceFeeBps, c.bountyBps)) revert BadFee();

        IERC20 t0 = IERC20(c.pool.token0());
        IERC20 t1 = IERC20(c.pool.token1());
        if (!((c.stock == t0 && c.base == t1) || (c.stock == t1 && c.base == t0))) revert BadConfig();

        pool = c.pool;
        oracle = c.oracle;
        token0 = t0;
        token1 = t1;
        stock = c.stock;
        base = c.base;
        stockIs1 = c.stock == t1;
        (stockDec, baseDec) = _decimalsOf(c.stock, c.base);
        tickSpacing = c.pool.tickSpacing();
        keeper = c.keeper;
        governor = c.governor;
        feeRecipient = c.feeRecipient;
        maxDeviationBps = c.maxDeviationBps;
        performanceFeeBps = c.performanceFeeBps;
        bountyBps = c.bountyBps;
    }

    function _decimalsOf(IERC20 s, IERC20 b) private view returns (uint8 sd, uint8 bd) {
        sd = IERC20Metadata(address(s)).decimals();
        bd = IERC20Metadata(address(b)).decimals();
    }

    // ================================================================== deposit (oracle-gated)

    /// Single-side stock (and/or USDG). Shares are minted against the ORACLE mark of the vault's
    /// existing value, so pool-spot manipulation cannot inflate them. Gated: a fresh in-session
    /// price for both legs and |pool-spot − oracle| ≤ maxDeviation.
    function deposit(uint256 stockAmt, uint256 baseAmt, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (stockAmt == 0 && baseAmt == 0) revert ZeroAmount();
        (uint256 fS, uint256 fB, uint160 sqrtO) = _requireTradeable();
        _harvest(); // realize pending fees BEFORE pricing, else this deposit skims prior holders' unharvested yield

        uint256 totalBefore = _valueAtOracle(fS, fB, sqrtO);
        uint256 supply = totalSupply();

        if (stockAmt > 0) stock.safeTransferFrom(msg.sender, address(this), stockAmt);
        if (baseAmt > 0) base.safeTransferFrom(msg.sender, address(this), baseAmt);

        uint256 depositUsd = stockAmt * fS + baseAmt * fB;
        shares = supply == 0 ? depositUsd : Math.mulDiv(depositUsd, supply, totalBefore);
        if (shares == 0 || shares < minShares) revert Slippage();

        _mint(msg.sender, shares);
        _deploy();
        emit Deposited(msg.sender, stockAmt, baseAmt, shares);
    }

    // ================================================================== withdraw (pro-rata, 24/7)

    /// Burn `shares` for a pro-rata slice of everything the vault physically holds — idle balances
    /// plus a proportional cut of the live position. No oracle is consulted: a proportional claim on
    /// real assets is solvent and manipulation-proof by construction, so withdraw is always open.
    function withdraw(uint256 shares, uint256 minStock, uint256 minBase)
        external
        nonReentrant
        returns (uint256 outStock, uint256 outBase)
    {
        if (shares == 0) revert ZeroAmount();
        _harvest(); // realize fees into idle first, so this share includes its cut of them
        uint256 supply = totalSupply();

        (uint256 out0, uint256 out1) = _proRataOut(shares, supply);
        _burn(msg.sender, shares);

        (outStock, outBase) = stockIs1 ? (out1, out0) : (out0, out1);
        if (outStock < minStock || outBase < minBase) revert Slippage();
        if (out0 > 0) token0.safeTransfer(msg.sender, out0);
        if (out1 > 0) token1.safeTransfer(msg.sender, out1);
        emit Withdrawn(msg.sender, shares, outStock, outBase);
    }

    /// What `withdraw(shares, …)` pays out RIGHT NOW as (stock, base). POST-HARVEST: withdraw harvests
    /// first, so the preview folds this share's slice of the fees a harvest realizes (net of the perf
    /// cut) into the idle basis. The position slice is valued at pool SPOT — what a real pool.burn
    /// yields — not the oracle mark.
    function previewWithdraw(uint256 shares) external view returns (uint256 stockOut, uint256 baseOut) {
        uint256 supply = totalSupply();
        if (shares == 0 || supply == 0) return (0, 0);
        (uint256 pf0, uint256 pf1) = pendingFees();
        uint256 basis0 = token0.balanceOf(address(this)) + _retained(pf0);
        uint256 basis1 = token1.balanceOf(address(this)) + _retained(pf1);

        (uint256 out0, uint256 out1, uint128 burnL) = _proRataParts(basis0, basis1, shares, supply);
        if (burnL > 0) {
            uint160 sa = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sb = TickMath.getSqrtRatioAtTick(tickUpper);
            (uint256 b0, uint256 b1) = LiquidityAmounts.getAmountsForLiquidity(_spotSqrt(), sa, sb, burnL);
            out0 += b0;
            out1 += b1;
        }
        (stockOut, baseOut) = stockIs1 ? (out1, out0) : (out0, out1);
    }

    /// Pro-rata slice `shares/supply` of idle balances plus the same fraction of the position, burned
    /// out of the pool. Idle is snapshotted BEFORE the burn so the fraction is exact.
    function _proRataOut(uint256 shares, uint256 supply) internal returns (uint256 out0, uint256 out1) {
        uint128 burnL;
        (out0, out1, burnL) =
            _proRataParts(token0.balanceOf(address(this)), token1.balanceOf(address(this)), shares, supply);
        if (burnL == 0) return (out0, out1);
        (uint256 b0, uint256 b1) = pool.burn(tickLower, tickUpper, burnL);
        pool.collect(address(this), tickLower, tickUpper, uint128(b0), uint128(b1));
        out0 += b0;
        out1 += b1;
    }

    /// Shared pro-rata fraction: `basis` slices plus the liquidity to burn. Callers realize `burnL`
    /// differently (withdraw via pool.burn, preview via spot math), but the fraction lives here once.
    function _proRataParts(uint256 basis0, uint256 basis1, uint256 shares, uint256 supply)
        internal
        view
        returns (uint256 out0, uint256 out1, uint128 burnL)
    {
        out0 = Math.mulDiv(basis0, shares, supply);
        out1 = Math.mulDiv(basis1, shares, supply);
        uint128 liq = _liquidity();
        if (!rangeSet || liq == 0) return (out0, out1, 0);
        burnL = uint128(Math.mulDiv(liq, shares, supply));
    }

    /// Amount of a realized fee the vault RETAINS as idle: the whole fee minus the performance cut
    /// (bounty is carved from that cut, so it does not change the retained remainder). Mirrors _splitFee.
    function _retained(uint256 fee) internal view returns (uint256) {
        return fee - (fee * performanceFeeBps) / BPS;
    }

    // ================================================================== harvest / compound / rebalance

    /// PERMISSIONLESS, 24/7 dark-keeper fee sweep: poke + collect accrued swap fees into idle, taking
    /// the performance cut to the recipient and the bounty to the caller. No price is read, so it is
    /// always safe to crank — fees keep flowing even if the keeper is down. Does not redeploy.
    function harvest() external nonReentrant returns (uint256 fee0, uint256 fee1) {
        return _harvest();
    }

    /// What `harvest()` would collect right now as (fee0, fee1): the position's already-owed fees PLUS
    /// the un-poked fees the pool has accrued since this position was last touched. harvest pokes
    /// (burn 0) before collecting, so tokensOwed alone understates the real yield — the feeGrowthInside
    /// delta is the honest remainder, and folding it in is what keeps this view truthful on a live pool.
    function pendingFees() public view returns (uint256 fee0, uint256 fee1) {
        if (!rangeSet) return (0, 0);
        bytes32 key = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
        (uint128 liq, uint256 inside0Last, uint256 inside1Last, uint128 owed0, uint128 owed1) = pool.positions(key);
        fee0 = owed0;
        fee1 = owed1;
        if (liq == 0) return (fee0, fee1);
        (uint256 inside0, uint256 inside1) = _feeGrowthInside();
        unchecked {
            fee0 += Math.mulDiv(inside0 - inside0Last, liq, Q128);
            fee1 += Math.mulDiv(inside1 - inside1Last, liq, Q128);
        }
    }

    /// Canonical V3 fee-growth-inside the active range: global minus the growth outside each boundary,
    /// with the below/above split flipping on the current tick. Accumulators wrap by design, so the
    /// subtractions are unchecked — the caller only ever consumes their difference against `insideLast`.
    function _feeGrowthInside() internal view returns (uint256 inside0, uint256 inside1) {
        IUniV3PoolFees p = IUniV3PoolFees(address(pool));
        (, int24 tick,,,,,) = pool.slot0();
        uint256 g0 = p.feeGrowthGlobal0X128();
        uint256 g1 = p.feeGrowthGlobal1X128();
        (,, uint256 lo0, uint256 lo1,,,,) = p.ticks(tickLower);
        (,, uint256 up0, uint256 up1,,,,) = p.ticks(tickUpper);
        unchecked {
            (uint256 below0, uint256 below1) = tick >= tickLower ? (lo0, lo1) : (g0 - lo0, g1 - lo1);
            (uint256 above0, uint256 above1) = tick < tickUpper ? (up0, up1) : (g0 - up0, g1 - up1);
            inside0 = g0 - below0 - above0;
            inside1 = g1 - below1 - above1;
        }
    }

    /// PERMISSIONLESS but gated: harvest, then redeploy idle back into the range. Reverts off-hours or
    /// when the pool is deviated from the oracle — redeploy prices its ratio off pool spot, so it only
    /// runs when spot ≈ oracle. Caller chooses nothing, so there is nothing to grief.
    function compound() external nonReentrant {
        _requireTradeable();
        _harvest();
        _deploy();
    }

    /// KEEPER-only, gated: move the position to a fresh range around spot. Burns the whole position,
    /// collects, and redeploys idle into [newLower, newUpper]. Value only ever moves between idle and
    /// the vault-owned pool position — never to the keeper.
    function rebalance(int24 newLower, int24 newUpper) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        if (newUpper <= newLower) revert TickOrder();
        if (newLower % tickSpacing != 0 || newUpper % tickSpacing != 0) revert TickNotAligned();
        _requireTradeable();
        _harvest();

        uint128 liq = _liquidity();
        if (rangeSet && liq > 0) {
            pool.burn(tickLower, tickUpper, liq);
            pool.collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
        }
        tickLower = newLower;
        tickUpper = newUpper;
        rangeSet = true;
        _deploy();
        emit Rebalanced(newLower, newUpper, _liquidity());
    }

    // ================================================================== internal: harvest + fee split

    function _harvest() internal returns (uint256 fee0, uint256 fee1) {
        if (!rangeSet) return (0, 0);
        if (_liquidity() > 0) pool.burn(tickLower, tickUpper, 0); // fee poke, principal untouched
        (uint128 c0, uint128 c1) =
            pool.collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
        fee0 = c0;
        fee1 = c1;
        _splitFee(token0, fee0);
        _splitFee(token1, fee1);
        emit Harvested(fee0, fee1);
    }

    /// Split a realized fee amount: performanceFeeBps is Essey's cut, of which bountyBps goes to the
    /// cranker (msg.sender) and the remainder to feeRecipient. The vault keeps the rest as idle.
    /// The feeRecipient leg is NON-BRICKING: _harvest gates every deposit/withdraw, so a recipient that
    /// reverts on receipt (blocklist token, or a hostile governor pointing fees at a reverting sink then
    /// lockFee-ing) would otherwise freeze ALL principal once a fee accrues; a failed pay is retained as
    /// backing instead. The bounty keeps safeTransfer: it pays msg.sender, so a reverting caller bricks
    /// only its OWN crank (self-harm), never another holder's exit.
    function _splitFee(IERC20 token, uint256 fee) internal returns (uint256 toRecipient, uint256 bounty) {
        if (fee == 0) return (0, 0);
        uint256 perf = (fee * performanceFeeBps) / BPS;
        bounty = (fee * bountyBps) / BPS;
        toRecipient = perf - bounty;
        if (bounty > 0) token.safeTransfer(msg.sender, bounty);
        if (toRecipient > 0 && !_payRecipient(token, toRecipient)) emit FeeRetained(address(token), toRecipient);
    }

    /// Pay feeRecipient without ever reverting the caller: SafeERC20's success rule (call ok AND returned
    /// true or empty) but returned as a CHECKED bool, so a failed pay retains rather than bricks _harvest.
    function _payRecipient(IERC20 token, uint256 amt) internal returns (bool) {
        (bool ok, bytes memory ret) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, feeRecipient, amt));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    // ================================================================== internal: liquidity ops

    function _deploy() internal {
        if (!rangeSet) return;
        uint256 i0 = token0.balanceOf(address(this));
        uint256 i1 = token1.balanceOf(address(this));
        i0 = i0 > AMOUNT_MARGIN ? i0 - AMOUNT_MARGIN : 0;
        i1 = i1 > AMOUNT_MARGIN ? i1 - AMOUNT_MARGIN : 0;
        uint160 sa = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sb = TickMath.getSqrtRatioAtTick(tickUpper);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(_spotSqrt(), sa, sb, i0, i1);
        if (liq == 0) return;
        pool.mint(address(this), tickLower, tickUpper, liq, "");
    }

    function _liquidity() internal view returns (uint128 liq) {
        if (!rangeSet) return 0;
        bytes32 key = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
        (liq,,,,) = pool.positions(key);
    }

    // ================================================================== internal: oracle valuation

    /// The vault's total value at the ORACLE mark: idle balances + the position priced at the
    /// oracle-implied sqrt price. Uses ONLY the oracle, never pool spot — this is the load-bearing
    /// anti-manipulation property. Reverts off-hours / on a stale feed (fail closed).
    function totalValueUsd() public view returns (uint256) {
        (uint256 fS, uint256 fB, uint160 sqrtO) = _prices();
        return _valueAtOracle(fS, fB, sqrtO);
    }

    function _valueAtOracle(uint256 fS, uint256 fB, uint160 sqrtO) internal view returns (uint256) {
        uint256 a0 = token0.balanceOf(address(this));
        uint256 a1 = token1.balanceOf(address(this));
        (uint256 p0, uint256 p1) = _positionAmounts(sqrtO);
        a0 += p0;
        a1 += p1;
        (uint256 aStock, uint256 aBase) = stockIs1 ? (a1, a0) : (a0, a1);
        return aStock * fS + aBase * fB;
    }

    function _positionAmounts(uint160 sqrtO) internal view returns (uint256 amount0, uint256 amount1) {
        uint128 liq = _liquidity();
        if (liq == 0) return (0, 0);
        uint160 sa = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sb = TickMath.getSqrtRatioAtTick(tickUpper);
        return LiquidityAmounts.getAmountsForLiquidity(sqrtO, sa, sb, liq);
    }

    /// Read both legs' oracle prices, convert to per-raw-token USD factors (1e18-scaled) and the
    /// oracle-implied sqrt price. Reverts NotInSession off equity hours; priceOf reverts on staleness.
    function _prices() internal view returns (uint256 factorStock, uint256 factorBase, uint160 sqrtOracle) {
        (factorStock, factorBase) = _factors();
        // pool price = token1-raw per token0-raw = USD(token0)/USD(token1); sqrt to X96.
        (uint256 f0, uint256 f1) = stockIs1 ? (factorBase, factorStock) : (factorStock, factorBase);
        sqrtOracle = uint160(Math.sqrt(Math.mulDiv(f0, uint256(1) << 192, f1)));
    }

    function _factors() internal view returns (uint256 factorStock, uint256 factorBase) {
        (uint256 sPx, uint8 sFeedDec, bool inSession) = oracle.priceOf(address(stock));
        if (!inSession) revert NotInSession();
        (uint256 bPx, uint8 bFeedDec,) = oracle.priceOf(address(base));
        factorStock = _factor(sPx, sFeedDec, stockDec);
        factorBase = _factor(bPx, bFeedDec, baseDec);
    }

    function _spotSqrt() internal view returns (uint160 s) {
        (s,,,,,,) = pool.slot0();
    }

    /// USD × 1e18 carried by one RAW unit of a token. NVDA: 220e8 · 1e10 / 1e18 = 220.
    /// L-1 deploy-config: an 18-dec token divides by 1e18, so a sub-$1 price truncates the factor — vet a low-price 18-dec stock before listing.
    function _factor(uint256 px, uint8 feedDec, uint8 tokenDec) internal pure returns (uint256) {
        return px * (10 ** (18 - feedDec)) / (10 ** tokenDec);
    }

    function _requireTradeable() internal view returns (uint256 fS, uint256 fB, uint160 sqrtO) {
        (fS, fB, sqrtO) = _prices();
        uint256 r = Math.mulDiv(sqrtO, 1e18, _spotSqrt());
        uint256 ratio = Math.mulDiv(r, r, 1e18); // (oracle/spot)^2 = price ratio, 1e18-scaled
        uint256 diff = ratio > 1e18 ? ratio - 1e18 : 1e18 - ratio;
        if (diff > (maxDeviationBps * 1e18) / BPS) revert PriceDeviation();
    }

    // ================================================================== fee governor (bounded + timelock)

    /// True iff the fee sits inside the hard rail and the bounty is carved from (never exceeds) it.
    function _feeWithinRails(uint16 perf, uint16 bounty) internal pure returns (bool) {
        if (perf > MAX_PERFORMANCE_FEE_BPS) return false;
        if (bounty > perf) return false;
        return true;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    /// Queue new fee params. Applies only after FEE_TIMELOCK via executeFee — never immediately.
    function proposeFee(address recipient, uint16 performanceBps, uint16 bounty) external onlyGovernor {
        if (feeLocked) revert FeeFrozenError();
        if (recipient == address(0)) revert ZeroAddress();
        if (!_feeWithinRails(performanceBps, bounty)) revert BadFee();
        pendingRecipient = recipient;
        pendingPerformanceBps = performanceBps;
        pendingBountyBps = bounty;
        pendingEffectiveTime = block.timestamp + FEE_TIMELOCK;
        emit FeeProposed(recipient, performanceBps, bounty, pendingEffectiveTime);
    }

    /// Permissionless: apply the pending fee params once the timelock has elapsed.
    function executeFee() external {
        if (feeLocked) revert FeeFrozenError();
        uint256 eff = pendingEffectiveTime;
        if (eff == 0) revert NothingPending();
        if (block.timestamp < eff) revert TimelockPending();
        feeRecipient = pendingRecipient;
        performanceFeeBps = pendingPerformanceBps;
        bountyBps = pendingBountyBps;
        pendingEffectiveTime = 0;
        emit FeeExecuted(feeRecipient, performanceFeeBps, bountyBps);
    }

    /// One-way, irreversible: freeze the current fee params and renounce the governor forever.
    function lockFee() external onlyGovernor {
        if (feeLocked) revert FeeFrozenError();
        feeLocked = true;
        governor = address(0);
        pendingEffectiveTime = 0;
        emit FeeFrozen();
    }

    // ================================================================== uniswap callback

    /// Pool-authenticated: pays exactly what the pool computed for our own mint, from idle, nothing
    /// else. No swap callback exists — the MVP never swaps (auto-pair is Phase 2).
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        if (msg.sender != address(pool)) revert NotPool();
        if (amount0Owed > 0) token0.safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) token1.safeTransfer(msg.sender, amount1Owed);
    }
}

/// Canonical Uniswap-V3 liquidity<->amounts math (v3-periphery LiquidityAmounts), 0.8-safe via OZ
/// Math.mulDiv. Valuation rounds DOWN (conservative for share price); the mock pool rounds mint owed
/// UP to mirror the real pool, which is why _deploy leaves AMOUNT_MARGIN idle.
library LiquidityAmounts {
    function getAmount0ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liq) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return Math.mulDiv(uint256(liq) << 96, sqrtB - sqrtA, sqrtB) / sqrtA;
    }

    function getAmount1ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liq) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return Math.mulDiv(liq, sqrtB - sqrtA, FixedPoint96.Q96);
    }

    function getAmountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liq)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtP <= sqrtA) {
            amount0 = getAmount0ForLiquidity(sqrtA, sqrtB, liq);
        } else if (sqrtP < sqrtB) {
            amount0 = getAmount0ForLiquidity(sqrtP, sqrtB, liq);
            amount1 = getAmount1ForLiquidity(sqrtA, sqrtP, liq);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtA, sqrtB, liq);
        }
    }

    function getLiquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = Math.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96);
        return Math.mulDiv(amount0, intermediate, sqrtB - sqrtA);
    }

    function getLiquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return Math.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA);
    }

    function getLiquidityForAmounts(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128 liq)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 l;
        if (sqrtP <= sqrtA) {
            l = getLiquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint256 l0 = getLiquidityForAmount0(sqrtP, sqrtB, amount0);
            uint256 l1 = getLiquidityForAmount1(sqrtA, sqrtP, amount1);
            l = l0 < l1 ? l0 : l1;
        } else {
            l = getLiquidityForAmount1(sqrtA, sqrtB, amount1);
        }
        liq = l > type(uint128).max ? type(uint128).max : uint128(l);
    }
}
