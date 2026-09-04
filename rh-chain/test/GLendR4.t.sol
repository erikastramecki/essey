// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IScaledUI} from "../src/interfaces/IScaledUI.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// G-LEND round 4, on the real chain: every finding, inverted into the property that now holds.
///
/// The auditor's harness lived in a scratchpad that is wiped at boot, and rounds 2 and 3 already
/// lost theirs that way. This is that harness, on the deployed AAPL and NVDA tokens, the deployed
/// feeds, the deployed USDG and the deployed risk parameters — so the numbers a finding was priced
/// at stay reproducible and the fix stays pinned.
///
/// The originals asserted that the attacks SUCCEEDED. Run against this tree they are red: A1b/A2 at
/// the promotion clock that no longer exists, B1 at `seenMultiplier` no longer advancing alone,
/// C1 at "the split leg is corroborated: 0 != 16353502154", E2 at NotAdmin(). What follows asserts
/// the other side of each of those.
abstract contract GLendR4Base is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant AAPL_WHALE = 0x9f736F87E6293AC1Bd9142E257dbfAC8b7AcF1ae;
    address constant USDG_WHALE = 0x2d4d2A025b10C09BDbd794B4FCe4F7ea8C7d7bB4;

    // The deployed pair, script/DeployMarkets.s.sol.
    uint256 constant GAP = 900;
    uint256 constant GRACE = 1 hours;

    EsseyPool pool;
    EsseyMarkets markets;
    LivenessOracle liveness;
    MarketHealthOracle health;

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address rotationAdmin = makeAddr("rotationAdmin");
    address keeper = makeAddr("keeper");
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");
    address treasury = makeAddr("treasury");

    uint8 assetDec;
    uint8 stockDec;
    int256 realPrice;

    function _setUpFork() internal {
        vm.createSelectFork(vm.rpcUrl("rh_mainnet"));
        (, realPrice,,,) = AggregatorV3Interface(AAPL_FEED).latestRoundData();
        require(realPrice > 0, "real price");
        assetDec = IERC20Metadata(USDG).decimals();
        stockDec = IERC20Metadata(AAPL).decimals();

        liveness = new LivenessOracle(keeper, guardian, rotationAdmin, GAP, GRACE);
        health = new MarketHealthOracle(keeper, guardian, admin);
        markets = new EsseyMarkets(AggregatorV3Interface(address(0)), liveness, health, admin, guardian, assetDec);
        vm.prank(admin);
        health.wireMarkets(address(markets));
        pool = new EsseyPool(
            IERC20(USDG), AAPL, markets, 500, 750, 3000, 1000, address(0), treasury, 0,
            EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")
        );
        _list(AAPL, AAPL_FEED, address(pool));

        _beat();
        vm.warp(block.timestamp + 60);
        _beat();
        vm.warp(block.timestamp + GRACE + 1);
        _beat();
        _settle();
        _rampDepth();
        _fund();
    }

    /// The deployed risk params, script/DeployMarkets.s.sol _marketList: 5000 / 7500 / 500.
    function _list(address token, address feed, address p) internal {
        // Read both decimals BEFORE the prank: an argument-position staticcall consumes it, and the
        // propose then arrives from the test contract and reverts NotAdmin.
        uint8 collDec = IERC20Metadata(token).decimals();
        uint8 feedDec = AggregatorV3Interface(feed).decimals();
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true,
            ltvBps: 5_000,
            liqThresholdBps: 7_500,
            liqBonusBps: 500,
            collateralDecimals: collDec,
            cap: uint128(250_000 * (10 ** assetDec)),
            maxPositionBps: 2_000
        });
        vm.prank(admin);
        markets.proposeMarket(token, AggregatorV3Interface(feed), 86_400, 90_000, feedDec, token, p, m);
        _warpQuiet(markets.PARAM_TIMELOCK() + 1);
        markets.commitMarket(token);
    }

    function _fund() internal {
        vm.prank(USDG_WHALE);
        IERC20(USDG).transfer(lender, 200_000 * (10 ** assetDec));
        vm.prank(USDG_WHALE);
        IERC20(USDG).transfer(liquidator, 50_000 * (10 ** assetDec));
        vm.prank(AAPL_WHALE);
        IERC20(AAPL).transfer(borrower, 50 * (10 ** stockDec));

        vm.startPrank(lender);
        IERC20(USDG).approve(address(pool), type(uint256).max);
        pool.deposit(200_000 * (10 ** assetDec), lender);
        vm.stopPrank();
        vm.prank(liquidator);
        IERC20(USDG).approve(address(pool), type(uint256).max);
    }

    function _beat() internal {
        vm.prank(keeper);
        liveness.heartbeat();
    }

    function _settle() internal {
        uint256 guardCount;
        while (!liveness.liquidationsAllowed() && guardCount++ < 200) {
            vm.warp(block.timestamp + GAP / 3);
            _beat();
        }
        require(liveness.liquidationsAllowed(), "liveness must settle");
    }

    function _postDepth() internal {
        vm.prank(keeper);
        health.postDepth(AAPL, uint128(4_000_000 * (10 ** assetDec)), uint64(block.number), "fork-swap-v1");
    }

    function _rampDepth() internal {
        _postDepth();
        for (uint256 i = 0; i < 30; i++) {
            _warpQuiet(12 hours);
            _postDepth();
        }
        _hold(realPrice, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
    }

    /// Warp on the keeper's beat WITHOUT observing — R4 HIGH-2's world, and the one every
    /// stale-baseline scenario here is actually about.
    function _warpQuiet(uint256 dt) internal {
        uint256 end = block.timestamp + dt;
        while (block.timestamp + GAP / 3 < end) {
            vm.warp(block.timestamp + GAP / 3);
            _beat();
            _reprice(realPrice);
        }
        vm.warp(end);
        _beat();
        _reprice(realPrice);
    }

    /// The DEPLOYED keeper: beat AND observe on the same tick (keeper/liveness-keeper.mjs).
    function _hold(int256 p, uint256 dt) internal {
        uint256 end = block.timestamp + dt;
        while (block.timestamp < end) {
            uint256 step = end - block.timestamp;
            if (step > GAP / 3) step = GAP / 3;
            vm.warp(block.timestamp + step);
            _beat();
            _reprice(p);
            markets.syncMultiplier(AAPL);
        }
        _postDepth();
    }

    /// The keeper beating but not observing, held at `p`.
    function _holdQuiet(int256 p, uint256 dt) internal {
        uint256 end = block.timestamp + dt;
        while (block.timestamp < end) {
            uint256 step = end - block.timestamp;
            if (step > GAP / 3) step = GAP / 3;
            vm.warp(block.timestamp + step);
            _beat();
            _reprice(p);
        }
        _postDepth();
    }

    function _reprice(int256 p) internal {
        vm.mockCall(
            AAPL_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), p, block.timestamp, block.timestamp, uint80(1))
        );
    }

    function _intoSession() internal {
        uint256 g;
        while (!markets.isUsMarketHours(block.timestamp) && g++ < 300) {
            _hold(realPrice, 1 hours);
        }
        require(markets.isUsMarketHours(block.timestamp), "no session");
        _postDepth();
        _reprice(realPrice);
    }

    function _coll() internal view returns (uint256) {
        return 10 * (10 ** stockDec);
    }

    /// Open at 90% of max LTV and season it in steps inside MAX_PRICE_DEVIATION_BPS, so nothing
    /// arms — an ordinary loan that has moved against its borrower, not an exotic one.
    function _seasonedPosition() internal returns (uint256 id, int256 seasoned) {
        _intoSession();
        vm.startPrank(borrower);
        IERC20(AAPL).approve(address(pool), _coll());
        id = pool.borrow(_coll(), (markets.maxBorrow(AAPL, _coll()) * 90) / 100);
        vm.stopPrank();

        seasoned = realPrice;
        for (uint256 i = 0; i < 3; i++) {
            seasoned = (seasoned * 85) / 100; // -1,500bps a step: inside the 2,000bps bound
            _reprice(seasoned);
            markets.syncMultiplier(AAPL);
        }
        assertEq(markets.priceDesyncAt(AAPL), 0, "no step of the seasoning armed the breaker");
        assertFalse(markets.isUnderwater(AAPL, _coll(), pool.debtOf(id)), "seasoned but still healthy");
    }
}

/// HIGH-1. A sub-bound feed leg — the half of a corporate action nothing else covers — cannot
/// justify a seizure until it has STOOD for PRICE_CONFIRM_DELAY, at every offset a permissionless
/// caller can choose. The original A1b took $381.84 of free profit on a $1,472.67 debt (2,592bps)
/// ONE SECOND after the leg landed, by anchoring the promotion clock an hour minus one second in
/// advance. There is no promotion clock to anchor now.
contract GLendR4Corroboration is GLendR4Base {
    function setUp() public {
        _setUpFork();
    }

    function _sixToFiveSplitLeg(int256 seasoned) internal returns (int256 leg) {
        leg = (seasoned * 5) / 6; // -1,667bps, under MAX_PRICE_DEVIATION_BPS
        _reprice(leg);
        markets.syncMultiplier(AAPL);
    }

    /// A1b, inverted, and at four offsets rather than the one the finding needed. The attacker
    /// chooses where in the observation cadence the leg lands; none of them buys a seizure.
    function test_theFeedLegOfASplitCannotBeSeizedAtAnyOffset() public {
        uint256[4] memory offsets =
            [uint256(1), 5 minutes, markets.CONFIRM_STEP() - 1, markets.PRICE_CONFIRM_DELAY() - 1];

        for (uint256 i = 0; i < offsets.length; i++) {
            uint256 snap = vm.snapshotState();
            (uint256 id, int256 seasoned) = _seasonedPosition();

            _holdQuiet(seasoned, offsets[i]); // position the clock; nobody observes
            int256 leg = _sixToFiveSplitLeg(seasoned);
            assertEq(markets.priceDesyncAt(AAPL), 0, "sub-bound: the breaker never arms");
            assertTrue(markets.isUnderwater(AAPL, _coll(), pool.debtOf(id)), "the LIVE read says underwater");

            vm.warp(block.timestamp + 1); // the second the old rule handed the position over
            _reprice(leg);
            _beat();
            vm.prank(liquidator);
            vm.expectRevert(abi.encodeWithSelector(EsseyPool.PriceNotCorroborated.selector, AAPL));
            pool.liquidate(id);
            vm.revertToState(snap);
        }
    }

    /// A2, inverted: the DEPLOYED keeper observing every 300s throughout is what made the delivered
    /// delay 300 seconds rather than an hour, because its own observations drove the promotion
    /// clock. Observing now only ages the delay line; it cannot shorten it.
    function test_anObservingKeeperCannotShortenTheDelay() public {
        (uint256 id, int256 seasoned) = _seasonedPosition();
        _hold(seasoned, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());

        uint256 legAt = block.timestamp;
        int256 leg = _sixToFiveSplitLeg(seasoned);
        _hold(leg, GAP / 3); // one keeper beat later, which used to be enough
        assertEq(block.timestamp - legAt, GAP / 3, "300 seconds after the leg");
        assertFalse(markets.isUnderwaterCorroborated(AAPL, _coll(), pool.debtOf(id)), "and it is not corroborated");
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.PriceNotCorroborated.selector, AAPL));
        pool.liquidate(id);

        // And the delay is a FLOOR, not a refusal: the same seizure goes through once the move has
        // genuinely stood, which is the only difference between a repricing and a half-landed action.
        _hold(leg, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        assertGe(block.timestamp - markets.confirmedObservedAt(AAPL), markets.PRICE_CONFIRM_DELAY(), "a full delay old");
        vm.prank(liquidator);
        pool.liquidate(id);
        assertEq(pool.debtOf(id), 0, "a real move is still liquidated, six hours later");
    }

    /// The magnitude, pinned. Mutating PRICE_CONFIRM_DELAY to one second must break something, and
    /// under the old rule nothing in 1,751 tests did — the whole suite sampled the one phase of the
    /// interval in which the gate was at full strength.
    function test_theDelayIsSixHoursAndTheLineDeliversIt() public {
        assertEq(markets.PRICE_CONFIRM_DELAY(), 6 hours, "the derivation is in the constant's doc block");
        assertEq(markets.CONFIRM_STEP(), 90 minutes, "four steps to the delay");
        assertEq(markets.MAX_CONFIRM_AGE(), 9 hours, "and one step of slack above the steady state");

        _hold(realPrice, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());
        uint256 age = block.timestamp - markets.confirmedObservedAt(AAPL);
        assertGe(age, 6 hours, "the corroborated observation is at least six hours old");
        assertLe(age, 9 hours, "and at most nine");
    }
}

/// MED-1. An observation is a (price, multiplier) PAIR. The AAPL feed is unreadable ~55h every
/// weekend against its 90,000s staleness bound, which is exactly when an issuer applies an action
/// for a Monday ex-date — and the multiplier half used to advance alone, so Monday's first
/// observation treated Friday's price and Monday's multiplier as one matched pair and made
/// `isUnderwaterCorroborated` true for a position healthy at every price that ever existed.
contract GLendR4PairSplit is GLendR4Base {
    function setUp() public {
        _setUpFork();
        _intoSession();
    }

    function _staleFeed(int256 p) internal {
        vm.mockCall(
            AAPL_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), p, block.timestamp - 200_000, block.timestamp - 200_000, uint80(1))
        );
    }

    function _setMultiplier(uint256 m) internal {
        vm.mockCall(AAPL, abi.encodeWithSelector(IScaledUI.uiMultiplier.selector), abi.encode(m));
    }

    /// B1, inverted.
    function test_anUnreadablePriceRecordsNeitherHalfOfTheObservation() public {
        uint256 m0 = IScaledUI(AAPL).uiMultiplier();
        vm.startPrank(borrower);
        IERC20(AAPL).approve(address(pool), _coll());
        uint256 id = pool.borrow(_coll(), (markets.maxBorrow(AAPL, _coll()) * 90) / 100);
        vm.stopPrank();

        // Friday close: the feed ages past maxStaleness. Then the issuer applies a 1:2 reverse split
        // over the weekend, so uiMultiplier halves while the price cannot be read.
        _staleFeed(realPrice);
        assertFalse(markets.canLiquidate(AAPL), "an unreadable price already declines");
        _setMultiplier(m0 / 2);
        markets.syncMultiplier(AAPL);
        assertEq(markets.seenMultiplier(AAPL), m0, "MED-1: the multiplier half did NOT move alone");
        assertEq(markets.seenPrice(AAPL), uint256(realPrice), "and the price half is untouched");

        // Monday, split-adjusted: the price doubles, so the PRODUCT is unchanged and nothing about
        // this is a dislocation. The pair the registry promotes is now a MATCHED one.
        int256 p2 = realPrice * 2;
        _hold(p2, markets.MULTIPLIER_GUARD_WINDOW() + 1);
        _hold(p2, markets.PRICE_CONFIRM_DELAY() + 2 * markets.CONFIRM_STEP());

        (uint256 live,) = markets.collateralValue(AAPL, _coll());
        (uint256 corr, bool available) = markets.corroboratedValue(AAPL, _coll());
        assertTrue(available, "corroborated once the feed came back and the line refilled");
        assertApproxEqRel(corr, live, 1e15, "and it agrees with the live read rather than halving it");

        uint256 owed = pool.debtOf(id);
        assertFalse(markets.isUnderwater(AAPL, _coll(), owed), "healthy on every real price");
        assertFalse(markets.isUnderwaterCorroborated(AAPL, _coll(), owed), "and the gate is not satisfied vacuously");
        vm.prank(liquidator);
        vm.expectRevert(EsseyPool.PositionHealthy.selector);
        pool.liquidate(id);
    }
}

/// HIGH-2. A market the keeper stops observing was harvested for 10,988bps — $1,618.18 of free
/// profit on a $1,472.67 debt — because `_breaker` discards a 5,000bps leg measured against a stale
/// baseline as drift, and the only protection left was one corroboration interval. It now has no
/// corroborated price at all, so it cannot be seized on any price.
contract GLendR4KeeperGap is GLendR4Base {
    function setUp() public {
        _setUpFork();
        _intoSession();
    }

    function _open() internal returns (uint256 id) {
        vm.startPrank(borrower);
        IERC20(AAPL).approve(address(pool), _coll());
        id = pool.borrow(_coll(), (markets.maxBorrow(AAPL, _coll()) * 90) / 100);
        vm.stopPrank();
    }

    /// C1, inverted. The setup is the whole finding: one quiet hour.
    function test_anUnobservedMarketCannotBeHarvestedOnASplitLeg() public {
        uint256 id = _open();
        _holdQuiet(realPrice, markets.MAX_BASELINE_AGE() + 1);

        int256 half = realPrice / 2; // the feed leg of a 2:1 split, -5,000bps
        _reprice(half);
        markets.syncMultiplier(AAPL);
        assertEq(markets.priceDesyncAt(AAPL), 0, "a stale baseline still declines to arm, by design");
        assertTrue(markets.canLiquidate(AAPL), "and the market gate is open: this is not the liveness bound");

        // One corroboration interval later — the whole of what used to be left — and again at the
        // ceiling. The delay line was never observed at the new level, so nothing vouches for it.
        _holdQuiet(half, markets.PRICE_CONFIRM_DELAY() + 1);
        (, bool available) = markets.corroboratedValue(AAPL, _coll());
        assertFalse(available, "HIGH-2: an unobserved market has no corroborated price");
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.PriceNotCorroborated.selector, AAPL));
        pool.liquidate(id);
    }

    /// The control, which is what makes the refusal above a fix rather than an outage: an OBSERVED
    /// market arms on the same leg and holds both gates for PRICE_DESYNC_HOLD.
    function test_theObservedMarketStillArms() public {
        uint256 id = _open();
        _hold(realPrice, 3 hours);

        _reprice(realPrice / 2);
        markets.syncMultiplier(AAPL);
        assertGt(markets.priceDesyncAt(AAPL), 0, "observed market: the breaker arms");
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.LiquidationNotAllowed.selector, AAPL));
        pool.liquidate(id);
    }
}

/// MED-2 and MED-3: the two authority findings.
contract GLendR4Authority is GLendR4Base {
    function setUp() public {
        _setUpFork();
        _intoSession();
    }

    /// E1, and the claim it rested on. The BRICK is still reachable — that is the liveness
    /// guardian's job — but "permanent and UNRECOVERABLE" is not true any more: the rotation admin
    /// removes both the dead keeper and the guardian that installed it, behind the same 2-day
    /// notice every risk parameter pays, and the guardian cannot veto its own removal.
    function test_theLivenessKillSwitchIsRecoverable() public {
        address deadKeeper = makeAddr("attackerControlledKeeper");
        vm.prank(guardian);
        liveness.setKeeper(deadKeeper);
        vm.warp(block.timestamp + GAP + 1);
        assertFalse(markets.canLiquidate(AAPL), "bricked");
        assertFalse(markets.canBorrow(AAPL), "on both sides");

        address newKeeper = makeAddr("recoveredKeeper");
        address newGuardian = makeAddr("recoveredGuardian");
        vm.prank(rotationAdmin);
        liveness.proposeRotation(newKeeper, newGuardian);

        vm.prank(rotationAdmin);
        vm.expectRevert(abi.encodeWithSelector(LivenessOracle.RotationNotElapsed.selector, liveness.ROTATION_TIMELOCK()));
        liveness.commitRotation();

        vm.warp(block.timestamp + liveness.ROTATION_TIMELOCK());
        liveness.commitRotation(); // permissionless once ripe
        assertEq(liveness.keeper(), newKeeper, "the dead keeper is gone");
        assertEq(liveness.guardian(), newGuardian, "and so is the guardian that installed it");

        vm.prank(guardian);
        vm.expectRevert(LivenessOracle.NotGuardian.selector);
        liveness.setKeeper(deadKeeper); // it cannot re-brick

        uint256 g;
        while (!liveness.liquidationsAllowed() && g++ < 300) {
            vm.warp(block.timestamp + GAP / 3);
            vm.prank(newKeeper);
            liveness.heartbeat();
        }
        assertTrue(liveness.liquidationsAllowed(), "liquidations come back");
    }

    /// The recovery key is not a second guardian: it acts only through the timelock, and it may not
    /// be either operational role — held with one, it recovers from nothing.
    function test_theRecoveryKeyHasNoImmediatePower() public {
        vm.prank(rotationAdmin);
        vm.expectRevert(LivenessOracle.NotGuardian.selector);
        liveness.setKeeper(makeAddr("x"));

        vm.prank(guardian);
        vm.expectRevert(LivenessOracle.NotRotationAdmin.selector);
        liveness.proposeRotation(makeAddr("k"), makeAddr("g"));

        vm.prank(rotationAdmin);
        vm.expectRevert(LivenessOracle.RolesMustDiffer.selector);
        liveness.proposeRotation(makeAddr("k"), rotationAdmin);

        vm.expectRevert(LivenessOracle.RolesMustDiffer.selector);
        new LivenessOracle(keeper, guardian, guardian, GAP, GRACE);
        vm.expectRevert(LivenessOracle.RolesMustDiffer.selector);
        new LivenessOracle(keeper, guardian, keeper, GAP, GRACE);
    }

    /// E2, inverted. `EsseyMarkets.admin` IS the deploy key, immutable and unrotatable, and it held
    /// both of the guardian's immediate levers while the contract's doc block attributed them to the
    /// guardian and DeployMarkets._roleKey refused every named role that WAS the deploy key.
    function test_theDeployKeyHoldsNeitherGuardianLever() public {
        assertEq(markets.admin(), admin, "admin is the deploy key in the script");
        assertTrue(markets.guardian() != markets.admin(), "and a different address from guardian");

        vm.prank(admin);
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        markets.pauseLiquidation(AAPL, block.timestamp + 1 hours);
        vm.prank(admin);
        vm.expectRevert(EsseyMarkets.NotAdmin.selector);
        markets.disableMarket(AAPL);

        vm.prank(guardian);
        markets.pauseLiquidation(AAPL, block.timestamp + 1 hours);
        assertFalse(markets.canLiquidate(AAPL), "the guardian still holds its emergency key");
    }
}

/// LOW-1, and CRIT-1's multi-state cases, which the fix must not have cost.
contract GLendR4Budget is GLendR4Base {
    function setUp() public {
        _setUpFork();
        _intoSession();
    }

    /// The observation read was capped at 50,000 gas while the VALUATION read of the same function
    /// was uncapped, so a token upgraded past the cap (Stock Tokens are beacon-upgradeable) would
    /// keep being borrowed and liquidated against while its observer recorded nothing at all — no
    /// breaker, no delay line, silently. One budget now covers both, so a token this registry cannot
    /// read stops being valued instead.
    function test_theValuationAndObservationReadsShareOneBudget() public {
        uint256 before = gasleft();
        (bool ok,) = AAPL.staticcall(abi.encodeWithSignature("uiMultiplier()"));
        uint256 used = before - gasleft();
        assertTrue(ok, "readable");
        console.log("AAPL uiMultiplier() gas:", used);

        // A source that burns more than the budget: valuation must REFUSE, not sail past it.
        vm.mockCallRevert(AAPL, abi.encodeWithSelector(IScaledUI.uiMultiplier.selector), "");
        vm.expectRevert(abi.encodeWithSelector(EsseyMarkets.BadMultiplierSource.selector, AAPL, AAPL));
        markets.collateralValue(AAPL, _coll());
        assertFalse(markets.canBorrow(AAPL), "and every gate declines through its own try/catch");
        assertFalse(markets.canLiquidate(AAPL));
    }

    /// D1. Four events on one market, alternating both exits from the armed state — the case three
    /// rounds of single-event tests could not reach, and where R3 CRIT-1 lived. It must stay closed
    /// under the delay line.
    function test_theArmedPairStaysWholeAcrossFourEvents() public {
        int256 p = realPrice;
        _hold(p, 2 hours);

        for (uint256 i = 0; i < 4; i++) {
            int256 gapped = i % 2 == 0 ? (p * 60) / 100 : (p * 160) / 100;
            _reprice(gapped);
            markets.syncMultiplier(AAPL);
            assertGt(markets.priceDesyncAt(AAPL), 0, "each event arms with its own stamp");
            assertGt(markets.desyncRefProduct(AAPL), 0, "and the pair is whole");

            if (i % 2 == 0) {
                _reprice(p); // exit by AGREEMENT: the legs come back together
                markets.syncMultiplier(AAPL);
            } else {
                _holdQuiet(gapped, markets.PRICE_DESYNC_HOLD() + 1); // exit by EXPIRY
                _reprice(gapped);
                markets.syncMultiplier(AAPL);
                p = gapped; // this IS the new level
            }
            assertEq(markets.priceDesyncAt(AAPL), 0, "released");
            assertEq(markets.desyncRefProduct(AAPL), 0, "and the reference with it, on every exit");
            _hold(p, 2 hours);
        }
    }

    /// D2. A guardian pause interleaved across an armed hold: two independent refusals, neither of
    /// which may swallow the other's state.
    function test_aGuardianPauseInterleavedWithAnArmedHold() public {
        _hold(realPrice, 2 hours);
        _reprice((realPrice * 60) / 100);
        markets.syncMultiplier(AAPL);
        uint256 armedAt = markets.priceDesyncAt(AAPL);
        assertGt(armedAt, 0, "armed");

        vm.prank(guardian);
        markets.pauseLiquidation(AAPL, block.timestamp + 12 hours);
        _holdQuiet((realPrice * 60) / 100, 12 hours);
        assertEq(markets.priceDesyncAt(AAPL), armedAt, "the pause did not touch the armed stamp");

        _reprice((realPrice * 60) / 100);
        markets.syncMultiplier(AAPL);
        assertEq(markets.priceDesyncAt(AAPL), 0, "and the hold released on its own clock");
        assertEq(markets.desyncRefProduct(AAPL), 0);
    }
}
