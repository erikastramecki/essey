// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EsseyReserve} from "../src/market/EsseyReserve.sol";

/// USDG-style 6-decimal collateral: the ONLY cross-decimal asset the reserve holds (RH Stock Tokens
/// are 18-dec). claimBase is an 18-dec $ESSEY genesis supply, so payShare divides a 6-dec balance by
/// an 18-dec denominator — the case no existing mock covers.
contract MockUSDG is ERC20 {
  constructor() ERC20("USDG", "USDG") {}
  function decimals() public pure override returns (uint8) {
    return 6;
  }
  function mint(address to, uint256 a) external {
    _mint(to, a);
  }
}

contract MockStock18 is ERC20 {
  constructor(string memory n) ERC20(n, n) {}
  function mint(address to, uint256 a) external {
    _mint(to, a);
  }
}

contract MockEssey is ERC20 {
  constructor(uint256 supply) ERC20("ESSEY", "ESSEY") {
    if (supply > 0) _mint(msg.sender, supply);
  }
  function burn(uint256 a) external {
    _burn(msg.sender, a);
  }
}

contract EsseyReserveDecimalsTest is Test {
  uint256 constant BASE = 1_000_000e18; // 18-dec claimBase
  uint256 constant WEIGHT_BPS = 9_500; // BPS - EXIT_FEE_BPS, mirrors EsseyReserve.sol:53-54,147

  MockEssey essey;
  EsseyReserve res;
  MockUSDG usdg;
  MockStock18 nvda;

  address treasury = address(0x7);
  address alice = address(0xA11CE);
  address bob = address(0xB0B);

  function setUp() public {
    vm.prank(treasury);
    essey = new MockEssey(BASE);
    res = new EsseyReserve(IERC20(address(essey)));
    usdg = new MockUSDG();
    nvda = new MockStock18("NVDA");
    vm.startPrank(treasury);
    essey.transfer(alice, 100_000e18);
    essey.transfer(bob, 100_000e18);
    vm.stopPrank();
  }

  function _fundUsdg(uint256 amt) internal {
    usdg.mint(address(this), amt);
    usdg.approve(address(res), amt);
    res.fund(address(usdg), amt);
  }

  function _fundNvda(uint256 amt) internal {
    nvda.mint(address(this), amt);
    nvda.approve(address(res), amt);
    res.fund(address(nvda), amt);
  }

  function _redeem(address who, uint256 amt) internal returns (uint256 id) {
    vm.startPrank(who);
    essey.approve(address(res), amt);
    id = res.redeem(amt);
    vm.stopPrank();
  }

  function _weight(uint256 e) internal pure returns (uint256) {
    return e * WEIGHT_BPS / 10_000;
  }

  // 1000 USDG (1000e6), 1% redeem, weight 0.95% -> exactly 9.5 USDG in 6-dec units.
  function test_usdg6_claim_pays_exact_proportional_slice() public {
    _fundUsdg(1_000e6);
    uint256 id = _redeem(alice, 10_000e18);
    vm.prank(alice);
    res.claim(id, address(usdg));
    assertEq(usdg.balanceOf(alice), 9_500_000); // 9.5 USDG, 6-dec
    assertEq(usdg.balanceOf(address(res)), 1_000e6 - 9_500_000);
  }

  // SOLVENCY (invariant a): the reserve pays out the exact floored slices and never more than it holds.
  function test_usdg6_solvency_two_claimants_never_overdraw() public {
    _fundUsdg(1_000e6);
    uint256 idA = _redeem(alice, 30_000e18);
    uint256 idB = _redeem(bob, 60_000e18);
    vm.prank(alice);
    res.claim(idA, address(usdg));
    vm.prank(bob);
    res.claim(idB, address(usdg));

    uint256 wA = _weight(30_000e18);
    uint256 wB = _weight(60_000e18);
    uint256 expectA = 1_000e6 * wA / BASE;
    uint256 expectB = (1_000e6 - expectA) * wB / (BASE - wA);
    assertEq(usdg.balanceOf(alice), expectA);
    assertEq(usdg.balanceOf(bob), expectB);
    uint256 paid = usdg.balanceOf(alice) + usdg.balanceOf(bob);
    assertLe(paid, 1_000e6);
    assertEq(usdg.balanceOf(address(res)), 1_000e6 - paid);
  }

  // ROUNDING conservative (invariant b): 1 unit of USDG backing a 0.95% weight floors to 0 — the
  // claimer gets nothing and the unit stays as over-collateralisation. A ceil would leak it out.
  function test_usdg6_dust_floors_to_pool_claimer_gets_zero() public {
    _fundUsdg(1);
    uint256 id = _redeem(alice, 10_000e18);
    vm.prank(alice);
    res.claim(id, address(usdg));
    assertEq(usdg.balanceOf(alice), 0);
    assertEq(res.reserveOf(address(usdg)), 1);
  }

  // A sub-payout leg (fund 1 unit) returns 0 WITHOUT consuming; once real balance arrives the same
  // receipt pays. Self-heal proven on a 6-dec token (invariant c).
  function test_usdg6_zero_payout_leg_not_consumed_then_heals() public {
    _fundUsdg(1);
    uint256 id = _redeem(alice, 10_000e18);
    vm.prank(alice);
    res.claim(id, address(usdg));
    assertFalse(res.claimed(id, address(usdg)));
    assertEq(res.claimedShares(address(usdg)), 0);

    _fundUsdg(1_000e6);
    vm.prank(alice);
    res.claim(id, address(usdg));
    assertEq(usdg.balanceOf(alice), 1_000_000_001 * _weight(10_000e18) / BASE);
    assertTrue(res.claimed(id, address(usdg)));
  }

  // Never-funded 6-dec leg: payout 0, leg stays retryable.
  function test_usdg6_unfunded_leg_retryable() public {
    uint256 id = _redeem(alice, 10_000e18);
    vm.prank(alice);
    res.claim(id, address(usdg));
    assertFalse(res.claimed(id, address(usdg)));
    _fundUsdg(1_000e6);
    vm.prank(alice);
    res.claim(id, address(usdg));
    assertEq(usdg.balanceOf(alice), 9_500_000);
  }

  // MIXED basket (invariant d): one receipt claims a 6-dec leg and an 18-dec leg in a single call.
  // Each divides by the same 18-dec claimBase; neither over-pays nor underflows.
  function test_usdg6_mixed_with_18dec_claimBase_no_overpay() public {
    _fundUsdg(1_000e6);
    _fundNvda(1_000e18);
    uint256 id = _redeem(alice, 10_000e18);
    address[] memory toks = new address[](2);
    toks[0] = address(usdg);
    toks[1] = address(nvda);
    vm.prank(alice);
    res.claimMany(id, toks);

    uint256 w = _weight(10_000e18);
    assertEq(usdg.balanceOf(alice), 1_000e6 * w / BASE); // 9.5 USDG
    assertEq(nvda.balanceOf(alice), 1_000e18 * w / BASE); // 9.5 NVDA
    assertEq(usdg.balanceOf(address(res)), 1_000e6 - usdg.balanceOf(alice));
    assertEq(nvda.balanceOf(address(res)), 1_000e18 - nvda.balanceOf(alice));
  }

  // FUZZ: over realistic 6-dec funded amounts and weights, solvency holds and no claimer is over-paid.
  // alice claims first against the full balance, so her leg is the exact floor — an exact no-overpay
  // pin; bob's leg is the contract's exact second-claim arithmetic; the sum never exceeds the balance.
  function testFuzz_usdg6_solvency_and_no_overpay(uint256 eA, uint256 eB, uint256 dep) public {
    eA = bound(eA, 1e18, 350_000e18);
    eB = bound(eB, 1e18, 350_000e18);
    dep = bound(dep, 1, 1_000_000_000e6); // up to 1B USDG in 6-dec units
    vm.startPrank(treasury);
    essey.transfer(alice, eA);
    essey.transfer(bob, eB);
    vm.stopPrank();

    _fundUsdg(dep);
    uint256 idA = _redeem(alice, eA);
    uint256 idB = _redeem(bob, eB);
    vm.prank(alice);
    res.claim(idA, address(usdg));
    vm.prank(bob);
    res.claim(idB, address(usdg));

    uint256 wA = _weight(eA);
    uint256 wB = _weight(eB);
    uint256 expectA = dep * wA / BASE;
    uint256 consumedA = expectA > 0 ? wA : 0; // a floored-to-zero leg is NOT consumed (:170-172)
    uint256 expectB = (dep - expectA) * wB / (BASE - consumedA);
    assertEq(usdg.balanceOf(alice), expectA); // floor, never rounded up
    assertEq(usdg.balanceOf(bob), expectB);
    uint256 paid = usdg.balanceOf(alice) + usdg.balanceOf(bob);
    assertLe(paid, dep); // solvency
    assertEq(usdg.balanceOf(address(res)), dep - paid); // dust retained by the pool
  }
}
