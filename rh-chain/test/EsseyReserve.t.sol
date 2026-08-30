// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EsseyReserve} from "../src/market/EsseyReserve.sol";

// ---------------------------------------------------------------- mocks

contract MockStock is ERC20 {
  constructor(string memory n) ERC20(n, n) {}
  function mint(address to, uint256 a) external {
    _mint(to, a);
  }
}

/// Burnable claim token with a settable genesis supply so claimBase is a clean round number.
contract MockEssey is ERC20 {
  constructor(uint256 supply) ERC20("ESSEY", "ESSEY") {
    if (supply > 0) _mint(msg.sender, supply);
  }
  function burn(uint256 a) external {
    _burn(msg.sender, a);
  }
}

/// A claim token WITHOUT burn() — exercises the 0xdEaD supply-removal fallback in _remove.
contract MockNoBurnEssey is ERC20 {
  constructor(uint256 supply) ERC20("NB", "NB") {
    _mint(msg.sender, supply);
  }
}

/// A Robinhood-style stock that can PAUSE transfers — a claim must skip it, not brick, and stay retryable.
contract MockPausableStock is ERC20 {
  bool public paused;
  constructor() ERC20("PAUS", "PAUS") {}
  function mint(address to, uint256 a) external {
    _mint(to, a);
  }
  function setPaused(bool p) external {
    paused = p;
  }
  function _update(address from, address to, uint256 v) internal override {
    require(!paused, "paused");
    super._update(from, to, v);
  }
}

/// balanceOf REVERTS — must be swallowed inside payShare's self-call.
contract EvilBalanceOfStock is ERC20 {
  constructor() ERC20("EVIL", "EVIL") {}
  function mint(address to, uint256 a) external {
    _mint(to, a);
  }
  function balanceOf(address) public pure override returns (uint256) {
    revert("evil balanceOf");
  }
}

/// balanceOf returns uint256 max — the slice multiply overflows (Panic 0x11); must skip, not brick.
contract HugeBalanceStock is ERC20 {
  constructor() ERC20("HUGE", "HUGE") {}
  function mint(address to, uint256 a) external {
    _mint(to, a);
  }
  function balanceOf(address) public pure override returns (uint256) {
    return type(uint256).max;
  }
}

/// THE real drain vector (Auditor C-1): a malicious token that is ITSELF the owner of its receipt and
/// re-enters claim(id, self) during its own outbound transfer, in the window before the leg is consumed.
/// Must never pay more than one net slice — defended by CEI (consume before transfer) AND nonReentrant.
contract ReentrantOwnerStock is ERC20 {
  EsseyReserve public res;
  uint256 public rid;
  bool public armed;
  constructor() ERC20("ROWN", "ROWN") {}
  function mint(address to, uint256 a) external {
    _mint(to, a);
  }
  function setup(EsseyReserve r, uint256 receiptId) external {
    res = r;
    rid = receiptId;
    armed = true;
  }
  function attack() external {
    res.claim(rid, address(this));
  }
  function _update(address from, address to, uint256 v) internal override {
    if (armed && from == address(res)) {
      armed = false; // one-shot
      res.claim(rid, address(this)); // re-enter the SAME leg during its own inbound transfer
    }
    super._update(from, to, v);
  }
}

// ---------------------------------------------------------------- tests

contract EsseyReserveTest is Test {
  uint256 constant BASE = 1_000_000e18; // claimBase
  MockEssey essey;
  EsseyReserve res;
  MockStock nvda;
  MockStock aapl;

  address treasury = address(0x7);
  address alice = address(0xA11CE);
  address bob = address(0xB0B);

  function setUp() public {
    vm.prank(treasury);
    essey = new MockEssey(BASE); // all supply to treasury
    res = new EsseyReserve(IERC20(address(essey)));
    nvda = new MockStock("NVDA");
    aapl = new MockStock("AAPL");
    vm.startPrank(treasury);
    essey.transfer(alice, 100_000e18); // 10%
    essey.transfer(bob, 100_000e18); // 10%
    vm.stopPrank();
  }

  function _fund(MockStock t, uint256 amt) internal {
    t.mint(address(this), amt);
    t.approve(address(res), amt);
    res.fund(address(t), amt);
  }

  function _redeem(address who, uint256 amt) internal returns (uint256 id) {
    vm.startPrank(who);
    essey.approve(address(res), amt);
    id = res.redeem(amt);
    vm.stopPrank();
  }

  // ---- basics

  function test_claimBase_is_genesis_supply() public view {
    assertEq(res.claimBase(), BASE);
    assertEq(res.EXIT_FEE_BPS(), 500);
  }

  function test_redeem_burns_and_mints_receipt() public {
    uint256 supplyBefore = essey.totalSupply();
    uint256 id = _redeem(alice, 50_000e18);
    (address owner, uint256 e) = res.receipts(id);
    assertEq(owner, alice);
    assertEq(e, 50_000e18);
    assertEq(essey.totalSupply(), supplyBefore - 50_000e18); // genuinely burned
  }

  function test_redeem_zero_reverts() public {
    vm.prank(alice);
    vm.expectRevert(EsseyReserve.ZeroAmount.selector);
    res.redeem(0);
  }

  function test_fund_zero_reverts() public {
    vm.expectRevert(EsseyReserve.ZeroAmount.selector);
    res.fund(address(nvda), 0);
  }

  function test_constructor_rejects_zero_essey() public {
    vm.expectRevert(EsseyReserve.ZeroAddress.selector);
    new EsseyReserve(IERC20(address(0)));
  }

  function test_constructor_rejects_zero_supply() public {
    MockEssey empty = new MockEssey(0);
    vm.expectRevert(EsseyReserve.ZeroSupply.selector);
    new EsseyReserve(IERC20(address(empty)));
  }

  // ---- pro-rata correctness: burn X% -> claim 95% of X% of a token

  function test_claim_is_pro_rata_of_supply() public {
    _fund(nvda, 1_000e18);
    uint256 id = _redeem(alice, 10_000e18); // 1% of BASE, weight 0.95%
    vm.prank(alice);
    res.claim(id, address(nvda));
    assertEq(nvda.balanceOf(alice), 95e17); // 0.95% of 1000 = 9.5
    assertEq(nvda.balanceOf(address(res)), 1_000e18 - 95e17); // 5% + remainder stays
  }

  function test_double_claim_is_noop() public {
    _fund(nvda, 1_000e18);
    uint256 id = _redeem(alice, 10_000e18);
    vm.startPrank(alice);
    res.claim(id, address(nvda));
    uint256 bal = nvda.balanceOf(alice);
    res.claim(id, address(nvda));
    vm.stopPrank();
    assertEq(nvda.balanceOf(alice), bal);
  }

  // ---- order-independence: EXACT. Each receipt collects exactly weight/claimBase of the deposit,
  //      whoever claims first. (The buggy full-e denominator gave the later claimer a fee-ratchet bonus.)

  function test_order_independence_bob_first() public {
    _fund(nvda, 1_000e18);
    uint256 idA = _redeem(alice, 30_000e18); // weight 28,500 -> 28.5
    uint256 idB = _redeem(bob, 60_000e18); // weight 57,000 -> 57
    vm.prank(bob);
    res.claim(idB, address(nvda));
    vm.prank(alice);
    res.claim(idA, address(nvda));
    assertEq(nvda.balanceOf(bob), 57e18);
    assertEq(nvda.balanceOf(alice), 285e17);
  }

  function test_order_independence_alice_first() public {
    _fund(nvda, 1_000e18);
    uint256 idA = _redeem(alice, 30_000e18);
    uint256 idB = _redeem(bob, 60_000e18);
    vm.prank(alice);
    res.claim(idA, address(nvda));
    vm.prank(bob);
    res.claim(idB, address(nvda));
    assertEq(nvda.balanceOf(alice), 285e17); // identical to bob-first: order-independent
    assertEq(nvda.balanceOf(bob), 57e18);
  }

  // ---- the 5% exit fee cannot be dodged by splitting a redemption into many receipts

  function test_fee_not_gameable_by_splitting() public {
    MockStock a = new MockStock("A");
    MockStock b = new MockStock("B");
    a.mint(address(this), 1_000e18);
    b.mint(address(this), 1_000e18);
    a.approve(address(res), 1_000e18);
    b.approve(address(res), 1_000e18);
    res.fund(address(a), 1_000e18);
    res.fund(address(b), 1_000e18);

    // alice: 100k as ONE receipt, claims token A
    uint256 idOne = _redeem(alice, 100_000e18);
    vm.prank(alice);
    res.claim(idOne, address(a));

    // bob: same 100k split across 10 receipts, claims token B on each
    vm.startPrank(bob);
    essey.approve(address(res), 100_000e18);
    for (uint256 i = 0; i < 10; i++) {
      uint256 id = res.redeem(10_000e18);
      res.claim(id, address(b));
    }
    vm.stopPrank();

    // identical: splitting gains nothing; the reserve retains exactly 5% either way
    assertEq(a.balanceOf(alice), 95e18); // 0.95 * 100k/1M * 1000
    assertEq(b.balanceOf(bob), 95e18);
    assertEq(a.balanceOf(address(res)), b.balanceOf(address(res)));
  }

  // ---- deposits arriving between redeem and claim are shared pro-rata by outstanding receipts

  function test_deposit_between_redeem_and_claim() public {
    _fund(nvda, 1_000e18);
    uint256 id = _redeem(alice, 10_000e18);
    _fund(nvda, 1_000e18); // doubles to 2000 AFTER redeem
    vm.prank(alice);
    res.claim(id, address(nvda));
    assertEq(nvda.balanceOf(alice), 19e18); // 0.95% of the live 2000
  }

  // ---- unbounded tokens: no basket, no cap

  function test_unbounded_many_tokens_claimMany() public {
    uint256 N = 40;
    address[] memory toks = new address[](N);
    for (uint256 i = 0; i < N; i++) {
      MockStock s = new MockStock("S");
      s.mint(address(this), 1_000e18);
      s.approve(address(res), 1_000e18);
      res.fund(address(s), 1_000e18);
      toks[i] = address(s);
    }
    uint256 id = _redeem(alice, 10_000e18);
    vm.prank(alice);
    res.claimMany(id, toks);
    for (uint256 i = 0; i < N; i++) {
      assertEq(IERC20(toks[i]).balanceOf(alice), 95e17);
    }
  }

  function test_claimMany_dedups() public {
    _fund(nvda, 1_000e18);
    uint256 id = _redeem(alice, 10_000e18);
    address[] memory toks = new address[](3);
    toks[0] = address(nvda);
    toks[1] = address(nvda);
    toks[2] = address(nvda);
    vm.prank(alice);
    res.claimMany(id, toks);
    assertEq(nvda.balanceOf(alice), 95e17); // paid once
  }

  // ---- bad-token isolation, all retryable

  function test_paused_token_skipped_then_retryable() public {
    MockPausableStock paus = new MockPausableStock();
    paus.mint(address(this), 1_000e18);
    paus.approve(address(res), 1_000e18);
    res.fund(address(paus), 1_000e18);
    uint256 id = _redeem(alice, 10_000e18);

    paus.setPaused(true);
    vm.prank(alice);
    res.claim(id, address(paus)); // reverts inside -> rolled back, NOT consumed
    assertEq(paus.balanceOf(alice), 0);
    assertFalse(res.claimed(id, address(paus)));
    assertEq(res.claimedShares(address(paus)), 0);

    paus.setPaused(false);
    vm.prank(alice);
    res.claim(id, address(paus));
    assertEq(paus.balanceOf(alice), 95e17);
    assertTrue(res.claimed(id, address(paus)));
  }

  // Auditor C-2: a ZERO-payout leg (token not yet funded) must stay retryable once a balance arrives.
  function test_zero_payout_leg_retryable() public {
    MockStock late = new MockStock("LATE"); // balance 0
    uint256 id = _redeem(alice, 10_000e18);
    vm.prank(alice);
    res.claim(id, address(late)); // payout 0 -> NOT consumed
    assertFalse(res.claimed(id, address(late)));
    assertEq(res.claimedShares(address(late)), 0);
    _fund(late, 1_000e18);
    vm.prank(alice);
    res.claim(id, address(late)); // retry now pays
    assertEq(late.balanceOf(alice), 95e17);
    assertTrue(res.claimed(id, address(late)));
  }

  function test_evil_balanceOf_isolated() public {
    EvilBalanceOfStock evil = new EvilBalanceOfStock();
    evil.mint(address(res), 1_000e18);
    _fund(nvda, 1_000e18);
    uint256 id = _redeem(alice, 10_000e18);
    address[] memory toks = new address[](2);
    toks[0] = address(evil);
    toks[1] = address(nvda);
    vm.prank(alice);
    res.claimMany(id, toks);
    assertEq(nvda.balanceOf(alice), 95e17);
    assertFalse(res.claimed(id, address(evil)));
  }

  function test_huge_balance_overflow_isolated() public {
    HugeBalanceStock huge = new HugeBalanceStock();
    _fund(nvda, 1_000e18);
    uint256 id = _redeem(alice, 10_000e18);
    address[] memory toks = new address[](2);
    toks[0] = address(huge);
    toks[1] = address(nvda);
    vm.prank(alice);
    res.claimMany(id, toks);
    assertEq(nvda.balanceOf(alice), 95e17);
    assertFalse(res.claimed(id, address(huge)));
  }

  // Auditor C-1: the same-leg reentrancy drain. Malicious token owns its receipt and re-enters
  // claim(id, self) during its own transfer. Must never pull more than ONE net slice; accounting intact.
  // Fails only if BOTH the CEI consume-before-transfer AND the nonReentrant guard are removed.
  function test_reentrancy_same_leg_no_double_pay() public {
    ReentrantOwnerStock rown = new ReentrantOwnerStock();
    rown.mint(address(res), 1_000e18); // reserve holds ROWN to pay out
    vm.prank(treasury);
    essey.transfer(address(rown), 10_000e18);
    vm.prank(address(rown));
    essey.approve(address(res), 10_000e18);
    vm.prank(address(rown));
    uint256 id = res.redeem(10_000e18); // receipt owned by the token itself
    rown.setup(res, id);
    rown.attack();
    assertLe(rown.balanceOf(address(rown)), 95e17); // at most one net slice — no double-pay/drain
    assertLe(res.claimedShares(address(rown)), 9_500e18); // weight consumed at most once
  }

  // ---- access control

  function test_only_owner_claims() public {
    _fund(nvda, 1_000e18);
    uint256 id = _redeem(alice, 10_000e18);
    vm.prank(bob);
    vm.expectRevert(EsseyReserve.NotOwner.selector);
    res.claim(id, address(nvda));
  }

  function test_payShare_only_self() public {
    vm.expectRevert(EsseyReserve.OnlySelf.selector);
    res.payShare(0, address(nvda), alice, 1e18, BASE);
  }

  // ---- supply-removal fallback for a non-burnable claim token

  function test_dead_fallback_when_no_burn() public {
    MockNoBurnEssey nb = new MockNoBurnEssey(BASE);
    EsseyReserve r2 = new EsseyReserve(IERC20(address(nb)));
    nb.transfer(alice, 50_000e18);
    vm.startPrank(alice);
    nb.approve(address(r2), 50_000e18);
    r2.redeem(50_000e18);
    vm.stopPrank();
    assertEq(nb.balanceOf(r2.DEAD()), 50_000e18);
    assertEq(r2.circulatingSupply(), BASE - 50_000e18);
  }

  // ---- views

  function test_floorOf_is_gross_backing_per_unit() public {
    _fund(nvda, 1_000e18);
    assertEq(res.floorOf(address(nvda)), (1_000e18 * 1e18) / BASE); // gross; a claim pulls 95% of it
  }

  function test_previewClaim_matches_actual() public {
    _fund(nvda, 1_000e18);
    uint256 id = _redeem(alice, 10_000e18);
    uint256 preview = res.previewClaim(id, address(nvda));
    vm.prank(alice);
    res.claim(id, address(nvda));
    assertEq(preview, nvda.balanceOf(alice));
    assertEq(res.previewClaim(id, address(nvda)), 0);
  }

  // payout floors, so indivisible dust stays in the reserve as over-collateralisation — never rounded
  // out to the claimer (a ceil would hand it out). 1 wei backing a 0.95%-weight receipt floors to 0.
  function test_dust_rounds_to_reserve_not_claimer() public {
    nvda.mint(address(this), 1);
    nvda.approve(address(res), 1);
    res.fund(address(nvda), 1);
    uint256 id = _redeem(alice, 10_000e18);
    vm.prank(alice);
    res.claim(id, address(nvda));
    assertEq(nvda.balanceOf(alice), 0); // floor: claimer gets nothing
    assertEq(res.reserveOf(address(nvda)), 1); // the wei stays backing everyone
  }

  // ---- SOLVENCY + EXACT-SHARE fuzz, now reaching the deep-denominator regime (up to 70% claimed)

  function testFuzz_exact_shares_and_solvency(uint256 eA, uint256 eB, uint256 dep, bool bobFirst) public {
    eA = bound(eA, 1e18, 350_000e18); // up to 35% each -> 70% total: denom shrinks to 30% of claimBase
    eB = bound(eB, 1e18, 350_000e18);
    dep = bound(dep, 1, 1_000_000e18);
    vm.startPrank(treasury);
    essey.transfer(alice, eA);
    essey.transfer(bob, eB);
    vm.stopPrank();

    _fund(nvda, dep);
    uint256 idA = _redeem(alice, eA);
    uint256 idB = _redeem(bob, eB);
    if (bobFirst) {
      vm.prank(bob);
      res.claim(idB, address(nvda));
      vm.prank(alice);
      res.claim(idA, address(nvda));
    } else {
      vm.prank(alice);
      res.claim(idA, address(nvda));
      vm.prank(bob);
      res.claim(idB, address(nvda));
    }
    uint256 S = res.claimBase();
    uint256 wA = eA * 9500 / 10000;
    uint256 wB = eB * 9500 / 10000;
    // each collects EXACTLY weight/claimBase of the deposit, order-independent (± wei rounding)
    assertApproxEqAbs(nvda.balanceOf(alice), dep * wA / S, 10);
    assertApproxEqAbs(nvda.balanceOf(bob), dep * wB / S, 10);
    uint256 paidOut = nvda.balanceOf(alice) + nvda.balanceOf(bob);
    assertLe(paidOut, dep); // solvency: never over-draw
    assertEq(nvda.balanceOf(address(res)), dep - paidOut);
  }
}
