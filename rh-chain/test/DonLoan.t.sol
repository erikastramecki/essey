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

/// Fixed-term, fixed-draw borrow-against-your-Don, the reference NFT-desk loan proven end to end on the
/// REAL Don + DonReserve: every loan draws ltvBps of the live floor and is DISBURSED IN FULL, interest
/// is PREPAID IN ETH at signing (split 70/30 feeSink/treasury), debt is FLAT FOREVER at principal, and
/// default is a CALENDAR event past expiry + grace — funded by the Don's own redeemable backing. No
/// oracle, no accrual, no penalty phase.
contract DonLoanTest is Test {
    ERC20Mock essey;
    Don don;
    DonReserve reserve;
    DonLoan loan;

    address treasury = address(0x7EA);
    address feeSink = address(0x51CC); // the fee->stock router stand-in (ETH sink)
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xC0FFEE);

    uint256 constant CAP = 8;
    uint256 constant FLOOR = 300_000e18; // per Don after seeding
    uint256 constant LTV = 5000; // 50% — the fixed draw
    uint256 constant LIQ = 7000; // 70% of the live floor
    uint256 constant GRACE = 30 days; // past expiry + this, calendar liquidation opens
    uint256 constant TIP = 100; // 1% of liquidation proceeds
    uint256 constant ETH_SHARE = 7000; // prepaid ETH: 70% -> feeSink, 30% -> treasury
    uint256 constant YEAR = 365 days;
    uint256 constant COEF = 1e12; // a test ETH-per-floor coefficient (default deploy is 0 = free)

    function setUp() public {
        essey = new ERC20Mock();
        don = new Don("Essey Don", "DON", CAP, address(this)); // test = minter
        reserve = new DonReserve(IERC20(address(essey)), IERC721(address(don)));
        loan = new DonLoan(_config(don, reserve, LTV, LIQ, GRACE, TIP, 0, ETH_SHARE)); // free by default
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

    /// Open a loan at the current year rate, funding the exact prepaid ETH from the caller.
    function _openLoan(address who, uint256 term) internal returns (uint256 id) {
        id = _donFor(who);
        uint256 prepaid = loan.prepaidEth(term);
        vm.deal(who, who.balance + prepaid);
        vm.prank(who);
        loan.borrow{value: prepaid}(id, term);
    }

    function _config(
        Don don_,
        DonReserve reserve_,
        uint256 ltv,
        uint256 liq,
        uint256 grace,
        uint256 tip,
        uint256 wad,
        uint256 ethShare
    ) internal view returns (DonLoan.Config memory) {
        return DonLoan.Config({
            essey: IERC20(address(essey)),
            don: don_,
            reserve: reserve_,
            feeSink: feeSink,
            treasury: treasury,
            ltvBps: ltv,
            liqThresholdBps: liq,
            defaultGraceSeconds: grace,
            liqTipBps: tip,
            ethPerFloorPerYearWad: wad,
            ethFeeStockShareBps: ethShare,
            guardian: address(this)
        });
    }

    function _newLoan(uint256 ltv, uint256 liq, uint256 grace, uint256 tip, uint256 wad, uint256 ethShare)
        internal
        returns (DonLoan)
    {
        return new DonLoan(_config(don, reserve, ltv, liq, grace, tip, wad, ethShare));
    }

    // ---------------------------------------------------------------- construction

    function test_ConstructorGuards() public {
        vm.expectRevert(DonLoan.BadConfig.selector); // gap below 20pp
        _newLoan(5000, 6900, GRACE, TIP, 0, ETH_SHARE);
        vm.expectRevert(DonLoan.BadConfig.selector); // threshold above 90%
        _newLoan(5000, 9100, GRACE, TIP, 0, ETH_SHARE);
        vm.expectRevert(DonLoan.BadConfig.selector); // zero ltv
        _newLoan(0, LIQ, GRACE, TIP, 0, ETH_SHARE);
        vm.expectRevert(DonLoan.BadConfig.selector); // tip above cap
        _newLoan(LTV, LIQ, GRACE, 501, 0, ETH_SHARE);
        vm.expectRevert(DonLoan.BadConfig.selector); // grace below a week
        _newLoan(LTV, LIQ, 7 days - 1, TIP, 0, ETH_SHARE);
        vm.expectRevert(DonLoan.BadConfig.selector); // grace above a quarter
        _newLoan(LTV, LIQ, 90 days + 1, TIP, 0, ETH_SHARE);
        vm.expectRevert(DonLoan.BadConfig.selector); // stock share above 100%
        _newLoan(LTV, LIQ, GRACE, TIP, 0, 10_001);
        vm.expectRevert(DonLoan.BadConfig.selector); // coefficient above the overflow-guard ceiling
        _newLoan(LTV, LIQ, GRACE, TIP, 1 ether + 1, ETH_SHARE);

        _newLoan(LTV, LIQ, GRACE, TIP, 1 ether, ETH_SHARE); // coefficient AT the ceiling is fine

        // reserve/don pairing must match - a foreign reserve can't price this collection
        Don other = new Don("Other", "OTH", CAP, address(this));
        DonReserve otherReserve = new DonReserve(IERC20(address(essey)), IERC721(address(other)));
        vm.expectRevert(DonLoan.BadConfig.selector);
        new DonLoan(_config(don, otherReserve, LTV, LIQ, GRACE, TIP, 0, ETH_SHARE));
    }

    // ---------------------------------------------------------------- borrow (full draw, ETH-prepaid)

    /// The whole draw is disbursed in $ESSEY — no interest netting. The Don is liened in place.
    function test_BorrowDisbursesFullPrincipal() public {
        uint256 id = _donFor(alice);
        uint256 principal = loan.maxBorrow();
        assertEq(principal, (FLOOR * LTV) / 10_000, "the fixed draw: 50% of the live floor");
        uint256 potBefore = loan.lendable();

        vm.prank(alice);
        loan.borrow{value: 0}(id, 365 days); // free by default

        assertEq(essey.balanceOf(alice), principal, "borrower gets the FULL draw - no interest netting");
        assertEq(loan.debtOf(id), principal, "and owes exactly it back");
        assertEq(loan.totalPrincipal(), principal);
        assertEq(potBefore - loan.lendable(), principal, "the pot funded exactly the disbursement");

        assertEq(don.ownerOf(id), alice, "the Don never leaves the borrower's wallet");
        assertTrue(don.liened(id), "but it is transfer-locked");
        vm.prank(alice);
        vm.expectRevert(Don.LienActive.selector);
        don.transferFrom(alice, bob, id);
    }

    /// The prepaid ETH interest: FLOOR-SCALED off the live floor, split 70/30 feeSink/treasury, exact
    /// refund of any excess, and a zero coefficient demands a zero msg.value (no accidental tips).
    function test_PrepaidEthSplitRefundAndZeroRule() public {
        // Default coefficient 0 => prepaid 0 => msg.value must be EXACTLY 0.
        uint256 id0 = _donFor(alice);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(DonLoan.WrongFee.selector);
        loan.borrow{value: 1}(id0, 30 days); // any tip rejected when nothing is owed
        vm.prank(alice);
        loan.borrow{value: 0}(id0, 30 days); // free borrow clears

        // Set the coefficient; the prepaid scales off the LIVE floor.
        vm.prank(treasury);
        loan.setEthRatePerFloorYear(COEF);
        uint256 term = 30 days;
        uint256 expected = (COEF * reserve.floorPerDon() * term) / (YEAR * 1e18);
        assertEq(loan.prepaidEth(term), expected, "prepaid = wad * floor * term / (YEAR * 1e18)");

        uint256 id = _donFor(bob);
        uint256 sinkBefore = feeSink.balance;
        uint256 treasBefore = treasury.balance;
        vm.deal(bob, 1 ether);

        // Underpay rejected.
        vm.prank(bob);
        vm.expectRevert(DonLoan.WrongFee.selector);
        loan.borrow{value: expected - 1}(id, term);

        // Overpay: exactly `expected` splits 70/30, the excess refunds to the wei.
        vm.prank(bob);
        loan.borrow{value: 0.5 ether}(id, term);
        uint256 toStock = (expected * ETH_SHARE) / 10_000;
        assertEq(feeSink.balance - sinkBefore, toStock, "70% of prepaid ETH -> feeSink (stock pipe)");
        assertEq(treasury.balance - treasBefore, expected - toStock, "30% -> treasury");
        assertEq(bob.balance, 1 ether - expected, "exactly the prepaid was charged, the rest refunded");
        assertEq(essey.balanceOf(bob), loan.maxBorrow(), "full draw disbursed regardless of the ETH leg");
    }

    /// The prepaid ETH scales linearly with the floor: double the reserve (double the floor) and the
    /// same term costs exactly twice the prepaid — the reference desk's value-scaled fee, off our floor.
    function test_PrepaidScalesWithFloor() public {
        vm.prank(treasury);
        loan.setEthRatePerFloorYear(COEF);
        uint256 term = 365 days;

        uint256 prepaidAtF = loan.prepaidEth(term);
        assertEq(prepaidAtF, (COEF * FLOOR * term) / (YEAR * 1e18), "floor-scaled off F");
        assertGt(prepaidAtF, 0);

        essey.mint(address(this), CAP * FLOOR); // double the reserve -> double the floor
        essey.approve(address(reserve), type(uint256).max);
        reserve.fund(CAP * FLOOR);
        assertEq(reserve.floorPerDon(), 2 * FLOOR, "floor doubled");

        assertEq(loan.prepaidEth(term), 2 * prepaidAtF, "same term, double the floor -> double the prepaid");
        assertEq(loan.maxBorrow(), (2 * FLOOR * LTV) / 10_000, "the draw tracks the floor too");
    }

    /// The 1-ETH output clamp bites: at an extreme floor (or coefficient) the computed prepaid would run
    /// past MAX_PREPAID_ETH, so it is capped — no borrow can ever cost more than that in prepaid ETH.
    function test_PrepaidClampsAtMax() public {
        // A big coefficient makes the raw prepaid enormous at the seeded floor; the clamp caps it.
        vm.prank(treasury);
        loan.setEthRatePerFloorYear(1e14); // full-year raw = 1e14 * 300000 = 3e19 wei = 30 ether
        uint256 raw = (1e14 * reserve.floorPerDon() * 365 days) / (YEAR * 1e18);
        assertGt(raw, loan.MAX_PREPAID_ETH(), "raw would exceed the cap");
        assertEq(loan.prepaidEth(365 days), loan.MAX_PREPAID_ETH(), "clamped to MAX_PREPAID_ETH");

        // A borrow at the clamp forwards exactly MAX_PREPAID_ETH (70/30) and refunds the rest.
        uint256 id = _donFor(alice);
        uint256 sinkBefore = feeSink.balance;
        uint256 treasBefore = treasury.balance;
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        loan.borrow{value: 2 ether}(id, 365 days);
        uint256 cap = loan.MAX_PREPAID_ETH();
        assertEq(feeSink.balance - sinkBefore, (cap * ETH_SHARE) / 10_000, "70% of the clamped prepaid");
        assertEq(treasury.balance - treasBefore, cap - (cap * ETH_SHARE) / 10_000, "30%");
        assertEq(alice.balance, 2 ether - cap, "only the clamped amount charged");
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
        loan.borrow(id, 7 days); // both boundaries inclusive
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
        DonLoan bareLoan = new DonLoan(_config(bare, bareReserve, LTV, LIQ, GRACE, TIP, 0, ETH_SHARE));
        bare.setLienManager(address(bareLoan));
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

    // ---------------------------------------------------------------- debt is flat forever

    function test_DebtFlatForever() public {
        uint256 id = _openLoan(alice, 30 days);
        uint256 principal = (FLOOR * LTV) / 10_000;

        vm.warp(block.timestamp + 15 days);
        assertEq(loan.debtOf(id), principal, "mid-term: flat");
        vm.warp(block.timestamp + 3650 days); // 10 years, deep past expiry
        assertEq(loan.debtOf(id), principal, "a decade past expiry: STILL exactly principal - no accrual");
    }

    // ---------------------------------------------------------------- repay

    function test_RepayOneToOneReleasesLien() public {
        uint256 id = _openLoan(alice, 365 days);
        uint256 principal = (FLOOR * LTV) / 10_000;

        vm.warp(block.timestamp + 300 days);
        essey.mint(alice, principal);
        vm.startPrank(alice);
        essey.approve(address(loan), type(uint256).max);
        uint256 paid = loan.repay(id, type(uint256).max); // overpay bid: only the principal is pulled
        vm.stopPrank();

        assertEq(paid, principal, "1:1 - exactly the principal, nothing more");
        assertEq(loan.debtOf(id), 0);
        assertFalse(don.liened(id), "the Don walks free");
        assertEq(loan.totalPrincipal(), 0);

        vm.prank(alice); // and is transferable again
        don.transferFrom(alice, bob, id);
        assertEq(don.ownerOf(id), bob);
    }

    /// The machinery kept from v2: a partial paydown reduces principal but keeps the lien until it clears.
    function test_PartialRepayKeepsLien() public {
        uint256 id = _openLoan(alice, 30 days);
        uint256 principal = loan.debtOf(id);
        essey.mint(alice, principal);
        vm.startPrank(alice);
        essey.approve(address(loan), type(uint256).max);
        uint256 paid = loan.repay(id, principal / 4);
        vm.stopPrank();
        assertEq(paid, principal / 4);
        assertEq(loan.debtOf(id), principal - principal / 4, "principal drawn down");
        assertTrue(don.liened(id), "still in debt -> still liened");
        assertEq(loan.totalPrincipal(), principal - principal / 4);
    }

    function test_AnyoneMayRepayAsGift() public {
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

    /// The ratio backstop math stays LIVE but is structurally unreachable: flat principal (50% of a
    /// non-decreasing floor) never crosses the 70% threshold, so the `debt <= threshold` comparison is
    /// always evaluated and always true - it can never open liquidation, but it is never removed.
    function test_RatioBackstopMathStaysLive() public {
        uint256 id = _openLoan(alice, 365 days);
        uint256 debt = loan.debtOf(id);
        uint256 threshold = loan.liquidationThreshold();
        assertEq(debt, (reserve.floorPerDon() * LTV) / 10_000, "debt = 50% of the floor");
        assertEq(threshold, (reserve.floorPerDon() * LIQ) / 10_000, "threshold = 70% of the floor");
        assertLt(debt, threshold, "the ratio backstop is structurally satisfied - it can never fire");

        // In-term (calendar not yet open) liquidation reverts on that very ratio comparison, args and all.
        vm.warp(block.timestamp + 180 days);
        vm.expectRevert(
            abi.encodeWithSelector(DonLoan.NotLiquidatable.selector, loan.debtOf(id), loan.liquidationThreshold())
        );
        loan.liquidate(id);

        // Even a decade on, the ratio value stays computed and stays below threshold - the math is live.
        vm.warp(block.timestamp + 3650 days);
        assertLt(loan.debtOf(id), loan.liquidationThreshold(), "flat debt sits under the ratio forever");
    }

    /// The CALENDAR trigger — the live one: not one second before expiry + grace, and open exactly after.
    /// The waterfall returns the surplus to the borrower.
    function test_CalendarLiquidationLastGraceThenOpens() public {
        uint256 start = block.timestamp;
        uint256 id = _openLoan(alice, 30 days);
        uint256 principal = (FLOOR * LTV) / 10_000;

        vm.warp(start + 30 days + GRACE); // the last grace second: still safe (ratio healthy, calendar closed)
        vm.expectRevert(
            abi.encodeWithSelector(DonLoan.NotLiquidatable.selector, loan.debtOf(id), loan.liquidationThreshold())
        );
        loan.liquidate(id);

        vm.warp(start + 30 days + GRACE + 1); // one second past grace: the calendar opens it
        assertLt(loan.debtOf(id), loan.liquidationThreshold(), "STILL ratio-healthy - purely calendar");

        uint256 proceeds = reserve.floorPerDon(); // redeemed at the live floor
        uint256 aliceBefore = essey.balanceOf(alice);
        uint256 potBefore = loan.lendable();

        vm.prank(keeper);
        loan.liquidate(id);

        // Waterfall: tip -> principal (back to the pot) -> surplus to the borrower. No interest leg.
        uint256 tip = (proceeds * TIP) / 10_000;
        uint256 surplus = proceeds - tip - principal;
        assertEq(essey.balanceOf(keeper), tip, "caller tip - no liquidator capital needed");
        assertEq(loan.lendable() - potBefore, principal, "principal restored to the pot");
        assertEq(essey.balanceOf(alice) - aliceBefore, surplus, "surplus returns to the borrower - deliberate");
        assertEq(don.ownerOf(id), address(reserve), "the Don was consumed by its own backing");
        assertEq(loan.debtOf(id), 0, "loan closed");
        assertEq(loan.totalPrincipal(), 0);
    }

    /// A staked, earning Don can be liquidated on the calendar: the seizure transfer clears its Bell tier.
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

        vm.warp(block.timestamp + 30 days + GRACE + 1); // calendar default
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
        assertEq(debtWhole, 150_000, "flat principal in whole-ESSEY units (fits the circuit's 64-bit bound)");
        assertEq(floorWhole, uint64(reserve.floorPerDon() / 1e18), "floor rounds DOWN");
        assertEq(ltv, uint16(LTV));
        assertEq(n, 1, "monotone nonce");
        assertLe(uint256(debtWhole) * 10_000, uint256(floorWhole) * ltv, "the exact relation the circuit proves");

        uint256 id2 = _openLoan(bob, 30 days);
        (,,,,, uint64 n2) = loan.loanTuple(id2);
        assertEq(n2, 2);

        vm.expectRevert(DonLoan.NoLoan.selector);
        loan.loanTuple(999);
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

    /// The coefficient setter is treasury-only and bounded by the overflow guard; the output clamp is
    /// what actually caps the toll (proven in test_PrepaidClampsAtMax).
    function test_EthRateCapAndAuth() public {
        vm.prank(alice);
        vm.expectRevert(DonLoan.NotTreasury.selector);
        loan.setEthRatePerFloorYear(1);

        vm.prank(treasury);
        vm.expectRevert(DonLoan.FeeTooHigh.selector);
        loan.setEthRatePerFloorYear(1 ether + 1); // above the overflow-guard ceiling

        vm.prank(treasury);
        loan.setEthRatePerFloorYear(COEF); // a working coefficient
        assertEq(loan.ethPerFloorPerYearWad(), COEF);
        assertEq(loan.prepaidEth(YEAR), (COEF * FLOOR) / 1e18, "full-year prepaid = wad * floor / 1e18");
    }

    /// Conservation across the whole lifecycle - term and hold fuzzed over the fixed draw. Two ledgers:
    /// ETH in (prepaid + surplus) == feeSink + treasury + refund; and no $ESSEY is minted or destroyed by
    /// the facility - the principal round-trips.
    function testFuzz_LifecycleConservation(uint32 dt, uint32 termRaw) public {
        vm.prank(treasury);
        loan.setEthRatePerFloorYear(COEF); // exercise the floor-scaled ETH leg

        uint256 id = _donFor(alice);
        uint256 term = bound(uint256(termRaw), 7 days, 365 days);
        uint256 hold = bound(uint256(dt), 1 hours, 3650 days);
        uint256 prepaid = loan.prepaidEth(term);

        uint256 esseyTotal0 = essey.balanceOf(address(loan)) + essey.balanceOf(address(reserve))
            + essey.balanceOf(alice) + essey.balanceOf(keeper) + essey.balanceOf(treasury)
            + essey.balanceOf(feeSink);

        // ETH ledger across the borrow: fund exactly prepaid + a surplus, then check the split and refund.
        uint256 surplusSent = 0.05 ether;
        vm.deal(alice, prepaid + surplusSent);
        uint256 feeSinkEth0 = feeSink.balance;
        uint256 treasuryEth0 = treasury.balance;

        vm.prank(alice);
        loan.borrow{value: prepaid + surplusSent}(id, term);

        uint256 toStock = (prepaid * ETH_SHARE) / 10_000;
        assertEq(feeSink.balance - feeSinkEth0, toStock, "ETH: feeSink leg");
        assertEq(treasury.balance - treasuryEth0, prepaid - toStock, "ETH: treasury leg");
        assertEq(alice.balance, surplusSent, "ETH: exact refund of the excess");
        assertEq(
            (feeSink.balance - feeSinkEth0) + (treasury.balance - treasuryEth0) + alice.balance,
            prepaid + surplusSent,
            "ETH conservation: in == feeSink + treasury + refund"
        );

        vm.warp(block.timestamp + hold);
        (,, uint64 expiry,) = loan.loans(id);
        uint256 debt = loan.debtOf(id);
        if (block.timestamp > uint256(expiry) + GRACE) {
            vm.prank(keeper);
            loan.liquidate(id); // only the calendar can open it - the ratio never fires
        } else {
            essey.mint(alice, debt); // top up alice to repay (tracked below)
            vm.startPrank(alice);
            essey.approve(address(loan), type(uint256).max);
            loan.repay(id, debt);
            vm.stopPrank();
            esseyTotal0 += debt; // the minted top-up enters the system
        }

        uint256 esseyTotal1 = essey.balanceOf(address(loan)) + essey.balanceOf(address(reserve))
            + essey.balanceOf(alice) + essey.balanceOf(keeper) + essey.balanceOf(treasury)
            + essey.balanceOf(feeSink);
        assertEq(esseyTotal1, esseyTotal0, "ESSEY conservation: the facility neither prints nor burns");
        assertEq(loan.debtOf(id), 0, "loan settled either way");
    }
}
