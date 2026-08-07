// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EsseyShieldedStock} from "../src/private/pool/EsseyShieldedStock.sol";
import {EsseyShieldedPool, IPoolVerifier, IEsseyPoolGate} from "../src/private/pool/EsseyShieldedPool.sol";
import {EsseyPoolGate} from "../src/private/pool/EsseyPoolGate.sol";
import {Groth16Verifier} from "../src/private/pool/PoolVerifier2.sol";

/// A tokenized-stock token with the Robinhood Stock Token hazard: an arbitrary-address `adminBurn` the issuer
/// can call to destroy tokens at ANY holder, including a shielded pool's own balance (mirrors MockStock in
/// RiskModules.t.sol). 18 decimals, like the real tokens. Open in the mock; role-gated on mainnet.
contract BurnableStock is ERC20 {
  constructor() ERC20("Apple Robinhood Token", "AAPL") {}
  function mint(address to, uint256 amt) external {
    _mint(to, amt);
  }
  function adminBurn(address from, uint256 amt) external {
    _burn(from, amt); // the issuer can burn anyone's balance - the whole hazard
  }
}

/// THE ADMINBURN HARNESS. Proves, on real depth-20 Groth16 proofs, that (1) a VANILLA shielded pool FREEZES
/// withdrawals when the stock issuer burns its backing - the failure mode we must characterize before trusting
/// stock shielding - and (2) EsseyShieldedStock instead pays every holder their PRO-RATA share, so the burn
/// loss is socialized fairly with no bank run. The zk proofs are the SAME depth-20 fixtures the base/supply
/// pools use (value = 100); the new surface under test is purely the burn-resilience accounting.
contract EsseyShieldedStockTest is Test {
  BurnableStock stock;
  // The withdraw proof's extDataHash is bound to recipient 0x1111...1111 / extAmount -100 / fee 0 - it must
  // match byte-for-byte or the extDataHash check reverts, so this recipient is fixed by the fixture.
  address recipient = address(0x1111111111111111111111111111111111111111);

  function _deployHasher() internal returns (address hasher) {
    bytes memory code = vm.parseBytes(_trim(vm.readFile("circuits-nova/build/Hasher2.bytecode.txt")));
    assembly {
      hasher := create(0, add(code, 0x20), mload(code))
    }
    require(hasher != address(0), "hasher deploy failed");
  }

  function _newStockPool() internal returns (EsseyShieldedStock pool) {
    address hasher = _deployHasher();
    Groth16Verifier verifier = new Groth16Verifier();
    EsseyPoolGate gate = new EsseyPoolGate(address(this), true); // openMode on testnet
    stock = new BurnableStock();
    pool = new EsseyShieldedStock(
      IPoolVerifier(address(verifier)), 20, hasher, IERC20(address(stock)), IEsseyPoolGate(address(gate)), address(this), type(uint256).max
    );
    stock.mint(address(this), 100);
  }

  function _newBasePool() internal returns (EsseyShieldedPool pool) {
    address hasher = _deployHasher();
    Groth16Verifier verifier = new Groth16Verifier();
    EsseyPoolGate gate = new EsseyPoolGate(address(this), true);
    stock = new BurnableStock();
    pool = new EsseyShieldedPool(
      IPoolVerifier(address(verifier)), 20, hasher, IERC20(address(stock)), IEsseyPoolGate(address(gate)), address(this), type(uint256).max
    );
    stock.mint(address(this), 100);
  }

  // ---------------------------------------------------------------------------------------------------------
  // (1) CHARACTERIZE THE FAILURE: a vanilla pool freezes the withdrawal after the issuer burns its backing.
  // ---------------------------------------------------------------------------------------------------------
  function test_NaiveBasePool_FreezesOnAdminBurn() public {
    EsseyShieldedPool pool = _newBasePool();

    // Shield 100.
    (EsseyShieldedPool.Proof memory dp, EsseyShieldedPool.ExtData memory de) = _baseDeposit();
    stock.approve(address(pool), 100);
    pool.transact(dp, de);
    assertEq(stock.balanceOf(address(pool)), 100, "pool backed 100");

    // The issuer burns 40 of the pool's backing -> it now holds 60 against a 100 note.
    stock.adminBurn(address(pool), 40);
    assertEq(stock.balanceOf(address(pool)), 60, "backing burned to 60");

    // The holder tries to withdraw their 100 note. The vanilla pool tries to transfer the FULL 100 from a
    // 60 balance -> ERC20InsufficientBalance. The note is unredeemable: the holder gets NOTHING and the
    // surviving 60 of backing is stranded. This is the bank-run failure mode.
    (EsseyShieldedPool.Proof memory wp, EsseyShieldedPool.ExtData memory we) = _baseWithdraw();
    vm.expectRevert();
    pool.transact(wp, we);
    assertEq(stock.balanceOf(recipient), 0, "frozen: holder recovered nothing");
  }

  // ---------------------------------------------------------------------------------------------------------
  // (2) THE MITIGATION: the stock pool pays the holder their pro-rata share instead of freezing.
  // ---------------------------------------------------------------------------------------------------------
  function test_StockPool_ProRataHaircut_recovers() public {
    EsseyShieldedStock pool = _newStockPool();

    // Shield 100.
    (EsseyShieldedStock.Proof memory dp, EsseyShieldedStock.ExtData memory de) = _stockDeposit();
    stock.approve(address(pool), 100);
    pool.transact(dp, de);
    assertEq(pool.totalShielded(), 100, "totalShielded tracks the deposit");
    assertEq(stock.balanceOf(address(pool)), 100, "fully backed");
    assertFalse(pool.isImpaired(), "solvent at par");

    // The issuer burns 40 -> the pool is impaired: 60 backing against 100 outstanding = 60% solvency.
    stock.adminBurn(address(pool), 40);
    assertTrue(pool.isImpaired(), "impaired after burn");
    assertEq(pool.previewWithdrawable(100), 60, "100 note now redeems for its 60% pro-rata share");

    // The holder withdraws. No revert: they receive their full pro-rata share (60), not zero. The note is
    // fully consumed and the pool drains exactly - no stranded backing, no shortfall.
    (EsseyShieldedStock.Proof memory wp, EsseyShieldedStock.ExtData memory we) = _stockWithdraw();
    pool.transact(wp, we);
    assertEq(stock.balanceOf(recipient), 60, "holder recovered their pro-rata 60 (not frozen out)");
    assertEq(stock.balanceOf(address(pool)), 0, "pool drained exactly - no stranded backing");
    assertEq(pool.totalShielded(), 0, "note fully consumed from the shielded set");
    assertTrue(pool.isSpent(wp.inputNullifiers[0]), "note spent");
  }

  // ---------------------------------------------------------------------------------------------------------
  // (3) The solvency gate: once impaired, deposits close, so no new depositor subsidizes the shortfall.
  // ---------------------------------------------------------------------------------------------------------
  function test_StockPool_DepositsCloseWhenImpaired() public {
    EsseyShieldedStock pool = _newStockPool();
    (EsseyShieldedStock.Proof memory dp, EsseyShieldedStock.ExtData memory de) = _stockDeposit();
    stock.approve(address(pool), 100);
    pool.transact(dp, de);

    stock.adminBurn(address(pool), 40); // impair the pool

    // A fresh deposit is refused at the solvency gate (before the proof is even checked), so a new depositor
    // can never be diluted into covering the burn. The pool is now withdraw-only.
    stock.mint(address(this), 100);
    stock.approve(address(pool), 100);
    vm.expectRevert(bytes("pool impaired - deposits closed"));
    pool.transact(dp, de);
  }

  // ---------------------------------------------------------------------------------------------------------
  // (4) The operational deposit pause never blocks withdrawals (it is not a compliance kill-switch).
  // ---------------------------------------------------------------------------------------------------------
  function test_StockPool_PauseBlocksDepositNotWithdraw() public {
    EsseyShieldedStock pool = _newStockPool();
    (EsseyShieldedStock.Proof memory dp, EsseyShieldedStock.ExtData memory de) = _stockDeposit();
    stock.approve(address(pool), 100);
    pool.transact(dp, de);

    pool.setDepositsPaused(true);

    // Deposit blocked while paused...
    stock.mint(address(this), 100);
    stock.approve(address(pool), 100);
    vm.expectRevert(EsseyShieldedStock.DepositNotApproved.selector);
    pool.transact(dp, de);

    // ...but the withdrawal still goes through in full (pool is solvent, no haircut).
    (EsseyShieldedStock.Proof memory wp, EsseyShieldedStock.ExtData memory we) = _stockWithdraw();
    pool.transact(wp, we);
    assertEq(stock.balanceOf(recipient), 100, "withdrawal unaffected by deposit pause");
  }

  // ---------------------------------------------------------------------------------------------------------
  // (5) The haircut math: identity when solvent, capped at par, and socialization is partition-independent.
  // ---------------------------------------------------------------------------------------------------------
  function test_quoteHaircut_cases() public {
    EsseyShieldedStock pool = _newStockPool();
    assertEq(pool.quoteHaircut(100, 100, 100), 100, "solvent -> par (identity)");
    assertEq(pool.quoteHaircut(100, 60, 100), 60, "40% burn -> 60% payout");
    assertEq(pool.quoteHaircut(100, 150, 100), 100, "excess backing capped at par");
    assertEq(pool.quoteHaircut(50, 0, 0), 50, "no outstanding notes -> identity");
    // Exact drain: the whole outstanding set redeems for exactly the surviving backing - nothing stranded.
    assertEq(pool.quoteHaircut(100, 60, 100), 60, "sum of notes == surviving backing");
  }

  /// Socialization is order- and partition-independent: splitting a claim into two holders never lets them
  /// extract MORE than one combined holder (no drain-by-splitting), and at most 1 unit less (integer dust,
  /// always retained by the pool). Since each holder's payout is a pure function of the same live ratio, this
  /// is exactly the property that makes exit order irrelevant.
  function testFuzz_haircut_socialization(uint256 a, uint256 balance, uint256 total) public {
    EsseyShieldedStock pool = _newStockPool();
    total = bound(total, 1, 1e30);
    balance = bound(balance, 0, 1e30);
    a = bound(a, 0, total);
    uint256 b = total - a; // two holders partitioning the whole outstanding set
    uint256 whole = pool.quoteHaircut(total, balance, total);
    uint256 split = pool.quoteHaircut(a, balance, total) + pool.quoteHaircut(b, balance, total);
    assertLe(split, whole, "splitting never extracts more than the combined claim");
    assertLe(whole - split, 1, "and at most 1 unit of dust less (retained by pool)");
  }

  /// The load-bearing STATEFUL property behind order-independence: a single haircut withdrawal preserves the
  /// solvency ratio balanceOf/totalShielded up to integer rounding (this is what `_transact` does - pay
  /// value*bal/total, decrement totalShielded by value). The ratio is monotonically NON-DECREASING: flooring
  /// retains sub-unit dust in the pool, so it weakly IMPROVES for remaining holders and never drops. That is
  /// what makes exit order safe - a later exiter is never disadvantaged, only (dust-scale) advantaged. Proven
  /// across the impaired regime (bal <= total) where the haircut is active. Cross-multiplied to stay exact.
  function testFuzz_ratioPreservedUnderWithdrawal(uint256 v, uint256 bal, uint256 total) public {
    EsseyShieldedStock pool = _newStockPool();
    total = bound(total, 1, 1e30);
    bal = bound(bal, 0, total); // impaired-or-exact: the regime where the haircut bites
    v = bound(v, 1, total); // withdraw a real note, at most the whole outstanding set
    uint256 pay = pool.quoteHaircut(v, bal, total);
    assertLe(pay, bal, "a withdrawal never pays out more than the pool holds (no bank-run revert)");
    uint256 newBal = bal - pay;
    uint256 newTotal = total - v;
    if (newTotal == 0) {
      assertEq(newBal, 0, "the last note drains the surviving backing exactly - nothing stranded");
    } else {
      // ratio preserved: newBal/newTotal >= bal/total (never drops - favours remaining holders) and rises by
      // at most one rounding unit. Order-independence follows directly from this invariance.
      assertGe(newBal * total, bal * newTotal, "solvency ratio never drops for remaining holders");
      assertLe(newBal * total - bal * newTotal, total, "ratio rises by at most rounding dust");
    }
  }

  /// The RELAYER-FEE path under a haircut (live code): recipient and relayer both scale by the same snapshot,
  /// so their combined payout can never exceed the surviving backing (no insufficient-balance revert) and
  /// never exceeds par. The circuit conserves value, so amt + fee <= totalShielded always holds for a real
  /// withdrawal - modelled here by the bound.
  function testFuzz_feePathNeverExceedsBacking(uint256 amt, uint256 fee, uint256 bal, uint256 total) public {
    EsseyShieldedStock pool = _newStockPool();
    total = bound(total, 1, 1e30);
    bal = bound(bal, 0, 1e30);
    amt = bound(amt, 0, total);
    fee = bound(fee, 0, total - amt); // amt + fee <= total (value conservation from the proof)
    uint256 payAmt = pool.quoteHaircut(amt, bal, total);
    uint256 payFee = pool.quoteHaircut(fee, bal, total);
    assertLe(payAmt, amt, "recipient never paid above par");
    assertLe(payFee, fee, "relayer never paid above par");
    if (bal <= total) {
      assertLe(payAmt + payFee, bal, "impaired: recipient + relayer together never exceed the backing");
    }
    if (bal >= total) {
      assertEq(payAmt, amt, "solvent: recipient paid in full");
      assertEq(payFee, fee, "solvent: relayer paid in full");
    }
  }

  // ---- fixtures: the same depth-20 proofs the base/supply pools use, one per struct type -------------------

  function _stockDeposit() internal pure returns (EsseyShieldedStock.Proof memory p, EsseyShieldedStock.ExtData memory e) {
    p = EsseyShieldedStock.Proof({
      a: [uint256(0x0c43368251c33b14a5db87732ac855218caaab69c1c60056b471dd45d518f6e3), uint256(0x11c8fee16b3e590d289141ff55a0bfedf95c8e6b4c9777ab1c167cafb3389dd5)],
      b: [
        [uint256(0x210f2f4d27a10d8fe25b9233afd93a5326e44969fd4f06e071d23759d984815d), uint256(0x0e1624953bf8ee0b04a5b18e9faa67331055fbb507102408103bba821f406ca7)],
        [uint256(0x2ac0b6dcf2d42e230bfb162b5ad20013172ffad520ed90c95175afcafe1d2217), uint256(0x0f9d51f497e1d7531e24240ba9560e73fb9b4e62f874cbd36da2c3bbfebff698)]
      ],
      c: [uint256(0x2cb75b90d47dc77a2ff6bb6e47894c30ffc0531f48a73b0d418aebad4ccd3447), uint256(0x21685f45230825e907a4efcb473f2fba95a645a54da4628a30aaaae58644fc19)],
      root: bytes32(0x2b0f6fc0179fa65b6f73627c0e1e84c7374d2eaec44c9a48f2571393ea77bcbb),
      inputNullifiers: [bytes32(0x1af59f0d0263108a005a43acde48bd6d81b2b44cf0d865aa866790cba302a78e), bytes32(0x1a1275e3f9ad322b3b5e2876e1262fb467d5dc4d92154c33443e312d7ad54fbb)],
      outputCommitments: [bytes32(0x157ea0e0c9d63a49044772668169d2770595846ed2cefb6563d83e46ad381667), bytes32(0x27a0892dac640ef501d486f45dcf524234252888ed5ed9617547e952d18a02b4)],
      publicAmount: 100,
      extDataHash: bytes32(0x008d9ffbaff3e4c3a2254578b66e772a0218b55a0e7979e299180942c827607c)
    });
    e = EsseyShieldedStock.ExtData(address(0), int256(100), address(0), 0, hex"", hex"");
  }

  function _stockWithdraw() internal view returns (EsseyShieldedStock.Proof memory p, EsseyShieldedStock.ExtData memory e) {
    p = EsseyShieldedStock.Proof({
      a: [uint256(0x030064510b8f9c08028fc2ceb24e8bfa7e817bacd27de4f51503d8650b75168e), uint256(0x2a1051eb87b7634f15ba5772f3eb6f17ef55e402ed2056a79b390dd4b1b5e0ed)],
      b: [
        [uint256(0x14ca9980a402aa4342998d6f8f7a6e4b7374c68f5bba96f285f247b919f7d3da), uint256(0x2a90ddec13cc78284755e352ecad9ef3a660c78606c38b075bb53638346efded)],
        [uint256(0x08c460cc1ca897a37cfcc6d732f4544fc6a2d4ea87ebc7bc4f0914ff14596ad0), uint256(0x130b7ab8eb7226ee63620aa5a9214126ebab0b32d95a46513eb6451d92408d60)]
      ],
      c: [uint256(0x107598a6238dd6f9076b72bfacf15327635b5e44dd08a5f55d3605e53dccb59c), uint256(0x2bac130568012e9022abfc6c13f34388aa70ca74a2d3859894d5e3c0b52e8a27)],
      root: bytes32(0x0633c0ec68749978a67b6990eee3cc3fcc513f7e1c5d096ec33091927f5dcc7c),
      inputNullifiers: [bytes32(0x0612a02aaa4c5a259665b1c9f537b222b05daceebad62d3d79bd86665246e593), bytes32(0x0c66da1e051fbc3cb6e3d2714395a1d21e35bd21e22cb4341a842ca6d5bceea8)],
      outputCommitments: [bytes32(0x07a3ee04205a099e175743f0f0013adaa3d7e926ab1b21372abfb1840b1594c4), bytes32(0x26d5a9ff1bc4de58bf839689c82e33d8c1f50df8d7c0c461fa43fc335055acae)],
      publicAmount: uint256(0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efffff9d),
      extDataHash: bytes32(0x2912ee1a618a0fdd368451ddb12eec90197a8b0b1861d282619240756ea7b27c)
    });
    e = EsseyShieldedStock.ExtData(recipient, int256(-100), address(0), 0, hex"", hex"");
  }

  function _baseDeposit() internal pure returns (EsseyShieldedPool.Proof memory p, EsseyShieldedPool.ExtData memory e) {
    p = EsseyShieldedPool.Proof({
      a: [uint256(0x0c43368251c33b14a5db87732ac855218caaab69c1c60056b471dd45d518f6e3), uint256(0x11c8fee16b3e590d289141ff55a0bfedf95c8e6b4c9777ab1c167cafb3389dd5)],
      b: [
        [uint256(0x210f2f4d27a10d8fe25b9233afd93a5326e44969fd4f06e071d23759d984815d), uint256(0x0e1624953bf8ee0b04a5b18e9faa67331055fbb507102408103bba821f406ca7)],
        [uint256(0x2ac0b6dcf2d42e230bfb162b5ad20013172ffad520ed90c95175afcafe1d2217), uint256(0x0f9d51f497e1d7531e24240ba9560e73fb9b4e62f874cbd36da2c3bbfebff698)]
      ],
      c: [uint256(0x2cb75b90d47dc77a2ff6bb6e47894c30ffc0531f48a73b0d418aebad4ccd3447), uint256(0x21685f45230825e907a4efcb473f2fba95a645a54da4628a30aaaae58644fc19)],
      root: bytes32(0x2b0f6fc0179fa65b6f73627c0e1e84c7374d2eaec44c9a48f2571393ea77bcbb),
      inputNullifiers: [bytes32(0x1af59f0d0263108a005a43acde48bd6d81b2b44cf0d865aa866790cba302a78e), bytes32(0x1a1275e3f9ad322b3b5e2876e1262fb467d5dc4d92154c33443e312d7ad54fbb)],
      outputCommitments: [bytes32(0x157ea0e0c9d63a49044772668169d2770595846ed2cefb6563d83e46ad381667), bytes32(0x27a0892dac640ef501d486f45dcf524234252888ed5ed9617547e952d18a02b4)],
      publicAmount: 100,
      extDataHash: bytes32(0x008d9ffbaff3e4c3a2254578b66e772a0218b55a0e7979e299180942c827607c)
    });
    e = EsseyShieldedPool.ExtData(address(0), int256(100), address(0), 0, hex"", hex"");
  }

  function _baseWithdraw() internal view returns (EsseyShieldedPool.Proof memory p, EsseyShieldedPool.ExtData memory e) {
    p = EsseyShieldedPool.Proof({
      a: [uint256(0x030064510b8f9c08028fc2ceb24e8bfa7e817bacd27de4f51503d8650b75168e), uint256(0x2a1051eb87b7634f15ba5772f3eb6f17ef55e402ed2056a79b390dd4b1b5e0ed)],
      b: [
        [uint256(0x14ca9980a402aa4342998d6f8f7a6e4b7374c68f5bba96f285f247b919f7d3da), uint256(0x2a90ddec13cc78284755e352ecad9ef3a660c78606c38b075bb53638346efded)],
        [uint256(0x08c460cc1ca897a37cfcc6d732f4544fc6a2d4ea87ebc7bc4f0914ff14596ad0), uint256(0x130b7ab8eb7226ee63620aa5a9214126ebab0b32d95a46513eb6451d92408d60)]
      ],
      c: [uint256(0x107598a6238dd6f9076b72bfacf15327635b5e44dd08a5f55d3605e53dccb59c), uint256(0x2bac130568012e9022abfc6c13f34388aa70ca74a2d3859894d5e3c0b52e8a27)],
      root: bytes32(0x0633c0ec68749978a67b6990eee3cc3fcc513f7e1c5d096ec33091927f5dcc7c),
      inputNullifiers: [bytes32(0x0612a02aaa4c5a259665b1c9f537b222b05daceebad62d3d79bd86665246e593), bytes32(0x0c66da1e051fbc3cb6e3d2714395a1d21e35bd21e22cb4341a842ca6d5bceea8)],
      outputCommitments: [bytes32(0x07a3ee04205a099e175743f0f0013adaa3d7e926ab1b21372abfb1840b1594c4), bytes32(0x26d5a9ff1bc4de58bf839689c82e33d8c1f50df8d7c0c461fa43fc335055acae)],
      publicAmount: uint256(0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efffff9d),
      extDataHash: bytes32(0x2912ee1a618a0fdd368451ddb12eec90197a8b0b1861d282619240756ea7b27c)
    });
    e = EsseyShieldedPool.ExtData(recipient, int256(-100), address(0), 0, hex"", hex"");
  }

  function _trim(string memory s) internal pure returns (string memory) {
    bytes memory b = bytes(s);
    uint256 end = b.length;
    while (end > 0 && (b[end - 1] == 0x0a || b[end - 1] == 0x0d || b[end - 1] == 0x20)) end--;
    bytes memory out = new bytes(end);
    for (uint256 i = 0; i < end; i++) out[i] = b[i];
    return string(out);
  }
}
