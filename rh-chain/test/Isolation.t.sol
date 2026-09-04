// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MockUSDG} from "./EsseyPool.t.sol";
import {MockFeed, MockStock} from "./RiskModules.t.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";

/// AD-1's central claim: pools sharing one EsseyMarkets + LivenessOracle are ISOLATED. Nothing
/// executed against pool A — including the issuer destroying or rescaling A's collateral — may
/// move pool B's share price, assets, borrows, or reserves by a single bit.
///
/// Pool B carries a real borrower and a year of accrued reserves, so a cross-pool coupling has
/// something to corrupt; pool A is zero-rate, so any writeOff residual on A exceeds A's own
/// reserves — exactly the case a coupled reserve-absorption would reach across for.
contract IsolationBase is Test {
    EsseyPool poolA;
    EsseyPool poolB;
    EsseyMarkets mk;
    LivenessOracle liv;
    MarketHealthOracle hox;
    MockFeed seq;
    MockFeed pxA;
    MockFeed pxB;
    MockStock tokA;
    MockStock tokB;
    MockUSDG usdg;

    address ADMIN;
    address KEEPER;
    address GUARDIAN;
    address RESOLVER;
    address LENDER;
    address ALICE;
    address BOB;

    uint256 constant MON_IN_SESSION = 1_753_110_000;
    uint256 constant GRACE = 30 minutes;
    uint256 constant GAP = 10 minutes;

    uint256 baseConvert;
    uint256 baseAssets;
    uint256 baseBorrows;
    uint256 baseReserves;

    function setUp() public virtual {
        ADMIN = makeAddr("admin"); KEEPER = makeAddr("keeper"); GUARDIAN = makeAddr("guardian");
        RESOLVER = makeAddr("resolver"); LENDER = makeAddr("lender");
        ALICE = makeAddr("alice"); BOB = makeAddr("bob");
        vm.warp(MON_IN_SESSION);

        seq = new MockFeed(0, 0); seq.setStartedAt(block.timestamp - 2 days);
        pxA = new MockFeed(200e8, 8);
        pxB = new MockFeed(200e8, 8);
        tokA = new MockStock();
        tokB = new MockStock();
        usdg = new MockUSDG();
        liv = new LivenessOracle(KEEPER, GUARDIAN, GAP, GRACE);
        hox = new MarketHealthOracle(KEEPER, GUARDIAN, ADMIN);
        mk = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, ADMIN, GUARDIAN, 6);
        vm.prank(ADMIN);
        hox.wireMarkets(address(mk));
        poolA = new EsseyPool(usdg, address(tokA), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey A Share", "aA", "Essey A Note", "nA"));
        poolB = new EsseyPool(usdg, address(tokB), mk, 1_000, 0, 0, 5_000, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey B Share", "aB", "Essey B Note", "nB"));

        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
        });
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tokA), AggregatorV3Interface(address(pxA)), 86_400, 90_000, 8, address(tokA), address(poolA), m);
        mk.proposeMarket(address(tokB), AggregatorV3Interface(address(pxB)), 86_400, 90_000, 8, address(tokB), address(poolB), m);
        mk.proposeResolver(RESOLVER);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        _stamp();
        mk.commitMarket(address(tokA));
        mk.commitMarket(address(tokB));
        mk.commitResolver();
        vm.stopPrank();
        _beat(); _advanceLive(GRACE);
        _seedOracle();

        usdg.mint(LENDER, 1_000_000e6);
        vm.startPrank(LENDER);
        usdg.approve(address(poolA), type(uint256).max);
        usdg.approve(address(poolB), type(uint256).max);
        poolA.deposit(500_000e6, LENDER);
        poolB.deposit(500_000e6, LENDER);
        vm.stopPrank();

        tokB.mint(BOB, 10e18);
        vm.startPrank(BOB);
        tokB.approve(address(poolB), type(uint256).max);
        usdg.approve(address(poolB), type(uint256).max);
        poolB.borrow(10e18, 700e6);
        vm.stopPrank();

        for (uint256 i = 0; i < 730; i++) { vm.warp(block.timestamp + 12 hours); _postD(); } // a year, on a live depth cadence
        _beat(); _advanceLive(GRACE);
        poolB.accrue();

        tokA.mint(ALICE, 10_000e18);
        usdg.mint(ALICE, 1_000_000e6);
        vm.startPrank(ALICE);
        tokA.approve(address(poolA), type(uint256).max);
        usdg.approve(address(poolA), type(uint256).max);
        vm.stopPrank();
        usdg.mint(RESOLVER, 1_000_000e6);
        vm.prank(RESOLVER);
        usdg.approve(address(poolA), type(uint256).max);

        assertGt(poolB.totalReserves(), 30e6, "fixture: B holds real reserves a coupling could drain");
        baseConvert = poolB.convertToAssets(1e6);
        baseAssets = poolB.totalAssets();
        baseBorrows = poolB.totalBorrows();
        baseReserves = poolB.totalReserves();
    }

    function _assertBUntouched() internal view {
        assertEq(poolB.convertToAssets(1e6), baseConvert, "B share price moved");
        assertEq(poolB.totalAssets(), baseAssets, "B totalAssets moved");
        assertEq(poolB.totalBorrows(), baseBorrows, "B totalBorrows moved");
        assertEq(poolB.totalReserves(), baseReserves, "B totalReserves moved");
    }

    function _stamp() internal {
        pxA.set(pxA.answer(), block.timestamp);
        pxB.set(pxB.answer(), block.timestamp);
    }

    function _beat() internal {
        vm.prank(KEEPER);
        liv.heartbeat();
    }

    function _advanceLive(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes); _stamp(); _beat(); _postD();
        }
        vm.warp(end); _stamp(); _beat(); _postD();
    }

    function _postD() internal {
        vm.startPrank(KEEPER);
        hox.postDepth(address(tokA), 4_000_000e6, uint64(block.number), "fork-swap-v1");
        hox.postDepth(address(tokB), 4_000_000e6, uint64(block.number), "fork-swap-v1");
        vm.stopPrank();
    }

    function _seedOracle() internal {
        _postD();
        for (uint256 i = 0; i < 42; i++) { vm.warp(block.timestamp + 12 hours); _postD(); } // ride the full ramp
        _beat(); _advanceLive(GRACE);
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }
}

/// Bounded-actor handler: every action targets pool A (or A's collateral token / shared
/// infrastructure). It never holds a reference to pool B — the invariant is that B cannot tell.
contract IsolationHandler is CommonBase, StdCheats, StdUtils {
    EsseyPool internal poolA;
    EsseyMarkets internal mk;
    LivenessOracle internal liv;
    MockStock internal tokA;
    MockFeed internal pxA;
    MockFeed internal pxB;
    MockUSDG internal usdg;
    address internal keeper;
    address internal resolver;

    address[] internal actors;
    uint256[] internal openIds;

    constructor(
        EsseyPool poolA_,
        EsseyMarkets mk_,
        LivenessOracle liv_,
        MockStock tokA_,
        MockFeed pxA_,
        MockFeed pxB_,
        MockUSDG usdg_,
        address keeper_,
        address resolver_
    ) {
        poolA = poolA_; mk = mk_; liv = liv_; tokA = tokA_; pxA = pxA_; pxB = pxB_;
        usdg = usdg_; keeper = keeper_; resolver = resolver_;
        for (uint256 i; i < 4; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            vm.startPrank(a);
            usdg.approve(address(poolA), type(uint256).max);
            tokA.approve(address(poolA), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(resolver);
        usdg.approve(address(poolA), type(uint256).max);
    }

    function deposit(uint256 a, uint256 amt) external {
        address actor = _actor(a);
        amt = bound(amt, 1, 100_000e6);
        usdg.mint(actor, amt);
        vm.prank(actor);
        try poolA.deposit(amt, actor) {} catch {}
    }

    function withdrawShares(uint256 a, uint256 sh) external {
        address actor = _actor(a);
        uint256 bal = poolA.balanceOf(actor);
        if (bal == 0) return;
        sh = bound(sh, 1, bal);
        vm.prank(actor);
        try poolA.redeem(sh, actor, actor) {} catch {}
    }

    function borrow(uint256 a, uint256 coll, uint256 frac) external {
        address actor = _actor(a);
        coll = bound(coll, 1e18, 100e18);
        tokA.mint(actor, coll);
        uint256 maxB;
        try mk.maxBorrow(address(tokA), coll) returns (uint256 m) { maxB = m; } catch { return; }
        if (maxB == 0) return;
        uint256 debt = bound(frac, 1, maxB);
        vm.prank(actor);
        try poolA.borrow(coll, debt) returns (uint256 id) { openIds.push(id); } catch {}
    }

    function repayFull(uint256 seed) external {
        (uint256 id, uint256 i) = _pick(seed);
        if (id == 0) return;
        address holder;
        try poolA.note().ownerOf(id) returns (address o) { holder = o; } catch { return; }
        uint256 owed = poolA.debtOf(id);
        if (owed == 0) return;
        usdg.mint(holder, owed);
        vm.prank(holder);
        try poolA.repay(id, owed) { _drop(i); } catch {}
    }

    function repayPartial(uint256 seed, uint256 x) external {
        (uint256 id,) = _pick(seed);
        if (id == 0) return;
        uint256 owed = poolA.debtOf(id);
        if (owed < 2) return;
        x = bound(x, 1, owed - 1);
        address payer = _actor(seed);
        usdg.mint(payer, x);
        vm.prank(payer);
        try poolA.repayPartial(id, x) {} catch {}
    }

    function addCollateral(uint256 seed, uint256 amt) external {
        (uint256 id,) = _pick(seed);
        if (id == 0) return;
        amt = bound(amt, 1, 50e18);
        address payer = _actor(seed);
        tokA.mint(payer, amt);
        vm.prank(payer);
        try poolA.addCollateral(id, amt) {} catch {}
    }

    function movePrice(uint256 p) external {
        p = bound(p, 20e8, 400e8);
        pxA.set(int256(p), block.timestamp);
    }

    function liquidate(uint256 seed) external {
        (uint256 id, uint256 i) = _pick(seed);
        if (id == 0) return;
        int256 p = (pxA.answer() * 6) / 10;
        if (p < 1e8) p = 1e8;
        pxA.set(p, block.timestamp);
        uint256 owed = poolA.debtOf(id);
        if (owed == 0) return;
        address liq = actors[0];
        usdg.mint(liq, owed);
        vm.prank(liq);
        try poolA.liquidate(id) { _drop(i); } catch {}
    }

    function writeOff(uint256 seed, uint256 rec, bool wipe) external {
        (uint256 id, uint256 i) = _pick(seed);
        if (id == 0) return;
        if (wipe) {
            uint256 b = tokA.balanceOf(address(poolA));
            if (b != 0) tokA.adminBurn(address(poolA), b);
        } else {
            pxA.set(30e8, block.timestamp);
        }
        uint256 owed = poolA.debtOf(id);
        rec = bound(rec, 0, owed);
        usdg.mint(resolver, rec);
        vm.prank(resolver);
        try poolA.writeOff(id, rec) { _drop(i); } catch {}
    }

    function adminBurn(uint256 amt) external {
        uint256 b = tokA.balanceOf(address(poolA));
        if (b == 0) return;
        amt = bound(amt, 1, b);
        tokA.adminBurn(address(poolA), amt);
    }

    function corporateAction(uint256 m) external {
        m = bound(m, 0.5e18, 2e18);
        tokA.setMultiplier(m);
    }

    /// Small warps only (< gapThreshold), heartbeat kept fresh: time moves without manufacturing a
    /// liveness outage, so gated actions stay reachable deep into a run.
    function warpBeat(uint256 secs) external {
        secs = bound(secs, 60, 8 minutes);
        vm.warp(block.timestamp + secs);
        vm.prank(keeper);
        liv.heartbeat();
        pxA.set(pxA.answer(), block.timestamp);
        pxB.set(pxB.answer(), block.timestamp);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pick(uint256 seed) internal view returns (uint256 id, uint256 i) {
        uint256 n = openIds.length;
        if (n == 0) return (0, 0);
        i = seed % n;
        id = openIds[i];
    }

    function _drop(uint256 i) internal {
        openIds[i] = openIds[openIds.length - 1];
        openIds.pop();
    }
}

contract IsolationInvariantTest is IsolationBase {
    IsolationHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new IsolationHandler(poolA, mk, liv, tokA, pxA, pxB, usdg, KEEPER, RESOLVER);
        bytes4[] memory sels = new bytes4[](12);
        sels[0] = IsolationHandler.deposit.selector;
        sels[1] = IsolationHandler.withdrawShares.selector;
        sels[2] = IsolationHandler.borrow.selector;
        sels[3] = IsolationHandler.repayFull.selector;
        sels[4] = IsolationHandler.repayPartial.selector;
        sels[5] = IsolationHandler.addCollateral.selector;
        sels[6] = IsolationHandler.movePrice.selector;
        sels[7] = IsolationHandler.liquidate.selector;
        sels[8] = IsolationHandler.writeOff.selector;
        sels[9] = IsolationHandler.adminBurn.selector;
        sels[10] = IsolationHandler.corporateAction.selector;
        sels[11] = IsolationHandler.warpBeat.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_poolBBitIdenticalUnderAnyPoolASequence() public view {
        _assertBUntouched();
    }
}

contract IsolationTest is IsolationBase {
    /// AD-2 x AD-1: per-token readings, per-market pools. A's depth collapsing to zero turns off
    /// A's new borrows and changes nothing about B.
    function test_depthCollapseOnAIsInvisibleToB() public {
        vm.prank(KEEPER);
        hox.postDepth(address(tokA), 0, uint64(block.number), "fork-swap-v1");
        assertFalse(mk.canBorrow(address(tokA)), "A closed same block");
        assertEq(mk.borrowCap(address(tokA)), 0);
        assertTrue(mk.canBorrow(address(tokB)), "B untouched");
        assertEq(mk.borrowCap(address(tokB)), 1_000_000e6);
        _assertBUntouched();
    }

    /// The binding: pool A's collateral token is immutable. A caller holding only B's token gets
    /// nothing — A pulls ITS token regardless of what the caller approved.
    function test_bindingRejectsSiblingCollateral() public {
        address MALLORY = makeAddr("mallory");
        tokB.mint(MALLORY, 10e18);
        vm.startPrank(MALLORY);
        tokB.approve(address(poolA), type(uint256).max);
        vm.expectRevert();
        poolA.borrow(10e18, 100e6);
        vm.stopPrank();
        assertEq(poolA.nextPositionId(), 1, "no position may open against the sibling's token");
        _assertBUntouched();
    }

    function test_writeOffOnStaleWipedALeavesBUntouched() public {
        vm.prank(ALICE);
        uint256 id = poolA.borrow(10e18, 700e6);
        tokA.adminBurn(address(poolA), tokA.balanceOf(address(poolA)));
        vm.warp(block.timestamp + 200_000); // feed silent, liveness dead
        assertFalse(mk.canLiquidate(address(tokA)), "fixture: every gate on A is closed");
        vm.prank(RESOLVER);
        poolA.writeOff(id, 0);
        assertEq(poolA.totalBorrows(), 0, "A recognised the loss");
        _assertBUntouched();
    }

    function test_wipeThenWriteOffLandsLossOnAAlone() public {
        vm.prank(ALICE);
        uint256 a1 = poolA.borrow(10e18, 700e6);
        address DAN = makeAddr("dan");
        tokA.mint(DAN, 10e18);
        vm.startPrank(DAN);
        tokA.approve(address(poolA), type(uint256).max);
        uint256 a2 = poolA.borrow(10e18, 500e6);
        vm.stopPrank();

        tokA.adminBurn(address(poolA), tokA.balanceOf(address(poolA)));
        uint256 assetsBefore = poolA.totalAssets();
        vm.startPrank(RESOLVER);
        poolA.writeOff(a1, 100e6);
        poolA.writeOff(a2, 0);
        vm.stopPrank();

        assertEq(poolA.totalAssets(), assetsBefore - 600e6 - 500e6, "the markdown lands on A's lenders alone");
        _assertBUntouched();
    }

    function test_fullUtilizationOnADoesNotPinB() public {
        vm.prank(ALICE);
        poolA.borrow(7_200e18, 500_000e6); // debt == cash: drains A to zero and pins the liquidity boundary
        assertEq(usdg.balanceOf(address(poolA)), 0);
        assertEq(poolA.utilizationBps(), 10_000);
        vm.prank(LENDER);
        // LOW-1: the cash constraint is advertised in maxWithdraw now, so the 4626 max gate refuses
        // before _withdraw's InsufficientLiquidity backstop is ever reached.
        assertEq(poolA.maxWithdraw(LENDER), 0, "a fully-drawn pool must advertise nothing withdrawable");
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, LENDER, 1e6, 0));
        poolA.withdraw(1e6, LENDER, LENDER);
        _assertBUntouched();

        uint256 before_ = usdg.balanceOf(LENDER);
        vm.prank(LENDER);
        poolB.withdraw(100_000e6, LENDER, LENDER);
        assertEq(usdg.balanceOf(LENDER) - before_, 100_000e6, "B withdraws freely while A is pinned dry");
    }

    function test_sharedRegistryOpsDoNotMoveB() public {
        vm.startPrank(ADMIN);
        mk.proposeResolver(makeAddr("resolver2"));
        mk.disableMarket(address(tokA));
        vm.stopPrank();
        assertFalse(mk.canBorrow(address(tokA)));
        assertTrue(mk.canBorrow(address(tokB)), "B's market must not be caught in A's shutdown");
        assertTrue(mk.canLiquidate(address(tokB)));
        _assertBUntouched();
    }
}
