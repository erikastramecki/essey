// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// THE MVP PATH, END TO END, AGAINST REAL ROBINHOOD CHAIN STATE.
///
/// Everything here is live mainnet: the real AAPL Stock Token behind its beacon proxy, the real
/// Chainlink feed, real USDG, and real holders whose balances are borrowed via impersonation. No
/// mocks. The suite's mocks are useful for adversarial cases but they are written by the same
/// person as the code, and one of them (a MockUSDG with the wrong decimals) hid a critical bug
/// for an entire audit round. This is the check that cannot be fooled that way.
///
///   forge test --match-path test/ForkMvp.t.sol --fork-url https://rpc.mainnet.chain.robinhood.com -vv
///
/// It is skipped when not forking, so the normal suite is unaffected.
contract ForkMvpTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant AAPL_WHALE = 0x9f736F87E6293AC1Bd9142E257dbfAC8b7AcF1ae; // EOA, ~309 AAPL
    address constant USDG_WHALE = 0x2d4d2A025b10C09BDbd794B4FCe4F7ea8C7d7bB4; // EOA, ~50M USDG

    EsseyPool pool;
    EsseyMarkets markets;
    LivenessOracle liveness;
    MarketHealthOracle health;
    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");

    bool forked;

    function setUp() public {
        // Only run when forked. block.chainid is 31337 under a plain `forge test`.
        if (block.chainid != 4663) return;
        forked = true;

        uint8 assetDec = IERC20Metadata(USDG).decimals();
        uint8 stockDec = IERC20Metadata(AAPL).decimals();
        uint8 feedDec = AggregatorV3Interface(AAPL_FEED).decimals();

        // Short grace: this test proves the MVP path, not the liveness timing (unit-tested).
        liveness = new LivenessOracle(keeper, admin, 30 minutes, 1 minutes);
        health = new MarketHealthOracle(keeper, admin, admin);
        // address(0): no L2 sequencer uptime feed exists on this chain — LivenessOracle stands in.
        // guardian == admin here: this fork test proves the MVP path, not the guardian split.
        markets = new EsseyMarkets(AggregatorV3Interface(address(0)), liveness, health, admin, admin, assetDec);
        vm.prank(admin);
        health.wireMarkets(address(markets));
        // The RH Stock Token carries the ERC-8056 surface itself (multiplierIsToken), so it is its own
        // uiMultiplier source; the pool is bound to AAPL as its single collateral.
        pool = new EsseyPool(
            IERC20(USDG), AAPL, markets, 0, 0, 0, 0, address(0), address(0x7EA), 0,
            EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")
        );

        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: stockDec, cap: uint128(1_000_000 * (10 ** assetDec)), maxPositionBps: 10_000
        });
        vm.startPrank(admin);
        markets.proposeMarket(AAPL, AggregatorV3Interface(AAPL_FEED), 86_400, 90_000, feedDec, AAPL, address(pool), m);
        vm.warp(block.timestamp + markets.PARAM_TIMELOCK());
        markets.commitMarket(AAPL);
        vm.stopPrank();

        // Bring liveness online in two beats rather than twelve.
        _beat();
        vm.warp(block.timestamp + 1 minutes);
        _beat();
        require(liveness.liquidationsAllowed(), "liveness must be online");
        // Ride the health oracle's from-zero depth ramp so effectiveCap (and thus borrowCap) clears
        // the MVP borrow. Posts on a <24h cadence so the reading never ages out mid-ramp.
        _rampDepth();

        // Move real balances from real holders.
        vm.prank(USDG_WHALE);
        IERC20(USDG).transfer(lender, 50_000 * (10 ** assetDec));
        vm.prank(AAPL_WHALE);
        IERC20(AAPL).transfer(borrower, 10 * (10 ** stockDec));
    }

    function _beat() internal { vm.prank(keeper); liveness.heartbeat(); }

    function _postDepth() internal {
        uint128 depth = uint128(4_000_000 * (10 ** IERC20Metadata(USDG).decimals())); // target > static cap: min() = cap
        vm.prank(keeper);
        health.postDepth(AAPL, depth, uint64(block.number), "fork-swap-v1");
    }

    /// Arm and ride the from-zero depth ramp on a <24h keeper cadence, past raiseDelay and the
    /// full slew, so effectiveCap reaches the static cap before the MVP borrow.
    function _rampDepth() internal {
        _postDepth();
        for (uint256 i = 0; i < 30; i++) {
            vm.warp(block.timestamp + 12 hours);
            _beat();
            _postDepth();
        }
    }

    /// Move the clock to the next instant inside a US equity session, keeping the feed fresh and
    /// the keeper beating. Forking pins block.timestamp to whenever the fork was taken, which may
    /// be a weekend or overnight.
    function _intoSession() internal {
        uint256 guard = 0;
        while (!markets.isUsMarketHours(block.timestamp) && guard++ < 200) {
            vm.warp(block.timestamp + 1 hours);
            _beat();
            _postDepth(); // keep the depth reading inside MAX_READING_AGE across the session hunt
        }
        _settleLiveness();
        _postDepth();
        require(markets.isUsMarketHours(block.timestamp), "could not reach a session");
        _refreshFeed();
    }

    /// Serve out resumeGrace on a live keeper cadence.
    ///
    /// G-LEND INFO-3: this is why `test_fullMvpPath_realTokenRealFeed` sat RED. Every 1-hour hop
    /// above is longer than gapThreshold, so each one registers as an outage and re-arms the grace;
    /// the fixture then asked for a borrow while the oracle was still inside it and got MarketClosed.
    /// The cause was always here, in the helper — and a permanently-red fork test is worse than no
    /// fork test, because it teaches everyone to ignore the one check that mocks cannot fool.
    function _settleLiveness() internal {
        _beat();
        vm.warp(block.timestamp + liveness.resumeGrace()); // < gapThreshold, so it registers no gap
        _beat();
        require(liveness.liquidationsAllowed(), "liveness must be settled before acting");
    }

    /// The real feed goes stale against the warped clock, so restamp its answer at the current time
    /// while keeping the REAL price. Only the timestamp is synthetic.
    function _refreshFeed() internal {
        (, int256 answer,,,) = AggregatorV3Interface(AAPL_FEED).latestRoundData();
        vm.mockCall(
            AAPL_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// Walk out of the session on the same live cadence, so liveness and depth stay up and the
    /// session is the ONLY gate that closes.
    function _outOfSession() internal {
        uint256 guard = 0;
        while (markets.isUsMarketHours(block.timestamp) && guard++ < 12) {
            vm.warp(block.timestamp + 1 hours);
            _beat();
            _postDepth();
        }
        _settleLiveness();
        _postDepth();
        _refreshFeed();
    }

    function test_fullMvpPath_realTokenRealFeed() public {
        if (!forked) return;
        _intoSession();

        uint8 assetDec = IERC20Metadata(USDG).decimals();
        uint8 stockDec = IERC20Metadata(AAPL).decimals();
        (, int256 answer,,,) = AggregatorV3Interface(AAPL_FEED).latestRoundData();
        console.log("AAPL price (8dp)      ", uint256(answer));

        // --- lender funds the pool ---
        vm.startPrank(lender);
        IERC20(USDG).approve(address(pool), type(uint256).max);
        pool.deposit(50_000 * (10 ** assetDec), lender);
        vm.stopPrank();
        console.log("pool totalAssets      ", pool.totalAssets());

        // --- quote ---
        uint256 collateral = 10 * (10 ** stockDec);
        (uint256 value, bool inSession) = markets.collateralValue(AAPL, collateral);
        uint256 max = markets.maxBorrow(AAPL, collateral);
        console.log("10 AAPL value (USDG)  ", value);
        console.log("max borrow  (USDG)    ", max);
        assertTrue(inSession, "must be in a session");
        assertGt(value, 0);
        // 10 shares of a several-hundred-dollar stock: sanity-bound the magnitude so a decimals
        // regression cannot pass this test quietly.
        assertGt(value, 1_000 * (10 ** assetDec), "10 AAPL must be worth >$1k");
        assertLt(value, 20_000 * (10 ** assetDec), "10 AAPL must be worth <$20k");

        // --- borrow ---
        uint256 debt = (max * 90) / 100; // 90% of the limit
        vm.startPrank(borrower);
        IERC20(AAPL).approve(address(pool), collateral);
        uint256 id = pool.borrow(collateral, debt);
        vm.stopPrank();
        console.log("borrowed    (USDG)    ", debt);
        assertEq(IERC20(USDG).balanceOf(borrower), debt, "borrower received USDG");
        assertEq(IERC20(AAPL).balanceOf(address(pool)), collateral, "pool holds the collateral");

        // --- health ---
        assertFalse(markets.isUnderwater(AAPL, collateral, pool.debtOf(id)), "healthy at 90% of max");

        // --- repay ---
        vm.startPrank(borrower);
        IERC20(USDG).approve(address(pool), debt);
        pool.repay(id, debt);
        vm.stopPrank();
        assertEq(pool.debtOf(id), 0, "debt cleared");
        assertEq(IERC20(AAPL).balanceOf(borrower), collateral, "collateral returned in full");
        console.log("repaid, collateral returned");
    }

    /// The 20pp buffer is the whole safety argument. Prove it against the real price: a position
    /// at max LTV must survive a 30% drop and must be liquidatable somewhere past that.
    function test_gapAbsorbsARealWeekendGap() public {
        if (!forked) return;
        _intoSession();
        uint256 collateral = 10 * (10 ** IERC20Metadata(AAPL).decimals());
        uint256 max = markets.maxBorrow(AAPL, collateral);
        (, int256 answer,,,) = AggregatorV3Interface(AAPL_FEED).latestRoundData();

        _repriceTo((answer * 70) / 100); // -30%
        assertFalse(markets.isUnderwater(AAPL, collateral, max), "must survive a 30% gap at max LTV");
        _repriceTo((answer * 60) / 100); // -40%
        assertTrue(markets.isUnderwater(AAPL, collateral, max), "and break past that");
    }

    function _repriceTo(int256 p) internal {
        vm.mockCall(
            AAPL_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), p, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// Off-hours borrowing must be refused against the real calendar — and refused for the RIGHT
    /// reason. Every other gate is held open here: the keeper is beating, depth is posted, the feed
    /// is fresh. Liquidation gates on FRESHNESS rather than session (EsseyMarkets._liquidationPriceGate)
    /// and stays open at the same instant; borrowing does not. Without that pair, `assertFalse(canBorrow)`
    /// passes on any fixture that has simply gone stale, which is what it used to be doing.
    function test_realOffHoursBlocksBorrowingButNotLiquidation() public {
        if (!forked) return;
        _intoSession();
        assertTrue(markets.canBorrow(AAPL), "control: borrowing IS open in session");
        _outOfSession();
        assertFalse(markets.isUsMarketHours(block.timestamp), "fixture must be off-hours");
        assertTrue(markets.canLiquidate(AAPL), "liquidation gates on freshness, not the session");
        assertFalse(markets.canBorrow(AAPL), "no borrowing off-session");

        // and the calendar's own weekend, which is off-hours by day-of-week rather than by clock
        uint256 day = (block.timestamp / 86400) * 86400;
        uint256 dow = ((block.timestamp / 86400) + 3) % 7;
        uint256 saturdayMidday = day + ((5 - dow + 7) % 7) * 1 days + 16 hours;
        assertFalse(markets.isUsMarketHours(saturdayMidday), "Saturday midday is not a session");
    }

    /// THE CHECK A MOCK CANNOT FOOL, made specific. G-LEND CRIT-1 was never a wrong VALUE — it was a
    /// wrong SHAPE, and every fixture in the repo agreed with the interface instead of with the
    /// chain. So assert the shape of every external surface the engine calls, at the deployed
    /// address, and let a change in any of them turn this red.
    function test_everyProductionReturnShape() public {
        if (!forked) return;

        (bool ok, bytes memory ret) = AAPL.staticcall(abi.encodeWithSignature("newUIMultiplier()"));
        console.log("newUIMultiplier ok / len", ok, ret.length);
        assertTrue(ok, "the CALL succeeds - it was always the decode that failed");
        assertEq(ret.length, 32, "ONE word, not the two IScaledUI declares. If this becomes 64, re-read _desyncGuard");

        (ok, ret) = AAPL.staticcall(abi.encodeWithSignature("uiMultiplier()"));
        assertTrue(ok && ret.length >= 32, "uiMultiplier must be readable, or collateralValue reverts");
        assertGt(abi.decode(ret, (uint256)), 0, "and nonzero, or every position prices at zero");

        (ok, ret) = USDG.staticcall(abi.encodeWithSignature("paused()"));
        console.log("USDG paused() ok / len", ok, ret.length);
        assertTrue(
            !ok || ret.length < 32 || abi.decode(ret, (uint256)) == 0,
            "a paused borrow asset suspends the whole accrual clock"
        );

        assertEq(IERC20Metadata(USDG).decimals(), 6, "USDG decimals - the 1e12 over-valuation lesson");
        assertEq(IERC20Metadata(AAPL).decimals(), 18, "Stock Token decimals");
        assertEq(AggregatorV3Interface(AAPL_FEED).decimals(), 8, "Chainlink feed decimals");
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(AAPL_FEED).latestRoundData();
        assertGt(answer, 0, "the feed must answer with a positive price");
        assertGt(updatedAt, 0, "and a real timestamp");
    }

    /// The CRIT-1 regression itself, at the production address: both gates must ANSWER against the
    /// real one-word token. They used to revert, and the pool calls them without a try.
    function test_bothGatesAnswerAgainstTheRealToken() public {
        if (!forked) return;
        _intoSession();
        assertTrue(markets.canBorrow(AAPL), "canBorrow must answer against the deployed token");
        assertTrue(markets.canLiquidate(AAPL), "canLiquidate must answer against the deployed token");
    }
}
