// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Don} from "../src/market/Don.sol";
import {DonReserve} from "../src/market/DonReserve.sol";
import {DonExchange, IDonFloor} from "../src/market/DonExchange.sol";
import {DonLoan} from "../src/market/DonLoan.sol";
import {Guarded} from "../src/market/Guarded.sol";

/// The freeze-only guardian (founder-approved): freezing stops NEW activity on the loan facility and
/// the desk — and provably cannot touch a single exit. Proven on the real contracts, mid-flight.
contract GuardedTest is Test, IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    ERC20Mock essey;
    Don don;
    DonReserve reserve;
    DonExchange ex;
    DonLoan loan;

    address guardian = address(0x6A2D);
    address feeSink = address(0x51CC);
    address treasury = address(0x7EA);
    address alice = address(0xA11CE);

    uint256 constant CAP = 8;
    uint256 constant FLOOR = 300_000e18;

    function setUp() public {
        essey = new ERC20Mock();
        don = new Don("Essey Don", "DON", CAP, address(this), address(0x7EE), 500);
        reserve = new DonReserve(IERC20(address(essey)), IERC721(address(don)));
        ex = new DonExchange(
            IERC721(address(don)), IERC20(address(essey)), IDonFloor(address(reserve)),
            feeSink, treasury, address(this), FLOOR, 800, 1200, 7000, guardian
        );
        loan = new DonLoan(
            DonLoan.Config({
                essey: IERC20(address(essey)),
                don: don,
                reserve: reserve,
                feeSink: feeSink,
                treasury: treasury,
                ltvBps: 5000,
                liqThresholdBps: 7000,
                defaultGraceSeconds: 30 days,
                liqTipBps: 100,
                ethPerFloorPerYearWad: 0,
                ethFeeStockShareBps: 7000,
                guardian: guardian
            })
        );
        don.setLienManager(address(loan));

        essey.mint(address(this), CAP * FLOOR + 2_000_000e18);
        essey.approve(address(reserve), type(uint256).max);
        reserve.fund(CAP * FLOOR);
        essey.approve(address(loan), type(uint256).max);
        loan.fund(1_000_000e18);
        essey.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        essey.approve(address(ex), type(uint256).max);
        essey.approve(address(loan), type(uint256).max);
        vm.stopPrank();
    }

    function test_OnlyGuardianFreezes() public {
        vm.expectRevert(Guarded.NotGuardian.selector);
        loan.freeze(); // even the deployer/admin can't — only the guardian
        vm.prank(guardian);
        loan.freeze();
        assertTrue(loan.frozen());
        vm.expectRevert(Guarded.NotGuardian.selector);
        loan.unfreeze();
        vm.prank(guardian);
        loan.unfreeze();
        assertFalse(loan.frozen());
    }

    /// THE property: freeze mid-flight — every new-activity path reverts, every exit still settles.
    function test_FreezeStopsNewActivityNeverExits() public {
        // Live state before the incident: a seeded desk, an open loan, a Don bought.
        uint256 seedId = don.mint(address(this), keccak256("float"));
        don.setApprovalForAll(address(ex), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = seedId;
        ex.seed(ids);
        vm.prank(alice);
        uint256 boughtId = ex.buy(type(uint256).max); // desk reserve now holds the price
        uint256 loanId = don.mint(alice, keccak256("collateral"));
        vm.prank(alice);
        loan.borrow(loanId, 30 days); // fixed draw: ltvBps of the live floor

        vm.prank(guardian);
        loan.freeze();
        vm.prank(guardian);
        ex.freeze();

        // NEW ACTIVITY: all blocked.
        vm.prank(alice);
        vm.expectRevert(Guarded.IsFrozen.selector);
        loan.borrow(boughtId, 30 days);
        vm.prank(alice);
        vm.expectRevert(Guarded.IsFrozen.selector);
        ex.buy(type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(Guarded.IsFrozen.selector);
        ex.snipe(1, type(uint256).max);
        vm.startPrank(alice);
        don.approve(address(ex), boughtId);
        vm.expectRevert(Guarded.IsFrozen.selector);
        ex.sell(boughtId, 0);
        vm.stopPrank();
        vm.expectRevert(Guarded.IsFrozen.selector);
        ex.seed(new uint256[](0));

        // EXITS: all still work, frozen or not.
        vm.prank(alice);
        loan.repay(loanId, type(uint256).max); // full repay -> lien released
        assertFalse(don.liened(loanId), "repay exit untouched by freeze");

        vm.startPrank(alice);
        don.approve(address(reserve), boughtId);
        uint256 paid = reserve.redeem(boughtId); // the canonical exit — adminless, unfreezable
        vm.stopPrank();
        assertGt(paid, 0, "redemption exit untouched by freeze");

        uint256 idle = loan.lendable();
        uint256 treasuryBefore = essey.balanceOf(treasury); // already holds its 30% trade-fee cut
        vm.prank(treasury);
        loan.withdrawIdle(idle); // treasury exit untouched
        assertEq(essey.balanceOf(treasury) - treasuryBefore, idle);
    }

    /// Liquidation is a settlement, not new activity — it must work while frozen (recovery can't wait).
    function test_LiquidationWorksWhileFrozen() public {
        uint256 id = don.mint(alice, keccak256("borrower"));
        vm.prank(alice);
        loan.borrow(id, 30 days);
        vm.warp(block.timestamp + 3650 days); // deep past expiry + grace, deep late accrual

        vm.prank(guardian);
        loan.freeze();
        loan.liquidate(id); // permissionless settlement proceeds under freeze
        assertEq(loan.debtOf(id), 0, "liquidation settled while frozen");
    }

    function test_RenounceIsOneWayAndRequiresUnfrozen() public {
        vm.startPrank(guardian);
        loan.freeze();
        vm.expectRevert(Guarded.NotWhileFrozen.selector);
        loan.renounceGuardian(); // can't freeze-and-abandon: no permanent brick

        loan.unfreeze();
        loan.renounceGuardian();
        vm.stopPrank();
        assertEq(loan.guardian(), address(0));

        vm.prank(guardian);
        vm.expectRevert(Guarded.NotGuardian.selector);
        loan.freeze(); // graduated to fully immutable — unfreezable forever
    }
}
