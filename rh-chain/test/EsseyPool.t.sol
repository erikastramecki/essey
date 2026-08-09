// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed, MockStock} from "./RiskModules.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Real USDG on Robinhood Chain has SIX decimals (verified by eth_call against mainnet).
/// The first version of this mock used 18, which made a 1e12 collateral-valuation error
/// invisible to the entire suite. Mocks that differ from production hide exactly the bugs
/// production has.
contract MockUSDG is ERC20 {
    constructor() ERC20("Global Dollar", "USDG") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    // Borrow-asset pause (fix #5): the pool suspends accrual only while the BORROW ASSET is paused.
    // Stored as a raw word so a test can also feed a NON-boolean value (fix #1 — must not panic accrue()).
    uint256 private _pausedWord;
    function setPausedWord(uint256 w) external { _pausedWord = w; }
    function paused() external view returns (uint256) { return _pausedWord; }
}

contract EsseyPoolTest is Test {
    EsseyPool pool;
    EsseyMarkets mk;
    LivenessOracle liv;
    MockFeed seq;
    MockFeed px;
    MockStock tok;
    MockUSDG usdg;

    address ADMIN;
    address KEEPER;
    address GUARDIAN;
    address LENDER;
    address ALICE;
    address LIQUIDATOR;

    uint256 constant MON_IN_SESSION = 1_753_110_000;
    uint256 constant MAX_AGE = 15 minutes;
    uint256 constant GRACE = 30 minutes;
    uint256 constant GAP = 10 minutes; // ~2 missed beats at a 5-minute cadence

    function setUp() public virtual {
        ADMIN = makeAddr("admin"); KEEPER = makeAddr("keeper"); GUARDIAN = makeAddr("guardian");
        LENDER = makeAddr("lender"); ALICE = makeAddr("alice"); LIQUIDATOR = makeAddr("liquidator");
        vm.warp(MON_IN_SESSION);

        seq = new MockFeed(0, 0); seq.setStartedAt(block.timestamp - 2 days);
        px = new MockFeed(200e8, 8); // $200/share
        tok = new MockStock();
        usdg = new MockUSDG();
        liv = new LivenessOracle(KEEPER, GUARDIAN, MAX_AGE, GRACE, GAP);
        mk = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, ADMIN, 6); // USDG is 6dp
        // zero-rate pool: isolates the invariants under test from accrual drift
        pool = new EsseyPool(usdg, mk, 0, 0, 0, 0, address(0), address(0x7EA), 0);

        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6
        });
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        vm.stopPrank();

        _beat(); _advanceLive(GRACE);

        usdg.mint(LENDER, 1_000_000e6);
        usdg.mint(ALICE, 100_000e6);
        usdg.mint(LIQUIDATOR, 100_000e6);
        tok.mint(ALICE, 1_000e18);

        vm.startPrank(LENDER);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e6, LENDER);
        vm.stopPrank();

        vm.startPrank(ALICE);
        tok.approve(address(pool), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.prank(LIQUIDATOR);
        usdg.approve(address(pool), type(uint256).max);
    }

    function _beat() internal { vm.prank(KEEPER); liv.heartbeat(); }
    function _advanceLive(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes); px.set(px.answer(), block.timestamp); _beat();
        }
        vm.warp(end); px.set(px.answer(), block.timestamp); _beat();
    }

    /// 10 shares at $200 = $2000 collateral; 35% LTV = $700 max.
    function _borrow(uint256 debt) internal returns (uint256 id) {
        vm.prank(ALICE);
        id = pool.borrow(address(tok), 10e18, debt);
    }

    // ---------------------------------------------------------------- basics

    function test_lenderDepositMintsShares() public view {
        assertGt(pool.balanceOf(LENDER), 0);
        assertEq(pool.totalAssets(), 500_000e6);
    }

    function test_borrowWithinLtv() public {
        uint256 id = _borrow(700e6);
        assertEq(usdg.balanceOf(ALICE), 100_700e6);
        assertEq(pool.debtOf(id), 700e6);
        assertEq(pool.marketBorrows(address(tok)), 700e6);
    }

    function test_borrowBeyondLtvReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.Undercollateralised.selector, 701e6, 700e6));
        pool.borrow(address(tok), 10e18, 701e6);
    }

    function test_borrowBlockedOffHours() public {
        uint256 night = (block.timestamp / 86400) * 86400 + 1 days + 3 hours;
        vm.warp(night); px.set(200e8, night);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.borrow(address(tok), 10e18, 100e18);
    }

    // ---------------------------------------------------------------- F5: repay

    /// Overpaying must NOT be an error, and must not overcharge. The Sui version demanded exact
    /// equality against a debt that grows every second — a race the borrower could lose.
    function test_repayAcceptsMoreThanOwedAndChargesOnlyTheDebt() public {
        uint256 id = _borrow(700e6);
        uint256 before_ = usdg.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.repay(id, 1_000e6); // deliberately generous
        assertEq(before_ - usdg.balanceOf(ALICE), 700e6, "must charge exactly the debt");
        assertEq(tok.balanceOf(ALICE), 1_000e18, "collateral fully returned");
        assertEq(pool.debtOf(id), 0);
    }

    function test_repayBelowOwedReverts() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        vm.expectRevert();
        pool.repay(id, 699e6);
    }

    function test_onlyBorrowerCanRepay() public {
        uint256 id = _borrow(700e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.repay(id, 700e6);
    }

    // ---------------------------------------------------------------- R5/R6: exposure release

    /// Closing a position must free its slot — exactly once. On Sui this leaked and eventually
    /// bricked all borrowing, then a second release path made the cap stop binding entirely.
    function test_repayFreesTheMarketCapSlotExactlyOnce() public {
        uint256 id = _borrow(700e6);
        assertEq(pool.marketBorrows(address(tok)), 700e6);
        vm.prank(ALICE);
        pool.repay(id, 700e6);
        assertEq(pool.marketBorrows(address(tok)), 0, "slot must be freed");
        // and borrowing the same size again must fit
        uint256 id2 = _borrow(700e6);
        assertEq(pool.marketBorrows(address(tok)), 700e6, "must not double-count or double-free");
        assertGt(id2, id);
    }

    // ---------------------------------------------------------------- F3: liquidation

    function test_healthyPositionCannotBeLiquidated() public {
        uint256 id = _borrow(700e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.PositionHealthy.selector);
        pool.liquidate(id);
    }

    /// THE F3 CASE. An underwater position is liquidated, but the liquidator takes only the debt
    /// plus the bonus — the SURPLUS goes back to the borrower. Seizing everything punished a
    /// borrower fractionally underwater.
    function test_liquidationRefundsSurplusToBorrower() public {
        uint256 id = _borrow(700e6);
        // drop to $125: collateral $1250, threshold 55% = $687.50 < $700 debt
        px.set(125e8, block.timestamp);
        assertEq(tok.balanceOf(ALICE), 990e18); // 10 posted

        vm.prank(LIQUIDATOR);
        pool.liquidate(id);

        // debt 700 + 8% bonus = 756 of value; at $125/share that is 6.048 shares
        uint256 seized = tok.balanceOf(LIQUIDATOR);
        assertApproxEqAbs(seized, 6.048e18, 1e15, "liquidator takes debt+bonus, not everything");
        // the rest returns to Alice
        assertApproxEqAbs(tok.balanceOf(ALICE), 990e18 + (10e18 - seized), 1e15, "surplus refunded");
        assertLt(seized, 10e18, "must never be the whole position");
    }

    function test_liquidationBlockedWithoutChainLiveness() public {
        uint256 id = _borrow(700e6);
        px.set(125e8, block.timestamp);
        vm.warp(block.timestamp + 4 hours); // outage: no heartbeat possible
        px.set(125e8, block.timestamp);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.LiquidationNotAllowed.selector, address(tok)));
        pool.liquidate(id);
    }

    // ---------------------------------------------------------------- adminBurn

    /// The issuer destroys collateral out of the live pool. The ledger must notice, and repayment
    /// must still work — returning whatever survived rather than reverting and trapping the rest.
    function test_adminBurnIsAbsorbedAndRepaymentStillWorks() public {
        uint256 id = _borrow(700e6);
        tok.adminBurn(address(pool), 4e18); // Robinhood burns 4 of Alice's 10 posted shares

        vm.prank(ALICE);
        pool.repay(id, 700e6);

        assertEq(pool.shortfallRaw(address(tok)), 4e18, "shortfall recorded");
        assertEq(tok.balanceOf(ALICE), 990e18 + 6e18, "returns what survived, does not revert");
        assertEq(pool.debtOf(id), 0, "debt still cleared");
    }

    // ---------------------------------------------------------------- end-to-end lifecycle

    /// Composes fixes #2/#4/#5 in one realistic flow: borrow with interest -> a partial adminBurn -> a
    /// borrower who arrives AFTER the burn is insulated -> the pre-burn borrower is liquidated on her
    /// haircut collateral -> the post-burn borrower repays and recovers his FULL deposit, having
    /// subsidised neither the burn nor the liquidation.
    function test_fullLifecycle_burnInsulationAccrualLiquidation() public {
        EsseyPool p2 = new EsseyPool(usdg, mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0); // 10% APR
        usdg.mint(LENDER, 500_000e6); // harness-independent liquidity
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(500_000e6, LENDER); vm.stopPrank();

        // Alice borrows at max LTV against 10 AAPL @ $200 (in session from setUp)
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 aliceId = p2.borrow(address(tok), 10e18, 700e6);
        vm.stopPrank();

        // the issuer burns half of Alice's collateral out of the pool
        tok.adminBurn(address(p2), 5e18); // 10 -> 5 for the tok cohort (only Alice so far)

        // Bob borrows FRESH after the burn — his snapshot is the post-burn index, so he is insulated
        address BOB = makeAddr("bob_lifecycle");
        tok.mint(BOB, 10e18); usdg.mint(BOB, 100_000e6);
        vm.startPrank(BOB);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 bobId = p2.borrow(address(tok), 10e18, 700e6);
        vm.stopPrank();

        // a little time passes (still in session): interest accrues on both debts. _advanceLive keeps the
        // keeper heartbeat fresh (5-min beats < gapThreshold, so no grace) so liquidation stays enabled.
        _advanceLive(2 hours);
        p2.accrue();
        assertGt(p2.debtOf(aliceId), 700e6, "interest accrued on Alice");
        assertGt(p2.debtOf(bobId), 700e6, "interest accrued on Bob");

        // price drops: Alice's HAIRCUT collateral (5 @ $120 = $600) is now below her debt -> liquidate her
        px.set(120e8, block.timestamp);
        vm.prank(LIQUIDATOR); usdg.approve(address(p2), type(uint256).max); // approve THIS pool
        vm.prank(LIQUIDATOR);
        p2.liquidate(aliceId);
        assertEq(p2.debtOf(aliceId), 0, "Alice liquidated on her haircut collateral");

        // Bob repays and recovers his FULL 10 AAPL — insulated from both the burn and Alice's liquidation
        uint256 bobOwed = p2.debtOf(bobId);
        vm.startPrank(BOB); usdg.mint(BOB, bobOwed); p2.repay(bobId, bobOwed); vm.stopPrank();
        assertEq(p2.debtOf(bobId), 0, "Bob's debt cleared");
        assertEq(tok.balanceOf(BOB), 10e18, "post-burn borrower recovered his FULL deposit (insulated)");
    }

    // ---------------------------------------------------------------- accrual

    function test_interestAccruesAndLenderEarns() public {
        EsseyPool p2 = new EsseyPool(usdg, mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0); // flat 10% APR
        vm.startPrank(LENDER);
        usdg.approve(address(p2), type(uint256).max);
        p2.deposit(100_000e6, LENDER);
        vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max);
        usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(address(tok), 10e18, 700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        assertApproxEqRel(p2.debtOf(id), 770e6, 0.01e18, "10% APR on 700");
        assertGt(p2.totalAssets(), 100_000e6, "lenders earn the interest");
    }

    /// R1-AUDIT: an adminBurn must make a position MORE liquidatable, not less. Reading the
    /// stored collateralRaw made a fully-unsecured position read as healthy — permanently
    /// unliquidatable while backing nothing.
    function test_burnedCollateralMakesPositionLiquidatableNotStuck() public {
        uint256 id = _borrow(700e6);
        tok.adminBurn(address(pool), 9e18); // 10 posted -> 1 survives, $200 backing $700
        vm.prank(LIQUIDATOR);
        pool.liquidate(id); // must NOT revert PositionHealthy
        assertEq(pool.debtOf(id), 0, "position closed");
    }

    /// R1-AUDIT: the ordering bug. Two borrowers, one burn — each loses their share, in either
    /// order. Previously whoever repaid first was made whole out of the other's collateral.
    function test_burnLossIsSharedNotAllocatedByRepaymentOrder() public {
        uint256 aliceId = _borrow(700e6);
        address BOB = makeAddr("bob");
        tok.mint(BOB, 100e18); usdg.mint(BOB, 10_000e6);
        vm.startPrank(BOB);
        tok.approve(address(pool), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        uint256 bobId = pool.borrow(address(tok), 10e18, 700e6);
        vm.stopPrank();

        tok.adminBurn(address(pool), 10e18); // 20 posted -> 10 survive

        uint256 aliceBefore = tok.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.repay(aliceId, 700e6);
        assertEq(tok.balanceOf(ALICE) - aliceBefore, 5e18, "Alice gets HER half, not all of it");

        uint256 bobBefore = tok.balanceOf(BOB);
        vm.prank(BOB);
        pool.repay(bobId, 700e6);
        assertEq(tok.balanceOf(BOB) - bobBefore, 5e18, "Bob is not left with zero");
    }

    /// R1-AUDIT: a zero-debt position could never be repaid nor liquidated — collateral trapped.
    function test_zeroDebtBorrowIsRejected() public {
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.borrow(address(tok), 10e18, 0);
    }

    /// R1-AUDIT + fix #5: accrual suspends ONLY while the BORROW ASSET is paused (the one pause that blocks
    /// every repayment). A COLLATERAL-token pause must NOT forgive interest pool-wide — watching collateral
    /// tokens let an unrelated pause hand every borrower a free loan.
    function test_accrualSuspendsOnlyWhenBorrowAssetPaused() public {
        EsseyPool p2 = new EsseyPool(usdg, mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0);
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(address(tok), 10e18, 700e6);
        vm.stopPrank();

        // A COLLATERAL pause must NOT forgive interest (the fix): it still accrues.
        tok.setPaused(true);
        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        assertGt(p2.debtOf(id), 700e6, "a collateral pause must NOT hand a free loan");

        // The BORROW ASSET pause DOES suspend accrual (no one can repay while it holds).
        uint256 debtBefore = p2.debtOf(id);
        usdg.setPausedWord(1);
        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        assertEq(p2.debtOf(id), debtBefore, "no interest while the borrow asset is paused");
        usdg.setPausedWord(0);
    }

    /// CRITICAL (fix #1): a BORROW ASSET whose paused() returns a NON-boolean word must not freeze the pool.
    /// Pre-fix, abi.decode(ret,(bool)) panicked (0x21) inside accrue() — run by every entry point —
    /// bricking deposit/borrow/repay/liquidate.
    function test_nonBooleanPausedWordDoesNotFreezeThePool() public {
        EsseyPool p2 = new EsseyPool(usdg, mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0);
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();

        usdg.setPausedWord(2); // a NON-boolean word on the borrow asset
        vm.warp(block.timestamp + 1 days);
        p2.accrue(); // pre-fix: reverts Panic(0x21); post-fix: nonzero word treated as paused, no revert

        // an entry point still works despite the non-bool word (deposit runs accrue() first)
        usdg.mint(LENDER, 1_000e6);
        vm.startPrank(LENDER); uint256 sh = p2.deposit(1_000e6, LENDER); vm.stopPrank();
        assertGt(sh, 0, "not frozen by a non-boolean paused() word on the borrow asset");
    }

    /// HIGH (borrow-path fix #4): interest pending between accruals must NOT be extractable by an atomic
    /// deposit->redeem. Pre-fix, OZ priced the deposit against stale (pre-accrual) totalAssets, so the
    /// depositor captured interest owed to existing lenders. Post-fix, accrue() runs before the preview,
    /// so the attacker buys shares at the current price and redeems at the same price — no free interest.
    function test_pendingInterestNotExtractableByDepositRedeem() public {
        EsseyPool p2 = new EsseyPool(usdg, mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0); // 10% APR
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        p2.borrow(address(tok), 10e18, 700e6); // a borrower generating interest (max LTV on 10 @ $200)
        vm.stopPrank();

        // interest accrues but is NOT yet booked (no accrue() call in the interim)
        vm.warp(block.timestamp + 30 days);

        address ATTACKER = makeAddr("attacker4");
        usdg.mint(ATTACKER, 100_000e6);
        vm.startPrank(ATTACKER);
        usdg.approve(address(p2), type(uint256).max);
        uint256 shares = p2.deposit(100_000e6, ATTACKER); // pre-fix: priced at stale low totalAssets
        uint256 got = p2.redeem(shares, ATTACKER, ATTACKER); // pre-fix: redeems after interest booked -> profit
        vm.stopPrank();

        assertLe(got, 100_000e6, "attacker cannot skim pending interest owed to existing lenders");
    }

    /// R1-AUDIT: THE FIRST-DEPOSITOR INFLATION ATTACK, run as an actual attack rather than
    /// asserted as prevented. Deposit 1 wei, donate directly to inflate the share price, and the
    /// victim's deposit rounds to zero shares while the attacker redeems everything.
    ///
    /// This test exists because setting _decimalsOffset() to 0 previously left the whole suite
    /// green — the mitigation was present but nothing proved it worked.
    function test_firstDepositorInflationAttackFails() public {
        EsseyPool p2 = new EsseyPool(usdg, mk, 0, 0, 0, 0, address(0), address(0x7EA), 0);
        address ATTACKER = makeAddr("attacker");
        address VICTIM = makeAddr("victim");
        usdg.mint(ATTACKER, 200_000e6);
        usdg.mint(VICTIM, 100_000e6);

        vm.startPrank(ATTACKER);
        usdg.approve(address(p2), type(uint256).max);
        p2.deposit(1, ATTACKER);                    // 1. one wei
        usdg.transfer(address(p2), 100_000e6);      // 2. donate to inflate share price
        vm.stopPrank();

        vm.startPrank(VICTIM);
        usdg.approve(address(p2), type(uint256).max);
        uint256 victimShares = p2.deposit(100_000e6, VICTIM);  // 3. must NOT round to zero
        vm.stopPrank();
        assertGt(victimShares, 0, "victim must receive shares");

        // 4. attacker redeems everything they hold and must not profit at the victim's expense
        vm.startPrank(ATTACKER);
        uint256 got = p2.redeem(p2.balanceOf(ATTACKER), ATTACKER, ATTACKER);
        vm.stopPrank();
        assertLe(got, 100_000e6 + 1, "attacker must not extract the victim's deposit");

        // and the victim can still get materially all of their money back
        vm.startPrank(VICTIM);
        uint256 back = p2.redeem(victimShares, VICTIM, VICTIM);
        vm.stopPrank();
        assertGe(back, 99_000e6, "victim recovers substantially all of their deposit");
    }

    // ------------------------------------------------- guards found by mutation sweep

    function test_withdrawBeyondAvailableCashReverts() public {
        _borrow(700e6);
        uint256 cash = usdg.balanceOf(address(pool));
        vm.prank(LENDER);
        // Assert the SPECIFIC error: a bare expectRevert() also matches the SafeERC20 failure
        // that would occur anyway, so it passed with the guard deleted. Found by mutation sweep.
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.InsufficientLiquidity.selector, cash + 1, cash));
        pool.withdraw(cash + 1, LENDER, LENDER);
    }

    function test_borrowBeyondMarketCapReverts() public {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 500e6 // cap below one max-LTV loan
        });
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        vm.stopPrank();
        _beat(); _advanceLive(GRACE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.ExceedsMarketCap.selector, 700e6, 500e6));
        pool.borrow(address(tok), 10e18, 700e6);
    }

    function test_borrowBeyondPoolLiquidityReverts() public {
        EsseyPool p2 = new EsseyPool(usdg, mk, 0, 0, 0, 0, address(0), address(0x7EA), 0); // empty pool: no cash at all
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.InsufficientLiquidity.selector, 700e6, 0));
        p2.borrow(address(tok), 10e18, 700e6);
        vm.stopPrank();
    }

    function test_repayOnAClosedPositionReverts() public {
        uint256 id = _borrow(700e6);
        vm.startPrank(ALICE);
        pool.repay(id, 700e6);
        // The position is deleted, so borrower is address(0) and the ownership check fires first.
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.repay(id, 700e6);
        vm.stopPrank();
    }

    function test_liquidatingAClosedPositionReverts() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        pool.repay(id, 700e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.liquidate(id);
    }

    function test_curveSumIsBounded() public {
        vm.expectRevert(EsseyPool.BadCurve.selector);
        new EsseyPool(usdg, mk, 90_000, 90_000, 90_000, 0, address(0), address(0x7EA), 0); // legs individually ok, sum is not
    }

    /// Mainnet-config fix: the pool's markets.assetDecimals must MATCH the real borrow-asset decimals(), so a
    /// mis-set value (e.g. 18 against mainnet USDG's 6) can't reintroduce the 1e12 LTV over-valuation. usdg is
    /// 6-dec; a markets built with assetDecimals=18 must be un-poolable against it.
    function test_assetDecimalsMustMatchTheBorrowAsset() public {
        EsseyMarkets wrong = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, ADMIN, 18); // 18 != usdg's 6
        vm.expectRevert(EsseyPool.AssetDecimalsMismatch.selector);
        new EsseyPool(usdg, wrong, 1_000, 0, 0, 0, address(0), address(0x7EA), 0);
    }

    function test_withdrawBeyondCashReverts() public {
        _borrow(700e6);
        vm.prank(LENDER);
        vm.expectRevert();
        pool.withdraw(500_000e6, LENDER, LENDER);
    }
}
