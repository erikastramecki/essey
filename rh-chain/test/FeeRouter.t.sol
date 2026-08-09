// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeRouter} from "../src/market/FeeRouter.sol";

contract MockUSDG is ERC20 {
  constructor() ERC20("Mock USDG", "USDG") {}
  function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract FeeRouterTest is Test {
  MockUSDG usdg;
  address bell = address(0xBE11);
  address bankroll = address(0xBA5E);
  address ops = address(0x0955);
  address keeper = address(0xC0FFEE);

  // The shipped split: 60% Bell revenue-share / 20% bankroll / 20% ops (ops = remainder).
  uint256 constant BELL_BPS = 6000;
  uint256 constant BANKROLL_BPS = 2000;

  function setUp() public {
    usdg = new MockUSDG();
  }

  function _router() internal returns (FeeRouter r) {
    r = new FeeRouter(IERC20(address(usdg)), bell, bankroll, ops, BELL_BPS, BANKROLL_BPS);
  }

  /// Emitters fund the router by a plain transfer (mirrors how fees actually arrive), then flush() splits.
  function _feed(FeeRouter r, uint256 amt) internal {
    usdg.mint(address(r), amt);
  }

  // -------------------------------------------------------------- construction

  function test_ShapesPinnedAtDeploy() public {
    FeeRouter r = _router();
    assertEq(address(r.token()), address(usdg));
    assertEq(r.bell(), bell);
    assertEq(r.bankroll(), bankroll);
    assertEq(r.ops(), ops);
    assertEq(r.bellBps(), BELL_BPS);
    assertEq(r.bankrollBps(), BANKROLL_BPS);
    assertEq(r.opsBps(), 2000, "ops derived as remainder to BPS");
    assertEq(r.bellBps() + r.bankrollBps() + r.opsBps(), r.BPS(), "three shares sum to exactly BPS");
  }

  function test_RejectsZeroAddresses() public {
    vm.expectRevert(FeeRouter.ZeroAddress.selector);
    new FeeRouter(IERC20(address(0)), bell, bankroll, ops, BELL_BPS, BANKROLL_BPS);
    vm.expectRevert(FeeRouter.ZeroAddress.selector);
    new FeeRouter(IERC20(address(usdg)), address(0), bankroll, ops, BELL_BPS, BANKROLL_BPS);
    vm.expectRevert(FeeRouter.ZeroAddress.selector);
    new FeeRouter(IERC20(address(usdg)), bell, address(0), ops, BELL_BPS, BANKROLL_BPS);
    vm.expectRevert(FeeRouter.ZeroAddress.selector);
    new FeeRouter(IERC20(address(usdg)), bell, bankroll, address(0), BELL_BPS, BANKROLL_BPS);
  }

  /// A destination equal to the router's own (about-to-be-deployed) address is rejected — no leak-to-self.
  function test_RejectsSelfDestination() public {
    address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
    vm.expectRevert(FeeRouter.SelfDestination.selector);
    new FeeRouter(IERC20(address(usdg)), next, bankroll, ops, BELL_BPS, BANKROLL_BPS);
  }

  function test_RejectsBadSplits() public {
    // a zero share (dead destination)
    vm.expectRevert(FeeRouter.BadSplit.selector);
    new FeeRouter(IERC20(address(usdg)), bell, bankroll, ops, 0, BANKROLL_BPS);
    vm.expectRevert(FeeRouter.BadSplit.selector);
    new FeeRouter(IERC20(address(usdg)), bell, bankroll, ops, BELL_BPS, 0);
    // bell + bankroll == BPS leaves ops at 0
    vm.expectRevert(FeeRouter.BadSplit.selector);
    new FeeRouter(IERC20(address(usdg)), bell, bankroll, ops, 8000, 2000);
    // bell + bankroll > BPS would underflow the ops share
    vm.expectRevert(FeeRouter.BadSplit.selector);
    new FeeRouter(IERC20(address(usdg)), bell, bankroll, ops, 9000, 2000);
    // a ~2^256 share must not overflow-wrap the sum check past its guard — each share is bounded < BPS first
    vm.expectRevert(FeeRouter.BadSplit.selector);
    new FeeRouter(IERC20(address(usdg)), bell, bankroll, ops, type(uint256).max, 2);
    vm.expectRevert(FeeRouter.BadSplit.selector);
    new FeeRouter(IERC20(address(usdg)), bell, bankroll, ops, 2, type(uint256).max);
  }

  // -------------------------------------------------------------- flush math

  function test_SplitsExactlyOnCleanAmount() public {
    FeeRouter r = _router();
    _feed(r, 1000);
    (uint256 toBell, uint256 toBankroll, uint256 toOps) = r.flush();
    assertEq(toBell, 600, "60%");
    assertEq(toBankroll, 200, "20%");
    assertEq(toOps, 200, "20%");
    assertEq(usdg.balanceOf(bell), 600);
    assertEq(usdg.balanceOf(bankroll), 200);
    assertEq(usdg.balanceOf(ops), 200);
    assertEq(usdg.balanceOf(address(r)), 0, "router fully drained");
  }

  /// Integer-division dust folds into the Bell's cut, so the whole balance always leaves and Seat holders
  /// (never ops/bankroll) absorb the rounding — and back-to-protocol is never short-changed.
  function test_DustFoldsIntoBell_wholeBalanceLeaves() public {
    FeeRouter r = _router();
    _feed(r, 7); // 7*2000/10000 = 1 (bankroll), 1 (ops); bell = 7-1-1 = 5 (>= its 4.2 floor share)
    (uint256 toBell, uint256 toBankroll, uint256 toOps) = r.flush();
    assertEq(toBankroll, 1);
    assertEq(toOps, 1);
    assertEq(toBell, 5, "bell absorbs the rounding remainder");
    assertEq(toBell + toBankroll + toOps, 7, "conservation: nothing stranded");
    assertEq(usdg.balanceOf(address(r)), 0);
    assertGe(toBell, (7 * BELL_BPS) / 10000, "bell never below its floor share");
  }

  function test_FlushZeroBalanceIsNoOp() public {
    FeeRouter r = _router();
    (uint256 a, uint256 b, uint256 c) = r.flush(); // nothing fed
    assertEq(a + b + c, 0, "no-op, no revert");
  }

  /// flush() is idempotent and safe to re-call: a second flush after a fresh deposit splits only the new funds.
  function test_IdempotentAcrossDeposits() public {
    FeeRouter r = _router();
    _feed(r, 1000);
    r.flush();
    (, , uint256 ops1) = (uint256(0), uint256(0), usdg.balanceOf(ops));
    r.flush(); // immediate re-call, empty -> no-op
    assertEq(usdg.balanceOf(ops), ops1, "re-flush on empty changes nothing");
    _feed(r, 500);
    r.flush();
    assertEq(usdg.balanceOf(bell), 600 + 300, "second batch split on top");
    assertEq(usdg.balanceOf(bankroll), 200 + 100);
    assertEq(usdg.balanceOf(ops), 200 + 100);
  }

  /// Anyone can flush — it is a permissionless keeper action with no privileged caller.
  function test_PermissionlessFlush() public {
    FeeRouter r = _router();
    _feed(r, 1000);
    vm.prank(keeper);
    r.flush();
    assertEq(usdg.balanceOf(bell), 600, "a stranger flushed; funds still went only to the pinned sinks");
  }

  // -------------------------------------------------------------- fuzz

  /// For ANY balance: the whole balance leaves (conservation), ops/bankroll never exceed their bps share, and
  /// the Bell always gets at least its floor share (it only ever gains from dust). Back-to-protocol >= 80%.
  function testFuzz_conservationAndBounds(uint256 amt) public {
    amt = bound(amt, 0, 1e30);
    FeeRouter r = _router();
    _feed(r, amt);
    (uint256 toBell, uint256 toBankroll, uint256 toOps) = r.flush();

    assertEq(toBell + toBankroll + toOps, amt, "conservation: exactly the balance is distributed");
    assertEq(usdg.balanceOf(address(r)), 0, "router always fully drained");
    assertLe(toBankroll, (amt * BANKROLL_BPS) / 10000, "bankroll never over its share");
    assertLe(toOps, (amt * 2000) / 10000, "ops never over its share");
    assertGe(toBell, (amt * BELL_BPS) / 10000, "bell at least its floor share (gains dust)");
    // back-to-protocol (bell + bankroll) is always >= 80% of the fee
    assertGe(toBell + toBankroll, (amt * 8000) / 10000, "ops share capped at ~20%");
  }
}
