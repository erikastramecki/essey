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

/// Borrow-against-your-Don, proven end to end on the REAL Don + DonReserve: ESSEY-denominated,
/// oracle-free, lien-in-place, liquidation funded by the Don's own redeemable backing.
contract DonLoanTest is Test {
    ERC20Mock essey;
    Don don;
    DonReserve reserve;
    DonLoan loan;

    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xC0FFEE);

    uint256 constant CAP = 8;
    uint256 constant FLOOR = 300_000e18; // per Don after seeding
    uint256 constant LTV = 5000; // 50%
    uint256 constant LIQ = 7000; // 70% of the live floor
    uint256 constant RATE = 1500; // 15% APR simple
    uint256 constant TIP = 100; // 1% of liquidation proceeds

    function setUp() public {
        essey = new ERC20Mock();
        don = new Don("Essey Don", "DON", CAP, address(this)); // test = minter
        reserve = new DonReserve(IERC20(address(essey)), IERC721(address(don)));
        loan = new DonLoan(IERC20(address(essey)), don, reserve, treasury, LTV, LIQ, RATE, TIP);
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

    function _maxLoan(address who) internal returns (uint256 id) {
        id = _donFor(who);
        uint256 cap = loan.maxBorrow(); // hoisted: a view call would consume the prank
        vm.prank(who);
        loan.borrow(id, cap);
    }

    // ---------------------------------------------------------------- construction

    function test_ConstructorGuards() public {
        vm.expectRevert(DonLoan.BadConfig.selector); // gap below 20pp
        new DonLoan(IERC20(address(essey)), don, reserve, treasury, 5000, 6900, RATE, TIP);
        vm.expectRevert(DonLoan.BadConfig.selector); // threshold above 90%
        new DonLoan(IERC20(address(essey)), don, reserve, treasury, 5000, 9100, RATE, TIP);
        vm.expectRevert(DonLoan.BadConfig.selector); // tip above cap
        new DonLoan(IERC20(address(essey)), don, reserve, treasury, LTV, LIQ, RATE, 501);
        vm.expectRevert(DonLoan.BadConfig.selector); // zero rate
        new DonLoan(IERC20(address(essey)), don, reserve, treasury, LTV, LIQ, 0, TIP);

        // reserve/don pairing must match - a foreign reserve can't price this collection
        Don other = new Don("Other", "OTH", CAP, address(this));
        DonReserve otherReserve = new DonReserve(IERC20(address(essey)), IERC721(address(other)));
        vm.expectRevert(DonLoan.BadConfig.selector);
        new DonLoan(IERC20(address(essey)), don, otherReserve, treasury, LTV, LIQ, RATE, TIP);
    }

    // ---------------------------------------------------------------- borrow

    function test_BorrowLiensInPlaceAndPaysOut() public {
        uint256 id = _donFor(alice);
        uint256 cap = loan.maxBorrow();
        assertEq(cap, (FLOOR * LTV) / 10_000, "50% of the live floor");

        vm.prank(alice);
        loan.borrow(id, cap);

        assertEq(essey.balanceOf(alice), cap, "ESSEY paid out");
        assertEq(don.ownerOf(id), alice, "the Don never leaves the borrower's wallet");
        assertTrue(don.liened(id), "but it is transfer-locked");
        assertEq(loan.debtOf(id), cap, "debt starts at principal");
        assertEq(loan.totalPrincipal(), cap);

        vm.prank(alice); // every exit is blocked while in debt
        vm.expectRevert(Don.LienActive.selector);
        don.transferFrom(alice, bob, id);
    }

    function test_BorrowGates() public {
        uint256 id = _donFor(alice);

        vm.prank(bob);
        vm.expectRevert(DonLoan.NotDonOwner.selector);
        loan.borrow(id, 1e18);

        uint256 cap = loan.maxBorrow();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DonLoan.ExceedsLtv.selector, cap + 1, cap));
        loan.borrow(id, cap + 1);

        vm.prank(alice);
        vm.expectRevert(DonLoan.ZeroAmount.selector);
        loan.borrow(id, 0);

        vm.prank(alice);
        loan.borrow(id, cap);
        vm.prank(alice);
        vm.expectRevert(DonLoan.LoanExists.selector);
        loan.borrow(id, 1e18); // one open loan per Don, no top-ups
    }

    /// The facility can only lend what it holds - a drained pot fails closed.
    function test_BorrowFailsClosedWhenPotEmpty() public {
        uint256 idle = loan.lendable();
        vm.prank(treasury);
        loan.withdrawIdle(idle); // treasury reclaims all idle capital
        uint256 id = _donFor(alice);
        uint256 cap = loan.maxBorrow();
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance
        loan.borrow(id, cap);
    }

    // ---------------------------------------------------------------- interest

    function test_SimpleInterestAccrues() public {
        uint256 id = _maxLoan(alice);
        uint256 principal = (FLOOR * LTV) / 10_000; // 150k

        vm.warp(block.timestamp + 365 days);
        assertEq(loan.debtOf(id), (principal * 11_500) / 10_000, "15% APR simple after one year");

        vm.warp(block.timestamp + 365 days);
        assertEq(loan.debtOf(id), (principal * 13_000) / 10_000, "non-compounding: 30% after two");
    }

    // ---------------------------------------------------------------- repay

    function test_RepayInterestFirstRaisesFloor() public {
        uint256 id = _maxLoan(alice);
        uint256 principal = (FLOOR * LTV) / 10_000;
        vm.warp(block.timestamp + 365 days);
        uint256 interest = (principal * RATE) / 10_000; // 22.5k

        uint256 floorBefore = reserve.floorPerDon();
        essey.mint(alice, interest);
        vm.startPrank(alice);
        essey.approve(address(loan), type(uint256).max);
        loan.repay(id, interest); // covers exactly the interest
        vm.stopPrank();

        assertEq(loan.debtOf(id), principal, "interest settled first");
        assertTrue(don.liened(id), "still in debt -> still liened");
        assertGt(reserve.floorPerDon(), floorBefore, "interest went to the reserve: EVERY Don's floor rose");
        assertEq(reserve.floorPerDon() - floorBefore, interest / CAP, "pro-rata across the cap");
    }

    function test_FullRepayReleasesTheLien() public {
        uint256 id = _maxLoan(alice);
        vm.warp(block.timestamp + 100 days);
        uint256 debt = loan.debtOf(id);

        essey.mint(alice, debt);
        vm.startPrank(alice);
        essey.approve(address(loan), type(uint256).max);
        uint256 paid = loan.repay(id, type(uint256).max); // overpay bid: only the debt is pulled
        vm.stopPrank();

        assertEq(paid, debt, "at most the outstanding debt moves");
        assertEq(loan.debtOf(id), 0);
        assertFalse(don.liened(id), "the Don walks free");
        assertEq(loan.totalPrincipal(), 0);

        vm.prank(alice); // and is transferable again
        don.transferFrom(alice, bob, id);
        assertEq(don.ownerOf(id), bob);
    }

    function test_AnyoneMayRepay() public {
        uint256 id = _maxLoan(alice);
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

    function test_HealthyLoanCannotBeLiquidated() public {
        uint256 id = _maxLoan(alice);
        vm.warp(block.timestamp + 365 days); // debt 57.5% of floor, threshold 70%
        vm.expectRevert(
            abi.encodeWithSelector(
                DonLoan.NotLiquidatable.selector, loan.debtOf(id), loan.liquidationThreshold()
            )
        );
        loan.liquidate(id);
    }

    /// Funding the reserve raises the LIVE floor and therefore the threshold - loans heal.
    function test_RisingFloorHealsLoans() public {
        uint256 id = _maxLoan(alice);
        vm.warp(block.timestamp + 1100 days); // ~45.2% interest -> debt ~72.6% of the static floor
        assertGt(loan.debtOf(id), loan.liquidationThreshold(), "underwater on the old floor");

        essey.mint(address(this), CAP * 50_000e18);
        reserve.fund(CAP * 50_000e18); // floor 300k -> 350k
        assertLt(loan.debtOf(id), loan.liquidationThreshold(), "healed by the rising floor");
    }

    function test_LiquidationWaterfall() public {
        uint256 id = _maxLoan(alice);
        uint256 principal = (FLOOR * LTV) / 10_000; // 150k
        vm.warp(block.timestamp + 1100 days);
        uint256 debt = loan.debtOf(id);
        assertGt(debt, loan.liquidationThreshold());
        uint256 interest = debt - principal;

        uint256 aliceBefore = essey.balanceOf(alice);
        uint256 potBefore = loan.lendable();
        uint256 reserveBefore = essey.balanceOf(address(reserve));

        vm.prank(keeper);
        loan.liquidate(id);

        uint256 proceeds = FLOOR; // redeemed at the floor
        uint256 tip = (proceeds * TIP) / 10_000; // 3k to the caller
        uint256 surplus = proceeds - tip - interest - principal;

        assertEq(essey.balanceOf(keeper), tip, "caller tip - no liquidator capital needed");
        assertEq(don.ownerOf(id), address(reserve), "the Don was consumed by its own backing");
        assertEq(loan.debtOf(id), 0, "loan closed");
        assertEq(loan.totalPrincipal(), 0);
        assertEq(essey.balanceOf(alice) - aliceBefore, surplus, "surplus returns to the borrower");
        assertEq(loan.lendable() - potBefore, principal, "principal restored to the pot");
        // Reserve: -proceeds (redeem) +interest (flywheel). Net change = interest - proceeds.
        assertEq(reserveBefore - essey.balanceOf(address(reserve)), proceeds - interest, "interest re-funds the floor");
    }

    /// Deep insolvency (nobody liquidated for years): waterfall saturates, facility eats the loss,
    /// borrower gets nothing, nothing reverts, nothing is owed by anyone.
    function test_LiquidationShortfallSaturates() public {
        uint256 id = _maxLoan(alice);
        uint256 principal = (FLOOR * LTV) / 10_000;
        vm.warp(block.timestamp + 3650 days); // 150% interest: debt = 2.5x principal = 125% of floor
        uint256 debt = loan.debtOf(id);
        assertGt(debt, FLOOR, "debt exceeds even the full floor");

        uint256 aliceBefore = essey.balanceOf(alice);
        uint256 potBefore = loan.lendable();
        vm.prank(keeper);
        loan.liquidate(id);

        uint256 tip = (FLOOR * TIP) / 10_000;
        uint256 interest = debt - principal; // 225k > available
        uint256 available = FLOOR - tip; // 297k
        assertEq(essey.balanceOf(keeper), tip);
        assertEq(essey.balanceOf(alice), aliceBefore, "no surplus for the borrower");
        assertEq(loan.lendable() - potBefore, available - interest, "partial principal recovery, loss absorbed");
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

        uint256 id = _maxLoan(alice);
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

    // ---------------------------------------------------------------- proof tuple & admin

    function test_LoanTupleWholeUnits() public {
        uint256 id = _maxLoan(alice);
        (address facility, address borrower, uint64 debtWhole, uint64 floorWhole, uint16 ltv, uint64 n) =
            loan.loanTuple(id);
        assertEq(facility, address(loan));
        assertEq(borrower, alice);
        assertEq(debtWhole, 150_000, "whole-ESSEY units fit the circuit's 64-bit bound");
        assertEq(floorWhole, 300_000);
        assertEq(ltv, uint16(LTV));
        assertEq(n, 1, "monotone nonce");
        assertLe(uint256(debtWhole) * 10_000, uint256(floorWhole) * ltv, "the exact relation the circuit proves");

        uint256 id2 = _maxLoan(bob);
        (,,,,, uint64 n2) = loan.loanTuple(id2);
        assertEq(n2, 2);

        vm.expectRevert(DonLoan.NoLoan.selector);
        loan.loanTuple(999);
    }

    /// The tuple must never understate risk: fractional debt rounds UP to whole tokens, so a loan that
    /// is unsafe by less than one ESSEY still reports as unsafe (the floor stays rounded down).
    function test_LoanTupleCeilsDebtConservatively() public {
        uint256 id = _maxLoan(alice);
        vm.warp(block.timestamp + 10 minutes); // accrue a fractional token of interest (~0.43 ESSEY)
        uint256 debt = loan.debtOf(id);
        assertGt(debt, 150_000e18);
        assertLt(debt, 150_001e18);
        (,, uint64 debtWhole,,,) = loan.loanTuple(id);
        assertEq(debtWhole, 150_001, "fractional debt rounds UP - conservative for the prover");
    }

    function test_WithdrawIdleTreasuryOnly() public {
        vm.prank(alice);
        vm.expectRevert(DonLoan.NotTreasury.selector);
        loan.withdrawIdle(1e18);

        uint256 before = essey.balanceOf(treasury);
        vm.prank(treasury);
        loan.withdrawIdle(1000e18);
        assertEq(essey.balanceOf(treasury) - before, 1000e18);
    }

    /// Conservation across the whole lifecycle: no ESSEY is minted or destroyed by the facility -
    /// every wei that leaves the pot is accounted to borrower/reserve/tip.
    function testFuzz_LifecycleConservation(uint96 amount, uint32 dt) public {
        uint256 id = _donFor(alice);
        uint256 borrowed = bound(uint256(amount), 1e18, loan.maxBorrow());
        uint256 hold = bound(uint256(dt), 1 hours, 3650 days);

        uint256 total0 = essey.balanceOf(address(loan)) + essey.balanceOf(address(reserve))
            + essey.balanceOf(alice) + essey.balanceOf(keeper) + essey.balanceOf(treasury);

        vm.prank(alice);
        loan.borrow(id, borrowed);
        vm.warp(block.timestamp + hold);

        uint256 debt = loan.debtOf(id);
        if (debt > loan.liquidationThreshold()) {
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
            + essey.balanceOf(alice) + essey.balanceOf(keeper) + essey.balanceOf(treasury);
        assertEq(total1, total0, "conservation: the facility neither prints nor burns ESSEY");
        assertEq(loan.debtOf(id), 0, "loan settled either way");
    }
}
