// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SeatReserve} from "../src/market/SeatReserve.sol";

contract MockUSDG is ERC20 {
  constructor() ERC20("Mock USDG", "USDG") {}
  function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// Mirrors Seat.sol: a fixed maxSupply the reserve reads, and a mint that hard-reverts past it - so the number
/// of Seats in existence can never exceed maxSupply (= the reserve's backedSupply).
contract MockSeat is ERC721 {
  uint256 public immutable maxSupply;
  uint256 public totalMinted;
  error SoldOut();
  constructor(uint256 maxSupply_) ERC721("Seat", "SEAT") { maxSupply = maxSupply_; }
  function mint(address to) external returns (uint256 id) {
    if (totalMinted >= maxSupply) revert SoldOut();
    id = ++totalMinted;
    _mint(to, id);
  }
}

contract SeatReserveTest is Test {
  MockUSDG usdg;
  address alice = address(0xA11CE);
  address bob = address(0xB0B);

  function setUp() public {
    usdg = new MockUSDG();
  }

  /// A reserve backing a Seat collection capped at `cap`. backedSupply is read from the Seat on-chain.
  function _reserve(uint256 cap) internal returns (SeatReserve res, MockSeat seat) {
    seat = new MockSeat(cap);
    res = new SeatReserve(IERC20(address(usdg)), IERC721(address(seat)));
    assertEq(res.backedSupply(), cap, "backedSupply pinned to the Seat cap on-chain");
  }

  function _fund(SeatReserve res, uint256 amt) internal {
    usdg.mint(address(this), amt);
    usdg.approve(address(res), amt);
    res.fund(amt);
  }

  function test_FloorRisesWithFunding() public {
    (SeatReserve res,) = _reserve(2222);
    assertEq(res.floorPerSeat(), 0, "empty reserve, no floor");
    _fund(res, 2222);
    assertEq(res.floorPerSeat(), 1, "floor = reserve / backedSupply");
    _fund(res, 2222);
    assertEq(res.floorPerSeat(), 2, "funding raises the floor for everyone");
  }

  function test_RedeemPaysFloor_locksSeat_forfeitsMembership() public {
    (SeatReserve res, MockSeat seat) = _reserve(2222);
    _fund(res, 4444); // floor = 2 per seat
    uint256 id = seat.mint(alice);
    vm.prank(alice);
    seat.approve(address(res), id);

    uint256 before = usdg.balanceOf(alice);
    vm.prank(alice);
    uint256 paid = res.redeem(id);

    assertEq(paid, 2, "paid the floor");
    assertEq(usdg.balanceOf(alice) - before, 2, "alice got USDG");
    assertEq(seat.ownerOf(id), address(res), "the Seat is locked in the reserve (membership forfeited)");
    assertEq(res.backedSupply(), 2221, "backedSupply decremented");
  }

  /// The floor is invariant under redemption (never drops for remaining holders) and the reserve is exactly
  /// solvent - total paid across ALL redemptions never exceeds what was funded.
  function test_FloorInvariant_and_ExactSolvency() public {
    (SeatReserve res, MockSeat seat) = _reserve(3);
    _fund(res, 100); // floor = 33 (100/3)

    uint256[3] memory ids;
    for (uint256 i = 0; i < 3; i++) { ids[i] = seat.mint(alice); vm.prank(alice); seat.approve(address(res), ids[i]); }

    uint256 prevFloor = 0;
    uint256 totalPaid = 0;
    for (uint256 i = 0; i < 3; i++) {
      uint256 floorNow = res.floorPerSeat();
      assertGe(floorNow, prevFloor, "floor never drops for remaining holders");
      prevFloor = floorNow;
      vm.prank(alice);
      totalPaid += res.redeem(ids[i]);
    }
    assertEq(totalPaid, 100, "total paid == funded (exactly solvent, nothing over-paid)");
    assertEq(res.reserve(), 0, "reserve fully drained");
    assertEq(res.backedSupply(), 0, "all backed Seats redeemed");
  }

  function test_OnlyOwnerCanRedeem() public {
    (SeatReserve res, MockSeat seat) = _reserve(2222);
    _fund(res, 2222);
    uint256 id = seat.mint(alice);
    vm.prank(alice);
    seat.approve(address(res), id);
    vm.prank(bob);
    vm.expectRevert(SeatReserve.NotSeatOwner.selector);
    res.redeem(id);
  }

  function test_RedeemRequiresApproval() public {
    (SeatReserve res, MockSeat seat) = _reserve(2222);
    _fund(res, 2222);
    uint256 id = seat.mint(alice);
    vm.prank(alice); // no approval given
    vm.expectRevert(); // ERC721: caller is not token owner or approved
    res.redeem(id);
  }

  function test_NoFloorReverts_whenReserveThin() public {
    (SeatReserve res, MockSeat seat) = _reserve(2222); // floor = reserve/2222; fund 1 -> floor 0
    _fund(res, 1);
    uint256 id = seat.mint(alice);
    vm.prank(alice);
    seat.approve(address(res), id);
    vm.prank(alice);
    vm.expectRevert(SeatReserve.NoFloor.selector);
    res.redeem(id);
    // ...but it's recoverable: fund() is permissionless, so topping up unblocks redemption.
    _fund(res, 3000);
    vm.prank(alice);
    assertGt(res.redeem(id), 0, "recoverable - a funded reserve pays the floor");
  }

  /// The theft case (more Seats in existence than backedSupply) is now STRUCTURALLY IMPOSSIBLE: backedSupply is
  /// the Seat's maxSupply, and mint hard-reverts past maxSupply - so a redeemer can never drain a share funded
  /// for a Seat that can't yet redeem. (Pre-hardening this depended on deploy discipline; now on the contract.)
  function test_CannotMintMoreThanBacked_theftCaseImpossible() public {
    (SeatReserve res, MockSeat seat) = _reserve(2);
    assertEq(res.backedSupply(), 2);
    seat.mint(alice);
    seat.mint(bob);
    vm.expectRevert(MockSeat.SoldOut.selector);
    seat.mint(alice); // cannot create a 3rd Seat to attack the 2-backed reserve
  }

  /// Under-minted disclosure property: with a cap of 100 but only 1 Seat minted, the floor is reserve/100
  /// (diluted across unminted Seats) and the unredeemed backing stays locked. Solvent, never over-paid.
  function test_UnderMinted_dilutesAndStrands_butStaysSolvent() public {
    (SeatReserve res, MockSeat seat) = _reserve(100);
    _fund(res, 1000); // floor = 10 (1000/100), NOT 1000 - diluted across the 100-cap
    assertEq(res.floorPerSeat(), 10, "floor is reserve/maxSupply, not reserve/minted");
    uint256 id = seat.mint(alice);
    vm.prank(alice); seat.approve(address(res), id);
    vm.prank(alice); assertEq(res.redeem(id), 10, "the one holder redeems their diluted share");
    assertEq(res.reserve(), 990, "the rest stays locked (stranded across unminted Seats) - never insolvent");
  }

  /// A direct USDG transfer (bypassing fund()) raises the floor the same way - and is just as unruggable.
  function test_DirectDonationRaisesFloor() public {
    (SeatReserve res, MockSeat seat) = _reserve(10);
    usdg.mint(address(this), 100);
    usdg.transfer(address(res), 100); // plain transfer, not fund()
    assertEq(res.floorPerSeat(), 10, "donation counts toward the floor");
    uint256 id = seat.mint(alice);
    vm.prank(alice); seat.approve(address(res), id);
    vm.prank(alice); assertEq(res.redeem(id), 10, "redeemable against a donated reserve");
  }

  /// No sequence of funding + redemptions ever pays out more than was funded, and the floor never drops - even
  /// when funding happens BETWEEN redemptions (floor rising mid-sequence).
  function testFuzz_solventAndNonDecreasing(uint96 fundAmt, uint8 backed, uint8 redeems, uint96 midFund) public {
    uint256 b = uint256(bound(backed, 1, 200));
    (SeatReserve res, MockSeat seat) = _reserve(b);
    uint256 amt = uint256(bound(fundAmt, 1, 1e24));
    _fund(res, amt);
    uint256 totalIn = amt;

    uint256 r = uint256(bound(redeems, 0, b));
    uint256 prevFloor = 0;
    uint256 totalPaid = 0;
    for (uint256 i = 0; i < r; i++) {
      if (i == r / 2 && midFund > 0) { _fund(res, midFund); totalIn += midFund; } // fund mid-sequence
      uint256 floorNow = res.floorPerSeat();
      if (floorNow == 0) break; // reserve too thin to pay even 1 unit per seat - redemption correctly halts
      assertGe(floorNow, prevFloor, "floor monotonically non-decreasing");
      prevFloor = floorNow;
      uint256 id = seat.mint(alice);
      vm.prank(alice); seat.approve(address(res), id);
      vm.prank(alice); totalPaid += res.redeem(id);
    }
    assertLe(totalPaid, totalIn, "never pays out more than was funded");
    assertEq(res.reserve(), totalIn - totalPaid, "reserve accounting exact");
  }
}
