// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Don} from "../src/market/Don.sol";
import {DonReserve} from "../src/market/DonReserve.sol";
import {DonLoan} from "../src/market/DonLoan.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed} from "./RiskModules.t.sol";

/// Fixed-term, fixed-draw borrow-against-your-Don, proven end to end on the REAL Don + DonReserve:
/// every loan draws ltvBps of the live floor, interest is prepaid at origination on the FLOOR VALUE
/// (discount note), debt is flat through the term, penalty accrual runs past expiry, and liquidation
/// opens by ratio OR calendar — funded by the Don's own redeemable backing. The ETH origination fee
/// is USD-priced by the ETH/USD feed (fee ONLY — the loan book never touches an oracle) with a
/// flat-wei fallback.
contract DonLoanTest is Test {
    ERC20Mock essey;
    Don don;
    DonReserve reserve;
    DonLoan loan;
    MockFeed ethFeed; // $2500, 8 dec

    address treasury = address(0x7EA);
    address feeSink = address(0x51CC); // the fee->stock router stand-in
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xC0FFEE);

    uint256 constant CAP = 8;
    uint256 constant FLOOR = 300_000e18; // per Don after seeding
    uint256 constant LTV = 5000; // 50% — the fixed draw
    uint256 constant LIQ = 7000; // 70% of the live floor
    uint256 constant RATE = 1500; // 15% APR on the floor value, prepaid over the term
    uint256 constant PENALTY = 3000; // 30% APR late phase (2x base), on principal
    uint256 constant GRACE = 30 days; // past expiry + this, calendar liquidation opens
    uint256 constant TIP = 100; // 1% of liquidation proceeds
    uint256 constant STOCK_SHARE = 7000; // interest: 70% -> feeSink, 30% -> floor
    uint256 constant YEAR = 365 days;

    function setUp() public {
        essey = new ERC20Mock();
        don = new Don("Essey Don", "DON", CAP, address(this)); // test = minter
        reserve = new DonReserve(IERC20(address(essey)), IERC721(address(don)));
        ethFeed = new MockFeed(2500e8, 8);
        loan = new DonLoan(_config(don, reserve, LTV, LIQ, RATE, PENALTY, GRACE, TIP, address(ethFeed)));
        don.setLienManager(address(loan));

        // Seed the floor (300k/Don over the full cap) and the lending pot.
        essey.mint(address(this), CAP * FLOOR);
        essey.approve(address(reserve), type(uint256).max);
        reserve.fund(CAP * FLOOR);
        essey.mint(address(this), 2_000_000e18);
        essey.approve(address(loan), type(uint256).max);
        loan.fund(2_000_000e18);
    }

    function _donFor(address who) internal returns (uint256 id) {
        id = don.mint(who, keccak256(abi.encode(don.totalMinted() + 1)));
    }

    function _openLoan(address who, uint256 term) internal returns (uint256 id) {
        id = _donFor(who);
        vm.prank(who);
        loan.borrow(id, term);
    }

    /// The contract's exact value-basis prepaid expression, on a given floor read.
    function _prepaid(uint256 floor_, uint256 term) internal pure returns (uint256) {
        return (floor_ * RATE * term) / (10_000 * YEAR);
    }

    /// The contract's exact late-phase accrual expression over `dt` seconds past expiry.
    function _late(uint256 principal, uint256 dt) internal pure returns (uint256) {
        return (principal * PENALTY * dt) / (10_000 * YEAR);
    }

    function _config(
        Don don_,
        DonReserve reserve_,
        uint256 ltv,
        uint256 liq,
        uint256 rate,
        uint256 penalty,
        uint256 grace,
        uint256 tip,
        address feed
    ) internal view returns (DonLoan.Config memory) {
        return DonLoan.Config({
            essey: IERC20(address(essey)),
            don: don_,
            reserve: reserve_,
            feeSink: feeSink,
            treasury: treasury,
            ltvBps: ltv,
            liqThresholdBps: liq,
            rateBps: rate,
            penaltyRateBps: penalty,
            defaultGraceSeconds: grace,
            liqTipBps: tip,
            stockShareBps: STOCK_SHARE,
            ethUsdFeed: AggregatorV3Interface(feed),
            guardian: address(this)
        });
    }

    function _newLoan(
        uint256 ltv,
        uint256 liq,
        uint256 rate,
        uint256 penalty,
        uint256 grace,
        uint256 tip,
        address feed
    ) internal returns (DonLoan) {
        return new DonLoan(_config(don, reserve, ltv, liq, rate, penalty, grace, tip, feed));
    }

    // ---------------------------------------------------------------- construction

    function test_ConstructorGuards() public {
        vm.expectRevert(DonLoan.BadConfig.selector); // gap below 20pp
        _newLoan(5000, 6900, RATE, PENALTY, GRACE, TIP, address(0));
        vm.expectRevert(DonLoan.BadConfig.selector); // threshold above 90%
        _newLoan(5000, 9100, RATE, PENALTY, GRACE, TIP, address(0));
        vm.expectRevert(DonLoan.BadConfig.selector); // tip above cap
        _newLoan(LTV, LIQ, RATE, PENALTY, GRACE, 501, address(0));
        vm.expectRevert(DonLoan.BadConfig.selector); // zero rate
        _newLoan(LTV, LIQ, 0, PENALTY, GRACE, TIP, address(0));
        vm.expectRevert(DonLoan.BadConfig.selector); // penalty must EXCEED the base rate
        _newLoan(LTV, LIQ, RATE, RATE, GRACE, TIP, address(0));
        vm.expectRevert(DonLoan.BadConfig.selector); // penalty above 100% APR
        _newLoan(LTV, LIQ, RATE, 10_001, GRACE, TIP, address(0));
        vm.expectRevert(DonLoan.BadConfig.selector); // grace below a week
        _newLoan(LTV, LIQ, RATE, PENALTY, 7 days - 1, TIP, address(0));
        vm.expectRevert(DonLoan.BadConfig.selector); // grace above a quarter
        _newLoan(LTV, LIQ, RATE, PENALTY, 90 days + 1, TIP, address(0));

        // reserve/don pairing must match - a foreign reserve can't price this collection
        Don other = new Don("Other", "OTH", CAP, address(this));
        DonReserve otherReserve = new DonReserve(IERC20(address(essey)), IERC721(address(other)));
        vm.expectRevert(DonLoan.BadConfig.selector);
        new DonLoan(_config(don, otherReserve, LTV, LIQ, RATE, PENALTY, GRACE, TIP, address(0)));
    }

    /// The value-basis invariant: a worst-case (MAX_TERM) prepaid at rateBps of the floor must stay
    /// strictly below the ltvBps draw of the same floor - no config may produce a negative disbursement.
    function test_ConstructorRejectsFeeSwallowingDraw() public {
        vm.expectRevert(DonLoan.BadConfig.selector); // rate == ltv: a year's fee equals the whole draw
        _newLoan(5000, 7000, 5000, 10_000, GRACE, TIP, address(0));
        vm.expectRevert(DonLoan.BadConfig.selector); // rate > ltv: fee exceeds the draw
        _newLoan(5000, 7000, 6000, 10_000, GRACE, TIP, address(0));
        _newLoan(5000, 7000, 4999, 9999, GRACE, TIP, address(0)); // one notch under: valid
    }

    // ---------------------------------------------------------------- borrow (fixed draw, discount note)

    function test_BorrowFixedDrawDiscountNote() public {
        uint256 id = _donFor(alice);
        uint256 floor0 = reserve.floorPerDon();
        uint256 principal = (floor0 * LTV) / 10_000;
        assertEq(principal, (FLOOR * LTV) / 10_000, "the fixed draw: 50% of the live floor");
        assertEq(loan.maxBorrow(), principal);
        uint256 potBefore = loan.lendable();
        uint256 reserveBefore = essey.balanceOf(address(reserve));

        // Value basis: a full-year term prepays rateBps of the FLOOR, not of the principal.
        uint256 prepaid = _prepaid(floor0, 365 days);
        assertEq(prepaid, (floor0 * RATE) / 10_000, "15% of the floor value - 2x the principal basis");
        assertEq(loan.prepaidInterest(365 days), prepaid, "quoted = charged");

        vm.prank(alice);
        loan.borrow(id, 365 days);

        assertEq(essey.balanceOf(alice), principal - prepaid, "NET disbursement: the draw minus prepaid interest");
        assertEq(loan.debtOf(id), principal, "but the FULL draw is owed back");
        assertEq(loan.totalPrincipal(), principal);
        assertEq(potBefore - loan.lendable(), principal, "the pot funded disbursement + prepaid routing");

        // The prepaid interest was routed 70/30 IN the borrow tx - revenue banked instantly.
        uint256 toStock = (prepaid * STOCK_SHARE) / 10_000;
        assertEq(essey.balanceOf(feeSink), toStock, "70% of prepaid -> the stock pot, at borrow");
        assertEq(essey.balanceOf(address(reserve)) - reserveBefore, prepaid - toStock, "30% -> the floor, at borrow");

        assertEq(don.ownerOf(id), alice, "the Don never leaves the borrower's wallet");
        assertTrue(don.liened(id), "but it is transfer-locked");
        vm.prank(alice); // every exit is blocked while in debt
        vm.expectRevert(Don.LienActive.selector);
        don.transferFrom(alice, bob, id);
    }

    /// A later borrower draws against the RISEN floor: earlier prepaid routing lifted it, so the line
    /// tracks the collection's value upward.
    function test_DrawTracksTheLiveFloor() public {
        _openLoan(alice, 365 days);
        uint256 id2 = _donFor(bob);
        uint256 floorNow = reserve.floorPerDon();
        assertGt(floorNow, FLOOR, "alice's prepaid routing raised the floor");
        vm.prank(bob);
        loan.borrow(id2, 365 days);
        (, uint256 principal2,,,,) = loan.loans(id2);
        assertEq(principal2, (floorNow * LTV) / 10_000, "bob's draw priced on the risen floor");
    }

    function test_TermBounds() public {
        uint256 id = _donFor(alice);

        vm.prank(alice);
        vm.expectRevert(DonLoan.BadTerm.selector);
        loan.borrow(id, 7 days - 1); // below the week minimum

        vm.prank(alice);
        vm.expectRevert(DonLoan.BadTerm.selector);
        loan.borrow(id, 365 days + 1); // above the year maximum

        vm.prank(alice);
        loan.borrow(id, 7 days); // both boundaries are inclusive

        uint256 id2 = _donFor(bob);
        vm.prank(bob);
        loan.borrow(id2, 365 days);
    }

    function test_BorrowGates() public {
        uint256 id = _donFor(alice);

        vm.prank(bob);
        vm.expectRevert(DonLoan.NotDonOwner.selector);
        loan.borrow(id, 30 days);

        vm.prank(alice);
        loan.borrow(id, 30 days);
        vm.prank(alice);
        vm.expectRevert(DonLoan.LoanExists.selector);
        loan.borrow(id, 30 days); // one open loan per Don, no top-ups

        // An unfunded floor lends nothing - the draw would be zero, so borrowing fails closed.
        Don bare = new Don("Bare", "BARE", CAP, address(this));
        DonReserve bareReserve = new DonReserve(IERC20(address(essey)), IERC721(address(bare)));
        DonLoan bareLoan = new DonLoan(_config(bare, bareReserve, LTV, LIQ, RATE, PENALTY, GRACE, TIP, address(0)));
        uint256 bareId = bare.mint(alice, keccak256("bare"));
        vm.prank(alice);
        vm.expectRevert(DonLoan.ZeroAmount.selector);
        bareLoan.borrow(bareId, 30 days);
    }

    /// The facility can only lend what it holds - a drained pot fails closed.
    function test_BorrowFailsClosedWhenPotEmpty() public {
        uint256 idle = loan.lendable();
        vm.prank(treasury);
        loan.withdrawIdle(idle); // treasury reclaims all idle capital
        uint256 id = _donFor(alice);
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance
        loan.borrow(id, 30 days);
    }

    // ---------------------------------------------------------------- debt through the term

    function test_DebtFlatDuringTerm() public {
        uint256 id = _openLoan(alice, 365 days);
        uint256 principal = (FLOOR * LTV) / 10_000; // 150k

        vm.warp(block.timestamp + 180 days);
        assertEq(loan.debtOf(id), principal, "mid-term: no accrual, the interest was prepaid");

        vm.warp(block.timestamp + 185 days); // exactly at expiry
        assertEq(loan.debtOf(id), principal, "at expiry: still exactly the principal");
    }

    function test_LatePhaseAccruesAtPenaltyRate() public {
        uint256 start = block.timestamp;
        uint256 id = _openLoan(alice, 30 days);
        uint256 principal = (FLOOR * LTV) / 10_000;

        vm.warp(start + 30 days + 100 days); // 100 days past expiry
        assertEq(loan.debtOf(id), principal + _late(principal, 100 days), "30% APR on principal, from expiry");

        vm.warp(start + 30 days + 200 days);
        assertEq(loan.debtOf(id), principal + _late(principal, 200 days), "simple, non-compounding");
    }

    // ---------------------------------------------------------------- repay

    function test_EarlyRepayOwesExactlyPrincipalNoRefund() public {
        uint256 id = _openLoan(alice, 365 days);
        uint256 principal = (FLOOR * LTV) / 10_000;
        uint256 sinkAfterBorrow = essey.balanceOf(feeSink);

        vm.warp(block.timestamp + 10 days); // repaying 355 days early
        essey.mint(alice, principal);
        vm.startPrank(alice);
        essey.approve(address(loan), type(uint256).max);
        uint256 paid = loan.repay(id, type(uint256).max); // overpay bid: only the debt is pulled
        vm.stopPrank();

        assertEq(paid, principal, "1:1 - the full draw, nothing more");
        assertEq(loan.debtOf(id), 0);
        assertFalse(don.liened(id), "the Don walks free");
        assertEq(loan.totalPrincipal(), 0);
        assertEq(essey.balanceOf(feeSink), sinkAfterBorrow, "prepaid interest NEVER refunds - none moved on repay");

        vm.prank(alice); // and is transferable again
        don.transferFrom(alice, bob, id);
        assertEq(don.ownerOf(id), bob);
    }

    function test_LateRepaySettlesLateInterestFirst() public {
        uint256 start = block.timestamp;
        uint256 id = _openLoan(alice, 30 days);
        uint256 principal = (FLOOR * LTV) / 10_000;
        uint256 sinkAfterBorrow = essey.balanceOf(feeSink);
        uint256 reserveAfterBorrow = essey.balanceOf(address(reserve));

        vm.warp(start + 30 days + 100 days);
        uint256 late = _late(principal, 100 days);

        essey.mint(alice, late + principal);
        vm.startPrank(alice);
        essey.approve(address(loan), type(uint256).max);
        loan.repay(id, late); // covers exactly the late interest
        vm.stopPrank();

        assertEq(loan.debtOf(id), principal, "late interest settled first");
        assertTrue(don.liened(id), "still in debt -> still liened");
        uint256 toStock = (late * STOCK_SHARE) / 10_000;
        assertEq(essey.balanceOf(feeSink) - sinkAfterBorrow, toStock, "70% of late interest -> the stock pot");
        assertEq(essey.balanceOf(address(reserve)) - reserveAfterBorrow, late - toStock, "30% -> the floor");

        vm.prank(alice);
        loan.repay(id, type(uint256).max); // the principal closes it
        assertEq(loan.debtOf(id), 0);
        assertFalse(don.liened(id));
        assertEq(loan.totalPrincipal(), 0);
    }

    function test_AnyoneMayRepay() public {
        uint256 id = _openLoan(alice, 30 days);
        uint256 debt = loan.debtOf(id);
        essey.mint(bob, debt);
        vm.startPrank(bob);
        essey.approve(address(loan), type(uint256).max);
        loan.repay(id, debt); // a gift
        vm.stopPrank();
        assertFalse(don.liened(id));
        assertEq(don.ownerOf(id), alice, "alice keeps her Don");
    }

    // ---------------------------------------------------------------- liquidation

    function test_HealthyLoanInTermCannotBeLiquidated() public {
        uint256 id = _openLoan(alice, 365 days);
        vm.warp(block.timestamp + 180 days); // mid-term: debt flat at 50% of floor, threshold 70%
        vm.expectRevert(
            abi.encodeWithSelector(
                DonLoan.NotLiquidatable.selector, loan.debtOf(id), loan.liquidationThreshold()
            )
        );
        loan.liquidate(id);
    }

    /// The calendar trigger: a loan past expiry + grace is liquidatable even though its ratio is
    /// perfectly healthy — and not one second sooner.
    function test_CalendarLiquidationPastGrace() public {
        uint256 start = block.timestamp;
        uint256 id = _openLoan(alice, 30 days);
        uint256 principal = (FLOOR * LTV) / 10_000;

        vm.warp(start + 30 days + GRACE); // the last grace second: still safe
        assertLt(loan.debtOf(id), loan.liquidationThreshold(), "ratio healthy throughout");
        vm.expectRevert(
            abi.encodeWithSelector(
                DonLoan.NotLiquidatable.selector, loan.debtOf(id), loan.liquidationThreshold()
            )
        );
        loan.liquidate(id);

        vm.warp(start + 30 days + GRACE + 1); // one second past grace: the calendar opens it
        uint256 debt = loan.debtOf(id);
        assertLt(debt, loan.liquidationThreshold(), "STILL ratio-healthy - this is purely calendar");
        uint256 late = debt - principal;

        uint256 proceeds = reserve.floorPerDon(); // redeemed at the live floor
        uint256 aliceBefore = essey.balanceOf(alice);
        uint256 potBefore = loan.lendable();
        uint256 sinkBefore = essey.balanceOf(feeSink);

        vm.prank(keeper);
        loan.liquidate(id);

        // Waterfall: tip -> late interest (70/30) -> principal -> surplus back to the borrower.
        uint256 tip = (proceeds * TIP) / 10_000;
        uint256 surplus = proceeds - tip - late - principal;
        assertEq(essey.balanceOf(keeper), tip, "caller tip - no liquidator capital needed");
        assertEq(essey.balanceOf(feeSink) - sinkBefore, (late * STOCK_SHARE) / 10_000, "70% of late -> stock pot");
        assertEq(loan.lendable() - potBefore, principal, "principal restored to the pot");
        assertEq(essey.balanceOf(alice) - aliceBefore, surplus, "surplus returns to the borrower - deliberate");
        assertEq(don.ownerOf(id), address(reserve), "the Don was consumed by its own backing");
        assertEq(loan.debtOf(id), 0, "loan closed");
        assertEq(loan.totalPrincipal(), 0);
    }

    /// The ratio trigger stays live: deep late accrual pushes debt over the threshold. (By then the
    /// calendar has long passed too — under the term/grace bounds the calendar always opens first —
    /// but the ratio math itself is exercised here.) The waterfall saturates: the facility eats the
    /// loss, the borrower gets no surplus, nobody is chased.
    function test_RatioLiquidationDeepLateSaturates() public {
        uint256 start = block.timestamp;
        uint256 id = _openLoan(alice, 30 days);
        uint256 principal = (FLOOR * LTV) / 10_000;

        vm.warp(start + 3650 days); // ~3x principal in late interest
        uint256 debt = loan.debtOf(id);
        assertGt(debt, loan.liquidationThreshold(), "ratio trigger armed by late accrual");
        uint256 late = debt - principal;

        uint256 proceeds = reserve.floorPerDon();
        uint256 tip = (proceeds * TIP) / 10_000;
        assertGt(late, proceeds - tip, "late interest alone exceeds the proceeds - full saturation");

        uint256 aliceBefore = essey.balanceOf(alice);
        uint256 potBefore = loan.lendable();
        uint256 sinkBefore = essey.balanceOf(feeSink);
        vm.prank(keeper);
        loan.liquidate(id);

        uint256 available = proceeds - tip; // all of it goes to late interest
        assertEq(essey.balanceOf(keeper), tip);
        assertEq(essey.balanceOf(alice), aliceBefore, "no surplus for the borrower");
        assertEq(essey.balanceOf(feeSink) - sinkBefore, (available * STOCK_SHARE) / 10_000, "recovered late still split 70/30");
        assertEq(loan.lendable(), potBefore, "zero principal recovery - the loss lands on the facility");
        assertEq(loan.debtOf(id), 0, "written off - nobody is chased for the shortfall");
    }

    /// A staked, earning Don can be liquidated: the seizure transfer clears its Bell tier on the way out.
    function test_LiquidateStakedDonClearsTier() public {
        uint256[] memory tierFees = new uint256[](1);
        tierFees[0] = 100e18;
        uint256[] memory tierWeights = new uint256[](1);
        tierWeights[0] = 100;
        Bell bell = new Bell(
            ISeatLike(address(don)), essey, new ERC20Mock(), treasury, 1e18, 0, tierFees, tierWeights,
            IConverter(address(0)), address(0)
        );
        don.setHook(address(bell));

        uint256 id = _openLoan(alice, 30 days);
        essey.mint(alice, 100e18);
        vm.startPrank(alice);
        essey.approve(address(bell), type(uint256).max);
        bell.activate(id, 1); // liened AND staked: still earning while collateralized
        vm.stopPrank();
        assertEq(bell.totalWeight(), 100);
        assertTrue(don.liened(id));

        vm.warp(block.timestamp + 3650 days);
        loan.liquidate(id);
        (uint8 tier,,,) = bell.seats(id);
        assertEq(tier, 0, "tier cleared by the seizure transfer");
        assertEq(bell.totalWeight(), 0);
        assertEq(don.ownerOf(id), address(reserve));
    }

    function test_LiquidateGates() public {
        vm.expectRevert(DonLoan.NoLoan.selector);
        loan.liquidate(42);
    }

    // ---------------------------------------------------------------- proof tuple

    function test_LoanTupleWholeUnits() public {
        uint256 id = _openLoan(alice, 30 days);
        (address facility, address borrower, uint64 debtWhole, uint64 floorWhole, uint16 ltv, uint64 n) =
            loan.loanTuple(id);
        assertEq(facility, address(loan));
        assertEq(borrower, alice);
        assertEq(debtWhole, 150_000, "whole-ESSEY units fit the circuit's 64-bit bound");
        assertEq(floorWhole, uint64(reserve.floorPerDon() / 1e18), "floor rounds DOWN (prepaid routing lifted it)");
        assertEq(ltv, uint16(LTV));
        assertEq(n, 1, "monotone nonce");
        assertLe(uint256(debtWhole) * 10_000, uint256(floorWhole) * ltv, "the exact relation the circuit proves");

        uint256 id2 = _openLoan(bob, 30 days);
        (,,,,, uint64 n2) = loan.loanTuple(id2);
        assertEq(n2, 2);

        vm.expectRevert(DonLoan.NoLoan.selector);
        loan.loanTuple(999);
    }

    /// The tuple must never understate risk: fractional debt rounds UP to whole tokens, so a loan that
    /// is unsafe by less than one ESSEY still reports as unsafe (the floor stays rounded down).
    function test_LoanTupleCeilsDebtConservatively() public {
        uint256 start = block.timestamp;
        uint256 id = _openLoan(alice, 30 days);
        vm.warp(start + 30 days + 10 minutes); // a fractional token of LATE interest (~0.86 ESSEY)
        uint256 debt = loan.debtOf(id);
        assertGt(debt, 150_000e18);
        assertLt(debt, 150_001e18);
        (,, uint64 debtWhole,,,) = loan.loanTuple(id);
        assertEq(debtWhole, 150_001, "fractional debt rounds UP - conservative for the prover");
    }

    // ---------------------------------------------------------------- origination fee

    /// The flat-wei leg: the fallback price (and the only price without a feed). Exact fee forwards
    /// to the feeSink's ETH->stock pipe; treasury-tunable under a hard cap; 0 = free (the default).
    function test_OriginationFeeFlat() public {
        uint256 id = _donFor(alice);
        assertEq(loan.originationFee(), 0, "free by default (no USD price, no flat fee)");

        vm.prank(treasury);
        loan.setOriginationFee(0.0053 ether);
        assertEq(loan.originationFee(), 0.0053 ether, "flat governs while USD mode is off");

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(DonLoan.WrongFee.selector);
        loan.borrow(id, 30 days); // fee now required

        uint256 sinkEthBefore = feeSink.balance;
        uint256 draw = loan.maxBorrow();
        vm.prank(alice);
        loan.borrow{value: 0.0053 ether}(id, 30 days);
        assertEq(feeSink.balance - sinkEthBefore, 0.0053 ether, "100% of the ETH fee -> the stock pipe");
        assertEq(loan.debtOf(id), draw, "fee is not debt - principal unchanged");

        vm.prank(alice);
        vm.expectRevert(DonLoan.NotTreasury.selector);
        loan.setOriginationFee(0);
        vm.prank(treasury);
        vm.expectRevert(DonLoan.FeeTooHigh.selector);
        loan.setOriginationFee(0.051 ether); // capped - a hostile setter can't price-brick borrows

        vm.prank(treasury);
        loan.setOriginationFee(0);
        uint256 id2 = _donFor(bob);
        vm.prank(bob);
        loan.borrow(id2, 30 days); // free again, no value needed
    }

    /// USD mode: $10.00 at a $2500 feed = 0.004 ETH; excess msg.value refunds to the wei.
    function test_OriginationFeeUsdPricedWithRefund() public {
        vm.prank(treasury);
        loan.setOriginationFeeUsdCents(1000); // $10.00
        assertEq(loan.originationFee(), 0.004 ether, "usdCents * 1e26 / (price * 100)");

        uint256 id = _donFor(alice);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(DonLoan.WrongFee.selector);
        loan.borrow{value: 0.003 ether}(id, 30 days); // underpay rejected

        uint256 sinkEthBefore = feeSink.balance;
        vm.prank(alice);
        loan.borrow{value: 0.01 ether}(id, 30 days); // overpay welcome
        assertEq(feeSink.balance - sinkEthBefore, 0.004 ether, "exactly the fee forwards");
        assertEq(alice.balance, 1 ether - 0.004 ether, "every excess wei refunded");
    }

    /// Fail-open: ANY unhealthy feed reading falls back to the flat fee - borrowing never bricks.
    function test_OriginationFeeFallsBackOnBadFeed() public {
        vm.startPrank(treasury);
        loan.setOriginationFeeUsdCents(1000); // $10.00 -> 0.004 ether at $2500
        loan.setOriginationFee(0.002 ether); // the distinguishable flat fallback
        vm.stopPrank();
        assertEq(loan.originationFee(), 0.004 ether, "healthy feed: USD mode");

        vm.warp(block.timestamp + 200_000); // feed now stale (updatedAt = deploy time)
        assertEq(loan.originationFee(), 0.002 ether, "stale feed -> flat fallback");

        ethFeed.set(2500e8, block.timestamp); // fresh again
        assertEq(loan.originationFee(), 0.004 ether);

        ethFeed.set(0, block.timestamp); // zero answer
        assertEq(loan.originationFee(), 0.002 ether, "zero answer -> flat fallback");
        ethFeed.set(-1, block.timestamp); // negative answer
        assertEq(loan.originationFee(), 0.002 ether, "negative answer -> flat fallback");

        ethFeed.set(2500e8, block.timestamp);
        ethFeed.setRounds(5, 4); // answeredInRound < roundId
        assertEq(loan.originationFee(), 0.002 ether, "incomplete round -> flat fallback");
        ethFeed.setRounds(5, 5);
        assertEq(loan.originationFee(), 0.004 ether, "healed feed: USD mode again");

        // And a borrow at the fallback price actually clears - fail-open end to end.
        ethFeed.set(0, block.timestamp);
        uint256 id = _donFor(alice);
        uint256 draw = loan.maxBorrow();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        loan.borrow{value: 0.002 ether}(id, 30 days);
        assertEq(loan.debtOf(id), draw, "borrow cleared on a dead feed");
    }

    /// A broken-LOW feed price would compute an absurd wei fee - the hard MAX_ORIGINATION_FEE clamp
    /// bounds the toll no matter what the feed says.
    function test_OriginationFeeClampsAtMax() public {
        vm.prank(treasury);
        loan.setOriginationFeeUsdCents(1000);
        ethFeed.set(1, block.timestamp); // $0.00000001 per ETH -> computed fee ~1e27 wei
        assertEq(loan.originationFee(), loan.MAX_ORIGINATION_FEE(), "oracle fee clamps to the same hard cap");
    }

    function test_OriginationFeeUsdCentsCapAndAuth() public {
        vm.prank(alice);
        vm.expectRevert(DonLoan.NotTreasury.selector);
        loan.setOriginationFeeUsdCents(1000);

        vm.prank(treasury);
        vm.expectRevert(DonLoan.FeeTooHigh.selector);
        loan.setOriginationFeeUsdCents(10_001); // above $100

        vm.prank(treasury);
        loan.setOriginationFeeUsdCents(10_000); // $100 boundary
        assertEq(loan.originationFee(), 0.04 ether, "$100 at $2500");
    }

    /// No feed wired at deploy = flat-only forever: the USD price can sit set but never engages.
    function test_OriginationFeeFlatOnlyWithoutFeed() public {
        DonLoan flatLoan = _newLoan(LTV, LIQ, RATE, PENALTY, GRACE, TIP, address(0));
        vm.startPrank(treasury);
        flatLoan.setOriginationFeeUsdCents(1000);
        flatLoan.setOriginationFee(0.001 ether);
        vm.stopPrank();
        assertEq(flatLoan.originationFee(), 0.001 ether, "flat governs when no feed exists");
    }

    // ---------------------------------------------------------------- admin & conservation

    function test_WithdrawIdleTreasuryOnly() public {
        vm.prank(alice);
        vm.expectRevert(DonLoan.NotTreasury.selector);
        loan.withdrawIdle(1e18);

        uint256 before = essey.balanceOf(treasury);
        vm.prank(treasury);
        loan.withdrawIdle(1000e18);
        assertEq(essey.balanceOf(treasury) - before, 1000e18);
    }

    /// Conservation across the whole lifecycle - term and hold fuzzed over the fixed draw: no ESSEY is
    /// minted or destroyed by the facility. Every wei that leaves the pot is accounted to borrower/
    /// reserve/tip/feeSink, INCLUDING the prepaid interest routed at borrow.
    function testFuzz_LifecycleConservation(uint32 dt, uint32 termRaw) public {
        uint256 id = _donFor(alice);
        uint256 term = bound(uint256(termRaw), 7 days, 365 days);
        uint256 hold = bound(uint256(dt), 1 hours, 3650 days);

        uint256 total0 = essey.balanceOf(address(loan)) + essey.balanceOf(address(reserve))
            + essey.balanceOf(alice) + essey.balanceOf(keeper) + essey.balanceOf(treasury)
            + essey.balanceOf(feeSink);

        vm.prank(alice);
        loan.borrow(id, term); // prepaid routes to feeSink/reserve inside the tracked set
        vm.warp(block.timestamp + hold);

        uint256 debt = loan.debtOf(id);
        (,,, uint64 expiry,,) = loan.loans(id);
        if (debt > loan.liquidationThreshold() || block.timestamp > uint256(expiry) + GRACE) {
            vm.prank(keeper);
            loan.liquidate(id);
        } else {
            essey.mint(alice, debt); // top up alice to repay (tracked below)
            vm.startPrank(alice);
            essey.approve(address(loan), type(uint256).max);
            loan.repay(id, debt);
            vm.stopPrank();
            total0 += debt; // the minted top-up enters the system
        }

        uint256 total1 = essey.balanceOf(address(loan)) + essey.balanceOf(address(reserve))
            + essey.balanceOf(alice) + essey.balanceOf(keeper) + essey.balanceOf(treasury)
            + essey.balanceOf(feeSink);
        assertEq(total1, total0, "conservation: the facility neither prints nor burns ESSEY");
        assertEq(loan.debtOf(id), 0, "loan settled either way");
    }
}
