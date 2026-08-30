// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {MarketHealthOracle} from "../src/MarketHealthOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {CollateralReconciler} from "../src/CollateralReconciler.sol";
import {MockFeed, MockStock} from "./RiskModules.t.sol";
import {Note} from "../src/market/Note.sol";
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
    MarketHealthOracle hox;
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
        hox = new MarketHealthOracle(KEEPER, GUARDIAN, ADMIN);
        mk = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, ADMIN, GUARDIAN, 6); // USDG is 6dp
        vm.prank(ADMIN);
        hox.wireMarkets(address(mk));
        // zero-rate pool: isolates the invariants under test from accrual drift
        pool = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));

        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
        });
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool), m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        vm.stopPrank();

        _beat(); _advanceLive(GRACE);
        _seedOracle();

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
            vm.warp(block.timestamp + 5 minutes); px.set(px.answer(), block.timestamp); _beat(); _postD();
        }
        vm.warp(end); px.set(px.answer(), block.timestamp); _beat(); _postD();
    }

    uint128 constant SEED_DEPTH = 4_000_000e6; // target 1_333_200e6 > Market.cap: min() = the static cap

    function _postD() internal {
        vm.prank(KEEPER); hox.postDepth(address(tok), SEED_DEPTH, uint64(block.number), "fork-swap-v1");
    }

    /// Arm the depth cap and ride raiseDelay + the full from-zero slew ramp on a live keeper
    /// cadence — a silent warp past MAX_READING_AGE resets the ramp. The base clamps to
    /// Market.cap, so the 1_333_200e6 target needs ~15.4 days; 21 keeps the day-of-week.
    function _seedOracle() internal {
        _postD();
        for (uint256 i = 0; i < 42; i++) { vm.warp(block.timestamp + 12 hours); _postD(); }
        _beat(); _advanceLive(GRACE);
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }

    /// Warp through the 2-day timelock on a live keeper cadence — a silent warp past
    /// MAX_READING_AGE resets the depth ramp.
    function _warpTimelock() internal {
        for (uint256 i = 0; i < 4; i++) { vm.warp(block.timestamp + 12 hours); _postD(); }
    }

    /// Make `p` the token's active pool through the real timelocked pipeline (F1: only the
    /// active pool opens new borrows, so a test pool must succeed `pool` before it can lend).
    function _activate(EsseyPool p) internal {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: 10_000
        });
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(p), m);
        _warpTimelock();
        px.set(px.answer(), block.timestamp);
        mk.commitMarket(address(tok));
        _beat(); _advanceLive(GRACE);
        while (!mk.isUsMarketHours(block.timestamp)) _advanceLive(30 minutes);
    }

    /// 10 shares at $200 = $2000 collateral; 35% LTV = $700 max.
    function _borrow(uint256 debt) internal returns (uint256 id) {
        vm.prank(ALICE);
        id = pool.borrow(10e18, debt);
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

    /// M-1: a PARTIAL close (one of several open positions) must release the closed position's
    /// PRINCIPAL from the per-market cap ledger, not its interest-inflated `owed`. Once interest has
    /// accrued the two diverge, so subtracting `owed` would under-count marketBorrows and silently
    /// free market cap the surviving position still occupies. Full-close tests can't see this (owed
    /// and principal both floor to the same value at zero rate / immediate repay).
    function test_marketBorrowsReleasesPrincipalNotOwedOnPartialClose() public {
        EsseyPool rp = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        _activate(rp);
        usdg.mint(LENDER, 500_000e6);
        vm.startPrank(LENDER);
        usdg.approve(address(rp), type(uint256).max);
        rp.deposit(500_000e6, LENDER);
        vm.stopPrank();

        vm.startPrank(ALICE);
        tok.approve(address(rp), type(uint256).max);
        usdg.approve(address(rp), type(uint256).max);
        uint256 id1 = rp.borrow(10e18, 700e6);
        uint256 id2 = rp.borrow(10e18, 500e6);
        vm.stopPrank();
        assertEq(rp.marketBorrows(address(tok)), 1_200e6, "sum of the two principals at open");

        _advanceLive(30 days);
        rp.accrue();
        uint256 owed1 = rp.debtOf(id1);
        assertGt(owed1, 700e6, "interest must have accrued so owed != principal");

        vm.startPrank(ALICE);
        usdg.mint(ALICE, owed1);
        rp.repay(id1, owed1); // full close of position 1
        vm.stopPrank();

        // The cap ledger must drop by id1's PRINCIPAL (700e6), leaving EXACTLY id2's principal.
        assertEq(rp.marketBorrows(address(tok)), 500e6, "released principal not owed: remaining == id2 principal");
        assertGt(rp.debtOf(id2), 500e6, "id2 still open and carrying its own accrued interest");
    }

    function test_borrowBeyondLtvReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.Undercollateralised.selector, 701e6, 700e6));
        pool.borrow(10e18, 701e6);
    }

    function test_borrowBlockedOffHours() public {
        uint256 night = (block.timestamp / 86400) * 86400 + 1 days + 3 hours;
        vm.warp(night); px.set(200e8, night);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.borrow(10e18, 100e18);
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
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        _activate(p2);
        usdg.mint(LENDER, 500_000e6); // harness-independent liquidity
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(500_000e6, LENDER); vm.stopPrank();

        // Alice borrows at max LTV against 10 AAPL @ $200 (in session from setUp)
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 aliceId = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        // the issuer burns half of Alice's collateral out of the pool
        tok.adminBurn(address(p2), 5e18); // 10 -> 5 for the tok cohort (only Alice so far)

        // Bob borrows FRESH after the burn — his snapshot is the post-burn index, so he is insulated
        address BOB = makeAddr("bob_lifecycle");
        tok.mint(BOB, 10e18); usdg.mint(BOB, 100_000e6);
        vm.startPrank(BOB);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 bobId = p2.borrow(10e18, 700e6);
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
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // flat 10% APR
        _activate(p2);
        vm.startPrank(LENDER);
        usdg.approve(address(p2), type(uint256).max);
        p2.deposit(100_000e6, LENDER);
        vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max);
        usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
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
        uint256 bobId = pool.borrow(10e18, 700e6);
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
        pool.borrow(10e18, 0);
    }

    /// R1-AUDIT + fix #5: accrual suspends ONLY while the BORROW ASSET is paused (the one pause that blocks
    /// every repayment). A COLLATERAL-token pause must NOT forgive interest pool-wide — watching collateral
    /// tokens let an unrelated pause hand every borrower a free loan.
    function test_accrualSuspendsOnlyWhenBorrowAssetPaused() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
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
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
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
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        p2.borrow(10e18, 700e6); // a borrower generating interest (max LTV on 10 @ $200)
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
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
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

    /// F-5 sweep survivor: the withdraw liquidity guard is `>`, not `>=` — draining the pool's
    /// idle cash to exactly zero is a legitimate withdrawal, not an error.
    function test_withdrawExactlyAllIdleCashSucceeds() public {
        uint256 cash = usdg.balanceOf(address(pool));
        vm.prank(LENDER);
        pool.withdraw(cash, LENDER, LENDER);
        assertEq(usdg.balanceOf(address(pool)), 0, "every idle wei is withdrawable");
    }

    /// F-5 sweep survivor: accrue over a borrow-free stretch must not move borrowIndex. With the
    /// early return deleted the index idles upward at baseBps — invisible to debtOf (ratios cancel)
    /// but wrong to every keeper and UI reading the public index.
    function test_accrueWithoutBorrowsLeavesTheIndexAlone() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% base APR
        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        assertEq(p2.borrowIndex(), 1e18, "no borrows, no one to charge, no index movement");
        assertEq(p2.totalBorrows(), 0);
    }

    function test_borrowBeyondMarketCapReverts() public {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 500e6, maxPositionBps: 10_000 // cap below one max-LTV loan
        });
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool), m);
        _warpTimelock();
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        _beat(); _advanceLive(GRACE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.ExceedsMarketCap.selector, 700e6, 500e6));
        pool.borrow(10e18, 700e6);
    }

    function test_borrowBeyondPoolLiquidityReverts() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // empty pool: no cash at all
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.InsufficientLiquidity.selector, 700e6, 0));
        p2.borrow(10e18, 700e6);
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
        new EsseyPool(usdg, address(tok), mk, 90_000, 90_000, 90_000, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // legs individually ok, sum is not
    }

    /// Mainnet-config fix: the pool's markets.assetDecimals must MATCH the real borrow-asset decimals(), so a
    /// mis-set value (e.g. 18 against mainnet USDG's 6) can't reintroduce the 1e12 LTV over-valuation. usdg is
    /// 6-dec; a markets built with assetDecimals=18 must be un-poolable against it.
    function test_assetDecimalsMustMatchTheBorrowAsset() public {
        EsseyMarkets wrong = new EsseyMarkets(AggregatorV3Interface(address(seq)), liv, hox, ADMIN, GUARDIAN, 18); // 18 != usdg's 6
        vm.expectRevert(EsseyPool.AssetDecimalsMismatch.selector);
        new EsseyPool(usdg, address(tok), wrong, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
    }

    // ---------------------------------------------------------------- F-3: addCollateral

    function test_addCollateralAfterLiquidationReverts() public {
        uint256 id = _borrow(700e6);
        px.set(125e8, block.timestamp); // $1250 backing, 55% threshold = $687.50 < $700
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.addCollateral(id, 1e18);
    }

    function test_addCollateralRestoresHealthAndBlocksLiquidation() public {
        uint256 id = _borrow(700e6);
        px.set(125e8, block.timestamp); // underwater at 10 shares
        vm.prank(ALICE);
        pool.addCollateral(id, 5e18); // 15 @ $125 = $1875; 55% = $1031.25 > $700
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.PositionHealthy.selector);
        pool.liquidate(id);
    }

    /// F-3 conservation: a top-up adds EXACTLY `amount` to the payer's entitlement and moves
    /// nobody else's. Also the pin that addCollateral reconciles first — without it, Alice's
    /// pre-burn raw would be re-credited whole and dilute Bob.
    function test_addCollateralConservesEntitlementsAcrossABurn() public {
        uint256 aliceId = _borrow(700e6);
        address BOB = makeAddr("bob_topup");
        tok.mint(BOB, 10e18); usdg.mint(BOB, 10_000e6);
        vm.startPrank(BOB);
        tok.approve(address(pool), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        uint256 bobId = pool.borrow(10e18, 700e6);
        vm.stopPrank();

        tok.adminBurn(address(pool), 10e18); // 20 posted -> 10 survive: 5 each

        vm.prank(ALICE);
        pool.addCollateral(aliceId, 2e18); // Alice: 5 surviving + 2 fresh = 7

        uint256 bobBefore = tok.balanceOf(BOB);
        vm.prank(BOB);
        pool.repay(bobId, 700e6);
        assertEq(tok.balanceOf(BOB) - bobBefore, 5e18, "Bob untouched by Alice's top-up");

        uint256 aliceBefore = tok.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.repay(aliceId, 700e6);
        assertEq(tok.balanceOf(ALICE) - aliceBefore, 7e18, "eff_after == eff_before + amount");
    }

    /// F-3: the ABSENCE of gates is the invariant (LivenessOracle.sol:109-111). Liveness dead,
    /// off-session, market disabled, caller a stranger — the top-up must still land.
    function test_addCollateralWorksUngatedByAnyone() public {
        uint256 id = _borrow(700e6);
        vm.prank(ADMIN);
        mk.disableMarket(address(tok));
        uint256 night = (block.timestamp / 86400) * 86400 + 1 days + 3 hours;
        vm.warp(night); // hours past the last heartbeat, off-session
        assertFalse(liv.liquidationsAllowed(), "liveness gate is genuinely closed");
        assertFalse(mk.canBorrow(address(tok)), "borrow gate is genuinely closed");

        address STRANGER = makeAddr("stranger_topup");
        tok.mint(STRANGER, 3e18);
        vm.startPrank(STRANGER);
        tok.approve(address(pool), type(uint256).max);
        pool.addCollateral(id, 3e18);
        vm.stopPrank();
        (, uint256 raw,,,) = pool.positions(id);
        assertEq(raw, 13e18, "top-up landed while every gate was closed");
    }

    function test_addCollateralZeroReverts() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.ZeroAmount.selector);
        pool.addCollateral(id, 0);
    }

    function test_addCollateralOnWipedCohortReverts() public {
        uint256 aliceId = _borrow(700e6);
        address BOB = makeAddr("bob_wiped");
        tok.mint(BOB, 10e18); usdg.mint(BOB, 10_000e6);
        vm.startPrank(BOB);
        tok.approve(address(pool), type(uint256).max);
        pool.borrow(10e18, 700e6);
        vm.stopPrank();
        tok.adminBurn(address(pool), 20e18); // total burn: index -> 0 with the cohort still open

        vm.prank(ALICE);
        tok.approve(address(pool), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(CollateralReconciler.CollateralCohortWiped.selector, address(tok)));
        pool.addCollateral(aliceId, 1e18);
    }

    // ---------------------------------------------------------------- F-4: repayPartial

    function testFuzz_repayPartialReducesDebtExactly(uint256 elapsed, uint256 x) public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        elapsed = bound(elapsed, 1 hours, 3 * 365 days);
        vm.warp(block.timestamp + elapsed);
        p2.accrue();
        uint256 owedBefore = p2.debtOf(id);
        x = bound(x, 1, owedBefore - 1);

        vm.prank(ALICE);
        p2.repayPartial(id, x);
        assertEq(p2.debtOf(id), owedBefore - x, "debt falls by exactly the payment");
    }

    function test_repayPartialOfFullOwedRevertsToRepay() public {
        uint256 id = _borrow(700e6);
        uint256 owed = pool.debtOf(id);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.UseFullRepay.selector, owed, owed));
        pool.repayPartial(id, owed);
    }

    function test_repayPartialZeroReverts() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.ZeroAmount.selector);
        pool.repayPartial(id, 0);
    }

    function test_repayPartialOnClosedPositionReverts() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        pool.repay(id, 700e6);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.repayPartial(id, 1);
    }

    /// F-4: the cap gates NEW borrows only. When an interest rebase carries principal past the
    /// market cap, the paydown must never revert ExceedsMarketCap — that would brick paydowns
    /// exactly when the market is most stressed.
    function test_repayPartialNeverRevertsExceedsMarketCap() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 500e6, maxPositionBps: 10_000
        });
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(p2), m);
        _warpTimelock();
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        _beat(); _advanceLive(GRACE);

        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 500e6); // exactly at the cap
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        assertGt(p2.debtOf(id), 500e6, "interest carried the debt past the cap");

        vm.prank(ALICE);
        p2.repayPartial(id, 1e6); // must NOT revert ExceedsMarketCap
        assertEq(p2.marketBorrows(address(tok)), p2.debtOf(id), "marketBorrows tracks the rebased principal");
    }

    function test_fullRepayAfterPartialClosesNormally() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        pool.repayPartial(id, 300e6);
        assertEq(pool.debtOf(id), 400e6);
        uint256 before_ = usdg.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.repay(id, 400e6);
        assertEq(before_ - usdg.balanceOf(ALICE), 400e6, "charges only the remainder");
        assertEq(tok.balanceOf(ALICE), 1_000e18, "collateral fully returned");
        assertEq(pool.marketBorrows(address(tok)), 0, "slot freed exactly once");
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.liquidate(id);
    }

    /// F-4: a 1-wei stranger paydown is PERMISSIONLESS and changes nothing but the debt.
    function test_strangerPartialRepayChangesOnlyDebt() public {
        uint256 id = _borrow(700e6);
        uint256 aliceUsdg = usdg.balanceOf(ALICE);
        uint256 aliceTok = tok.balanceOf(ALICE);
        uint256 assetsBefore = pool.totalAssets();

        vm.prank(LIQUIDATOR); // not the Note holder
        pool.repayPartial(id, 1);

        assertEq(pool.debtOf(id), 700e6 - 1, "debt down by exactly the wei");
        assertEq(pool.marketBorrows(address(tok)), 700e6 - 1);
        assertEq(pool.note().ownerOf(id), ALICE, "deed untouched");
        (, uint256 raw,,,) = pool.positions(id);
        assertEq(raw, 10e18, "collateral untouched");
        assertEq(usdg.balanceOf(ALICE), aliceUsdg);
        assertEq(tok.balanceOf(ALICE), aliceTok);
        assertEq(pool.totalAssets(), assetsBefore, "cash up, borrows down, in lockstep");
    }

    // ------------------------------------------------- AD-1 step 3: per-position cap

    function _setPositionCap(uint16 bps, EsseyPool p) internal {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6, maxPositionBps: bps
        });
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(p), m);
        _warpTimelock();
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        _beat(); _advanceLive(GRACE);
    }

    function test_borrowPositionCapBoundaryIsExact() public {
        _setPositionCap(5, pool); // limit = 1_000_000e6 x 5bp = 500e6, inside the 700e6 LTV headroom
        vm.prank(ALICE);
        pool.borrow(10e18, 500e6); // exactly at the limit
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.ExceedsPositionCap.selector, 500e6 + 1, 500e6));
        pool.borrow(10e18, 500e6 + 1);
    }

    /// The position cap gates NEW borrows only: an interest rebase may carry a position past it,
    /// and the paydown must never revert for it (mirror of the market-cap rule above).
    function test_repayPartialIgnoresPositionCap() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR
        _setPositionCap(7, p2); // limit = 700e6: a max-LTV borrow sits exactly at it
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        uint256 owed = p2.debtOf(id);
        assertGt(owed, 700e6, "interest carried the debt past the position limit");

        vm.prank(ALICE);
        p2.repayPartial(id, 1e6); // must NOT revert ExceedsPositionCap
        assertEq(p2.debtOf(id), owed - 1e6, "paydown lands while past the limit");
    }

    // ------------------------------------------------- AD-1 step 4: writeOff (F-1)

    function _installResolver() internal returns (address R) {
        R = makeAddr("resolver");
        vm.prank(ADMIN);
        mk.proposeResolver(R);
        _warpTimelock();
        px.set(200e8, block.timestamp);
        vm.prank(ADMIN);
        mk.commitResolver();
        _beat(); _advanceLive(GRACE);
        usdg.mint(R, 100_000e6);
        vm.prank(R);
        usdg.approve(address(pool), type(uint256).max);
    }

    function test_writeOffOnlyResolver() public {
        uint256 id = _borrow(700e6);
        vm.prank(LIQUIDATOR); // resolver still unset: nobody may write off
        vm.expectRevert(EsseyPool.NotResolver.selector);
        pool.writeOff(id, 0);
        _installResolver();
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.NotResolver.selector);
        pool.writeOff(id, 0);
    }

    /// Merely-underwater is the LIQUIDATOR's territory, at market. Write-off demands strictly
    /// beyond-recovery — including the value == owed edge.
    function test_writeOffMerelyUnderwaterReverts() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        px.set(125e8, block.timestamp); // underwater (threshold $687.50) yet worth $1250 > $700
        vm.prank(R);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.NotInsolvent.selector, 1250e6, 700e6));
        pool.writeOff(id, 0);
        px.set(70e8, block.timestamp); // worth EXACTLY the debt: still not beyond recovery
        vm.prank(R);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.NotInsolvent.selector, 700e6, 700e6));
        pool.writeOff(id, 0);
    }

    function test_writeOffNeedsLiquidatableWhenCollateralSurvives() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        px.set(60e8, block.timestamp); // beyond recovery on value
        vm.warp(block.timestamp + 2 hours); // but chain liveness is unproven
        px.set(60e8, block.timestamp); // price itself fresh — the liveness gate must still hold
        assertFalse(mk.canLiquidate(address(tok)), "fixture: gate closed by liveness alone");
        vm.prank(R);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.LiquidationNotAllowed.selector, address(tok)));
        pool.writeOff(id, 0);
    }

    function test_writeOffRecoveredAboveOwedReverts() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        px.set(60e8, block.timestamp); // $600 backing $700: beyond recovery
        vm.prank(R);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.RecoveredExceedsOwed.selector, 700e6 + 1, 700e6));
        pool.writeOff(id, 700e6 + 1);
    }

    /// The AD-1 accounting core: the lender loss is EXACTLY residual - fromReserves, taken as a
    /// share-price markdown at the moment of write-off, with exposure released and the residual
    /// collateral swept to the resolver.
    function test_writeOffSharePriceDeltaIsExact() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        px.set(60e8, block.timestamp);
        uint256 assetsBefore = pool.totalAssets();
        uint256 sharesBefore = pool.balanceOf(LENDER);

        vm.expectEmit(true, true, true, true);
        emit EsseyPool.WrittenOff(id, 700e6, 600e6, 0, 100e6, 10e18);
        vm.prank(R);
        pool.writeOff(id, 600e6); // the $600 collateral-value floor (A-M1)

        assertEq(pool.totalAssets(), assetsBefore - 100e6, "loss == residual - fromReserves, exactly");
        assertEq(pool.balanceOf(LENDER), sharesBefore, "the markdown moves price, never shares");
        assertEq(pool.totalBorrows(), 0, "debt released");
        assertEq(pool.marketBorrows(address(tok)), 0, "cap slot released");
        assertEq(tok.balanceOf(R), 10e18, "residual collateral swept to the resolver");
        Note n = pool.note();
        vm.expectRevert();
        n.ownerOf(id); // deed burned
    }

    function test_writeOffReservesAbsorbBeforeLenders() public {
        address R = _installResolver();
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 5_000, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")); // 10% APR, half to reserves
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        _beat(); _advanceLive(GRACE);
        p2.accrue();
        uint256 owed = p2.debtOf(id);
        uint256 reserves = p2.totalReserves();
        assertGt(reserves, 30e6, "fixture: a year of reserves to absorb with");

        px.set(1e8, block.timestamp); // $10 backing ~$770: beyond recovery
        uint256 assetsBefore = p2.totalAssets();
        vm.startPrank(R);
        usdg.approve(address(p2), type(uint256).max);
        p2.writeOff(id, owed - 30e6); // residual 30e6, fully inside reserves
        vm.stopPrank();

        assertEq(p2.totalAssets(), assetsBefore, "reserves absorb first; lender value untouched");
        assertEq(p2.totalReserves(), reserves - 30e6, "reserves down by exactly the residual");
    }

    function test_writeOffAccruesFirst() public {
        address R = _installResolver();
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 1_000, 0, 0, 5_000, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        _activate(p2);
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        _beat(); _advanceLive(GRACE);
        px.set(1e8, block.timestamp);
        vm.startPrank(R);
        usdg.approve(address(p2), type(uint256).max);
        p2.writeOff(id, 10e6); // 10 shares @ $1 = the $10 floor; no accrue() since the warp except writeOff's own
        vm.stopPrank();
        assertEq(p2.lastAccrual(), block.timestamp, "writeOff settles against accrued debt");
        assertEq(p2.totalBorrows(), 0);
    }

    function test_writeOffTwiceReverts() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        px.set(60e8, block.timestamp);
        vm.prank(R);
        pool.writeOff(id, 600e6);
        vm.prank(R);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.writeOff(id, 600e6);
    }

    /// The wiped-cohort path must work with NO price read: when the issuer has destroyed the
    /// collateral outright the feed may be silent and liveness dead — exactly then the loss
    /// must still be recognisable.
    function test_writeOffWipedCohortNeedsNoPrice() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        tok.adminBurn(address(pool), 10e18); // issuer wipes the whole cohort
        vm.warp(block.timestamp + 200_000); // feed silent, liveness dead
        assertFalse(mk.canLiquidate(address(tok)), "fixture: every gate is closed");
        vm.prank(R);
        pool.writeOff(id, 0);
        assertEq(pool.totalBorrows(), 0, "written off with nothing readable but the balance");
        assertEq(pool.shortfallRaw(address(tok)), 10e18, "the burn was reconciled on the way");
    }

    function test_writeOffDepositSandwichCannotProfit() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        px.set(60e8, block.timestamp);
        address ATT = makeAddr("sandwich");
        usdg.mint(ATT, 100_000e6);
        vm.startPrank(ATT);
        usdg.approve(address(pool), type(uint256).max);
        uint256 sh = pool.deposit(100_000e6, ATT); // front-run the pending write-off
        vm.stopPrank();
        vm.prank(R);
        pool.writeOff(id, 600e6); // pays the floor; residual loss = 100e6
        vm.startPrank(ATT);
        uint256 got = pool.redeem(sh, ATT, ATT);
        vm.stopPrank();
        assertLt(got, 100_000e6, "front-running a write-off buys a share of the loss, not a profit");
    }

    /// A-M1: the resolver pays AT LEAST the market value of the collateral it sweeps — without
    /// the floor it could pay 0 and sweep collateral worth ~owed. Boundary exact in both
    /// directions: floor-1 reverts, floor itself lands.
    function test_writeOffRecoveredBelowCollateralFloorReverts() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        px.set(60e8, block.timestamp); // 10 shares @ $60 = $600 floor against $700 owed
        vm.prank(R);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.RecoveredBelowFloor.selector, 600e6 - 1, 600e6));
        pool.writeOff(id, 600e6 - 1);
        vm.prank(R);
        pool.writeOff(id, 600e6);
        assertEq(tok.balanceOf(R), 10e18, "collateral sweeps only once paid for at value");
    }

    // ------------------------------------------------- C-M2/B-L1: disable must not freeze positions

    function test_liquidateSucceedsOnADisabledMarket() public {
        uint256 id = _borrow(700e6);
        px.set(125e8, block.timestamp); // underwater: $1250 backing, threshold $687.50 < $700
        vm.prank(ADMIN);
        mk.disableMarket(address(tok));
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        assertEq(pool.debtOf(id), 0, "existing positions stay liquidatable after a disable");
    }

    function test_writeOffSucceedsOnADisabledMarket() public {
        address R = _installResolver();
        uint256 id = _borrow(700e6);
        px.set(60e8, block.timestamp); // $600 backing $700: beyond recovery
        vm.prank(ADMIN);
        mk.disableMarket(address(tok));
        vm.prank(R);
        pool.writeOff(id, 600e6);
        assertEq(pool.totalBorrows(), 0, "surviving dust stays write-off-able after a disable");
    }

    function test_repayStillWorksOnADisabledMarket() public {
        uint256 id = _borrow(700e6);
        vm.prank(ADMIN);
        mk.disableMarket(address(tok));
        vm.prank(ALICE);
        pool.repay(id, 700e6);
        assertEq(tok.balanceOf(ALICE), 1_000e18, "repay + collateral return survive a disable");
    }

    // ------------------------------------------------- B-M2: Notes are bearer deeds

    /// Repay authority follows the deed: after a transfer the buyer repays and takes the
    /// collateral; the original borrower is a stranger to the position.
    function test_transferredNoteMovesRepayAuthorityAndCollateral() public {
        uint256 id = _borrow(700e6);
        address BUYER = makeAddr("note_buyer");
        Note deed = pool.note(); // read BEFORE the prank: the getter call would consume it
        vm.prank(ALICE);
        deed.transferFrom(ALICE, BUYER, id);

        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.repay(id, 700e6);

        usdg.mint(BUYER, 1_000e6);
        vm.startPrank(BUYER);
        usdg.approve(address(pool), type(uint256).max);
        pool.repay(id, 700e6);
        vm.stopPrank();
        assertEq(tok.balanceOf(BUYER), 10e18, "collateral goes to the deed holder, not the opener");
    }

    /// Liquidation surplus routes to the CURRENT holder — the read-before-burn in liquidate().
    function test_transferredNoteRoutesLiquidationSurplusToHolder() public {
        uint256 id = _borrow(700e6);
        address BUYER = makeAddr("note_buyer2");
        Note deed = pool.note();
        vm.prank(ALICE);
        deed.transferFrom(ALICE, BUYER, id);

        px.set(125e8, block.timestamp); // underwater: $1250 backing, threshold $687.50 < $700
        uint256 aliceTokBefore = tok.balanceOf(ALICE);
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);

        uint256 seized = tok.balanceOf(LIQUIDATOR);
        assertLt(seized, 10e18, "fixture: a surplus exists to route");
        assertEq(tok.balanceOf(BUYER), 10e18 - seized, "surplus goes to the holder at liquidation time");
        assertEq(tok.balanceOf(ALICE), aliceTokBefore, "the original borrower gets none of it");
    }

    function test_transferredNoteKeepsRepayPartialPermissionless() public {
        uint256 id = _borrow(700e6);
        Note deed = pool.note();
        vm.prank(ALICE);
        deed.transferFrom(ALICE, makeAddr("note_buyer3"), id);
        vm.prank(LIQUIDATOR); // any stranger
        pool.repayPartial(id, 100e6);
        assertEq(pool.debtOf(id), 600e6, "stranger paydown still lands after a transfer");
    }

    // ------------------------------------------------- AD-1: single-collateral binding

    function test_identityAndCollateralAreConstructorBound() public {
        EsseyPool p2 = new EsseyPool(
            usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0,
            EsseyPool.Identity("Essey AAPL Pool Share", "aAAPL", "Essey AAPL Note", "nAAPL")
        );
        assertEq(p2.name(), "Essey AAPL Pool Share");
        assertEq(p2.symbol(), "aAAPL");
        assertEq(p2.note().name(), "Essey AAPL Note");
        assertEq(p2.note().symbol(), "nAAPL");
        assertEq(p2.collateralToken(), address(tok));
    }

    function test_withdrawBeyondCashReverts() public {
        _borrow(700e6);
        vm.prank(LENDER);
        vm.expectRevert();
        pool.withdraw(500_000e6, LENDER, LENDER);
    }
}
