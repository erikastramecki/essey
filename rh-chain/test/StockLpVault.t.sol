// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {StockLpVault, IStockOracle} from "../src/market/StockLpVault.sol";
import {IUniV3PoolMin, TickMath} from "../src/market/EsseyLadderSeeder.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {GuardHarness, MockFeed} from "./RiskModules.t.sol";

contract MockToken is ERC20 {
    uint8 private immutable _dec;
    // RH Stock Tokens are default-allow blocklist tokens: a transfer to a blocked address reverts. Used
    // to reproduce a feeRecipient that reverts on receipt without a hook token.
    mapping(address => bool) public blocked;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function adminBurn(address from, uint256 amt) external {
        _burn(from, amt);
    }

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}

/// StockLpVault — single-sided oracle-marked LP vault. Each test name is the invariant it pins; the
/// money paths are mutation-verified RED in the accompanying report.
contract StockLpVaultTest is Test {
    // Monday 15:00 UTC — inside the conservative 14:30-20:00 UTC session window.
    uint256 constant MON_IN_SESSION = 1_753_110_000;
    /// What re-flooring a pro-rata claim costs when supply grows: MEASURED at $1.14e-6 on a $7,202 claim
    /// here (liquidity is lumpy, so alice's slice re-floors once she is no longer the whole supply).
    /// NOT a tolerance for a mis-valuation: see the mutation delta recorded on the test below.
    uint256 constant PRORATA_DUST_USD18 = 1e13; // $1e-5

    MockToken usdg; // token0, 6-dec, $1
    MockToken nvda; // token1, 18-dec, $220
    MockFeed baseFeed;
    MockFeed stockFeed;
    GuardHarness oracle;
    MockV3Pool pool;
    StockLpVault vault;

    address keeper = address(0xCAFE1);
    address governor = address(0x600D);
    address feeRecipient = address(0xFEE5);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint160 sqrtOracle;

    // ranges (aligned to spacing 10); spot sits at tick ~222362
    int24 constant LO_BELOW = 222000; // NVDA-only sell wall (both ticks below spot)
    int24 constant HI_BELOW = 222360;
    int24 constant LO_WIDE = 222000; // straddles spot
    int24 constant HI_WIDE = 222720;
    int24 constant LO_ABOVE = 222500; // USDG-only buy wall (both ticks above spot)
    int24 constant HI_ABOVE = 222720;

    function setUp() public {
        vm.warp(MON_IN_SESSION);

        usdg = new MockToken("USD Gold", "USDG", 6);
        nvda = new MockToken("NVDA RH Token", "NVDA", 18);
        baseFeed = new MockFeed(1e8, 8);
        stockFeed = new MockFeed(220e8, 8);

        oracle = new GuardHarness(AggregatorV3Interface(address(0)));
        oracle.setFeed(address(usdg), AggregatorV3Interface(address(baseFeed)), 86_400, 86_400 + 3_600, 8);
        oracle.setFeed(address(nvda), AggregatorV3Interface(address(stockFeed)), 86_400, 86_400 + 3_600, 8);

        // oracle-implied sqrt (token0=USDG,token1=NVDA => stockIs1): f0=factorBase, f1=factorStock.
        uint256 factorStock = 220e8 * (10 ** (36 - 8 - 18)); // USD 1e36 per raw NVDA = 220e18
        uint256 factorBase = 1e8 * (10 ** (36 - 8 - 6)); // USD 1e36 per raw USDG = 1e30
        sqrtOracle = uint160(Math.sqrt(Math.mulDiv(factorBase, uint256(1) << 192, factorStock)));

        pool = new MockV3Pool(address(usdg), address(nvda), 10, sqrtOracle, 222362);

        vault = new StockLpVault(
            StockLpVault.VaultConfig({
                pool: IUniV3PoolMin(address(pool)),
                oracle: IStockOracle(address(oracle)),
                stock: IERC20(address(nvda)),
                base: IERC20(address(usdg)),
                keeper: keeper,
                governor: governor,
                feeRecipient: feeRecipient,
                maxDeviationBps: 100, // 1%
                performanceFeeBps: 1_000, // 10% (PLACEHOLDER)
                bountyBps: 10, // 0.1% (PLACEHOLDER)
                name: "Essey NVDA LP",
                symbol: "eNVDA-LP"
            })
        );

        // sanity: the single-sided range sits strictly below spot (token1-only), wide range straddles.
        assertLt(TickMath.getSqrtRatioAtTick(HI_BELOW), sqrtOracle, "HI_BELOW must be under spot");
        assertLt(TickMath.getSqrtRatioAtTick(LO_WIDE), sqrtOracle, "wide lower under spot");
        assertGt(TickMath.getSqrtRatioAtTick(HI_WIDE), sqrtOracle, "wide upper over spot");

        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    // ---------------------------------------------------------------- helpers

    function _fund(address who) internal {
        nvda.mint(who, 1_000e18);
        usdg.mint(who, 1_000_000e6);
        vm.startPrank(who);
        nvda.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _refreshFeeds() internal {
        baseFeed.set(1e8, block.timestamp);
        stockFeed.set(220e8, block.timestamp);
    }

    function _seed(int24 lo, int24 hi) internal {
        vm.prank(keeper);
        vault.rebalance(lo, hi);
    }

    function _deposit(address who, uint256 stockAmt, uint256 baseAmt) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(stockAmt, baseAmt, 0);
    }

    /// USD × 1e18 at the FEEDS' marks, derived straight from the aggregators — deliberately NOT through
    /// `_factor`/`totalValueUsd`, so a dilution measured with it is not measured by the suspect itself.
    function _usd18(uint256 stockRaw, uint256 baseRaw) internal view returns (uint256) {
        (, int256 sPx,,,) = stockFeed.latestRoundData();
        (, int256 bPx,,,) = baseFeed.latestRoundData();
        return Math.mulDiv(stockRaw, uint256(sPx) * 1e10, 1e18) + Math.mulDiv(baseRaw, uint256(bPx) * 1e10, 1e6);
    }

    /// What `who` could actually withdraw right now, in independent feed USD. `previewWithdraw` is a
    /// separate code path from the oracle valuation and is pinned equal to a REAL pool.burn on the fork.
    function _claimUsd18(address who) internal view returns (uint256) {
        (uint256 s, uint256 b) = vault.previewWithdraw(vault.balanceOf(who));
        return _usd18(s, b);
    }

    /// |pool spot − oracle| in bps of price, exactly as `_requireTradeable` computes it.
    function _deviationBps() internal view returns (uint256) {
        (uint160 spot,,,,,,) = pool.slot0();
        uint256 r = Math.mulDiv(sqrtOracle, 1e18, spot);
        uint256 ratio = Math.mulDiv(r, r, 1e18);
        return (ratio > 1e18 ? ratio - 1e18 : 1e18 - ratio) * 10_000 / 1e18;
    }

    /// Park mock spot just inside the 1% gate. A price move is ~half that in sqrt space.
    function _pushDeviation(bool stockDearer) internal {
        uint256 halfBps = 45;
        uint160 target = stockDearer
            ? uint160(uint256(sqrtOracle) * (10_000 - halfBps) / 10_000)
            : uint160(uint256(sqrtOracle) * (10_000 + halfBps) / 10_000);
        pool.setSqrtPriceX96(target, 222362);
        assertGe(_deviationBps(), 75, "deviation not pushed near the gate ceiling");
        assertLe(_deviationBps(), 100, "deviation escaped the gate the vault enforces");
    }

    // ================================================================ oracle-not-spot share valuation

    /// G3-1 pin — PRICES come from the oracle, COMPOSITION comes from spot. The predecessor of this test
    /// asserted the value was independent of spot, which is the defect itself: valuing the amounts the
    /// position WOULD hold at the oracle sqrt priced tokens the vault does not have, and because a V3
    /// position is concave in price that fiction sat BELOW the truth in both directions, under-stating
    /// the vault and over-minting every depositor. Measured with the independent feed ruler.
    /// MUTATION: `_positionAmounts` back to the oracle sqrt -> the value drops below the held ruler -> RED.
    /// MUTATION: price the amounts at spot instead of fS/fB -> the marks move with spot -> RED.
    function test_totalValueIsHeldCompositionMarkedAtOraclePrices() public {
        _seed(LO_WIDE, HI_WIDE);
        _deposit(alice, 10e18, 5_000e6); // two-sided, position lands in range
        assertEq(vault.totalValueUsd(), _claimUsd18(alice), "aligned: value == what the sole holder can take");

        _pushDeviation(true); // composition shifts; the marks must not
        assertEq(vault.totalValueUsd(), _claimUsd18(alice), "deviated: value == what the sole holder can take");
    }

    /// The other half of G3-1: the deviation term's SIGN. Marking the held composition at the oracle is
    /// the tangent to a concave curve, so it can only RISE as spot leaves the oracle — which is what
    /// makes manipulation mint FEWER shares. Nothing pinned the sign before, and a +8/+8 bps log in both
    /// directions was read as a bounded skim when it was a concavity gap.
    /// MUTATION: `_positionAmounts` back to the oracle sqrt -> the value falls instead -> RED.
    function test_deviationCanOnlyRaiseTheMintDenominator() public {
        _seed(LO_WIDE, HI_WIDE);
        _deposit(alice, 10e18, 5_000e6);
        uint256 aligned = vault.totalValueUsd();

        _pushDeviation(true);
        uint256 dearer = vault.totalValueUsd();
        pool.setSqrtPriceX96(sqrtOracle, 222362);
        assertEq(vault.totalValueUsd(), aligned, "restoring spot restores the aligned value");
        _pushDeviation(false);
        uint256 cheaper = vault.totalValueUsd();

        assertGt(dearer, aligned, "stock-dearer spot must RAISE the denominator");
        assertGt(cheaper, aligned, "stock-cheaper spot must RAISE it too");
    }

    /// F1 pin — the TWO-SIDED IN-RANGE fixture (the root cause). Every below-spot range is token1-only,
    /// so the position's token0 arm p0 is always zero and any mutation on a token0-arm line survives
    /// unseen. A wide range straddling spot, funded two-sided, makes the position hold BOTH tokens, so
    /// _valueAtOracle's token0 arm is finally driven nonzero. At oracle==spot the vault's oracle value
    /// conserves the deposit exactly, so one absolute total pins BOTH arms at once.
    /// MUTATION: drop `a0 += p0` (base position value) -> total loses the token0 leg -> RED.
    /// MUTATION: drop `a1 += p1` (stock position value) -> total loses the token1 leg -> RED.
    function test_totalValueUsdCountsBothArmsOfInRangePosition() public {
        _seed(LO_WIDE, HI_WIDE);
        _deposit(alice, 10e18, 5_000e6); // two-sided, straddles spot -> position holds token0 AND token1

        assertGt(usdg.balanceOf(address(pool)), 0, "token0 (USDG) genuinely deployed into the position");
        assertGt(nvda.balanceOf(address(pool)), 0, "token1 (NVDA) genuinely deployed into the position");

        // 10 NVDA at $220 plus 5,000 USDG at $1 = $7,200, in the view's USD-1e18 unit.
        uint256 expected = 7_200e18;
        assertEq(vault.totalValueUsd(), expected, "oracle value counts BOTH position arms (idle + p0 + p1)");
    }

    /// The mark carries the FEED's full precision for an 18-dec stock, not whole dollars. The old
    /// `_factor` divided by 10**tokenDec and floored $220.4321 to $220 — a 19.6 bps under-mark that a
    /// USDG depositor could round-trip out of the stock side (StockLpVaultFork.t.sol). The fixture's
    /// 220e8 is exactly representable either way, which is why this needs its own non-integral price.
    /// MUTATION: `10 ** (MARK_EXP - shift)` off by one in either direction, or the old
    /// `px * 10**(18-feedDec) / 10**tokenDec` restored -> RED.
    function test_markCarriesFullFeedPrecisionForEighteenDecStock() public {
        stockFeed.set(220_4321_0000, block.timestamp); // $220.4321 — 19.6 bps off spot, inside the 1% gate
        _deposit(alice, 100e18, 0); // no range set: pure idle, so the total IS the mark

        assertEq(vault.totalValueUsd(), 22_043_21e16, "100 NVDA marked at $220.4321, not $220");
        assertTrue(vault.totalValueUsd() != 22_000e18, "whole-dollar mark must be gone");
    }

    /// The base (6-dec) leg carries its feed's precision too — it always did, since 10**(18-8) covered
    /// 10**6, and it must keep doing so under the rescale. The other half of the decimal sweep.
    /// MUTATION: any exponent shift in _factor -> RED here as well as on the stock leg.
    function test_markCarriesFullFeedPrecisionForSixDecBase() public {
        baseFeed.set(99_987_654, block.timestamp); // $0.99987654 — 12.3 bps off spot, inside the gate
        _deposit(alice, 0, 1_000e6);

        assertEq(vault.totalValueUsd(), 999_87654e13, "1,000 USDG marked at $0.99987654");
    }

    /// The seed deposit defines the share unit: one share stays USD × 1e-18 at the oracle mark, so the
    /// mark's 1e36 carry is stripped exactly once, on the way in. Every later mint is a ratio in which
    /// the carry cancels, which is why only this branch divides.
    /// MUTATION: drop the `/ PRICE_SCALE`, multiply by it instead, or apply it to the ratio branch -> RED.
    function test_seedDepositMintsExactlyItsOracleMarkUsd() public {
        uint256 shares = _deposit(alice, 100e18, 0); // no range set: pure idle, no position rounding
        assertEq(shares, 22_000e18, "100 NVDA at $220 mints exactly 22,000 shares");
    }

    /// Rounding at the share/value boundary is DOWN, in the vault's favour: a seed deposit worth a
    /// fraction of the 1e18 share unit mints the floor, never the ceiling. Needs a non-integral price —
    /// at $220 every raw amount is a whole number of share units and both directions agree.
    /// MUTATION: Math.ceilDiv at either `/ PRICE_SCALE` -> RED.
    function test_seedShareRoundsDownNotUp() public {
        stockFeed.set(220_4321_0000, block.timestamp);
        uint256 shares = _deposit(alice, 1, 0); // one raw wei = 220.4321 share units
        assertEq(shares, 220, "floor, not the 221 a round-up would mint");
        assertEq(vault.totalValueUsd(), 220, "the view floors the same way");
    }

    /// G3-2 pin — a donated share-price inflation must not pay. The attacker seeds dust, bare-transfers a
    /// large balance in (the vault credits balanceOf as backing), and waits for a victim. Before the
    /// virtual offset this took $2,297 off a $202k deposit on the live pool with the attacker's capital
    /// fully recoverable; the USD-anchored seed only made it cost 1e18x more than an ERC4626 default.
    /// MUTATION: drop VIRTUAL_SHARES/VIRTUAL_ASSETS (restore the `supply == 0` seed branch) -> RED.
    /// MUTATION: VIRTUAL_ASSETS off the 1e18-per-USD line -> the seed unit moves -> the seed pins go RED.
    function test_donationInflationCannotSkimTheNextDepositor() public {
        // No range set: the donation stays idle, exactly as it would before the keeper seeds.
        uint256 attackerShares = _deposit(bob, 1, 0); // 1 wei of stock
        uint256 donated = _usd18(500e18, 0);
        vm.prank(bob);
        nvda.transfer(address(vault), 500e18);

        uint256 victimIn = _usd18(100e18, 0);
        uint256 victimShares = _deposit(carol, 100e18, 0);
        vm.prank(carol);
        (uint256 vS, uint256 vB) = vault.withdraw(victimShares, 0, 0);
        assertGe(_usd18(vS, vB), victimIn, "the victim's round trip must not lose value");

        // And the donation is not recoverable: it was split with virtual shares nobody can redeem.
        vm.prank(bob);
        (uint256 aS, uint256 aB) = vault.withdraw(attackerShares, 0, 0);
        assertLt(_usd18(aS, aB), donated / 1_000, "attacker must forfeit the donation, not park it");
    }

    /// G3-2, DoS arm — the same setup used to make every deposit below one inflated share unit revert
    /// `Slippage` (a $217 deposit did, on the live pool). The offset floors value-per-share at
    /// TVL / VIRTUAL_SHARES, so the floor is dust.
    /// MUTATION: drop the virtual offset -> a $220 deposit prices to zero shares and reverts -> RED.
    function test_donationInflationCannotBrickSmallDeposits() public {
        _deposit(bob, 1, 0);
        vm.prank(bob);
        nvda.transfer(address(vault), 500e18); // $110,000 parked as backing

        assertGt(_deposit(carol, 1e18, 0), 0, "a $220 deposit must still mint shares");
    }

    /// MARK_EXP is INCLUSIVE: an 18-dec feed on an 18-dec token sums to exactly 36, whose factor is an
    /// exact 10**0, so it must be accepted. Every fixture feed is 8-dec, so nothing else drives this.
    /// MUTATION: `shift > MARK_EXP` -> `>=` -> a legal pair is refused -> RED.
    function test_factorAcceptsTheExactDecimalCeiling() public {
        stockFeed.set(220e18, block.timestamp); // same $220, quoted at 18 decimals
        oracle.setFeed(address(nvda), AggregatorV3Interface(address(stockFeed)), 86_400, 86_400 + 3_600, 18);
        _deposit(alice, 100e18, 0);
        assertEq(vault.totalValueUsd(), 22_000e18, "an 18-dec feed marks the same $220 as the 8-dec one");
    }

    /// A feed/token decimal pair with no exact factor is REFUSED, not floored: the rescale buys exactness
    /// for every combination up to MARK_EXP and fails closed past it.
    /// MUTATION: drop the `shift > MARK_EXP` guard -> the exponent underflows to a panic, not BadConfig -> RED.
    function test_factorRefusesDecimalsItCannotRepresentExactly() public {
        // 20-dec feed on the 18-dec stock: 38 > MARK_EXP, so no whole-number factor exists.
        oracle.setFeed(address(nvda), AggregatorV3Interface(address(stockFeed)), 86_400, 86_400 + 3_600, 20);
        vm.prank(alice);
        vm.expectRevert(StockLpVault.BadConfig.selector);
        vault.deposit(10e18, 0, 0);
    }

    /// Deposit is refused when the pool is manipulated away from the oracle beyond maxDeviation —
    /// the depositor cannot enter against a spot they moved.
    function test_depositRevertsOnPoolDeviation() public {
        _seed(LO_WIDE, HI_WIDE);
        pool.setSqrtPriceX96(uint160(uint256(sqrtOracle) * 105 / 100), 222362); // ~+10% price, > 1% band
        vm.prank(alice);
        vm.expectRevert(StockLpVault.PriceDeviation.selector);
        vault.deposit(10e18, 0, 0);
    }

    /// Deposit fails closed off-session — no verifiable equity price, so no share minting.
    function test_depositRevertsOffSession() public {
        _seed(LO_BELOW, HI_BELOW);
        vm.warp(MON_IN_SESSION + 5 days); // Saturday, same time of day
        _refreshFeeds();
        vm.prank(alice);
        vm.expectRevert(StockLpVault.NotInSession.selector);
        vault.deposit(10e18, 0, 0);
    }

    // ================================================================ single-sided entry

    /// A holder with ONLY stock and zero USDG can enter: the below-spot range owes token1 only.
    function test_singleSidedStockDepositNeedsNoUsdg() public {
        _seed(LO_BELOW, HI_BELOW);
        uint256 usdgBefore = usdg.balanceOf(alice);
        uint256 shares = _deposit(alice, 100e18, 0);

        assertGt(shares, 0, "shares minted");
        assertEq(usdg.balanceOf(alice), usdgBefore, "no USDG required");
        assertGt(_positionLiquidity(), 0, "stock was deployed into the position");
        assertEq(usdg.balanceOf(address(pool)), 0, "position is single-sided: pool holds no USDG");
    }

    // ================================================================ withdraw is pro-rata

    /// Withdraw returns the caller's fraction of BOTH tokens: the stock arm (token1 position burn)
    /// AND the base arm (idle USDG). The below-spot range is token1-only, so the two-sided deposit's
    /// USDG stays idle and the base pro-rata is exercised — not left as dust.
    /// MUTATION: replace Math.mulDiv(bal, shares, supply) with `bal` or `shares` on EITHER arm -> RED.
    function test_withdrawReturnsProRata() public {
        _seed(LO_BELOW, HI_BELOW);
        uint256 aShares = _deposit(alice, 100e18, 5_000e6);
        _deposit(bob, 100e18, 5_000e6); // equal two-sided deposits -> alice owns half

        vm.prank(alice);
        (uint256 outStock, uint256 outBase) = vault.withdraw(aShares, 0, 0);

        assertApproxEqAbs(outStock, 100e18, 1e6, "gets ~half the stock (her deposit) back");
        assertApproxEqAbs(outBase, 5_000e6, 1e3, "gets ~half the idle USDG back");
        assertApproxEqAbs(_positionLiquidityStockValue(), 100e18, 1e6, "bob's half remains");
    }

    /// F1 pin — token0 (USDG/base) IDLE arm: a PARTIAL-share withdraw pays EXACTLY the caller's
    /// fraction of idle token0, never the whole idle balance. Two-sided deposit into a below-spot
    /// (token1-only) range leaves the USDG fully idle, so out0 is pure idle pro-rata with no burn term.
    /// MUTATION: out0 = Math.mulDiv(basis0, shares, supply) -> out0 = basis0 (pays ALL idle base) -> RED.
    function test_withdrawIdleBaseIsExactProRataNotWhole() public {
        _seed(LO_BELOW, HI_BELOW);
        uint256 aShares = _deposit(alice, 100e18, 5_000e6);
        _deposit(bob, 100e18, 5_000e6); // second holder so alice owns a FRACTION, not all

        uint256 idle0 = usdg.balanceOf(address(vault));
        assertGt(idle0, 0, "idle USDG present to pro-rata");
        uint256 supply = vault.totalSupply();
        uint256 expectBase = Math.mulDiv(idle0, aShares, supply);

        vm.prank(alice);
        (uint256 outStock, uint256 outBase) = vault.withdraw(aShares, 0, 0);

        assertGt(outStock, 0, "stock out from the token1 position burn");
        assertLt(outBase, idle0, "must NOT pay the whole idle base to one withdrawer");
        assertEq(outBase, expectBase, "base out is EXACT idle pro-rata");
    }

    /// F1 pin — token0 (USDG/base) FEE arm: an un-poked token0 feeGrowth folds into BOTH pendingFees
    /// and previewWithdraw's base basis (net of the perf cut), exactly as the token1 arm does. The
    /// two-sided tests deploy nearly all USDG, so without this the base fee term is never driven nonzero.
    /// MUTATION A: pendingFees `fee0 += mulDiv(inside0 - inside0Last, liq, Q128)` -> `fee0 += 0` -> pf0 RED.
    /// MUTATION B: drop `_retained(pf0)` from previewWithdraw's basis0 -> preview base RED.
    function test_baseFeeArmFoldsIntoPendingAndPreview() public {
        _seed(LO_WIDE, HI_WIDE); // in-range so feeGrowth accrues to the position
        uint256 shares = _deposit(alice, 10e18, 5_000e6);

        (, uint256 preBase) = vault.previewWithdraw(shares); // base out before any fee accrues

        uint128 grow0 = 200e6; // un-poked USDG fees a harvest would realize
        usdg.mint(address(pool), grow0);
        pool.accrueGrowth(address(vault), LO_WIDE, HI_WIDE, grow0, 0);

        (uint256 pf0, uint256 pf1) = vault.pendingFees();
        assertApproxEqAbs(pf0, grow0, 1e3, "pending folds in the un-poked BASE fee growth");
        assertEq(pf1, 0, "no stock (token1) fees this case");

        (, uint256 previewBase) = vault.previewWithdraw(shares);
        uint256 net = uint256(grow0) - uint256(grow0) * 1_000 / 10_000; // net of the 10% perf cut
        assertApproxEqAbs(previewBase, preBase + net, 1e3, "preview base folds in the retained base fee");

        vm.prank(alice);
        (, uint256 outBase) = vault.withdraw(shares, 0, 0);
        assertEq(previewBase, outBase, "preview base == actual base out, exactly");
    }

    // ================================================================ no value minted / round-trip

    /// A deposit immediately followed by a full withdraw never returns MORE than was put in, and mints
    /// no phantom USDG. Vault rounding always favors the vault.
    function test_noValueMintedOnRoundTrip() public {
        _seed(LO_BELOW, HI_BELOW);
        uint256 shares = _deposit(alice, 100e18, 0);
        vm.prank(alice);
        (uint256 outStock, uint256 outBase) = vault.withdraw(shares, 0, 0);
        assertLe(outStock, 100e18, "never returns more stock than deposited");
        assertApproxEqAbs(outStock, 100e18, 1e6, "returns ~all of it (only dust lost)");
        assertEq(outBase, 0, "no phantom USDG minted");
    }

    /// A later depositor cannot dilute an existing holder's redeemable value — measured on a DEVIATED
    /// pool, with the independent feed ruler.
    /// This test used to measure the dilution with `vault.totalValueUsd()`, the same biased function the
    /// deposit prices against: the suspect ruler applied to the suspect, green at any deviation with
    /// G3-1 unfixed. It also ran only at spot == oracle, where the deviation term cannot exist at all.
    /// MUTATION: `_positionAmounts` back to the oracle sqrt -> bob over-mints, alice's claim falls -> RED.
    function test_thirdPartyDepositDoesNotDiluteExistingHolder() public {
        _seed(LO_WIDE, HI_WIDE); // straddles spot, so the position holds BOTH tokens and can be skewed
        _deposit(alice, 10e18, 5_000e6);
        _pushDeviation(true);

        uint256 before = _claimUsd18(alice);
        _deposit(bob, 100e18, 20_000e6); // enters LARGE against the deviated pool
        assertGe(_claimUsd18(alice) + PRORATA_DUST_USD18, before, "alice's claim must not fall when bob enters");
    }

    /// M-1 pin: a depositor who enters while fees are PENDING (accrued to prior holders but not yet
    /// harvested) cannot skim them. deposit() harvests first, so pending fees are realized into the
    /// value new shares price against — the sole prior holder keeps her full net-fee entitlement.
    /// MUTATION: remove the _harvest() at the top of deposit() -> bob is priced against a value that
    /// omits the pending fees, dilutes alice to her share fraction of them, and this goes RED.
    function test_depositHarvestsSoNewEntrantCannotSkimPendingFees() public {
        _seed(LO_BELOW, HI_BELOW);
        _deposit(alice, 100e18, 0); // sole holder when the fees accrue

        uint128 fee1 = 500e18; // real pending fees, owed to the position, not yet harvested
        nvda.mint(address(pool), fee1);
        pool.accrueFees(address(vault), LO_BELOW, HI_BELOW, 0, fee1);

        _deposit(bob, 400e18, 0); // bob enters LARGE while fees are pending — the skim window

        uint256 aShares = vault.balanceOf(alice);
        vm.prank(alice);
        (uint256 aliceOut,) = vault.withdraw(aShares, 0, 0);

        uint256 net = uint256(fee1) - uint256(fee1) * 1_000 / 10_000; // fees net of the 10% perf cut
        assertApproxEqAbs(aliceOut, 100e18 + net, 1e10, "alice keeps her principal + ALL net fees she earned alone");
    }

    // ================================================================ keeper cannot divert

    /// The keeper can rebalance but has NO path to receive vault funds; a rebalance conserves value
    /// and leaves the keeper's balances at zero.
    /// MUTATION: make rebalance transfer any token to msg.sender/keeper -> RED.
    function test_keeperCannotDivertFunds() public {
        _seed(LO_BELOW, HI_BELOW);
        _deposit(alice, 100e18, 0);
        uint256 valueBefore = vault.totalValueUsd();

        vm.prank(keeper);
        vault.rebalance(LO_WIDE, HI_WIDE);

        assertEq(nvda.balanceOf(keeper), 0, "keeper got no stock");
        assertEq(usdg.balanceOf(keeper), 0, "keeper got no USDG");
        assertApproxEqAbs(vault.totalValueUsd(), valueBefore, valueBefore / 1e5 + 1, "value conserved across rebalance");
    }

    /// The keeper holds no shares, so it cannot withdraw anything to itself.
    function test_keeperCannotWithdrawWithoutShares() public {
        _seed(LO_BELOW, HI_BELOW);
        _deposit(alice, 100e18, 0);
        vm.prank(keeper);
        vm.expectRevert(); // ERC20 burn amount exceeds balance
        vault.withdraw(1, 0, 0);
    }

    /// G3-4 pin — the keeper is ROTATABLE. It was immutable with no setter, so a leaked keeper key could
    /// park the range permanently out of position and a full vault migration was the only remedy.
    /// MUTATION: drop `keeper = newKeeper` -> the old key keeps rebalance rights -> RED.
    /// MUTATION: swap the KeeperRotated args -> the expectEmit shape mismatches -> RED.
    function test_keeperRotationMovesRebalanceRights() public {
        address newKeeper = address(0xCAFE2);
        vm.expectEmit(true, true, false, false, address(vault));
        emit StockLpVault.KeeperRotated(keeper, newKeeper);
        vm.prank(governor);
        vault.setKeeper(newKeeper);

        vm.prank(keeper);
        vm.expectRevert(StockLpVault.NotKeeper.selector);
        vault.rebalance(LO_WIDE, HI_WIDE);

        vm.prank(newKeeper);
        vault.rebalance(LO_WIDE, HI_WIDE);
        assertEq(vault.tickLower(), LO_WIDE, "the rotated keeper holds the range");
    }

    /// Rotation is governor-only and cannot brick rebalance by pointing at nobody.
    /// MUTATION: drop onlyGovernor, or drop the zero check -> RED.
    function test_keeperRotationIsGovernorOnlyAndNonZero() public {
        vm.prank(alice);
        vm.expectRevert(StockLpVault.NotGovernor.selector);
        vault.setKeeper(alice);

        vm.prank(governor);
        vm.expectRevert(StockLpVault.ZeroAddress.selector);
        vault.setKeeper(address(0));
    }

    /// The price of locking the fee: lockFee renounces the governor, so it freezes the keeper too.
    /// Recorded here because it is a deliberate consequence, not an oversight.
    function test_lockFeeAlsoFreezesTheKeeperForever() public {
        vm.prank(governor);
        vault.lockFee();
        vm.prank(governor);
        vm.expectRevert(StockLpVault.NotGovernor.selector);
        vault.setKeeper(address(0xCAFE2));
    }

    /// Only the keeper may rebalance.
    function test_rebalanceIsKeeperGated() public {
        _seed(LO_BELOW, HI_BELOW);
        vm.prank(alice);
        vm.expectRevert(StockLpVault.NotKeeper.selector);
        vault.rebalance(LO_WIDE, HI_WIDE);
    }

    // ================================================================ fee mechanism (performance + bounty)

    /// Harvest splits realized fees EXACTLY: performanceFeeBps is Essey's cut, of which bountyBps goes
    /// to the cranker and the rest to feeRecipient; the vault keeps the remainder as idle.
    /// MUTATION: drop the perf skim, or inflate/deflate the bps -> RED on the exact-shape assertions.
    function test_performanceFeeExactSplitAndBounty() public {
        _seed(LO_BELOW, HI_BELOW);
        _deposit(alice, 100e18, 0);

        uint128 fee1 = 1_000e18; // 1000 NVDA of accrued fees
        nvda.mint(address(pool), fee1);
        pool.accrueFees(address(vault), LO_BELOW, HI_BELOW, 0, fee1);

        uint256 recipBefore = nvda.balanceOf(feeRecipient);
        uint256 idleBefore = nvda.balanceOf(address(vault));

        address cranker = address(0xD00D); // unfunded, so its balance IS the bounty
        vm.prank(cranker);
        vault.harvest();

        uint256 perf = uint256(fee1) * 1_000 / 10_000; // 10%
        uint256 bounty = uint256(fee1) * 10 / 10_000; // 0.1%
        assertEq(nvda.balanceOf(cranker), bounty, "cranker gets exactly the bounty");
        assertEq(nvda.balanceOf(feeRecipient) - recipBefore, perf - bounty, "recipient gets perf minus bounty");
        assertEq(
            nvda.balanceOf(address(vault)) - idleBefore,
            uint256(fee1) - perf,
            "vault keeps fees net of the full perf cut"
        );
    }

    /// The user's withdrawable is net of EXACTLY the performance fee — never more. The perf cut on the
    /// fees is the only value that leaves before the pro-rata split.
    function test_userWithdrawableIsNetOfExactlyTheFee() public {
        _seed(LO_BELOW, HI_BELOW);
        uint256 shares = _deposit(alice, 100e18, 0);

        uint128 fee1 = 500e18;
        nvda.mint(address(pool), fee1);
        pool.accrueFees(address(vault), LO_BELOW, HI_BELOW, 0, fee1);

        vm.prank(alice);
        (uint256 outStock,) = vault.withdraw(shares, 0, 0);

        // sole depositor: gets principal + fees net of the 10% perf cut (bounty is carved FROM the cut,
        // so the user's net is unaffected by it).
        uint256 perf = uint256(fee1) * 1_000 / 10_000;
        assertApproxEqAbs(outStock, 100e18 + (uint256(fee1) - perf), 1e6, "principal + fees minus exactly the perf fee");
    }

    /// Compound is permissionless and cannot be griefed: the caller chooses nothing and can extract at
    /// most the fixed bounty; the rest of the fee is redeployed / routed.
    function test_compoundPermissionlessCannotBeGriefed() public {
        _seed(LO_BELOW, HI_BELOW);
        _deposit(alice, 100e18, 0);
        uint128 fee1 = 100e18;
        nvda.mint(address(pool), fee1);
        pool.accrueFees(address(vault), LO_BELOW, HI_BELOW, 0, fee1);

        uint256 liqBefore = _positionLiquidity();
        address cranker = address(0xD00D); // unfunded
        vm.prank(cranker);
        vault.compound(); // no params: nothing to grief

        assertEq(nvda.balanceOf(cranker), uint256(fee1) * 10 / 10_000, "caller limited to the bounty");
        assertGt(_positionLiquidity(), liqBefore, "net fees were redeployed into the position");
    }

    /// H-MED pin — a feeRecipient that REVERTS on receipt must NOT be able to brick _harvest, which
    /// gates every deposit and withdraw. A hostile/compromised governor can propose fees to a sink that
    /// reverts (here a blocklist token refusing the recipient — the RH-token-realistic instance), wait
    /// the timelock, execute, and lock. Once any fee accrues, a bricking recipient transfer would revert
    /// EVERY harvest -> every withdraw -> ALL principal frozen. The fix retains the skipped fee as idle
    /// backing and keeps all three paths open.
    /// MUTATION: restore `token.safeTransfer(feeRecipient, toRecipient)` in _splitFee -> harvest RED.
    function test_revertingFeeRecipientDoesNotBrickHarvest() public {
        _seed(LO_BELOW, HI_BELOW);
        _deposit(alice, 100e18, 0); // sole holder

        address badRecipient = address(0xDEAD5);
        vm.prank(governor);
        vault.proposeFee(badRecipient, 1_000, 10); // perf > 0 so a recipient leg exists
        vm.warp(block.timestamp + vault.FEE_TIMELOCK());
        vault.executeFee();
        _refreshFeeds(); // stay in-session after the timelock warp
        nvda.setBlocked(badRecipient, true); // recipient now reverts on any receipt

        // --- harvest: skipped fee retained as idle, nothing frozen
        uint128 feeA = 1_000e18;
        nvda.mint(address(pool), feeA);
        pool.accrueFees(address(vault), LO_BELOW, HI_BELOW, 0, feeA);

        uint256 bountyA = uint256(feeA) * 10 / 10_000;
        uint256 toRecipientA = uint256(feeA) * 1_000 / 10_000 - bountyA;
        uint256 idleBefore = nvda.balanceOf(address(vault));
        address cranker = address(0xC7A5E);

        vm.expectEmit(true, false, false, true, address(vault));
        emit StockLpVault.FeeRetained(address(nvda), toRecipientA);
        vm.prank(cranker);
        vault.harvest();

        assertEq(nvda.balanceOf(badRecipient), 0, "reverting recipient received nothing");
        assertEq(nvda.balanceOf(cranker), bountyA, "cranker still paid the bounty");
        assertEq(
            nvda.balanceOf(address(vault)) - idleBefore,
            uint256(feeA) - bountyA,
            "skipped fee retained as idle backing (fee minus only the bounty)"
        );

        // --- deposit: its internal _harvest hits the same reverting leg and must still succeed
        uint128 feeB = 200e18;
        nvda.mint(address(pool), feeB);
        pool.accrueFees(address(vault), LO_BELOW, HI_BELOW, 0, feeB);
        uint256 bShares = _deposit(alice, 10e18, 0);
        assertGt(bShares, 0, "deposit not bricked by the reverting fee recipient");

        // --- withdraw: its internal _harvest hits it too; principal + retained fees all exit
        uint128 feeC = 50e18;
        nvda.mint(address(pool), feeC);
        pool.accrueFees(address(vault), LO_BELOW, HI_BELOW, 0, feeC);
        uint256 allShares = vault.balanceOf(alice);
        vm.prank(alice);
        (uint256 outStock,) = vault.withdraw(allShares, 0, 0);
        assertGt(outStock, 1_000e18, "sole holder exits with principal + retained fees, nothing frozen");
        assertEq(nvda.balanceOf(badRecipient), 0, "recipient got nothing across harvest, deposit, and withdraw");
    }

    // ================================================================ solvency

    /// Every holder can withdraw their full share; the vault pays out no more than it holds and ends
    /// ~empty. No withdraw reverts for insufficient balance.
    function test_solvencyAllHoldersCanExit() public {
        _seed(LO_BELOW, HI_BELOW);
        uint256 aS = _deposit(alice, 120e18, 0);
        uint256 bS = _deposit(bob, 300e18, 0);
        uint256 cS = _deposit(carol, 55e18, 0);

        uint256 aStart = nvda.balanceOf(alice);
        uint256 bStart = nvda.balanceOf(bob);
        uint256 cStart = nvda.balanceOf(carol);

        vm.prank(bob);
        vault.withdraw(bS, 0, 0);
        vm.prank(alice);
        vault.withdraw(aS, 0, 0);
        vm.prank(carol);
        vault.withdraw(cS, 0, 0);

        assertApproxEqAbs(nvda.balanceOf(alice) - aStart, 120e18, 1e7, "alice ~whole");
        assertApproxEqAbs(nvda.balanceOf(bob) - bStart, 300e18, 1e7, "bob ~whole");
        assertApproxEqAbs(nvda.balanceOf(carol) - cStart, 55e18, 1e7, "carol ~whole");
        assertLt(_positionLiquidityStockValue(), 1e9, "vault drained to dust");
    }

    /// adminBurn on the vault's idle stock is socialized pro-rata across shares (the model never tracks
    /// per-depositor token amounts) — no single holder eats the haircut.
    function test_adminBurnSocializedProRata() public {
        // no range: deposits sit idle so the burn hits vault-held tokens directly.
        uint256 aS = _deposit(alice, 100e18, 0);
        uint256 bS = _deposit(bob, 100e18, 0);

        nvda.adminBurn(address(vault), 40e18); // issuer burns 20% of the 200 held

        vm.prank(alice);
        (uint256 aOut,) = vault.withdraw(aS, 0, 0);
        vm.prank(bob);
        (uint256 bOut,) = vault.withdraw(bS, 0, 0);

        assertApproxEqAbs(aOut, 80e18, 1e6, "alice eats exactly her pro-rata 20%");
        assertApproxEqAbs(bOut, 80e18, 1e6, "bob eats the same pro-rata 20%");
    }

    // ================================================================ fee governor (rails + timelock)

    function test_feeCapRejectsAboveRail() public {
        StockLpVault.VaultConfig memory c = _baseConfig();
        c.performanceFeeBps = 2_001; // above MAX 2000
        vm.expectRevert(StockLpVault.BadFee.selector);
        new StockLpVault(c);
    }

    function test_feeBountyCannotExceedPerformance() public {
        StockLpVault.VaultConfig memory c = _baseConfig();
        c.performanceFeeBps = 100;
        c.bountyBps = 101; // bounty carved FROM perf, cannot exceed it
        vm.expectRevert(StockLpVault.BadFee.selector);
        new StockLpVault(c);
    }

    function test_feeCapBoundaryAllowsExactlyMax() public {
        StockLpVault.VaultConfig memory c = _baseConfig();
        c.performanceFeeBps = 2_000; // exactly the rail
        c.bountyBps = 2_000;
        StockLpVault v = new StockLpVault(c);
        assertEq(v.performanceFeeBps(), 2_000);
    }

    function test_feeGovernorTimelockAndRails() public {
        vm.prank(alice);
        vm.expectRevert(StockLpVault.NotGovernor.selector);
        vault.proposeFee(feeRecipient, 500, 5);

        vm.prank(governor);
        vm.expectRevert(StockLpVault.BadFee.selector);
        vault.proposeFee(feeRecipient, 2_001, 0);

        vm.prank(governor);
        vault.proposeFee(address(0xBEEF), 1_500, 5);

        vm.expectRevert(StockLpVault.TimelockPending.selector);
        vault.executeFee();

        vm.warp(block.timestamp + vault.FEE_TIMELOCK());
        vault.executeFee();
        assertEq(vault.performanceFeeBps(), 1_500);
        assertEq(vault.bountyBps(), 5);
        assertEq(vault.feeRecipient(), address(0xBEEF));
    }

    function test_feeLockIsOneWay() public {
        vm.prank(governor);
        vault.lockFee();
        assertEq(vault.governor(), address(0), "governor renounced");
        vm.prank(governor);
        vm.expectRevert(StockLpVault.NotGovernor.selector);
        vault.proposeFee(feeRecipient, 100, 0);
    }

    // ================================================================ UI views (previewWithdraw / pendingFees)

    /// previewWithdraw returns EXACTLY what a real withdraw pays out, so the UI's headline "what you'd
    /// get now" and its minStock/minBase slippage guards are the truth, not an approximation.
    /// MUTATION: value the position slice at oracle sqrt instead of pool spot, or drop the burn slice -> RED.
    function test_previewWithdrawMatchesActualWithdraw() public {
        _seed(LO_WIDE, HI_WIDE);
        uint256 aShares = _deposit(alice, 10e18, 5_000e6);
        _deposit(bob, 4e18, 2_000e6);

        // in-range position, and spot moved OFF the oracle mark: the burn slice now depends on which
        // sqrt price it is valued at, so this pins "valued at pool spot, not the oracle mark."
        pool.setSqrtPriceX96(TickMath.getSqrtRatioAtTick(222300), 222300);

        (uint256 pStock, uint256 pBase) = vault.previewWithdraw(aShares);

        vm.prank(alice);
        (uint256 outStock, uint256 outBase) = vault.withdraw(aShares, 0, 0);

        assertGt(outStock, 0, "stock out");
        assertGt(outBase, 0, "base out (two-sided in range)");
        assertEq(pStock, outStock, "preview stock == actual stock out");
        assertEq(pBase, outBase, "preview base == actual base out");
    }

    /// previewWithdraw is POST-harvest: withdraw harvests first, so the preview must fold in this share's
    /// slice of the fees a harvest realizes, net of the performance cut. A pre-harvest preview would
    /// understate the payout the caller actually receives.
    /// MUTATION: drop `_retained(pf)` from the idle basis (pre-harvest preview) -> both asserts RED.
    function test_previewWithdrawIsPostHarvestNetOfFee() public {
        _seed(LO_WIDE, HI_WIDE); // in-range so the position earns feeGrowth (single-sided needs both tokens)
        uint256 shares = _deposit(alice, 10e18, 5_000e6);

        (uint256 preStock,) = vault.previewWithdraw(shares); // before any fee accrues

        uint128 grow1 = 200e18; // un-poked NVDA fees a harvest would realize
        nvda.mint(address(pool), grow1);
        pool.accrueGrowth(address(vault), LO_WIDE, HI_WIDE, 0, grow1);

        (uint256 previewStock, uint256 previewBase) = vault.previewWithdraw(shares);

        uint256 net = uint256(grow1) - uint256(grow1) * 1_000 / 10_000; // minus the 10% perf cut
        assertApproxEqAbs(previewStock, preStock + net, 1e6, "preview folds in retained fees (post-harvest)");

        vm.prank(alice);
        (uint256 outStock, uint256 outBase) = vault.withdraw(shares, 0, 0);
        assertEq(previewStock, outStock, "preview == actual stock out, exactly");
        assertEq(previewBase, outBase, "preview == actual base out, exactly");
    }

    /// pendingFees returns EXACTLY what harvest collects — the already-owed fees PLUS the un-poked
    /// feeGrowth harvest's poke would realize. tokensOwed alone would understate the second term.
    /// MUTATION: drop the feeGrowthInside delta term -> pending misses `grow1`, mismatching harvest -> RED.
    function test_pendingFeesMatchesHarvestCollected() public {
        _seed(LO_WIDE, HI_WIDE); // in-range so feeGrowth accrues to the position
        _deposit(alice, 10e18, 5_000e6);

        uint128 owed1 = 30e18; // already poked into tokensOwed
        uint128 grow1 = 120e18; // un-poked, still living in feeGrowth
        nvda.mint(address(pool), uint256(owed1) + grow1);
        pool.accrueFees(address(vault), LO_WIDE, HI_WIDE, 0, owed1);
        pool.accrueGrowth(address(vault), LO_WIDE, HI_WIDE, 0, grow1);

        (uint256 pf0, uint256 pf1) = vault.pendingFees();
        assertEq(pf0, 0, "no token0 fees");
        assertApproxEqAbs(pf1, uint256(owed1) + grow1, 1e6, "pending == owed + un-poked growth");

        vm.prank(address(0xD00D));
        (uint256 h0, uint256 h1) = vault.harvest();

        assertEq(pf0, h0, "pendingFees token0 == harvest collected token0");
        assertEq(pf1, h1, "pendingFees token1 == harvest collected token1");

        (uint256 after0, uint256 after1) = vault.pendingFees();
        assertEq(after0, 0, "nothing pending after harvest");
        assertEq(after1, 0, "nothing pending after harvest");
    }

    // ================================================================ withdraw slippage guard (S9)

    /// S9 pin — the withdraw slippage guard is OR, not AND: the STOCK leg alone under min reverts.
    /// MUTATION: `outStock < minStock || outBase < minBase` -> `&&` -> stock-leg-alone survives -> RED.
    function test_withdrawSlippageGuardTripsOnStockLegAlone() public {
        _seed(LO_BELOW, HI_BELOW);
        uint256 s = _deposit(alice, 100e18, 5_000e6);
        vm.prank(alice);
        vm.expectRevert(StockLpVault.Slippage.selector);
        vault.withdraw(s, type(uint256).max, 0); // base leg fine, stock leg under min
    }

    /// S9 symmetric — the BASE leg alone under min reverts too (the OR guard's other operand).
    function test_withdrawSlippageGuardTripsOnBaseLegAlone() public {
        _seed(LO_BELOW, HI_BELOW);
        uint256 s = _deposit(alice, 100e18, 5_000e6);
        vm.prank(alice);
        vm.expectRevert(StockLpVault.Slippage.selector);
        vault.withdraw(s, 0, type(uint256).max); // stock leg fine, base leg under min
    }

    // ================================================================ guard convergence sweep
    //
    // Every reachable revert guard below is pinned RED against removal/comparator-weakening. NOT pinned,
    // and why no non-equivalent mutant exists: the `!rangeSet` / `liq == 0` / `amount > 0` early returns
    // (_harvest, _liquidity, _proRataParts, _positionAmounts, _splitFee, the zero-value transfer skips)
    // are EQUIVALENT — a downstream guard re-checks the state or the pro-rata math multiplies by zero;
    // and `feeLocked` in proposeFee/lockFee is UNREACHABLE — lockFee renounces the governor in the same
    // call, so onlyGovernor trips first. (executeFee's feeLocked IS reachable/permissionless — pinned below.)

    /// Each of the seven constructor addresses is individually required.
    /// MUTATION: drop any operand of the ZeroAddress guard -> that field's case survives -> RED.
    function test_constructorRejectsEachZeroAddress() public {
        StockLpVault.VaultConfig memory c = _baseConfig();
        c.pool = IUniV3PoolMin(address(0));
        vm.expectRevert(StockLpVault.ZeroAddress.selector);
        new StockLpVault(c);

        c = _baseConfig();
        c.oracle = IStockOracle(address(0));
        vm.expectRevert(StockLpVault.ZeroAddress.selector);
        new StockLpVault(c);

        c = _baseConfig();
        c.stock = IERC20(address(0));
        vm.expectRevert(StockLpVault.ZeroAddress.selector);
        new StockLpVault(c);

        c = _baseConfig();
        c.base = IERC20(address(0));
        vm.expectRevert(StockLpVault.ZeroAddress.selector);
        new StockLpVault(c);

        c = _baseConfig();
        c.keeper = address(0);
        vm.expectRevert(StockLpVault.ZeroAddress.selector);
        new StockLpVault(c);

        c = _baseConfig();
        c.governor = address(0);
        vm.expectRevert(StockLpVault.ZeroAddress.selector);
        new StockLpVault(c);

        c = _baseConfig();
        c.feeRecipient = address(0);
        vm.expectRevert(StockLpVault.ZeroAddress.selector);
        new StockLpVault(c);
    }

    /// maxDeviationBps must be nonzero AND within the ceiling — both directions of the OR guard.
    /// MUTATION: `== 0 || > CEIL` -> `&&` -> the zero case survives -> RED.
    function test_constructorRejectsBadDeviation() public {
        StockLpVault.VaultConfig memory c = _baseConfig();
        c.maxDeviationBps = 0;
        vm.expectRevert(StockLpVault.BadConfig.selector);
        new StockLpVault(c);

        c = _baseConfig();
        c.maxDeviationBps = 501; // above MAX_DEVIATION_CEIL_BPS (500)
        vm.expectRevert(StockLpVault.BadConfig.selector);
        new StockLpVault(c);
    }

    /// The stock/base pair must match the pool's token0/token1 in one of the two orderings.
    /// MUTATION: drop the pair guard -> a mismatched listing constructs instead of reverting -> RED.
    function test_constructorRejectsTokenMismatch() public {
        StockLpVault.VaultConfig memory c = _baseConfig();
        c.base = IERC20(address(nvda)); // both legs NVDA -> neither ordering matches the pool
        vm.expectRevert(StockLpVault.BadConfig.selector);
        new StockLpVault(c);
    }

    /// deposit rejects the empty deposit.
    function test_depositRejectsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(StockLpVault.ZeroAmount.selector);
        vault.deposit(0, 0, 0);
    }

    /// deposit enforces minShares: a computed share count below the caller's floor reverts.
    /// MUTATION: drop `|| shares < minShares` -> the below-floor case survives -> RED.
    function test_depositRejectsBelowMinShares() public {
        _seed(LO_BELOW, HI_BELOW);
        vm.prank(alice);
        vm.expectRevert(StockLpVault.Slippage.selector);
        vault.deposit(100e18, 0, type(uint256).max);
    }

    /// withdraw rejects zero shares.
    function test_withdrawRejectsZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(StockLpVault.ZeroAmount.selector);
        vault.withdraw(0, 0, 0);
    }

    /// rebalance rejects a non-ascending range at the boundary (equal ticks).
    /// MUTATION: `newUpper <= newLower` -> `<` -> the equal-tick case survives -> RED.
    function test_rebalanceRejectsTickOrder() public {
        vm.prank(keeper);
        vm.expectRevert(StockLpVault.TickOrder.selector);
        vault.rebalance(222000, 222000);
    }

    /// rebalance rejects ticks off the spacing grid.
    function test_rebalanceRejectsUnalignedTicks() public {
        vm.prank(keeper);
        vm.expectRevert(StockLpVault.TickNotAligned.selector);
        vault.rebalance(222001, 222720);
    }

    /// F2 pin — the alignment guard is symmetric: an unaligned UPPER tick reverts too. The test above
    /// only misaligns the lower tick, so dropping the `newUpper % tickSpacing != 0` operand survives;
    /// this drives the other operand.
    /// MUTATION: drop `|| newUpper % tickSpacing != 0` -> unaligned upper no longer reverts -> RED.
    function test_rebalanceRejectsUnalignedUpperTick() public {
        vm.prank(keeper);
        vm.expectRevert(StockLpVault.TickNotAligned.selector);
        vault.rebalance(222000, 222001); // lower aligned, upper off the spacing-10 grid
    }

    /// proposeFee rejects a zero recipient.
    function test_proposeFeeRejectsZeroRecipient() public {
        vm.prank(governor);
        vm.expectRevert(StockLpVault.ZeroAddress.selector);
        vault.proposeFee(address(0), 100, 0);
    }

    /// executeFee reverts when nothing is queued.
    function test_executeFeeRejectsNothingPending() public {
        vm.expectRevert(StockLpVault.NothingPending.selector);
        vault.executeFee();
    }

    /// executeFee is dead once the fee is frozen — the lock is checked before the pending-time.
    /// MUTATION: drop the `feeLocked` guard in executeFee -> falls through to NothingPending -> RED.
    function test_executeFeeRejectsWhenLocked() public {
        vm.prank(governor);
        vault.lockFee();
        vm.expectRevert(StockLpVault.FeeFrozenError.selector);
        vault.executeFee();
    }

    /// F3 pin — executeFee ZEROES pendingEffectiveTime so an applied change cannot be replayed. Without
    /// the reset the pending stays live: pendingEffectiveTime() reads nonzero and a second executeFee
    /// re-applies it instead of reverting.
    /// MUTATION: drop `pendingEffectiveTime = 0` in executeFee -> replay guard gone -> RED.
    function test_executeFeeClearsPendingSoItCannotReplay() public {
        vm.prank(governor);
        vault.proposeFee(address(0xBEEF), 1_500, 5);
        vm.warp(block.timestamp + vault.FEE_TIMELOCK());
        vault.executeFee();

        assertEq(vault.pendingEffectiveTime(), 0, "pending cleared after execute");
        vm.expectRevert(StockLpVault.NothingPending.selector);
        vault.executeFee(); // second execute finds nothing pending
    }

    /// The mint callback pays only the pool: any other caller is rejected.
    /// MUTATION: drop the `msg.sender != pool` guard -> a stranger's call no longer reverts -> RED.
    function test_mintCallbackRejectsNonPool() public {
        vm.prank(alice);
        vm.expectRevert(StockLpVault.NotPool.selector);
        vault.uniswapV3MintCallback(0, 0, "");
    }

    // ================================================================ mutation-campaign pins (round 2)

    /// F-C1 pin — the withdrawer RECEIVES the token0/base (USDG) leg. A real balance-delta on msg.sender,
    /// mirroring the token1 pin, so diverting the token0 transfer recipient cannot pass green.
    /// MUTATION: withdraw's `token0.safeTransfer(msg.sender, out0)` recipient -> feeRecipient / address(0) -> RED.
    function test_withdrawCreditsBaseLegToWithdrawer() public {
        _seed(LO_BELOW, HI_BELOW);
        uint256 aShares = _deposit(alice, 100e18, 5_000e6);
        _deposit(bob, 100e18, 5_000e6); // idle USDG stays in the vault (below-spot range is token1-only)

        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 recipBefore = usdg.balanceOf(feeRecipient);

        vm.prank(alice);
        (, uint256 outBase) = vault.withdraw(aShares, 0, 0);

        assertGt(outBase, 0, "base leg is nonzero");
        assertEq(usdg.balanceOf(alice) - aliceBefore, outBase, "withdrawer's USDG rises by exactly outBase");
        assertEq(usdg.balanceOf(feeRecipient), recipBefore, "no base leg diverted to the fee recipient");
    }

    /// F-C2 pin — compound() is tradeable-gated: a permissionless cranker cannot redeploy against a
    /// manipulated (spot off oracle) or unpriced (off-hours) pool.
    /// MUTATION: delete compound()'s `_requireTradeable()` -> both reverts vanish -> RED.
    function test_compoundIsTradeableGated() public {
        _seed(LO_WIDE, HI_WIDE);
        _deposit(alice, 10e18, 5_000e6);

        pool.setSqrtPriceX96(uint160(uint256(sqrtOracle) * 105 / 100), 222362);
        vm.expectRevert(StockLpVault.PriceDeviation.selector);
        vault.compound();

        pool.setSqrtPriceX96(sqrtOracle, 222362);
        vm.warp(MON_IN_SESSION + 5 days);
        _refreshFeeds();
        vm.expectRevert(StockLpVault.NotInSession.selector);
        vault.compound();
    }

    /// F-C3 pin — rebalance() is deviation-gated: the keeper cannot move the range while spot is off oracle.
    /// MUTATION: delete rebalance()'s `_requireTradeable()` -> RED.
    function test_rebalanceIsTradeableGated() public {
        _seed(LO_BELOW, HI_BELOW);
        pool.setSqrtPriceX96(uint160(uint256(sqrtOracle) * 105 / 100), 222362);
        vm.prank(keeper);
        vm.expectRevert(StockLpVault.PriceDeviation.selector);
        vault.rebalance(LO_WIDE, HI_WIDE);
    }

    /// Deviation is measured in PRICE space (oracle/spot)^2, not raw sqrt space: a ~1.6% price move
    /// (0.8% in sqrt) sits above the 1% band and must revert. Sqrt-space would wave it through at half.
    /// MUTATION: `ratio = mulDiv(r, r, 1e18)` -> `ratio = r` (drop the squaring) -> RED.
    function test_depositDeviationIsPriceSpaceNotSqrt() public {
        _seed(LO_BELOW, HI_BELOW);
        pool.setSqrtPriceX96(uint160(uint256(sqrtOracle) * 1_008 / 1_000), 222362);
        vm.prank(alice);
        vm.expectRevert(StockLpVault.PriceDeviation.selector);
        vault.deposit(10e18, 0, 0);
    }

    /// F4 pin — the deviation ratio is oracle/spot, NOT its reciprocal. The two directions are
    /// reciprocals, so |ratio-1| differs; near the band edge only one side trips. Spot is placed in
    /// that sub-bp split: with sqrtO/spot the price sits ~0.5bp OVER the 1% band (revert), while the
    /// reciprocal spot/sqrtO sits ~0.5bp UNDER it (would wave the deposit through). The multiplier is
    /// derived for maxDeviationBps=100 and these oracle prices — recompute it if either changes.
    /// MUTATION: `Math.mulDiv(sqrtO, 1e18, _spotSqrt())` -> `Math.mulDiv(_spotSqrt(), 1e18, sqrtO)` -> RED.
    function test_depositDeviationDirectionIsOracleOverSpot() public {
        _seed(LO_BELOW, HI_BELOW);
        uint160 spot = uint160(uint256(sqrtOracle) * 995_013 / 1_000_000); // just past the band, one way only
        pool.setSqrtPriceX96(spot, 222362);
        vm.prank(alice);
        vm.expectRevert(StockLpVault.PriceDeviation.selector);
        vault.deposit(10e18, 0, 0);
    }

    /// pendingFees folds the token0 (USDG/base) ALREADY-OWED arm, exactly as it does the token1 arm.
    /// MUTATION: pendingFees `fee0 = owed0` -> `fee0 = 0` -> RED.
    function test_pendingFeesIncludesBaseOwedArm() public {
        _seed(LO_WIDE, HI_WIDE);
        _deposit(alice, 10e18, 5_000e6);

        uint128 owed0 = 300e6;
        usdg.mint(address(pool), owed0);
        pool.accrueFees(address(vault), LO_WIDE, HI_WIDE, owed0, 0);

        (uint256 pf0,) = vault.pendingFees();
        assertEq(pf0, owed0, "pending folds the token0 already-owed fees");

        vm.prank(address(0xD00D));
        (uint256 h0,) = vault.harvest();
        assertEq(h0, owed0, "harvest collects exactly the owed token0 fees");
    }

    /// D6 pin — deposit rejects a rounds-to-zero share mint even at minShares 0 (the `shares == 0` operand
    /// stands alone). A donation inflates value-per-share so a dust deposit prices to zero shares.
    /// MUTATION: drop the `shares == 0` operand -> a 0-share deposit mints nothing yet succeeds -> RED.
    function test_depositRejectsZeroSharesEvenAtZeroMin() public {
        _seed(LO_BELOW, HI_BELOW);
        _deposit(alice, 1e18, 0);

        usdg.mint(address(vault), 1_000_000e6); // value-per-share inflated, no new shares

        vm.prank(bob);
        vm.expectRevert(StockLpVault.Slippage.selector);
        vault.deposit(1, 0, 0);
    }

    /// PV2 pin — previewWithdraw returns (0,0) on an empty vault; the `supply == 0` operand guards the
    /// pro-rata division so a pre-launch UI read yields zeros, not a revert.
    /// MUTATION: drop the `supply == 0` operand -> mulDiv by a zero supply reverts -> RED.
    function test_previewWithdrawZeroOnEmptyVault() public view {
        (uint256 s, uint256 b) = vault.previewWithdraw(100e18);
        assertEq(s, 0, "no stock previewed on empty vault");
        assertEq(b, 0, "no base previewed on empty vault");
    }

    /// Y1 pin — _deploy leaves the token0 (USDG/base) AMOUNT_MARGIN idle so the mint round-up stays
    /// payable, mirroring token1. An ABOVE-spot range is USDG-only, driving the token0 arm: with the
    /// margin the vault retains >= 1e3 raw idle; without it, only round-trip dust.
    /// MUTATION: drop `i0 - AMOUNT_MARGIN` in _deploy -> retained idle collapses below 1e3 -> RED.
    function test_deployRetainsBaseMarginAboveSpot() public {
        _seed(LO_ABOVE, HI_ABOVE);
        _deposit(alice, 0, 120_000e6);
        assertGt(_positionLiquidity(), 0, "USDG deployed into the above-spot position");
        assertGe(usdg.balanceOf(address(vault)), 1_000, "token0 margin retained idle for mint payability");
    }

    // ---------------------------------------------------------------- internal views

    function _baseConfig() internal view returns (StockLpVault.VaultConfig memory) {
        return StockLpVault.VaultConfig({
            pool: IUniV3PoolMin(address(pool)),
            oracle: IStockOracle(address(oracle)),
            stock: IERC20(address(nvda)),
            base: IERC20(address(usdg)),
            keeper: keeper,
            governor: governor,
            feeRecipient: feeRecipient,
            maxDeviationBps: 100,
            performanceFeeBps: 1_000,
            bountyBps: 10,
            name: "x",
            symbol: "x"
        });
    }

    function _positionLiquidity() internal view returns (uint128 liq) {
        bytes32 key = keccak256(abi.encodePacked(address(vault), vault.tickLower(), vault.tickUpper()));
        (liq,,,,) = pool.positions(key);
    }

    /// Rough stock-side value of the live position (single-sided below-spot => all token1).
    function _positionLiquidityStockValue() internal view returns (uint256 amount1) {
        uint128 liq = _positionLiquidity();
        if (liq == 0) return 0;
        uint160 sa = TickMath.getSqrtRatioAtTick(vault.tickLower());
        uint160 sb = TickMath.getSqrtRatioAtTick(vault.tickUpper());
        // below spot: all token1
        amount1 = Math.mulDiv(liq, sb - sa, 0x1000000000000000000000000);
    }
}
