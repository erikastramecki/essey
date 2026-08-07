// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RecurringBuy, IStockConverter} from "../src/market/RecurringBuy.sol";

contract MockUSDG is ERC20 {
  constructor() ERC20("Mock USDG", "USDG") {}
  function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockStock is ERC20 {
  constructor() ERC20("Apple", "AAPL") {}
  function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// Mirrors StockConverter.convert: pulls `amountIn` USDG from the caller, delivers stock (1:1 here) straight to
/// `recipient`. `closed` simulates off-session / stale-feed: convert reverts, so a fill reverts and retries.
contract MockConverter is IStockConverter {
  IERC20 public usdg;
  MockStock public stock;
  bool public closed;
  bool public supported = true;
  error SessionClosed();

  constructor(IERC20 _usdg, MockStock _stock) { usdg = _usdg; stock = _stock; }
  function setClosed(bool c) external { closed = c; }
  function setSupported(bool s) external { supported = s; }
  function isSupported(address) external view returns (bool) { return supported; }

  function convert(uint256 amountIn, address, address recipient) external returns (uint256) {
    if (closed) revert SessionClosed();
    usdg.transferFrom(msg.sender, address(this), amountIn); // pull base from the caller (RecurringBuy)
    stock.mint(recipient, amountIn); // deliver stock straight to the owner (1:1 mock rate)
    return amountIn;
  }
}

contract RecurringBuyTest is Test {
  RecurringBuy rb;
  MockUSDG usdg;
  MockStock aapl;
  MockConverter conv;
  address user = address(0x5EA7);
  address keeper = address(0xC0FFEE);

  function setUp() public {
    usdg = new MockUSDG();
    aapl = new MockStock();
    conv = new MockConverter(IERC20(address(usdg)), aapl);
    rb = new RecurringBuy(IERC20(address(usdg)), IStockConverter(address(conv)));

    usdg.mint(user, 1000 ether);
    vm.prank(user);
    usdg.approve(address(rb), type(uint256).max); // funds stay in the wallet; allowance lets fills pull one at a time
  }

  function _create(uint128 perFill, uint64 everySec, uint32 total) internal returns (uint256 id) {
    vm.prank(user);
    id = rb.create(address(aapl), perFill, everySec, total);
  }

  function test_Create_firstFillDueImmediately() public {
    uint256 id = _create(100 ether, 1 days, 5);
    (address owner,,,,, uint32 filled, uint64 nextDue,) = rb.schedules(id);
    assertEq(owner, user);
    assertEq(filled, 0);
    assertEq(nextDue, uint64(block.timestamp), "first fill eligible now");
    assertTrue(rb.dueNow(id));
  }

  function test_ExecuteFill_nonCustodial_deliversStock_advancesGrid() public {
    uint256 id = _create(100 ether, 1 days, 3);
    uint256 userUsdgBefore = usdg.balanceOf(user);

    vm.prank(keeper); // PERMISSIONLESS: a keeper (not the owner) executes
    rb.executeFill(id);

    assertEq(usdg.balanceOf(user), userUsdgBefore - 100 ether, "exactly one fill pulled from the owner's wallet");
    assertEq(aapl.balanceOf(user), 100 ether, "stock delivered straight to the owner");
    assertEq(usdg.balanceOf(address(rb)), 0, "RecurringBuy holds no funds at rest (non-custodial)");
    (,,,,, uint32 filled, uint64 nextDue,) = rb.schedules(id);
    assertEq(filled, 1);
    assertEq(nextDue, uint64(block.timestamp) + 1 days, "grid advanced one interval");
    assertFalse(rb.dueNow(id), "not due again until nextDue");
  }

  function test_NotDue_reverts() public {
    uint256 id = _create(100 ether, 1 days, 3);
    vm.prank(keeper); rb.executeFill(id); // now nextDue is +1 day
    vm.prank(keeper);
    vm.expectRevert(RecurringBuy.NotDue.selector);
    rb.executeFill(id);
  }

  /// Skip-not-backfill: a keeper that comes back 3 days late does ONE fill and jumps nextDue past the missed
  /// slots to the next future slot on the original phase — never a lump catch-up.
  function test_SkipNotBackfill() public {
    uint256 id = _create(100 ether, 1 days, 10);
    uint64 start = uint64(block.timestamp);
    vm.warp(start + 3 days + 1); // keeper was down; now 3+ days past the first due
    vm.prank(keeper); rb.executeFill(id);
    (,,,,, uint32 filled, uint64 nextDue,) = rb.schedules(id);
    assertEq(filled, 1, "only ONE fill, not four (missed slices lost, no backfill)");
    // next future slot on the 1-day grid anchored at `start`: start + 4 days
    assertEq(nextDue, start + 4 days, "grid jumped past the elapsed periods to the next future slot");
  }

  /// Closed session / stale feed: convert reverts -> the whole fill reverts, NO state change -> it retries and
  /// succeeds once the market reopens. (The core "safe to miss, never mis-execute" property.)
  function test_ClosedSession_revertsWholeFill_thenRetries() public {
    uint256 id = _create(100 ether, 1 days, 3);
    conv.setClosed(true);
    vm.prank(keeper);
    vm.expectRevert(MockConverter.SessionClosed.selector);
    rb.executeFill(id);
    // nothing changed: no fill, no grid advance, no funds moved
    (,,,,, uint32 filled,,) = rb.schedules(id);
    assertEq(filled, 0, "no slot consumed on a reverted fill");
    assertEq(aapl.balanceOf(user), 0);
    assertEq(usdg.balanceOf(user), 1000 ether);
    // market reopens -> the same due fill now lands
    conv.setClosed(false);
    vm.prank(keeper); rb.executeFill(id);
    assertEq(aapl.balanceOf(user), 100 ether, "fill retried successfully once open");
  }

  function test_Cancel_ownerOnly_thenInactive() public {
    uint256 id = _create(100 ether, 1 days, 3);
    vm.prank(keeper);
    vm.expectRevert(RecurringBuy.NotOwner.selector);
    rb.cancel(id);
    vm.prank(user); rb.cancel(id);
    vm.prank(keeper);
    vm.expectRevert(RecurringBuy.NotActive.selector);
    rb.executeFill(id);
  }

  function test_RevokingAllowance_neutralizes() public {
    uint256 id = _create(100 ether, 1 days, 3);
    vm.prank(user);
    usdg.approve(address(rb), 0); // revoke — the schedule can no longer pull anything
    vm.prank(keeper);
    vm.expectRevert(); // ERC20InsufficientAllowance
    rb.executeFill(id);
  }

  function test_CompletesAtTotalFills() public {
    uint256 id = _create(100 ether, 1 days, 2);
    vm.prank(keeper); rb.executeFill(id);
    vm.warp(block.timestamp + 1 days);
    vm.prank(keeper); rb.executeFill(id); // 2nd and last
    (,,,,, uint32 filled,,) = rb.schedules(id);
    assertEq(filled, 2);
    vm.warp(block.timestamp + 1 days);
    vm.prank(keeper);
    vm.expectRevert(RecurringBuy.NotActive.selector); // done
    rb.executeFill(id);
  }

  function test_BadParams() public {
    vm.startPrank(user);
    vm.expectRevert(RecurringBuy.BadParams.selector); rb.create(address(aapl), 0, 1 days, 3); // zero amount
    vm.expectRevert(RecurringBuy.BadParams.selector); rb.create(address(aapl), 1 ether, 1 days, 0); // zero fills
    vm.expectRevert(RecurringBuy.BadParams.selector); rb.create(address(aapl), 1 ether, 1 days, 1001); // > MAX_FILLS
    vm.expectRevert(RecurringBuy.BadParams.selector); rb.create(address(aapl), 1 ether, 59, 3); // interval too short
    vm.expectRevert(RecurringBuy.BadParams.selector); rb.create(address(aapl), 1 ether, 91 days, 3); // interval too long
    vm.stopPrank();
    conv.setSupported(false);
    vm.prank(user);
    vm.expectRevert(RecurringBuy.StockNotSupported.selector); rb.create(address(aapl), 1 ether, 1 days, 3);
  }

  /// A permissionless executor can never make a fill worse: the mock (like the real converter) delivers a
  /// floor-bounded output regardless of who calls, and only when due. Any caller advances the OWNER's schedule
  /// as intended — there is no way to redirect funds or over-pull.
  function test_PermissionlessExecutor_cannotHarm() public {
    uint256 id = _create(100 ether, 1 days, 3);
    vm.prank(address(0xBEEF)); // a random third party
    rb.executeFill(id);
    assertEq(aapl.balanceOf(user), 100 ether, "stock still goes to the owner, not the caller");
    assertEq(aapl.balanceOf(address(0xBEEF)), 0, "the executor gets nothing");
  }
}
