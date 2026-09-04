// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EsseyPoolTest} from "./EsseyPool.t.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {EsseyMarkets} from "../src/EsseyMarkets.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {Note} from "../src/market/Note.sol";

/// borrowMore / removeCollateral — the AD-1 batch-or-never pair. Reuses the EsseyPoolTest harness:
/// ALICE holds 10 shares @ $200 = $2000 collateral, 35% LTV, 55% liquidation threshold, on a
/// zero-rate pool unless a test builds its own accrual pool.
contract BorrowMoreRemoveCollateralTest is EsseyPoolTest {
    /// Re-commit `pool`'s market with a new static cap / position-cap through the real pipeline.
    function _recommit(uint128 cap, uint16 posBps) internal {
        EsseyMarkets.Market memory m = EsseyMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: cap, maxPositionBps: posBps
        });
        vm.prank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 86_400, 90_000, 8, address(tok), address(pool), m);
        _warpTimelock();
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        _beat(); _advanceLive(GRACE);
    }

    // ---------------------------------------------------------------- borrowMore: LTV

    function test_borrowMoreUpToLtvSucceeds() public {
        uint256 id = _borrow(400e6);
        uint256 usdgBefore = usdg.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.borrowMore(id, 300e6); // 400 + 300 = 700 = the max-LTV limit
        assertEq(pool.debtOf(id), 700e6, "debt grew by exactly the draw");
        assertEq(pool.marketBorrows(address(tok)), 700e6, "marketBorrows tracks the new principal");
        assertEq(pool.totalBorrows(), 700e6, "totalBorrows rose by the draw");
        assertEq(usdg.balanceOf(ALICE) - usdgBefore, 300e6, "the draw reached the borrower");
    }

    function test_borrowMoreOneWeiPastLtvReverts() public {
        uint256 id = _borrow(400e6);
        vm.prank(ALICE);
        pool.borrowMore(id, 300e6); // now exactly at 700e6
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.Undercollateralised.selector, 700e6 + 1, 700e6));
        pool.borrowMore(id, 1);
    }

    /// borrowMore on an unhealthy position is impossible — the LTV gate blocks it.
    function test_borrowMoreOnUnderwaterPositionReverts() public {
        uint256 id = _borrow(700e6);
        _walkPrice(125e8); // 10 @ $125 = $1250; LTV max = $437.5 << $700 owed
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.Undercollateralised.selector, 700e6 + 1e6, 437.5e6));
        pool.borrowMore(id, 1e6);
    }

    // ---------------------------------------------------------------- borrowMore: auth + bearer

    function test_borrowMoreByNonOwnerReverts() public {
        uint256 id = _borrow(400e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.borrowMore(id, 100e6);
    }

    /// The bearer-position debt pump: growing the debt follows the Note, not the opener. After a
    /// transfer the opener cannot draw, and the new holder draws to themselves.
    function test_borrowMoreFollowsNoteTransfer() public {
        uint256 id = _borrow(400e6);
        address BUYER = makeAddr("bm_buyer");
        Note deed = pool.note();
        vm.prank(ALICE);
        deed.transferFrom(ALICE, BUYER, id);

        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.borrowMore(id, 100e6);

        vm.prank(BUYER);
        pool.borrowMore(id, 100e6);
        assertEq(pool.debtOf(id), 500e6, "the holder grew the debt");
        assertEq(usdg.balanceOf(BUYER), 100e6, "the draw reached the new holder, not the opener");
    }

    // ---------------------------------------------------------------- borrowMore: caps + gates

    function test_borrowMoreBreachingMarketCapReverts() public {
        _recommit(500e6, 10_000); // cap below one max-LTV loan
        uint256 id = _borrow(400e6);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.ExceedsMarketCap.selector, 600e6, 500e6));
        pool.borrowMore(id, 200e6); // would = 400 + 200 = 600 > 500
    }

    function test_borrowMoreBreachingPositionCapReverts() public {
        _recommit(1_000_000e6, 5); // posLimit = 1_000_000e6 x 5bp = 500e6
        uint256 id = _borrow(400e6);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.ExceedsPositionCap.selector, 550e6, 500e6));
        pool.borrowMore(id, 150e6); // newPrincipal 550 > 500, under both cap and LTV
    }

    function test_borrowMoreOffSessionReverts() public {
        uint256 id = _borrow(400e6);
        uint256 night = (block.timestamp / 86400) * 86400 + 1 days + 3 hours;
        vm.warp(night); px.set(200e8, night);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.borrowMore(id, 100e6);
    }

    /// A retired (superseded) pool must not open new debt on an existing position either — the
    /// F1 activePool gate applies to borrowMore exactly as to borrow.
    function test_borrowMoreOnRetiredPoolReverts() public {
        uint256 id = _borrow(400e6);
        EsseyPool p3 = new EsseyPool(
            usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0,
            EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")
        );
        _activate(p3); // activePool[tok] -> p3; `pool` is now retired
        assertTrue(mk.canBorrow(address(tok)), "fixture: the market itself is still open");
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NotActivePool.selector);
        pool.borrowMore(id, 100e6);
    }

    function test_borrowMoreZeroReverts() public {
        uint256 id = _borrow(400e6);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.ZeroAmount.selector);
        pool.borrowMore(id, 0);
    }

    function test_borrowMoreOnClosedPositionReverts() public {
        uint256 id = _borrow(400e6);
        vm.prank(ALICE);
        pool.repay(id, 400e6);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.borrowMore(id, 1e6);
    }

    /// The correctness core of the rebase: accrued interest is folded into principal AND into
    /// marketBorrows, so marketBorrows still equals the position's debt afterwards, and the
    /// borrower owes their prior debt plus exactly the new draw — no interest escapes.
    function test_borrowMoreFoldsAccruedInterestIntoMarketBorrows() public {
        EsseyPool p2 = new EsseyPool(
            usdg, address(tok), mk, 1_000, 0, 0, 0, address(0), address(0x7EA), 0,
            EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE")
        ); // 10% APR
        _activate(p2);
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(10e18, 400e6);
        vm.stopPrank();

        _seedOracle(); // ~21 days of live keeper cadence: interest accrues, depth stays fresh, ends in session
        p2.accrue();
        uint256 owedBefore = p2.debtOf(id);
        assertGt(owedBefore, 400e6, "fixture: interest accrued over the seeding window");

        vm.prank(ALICE);
        p2.borrowMore(id, 100e6);
        assertEq(p2.debtOf(id), owedBefore + 100e6, "owes prior debt + draw; no interest escaped");
        assertEq(p2.marketBorrows(address(tok)), p2.debtOf(id), "marketBorrows == rebased principal");
        assertEq(p2.totalBorrows(), owedBefore + 100e6, "totalBorrows rose by only the draw");
    }

    // ---------------------------------------------------------------- removeCollateral: LTV boundary

    /// Down to the LTV floor succeeds; one wei past reverts. 350e6 debt needs 5 shares ($1000 x
    /// 35% = $350), so 5 of the 10 posted are withdrawable.
    function test_removeCollateralToLtvFloorSucceeds() public {
        uint256 id = _borrow(350e6);
        uint256 tokBefore = tok.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.removeCollateral(id, 5e18); // remaining 5e18, exactly the floor
        assertEq(tok.balanceOf(ALICE) - tokBefore, 5e18, "collateral returned to the holder");
        (, uint256 raw,,,) = pool.positions(id);
        assertEq(raw, 5e18, "position collateral reduced to the floor");
    }

    function test_removeCollateralOneWeiPastFloorReverts() public {
        uint256 id = _borrow(350e6);
        vm.prank(ALICE);
        pool.removeCollateral(id, 5e18); // at the floor
        // Literals, not `mk.maxBorrow(...)` read back: this is the file's one deterministic
        // remainder (5e18 - 1 @ $200 = 999_999_999.9998), and the old self-referential form made
        // both the truncation and the LTV cut unfalsifiable.
        assertEq(pool.debtOf(id), 350e6, "zero-rate pool: the debt did not move");
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.Undercollateralised.selector, 350e6, 349_999_999));
        pool.removeCollateral(id, 1);
    }

    /// The LTV gate (35%) binds well before the liquidation threshold (55%), so a removal can never
    /// cross a position into liquidatable territory: at the LTV floor it is provably NOT underwater.
    function test_removeCollateralCannotCrossIntoLiquidatable() public {
        uint256 id = _borrow(350e6);
        // leaving 3e18 @ $200 = $600; 55% threshold = $330 < $350 owed => that WOULD be liquidatable
        uint256 max3 = mk.maxBorrow(address(tok), 3e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.Undercollateralised.selector, 350e6, max3));
        pool.removeCollateral(id, 7e18);
        // and at the deepest legal removal (the LTV floor) the position stays clear of liquidation
        vm.prank(ALICE);
        pool.removeCollateral(id, 5e18);
        assertFalse(mk.isUnderwater(address(tok), 5e18, pool.debtOf(id)), "LTV floor stays clear of liq threshold");
    }

    function test_removeCollateralByNonOwnerReverts() public {
        uint256 id = _borrow(350e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.removeCollateral(id, 1e18);
    }

    function test_removeCollateralExceedingBalanceReverts() public {
        uint256 id = _borrow(350e6);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.InsufficientLiquidity.selector, 11e18, 10e18));
        pool.removeCollateral(id, 11e18);
    }

    /// Removing the ENTIRE balance is a health failure, not a liquidity one: `amount == eff` clears
    /// the balance guard and the LTV check rejects it (0 collateral can back no debt). Pins the
    /// `>` boundary against a `>=` that would misreport InsufficientLiquidity.
    function test_removeCollateralAllRevertsOnLtv() public {
        uint256 id = _borrow(350e6);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.Undercollateralised.selector, 350e6, 0));
        pool.removeCollateral(id, 10e18);
    }

    function test_removeCollateralZeroReverts() public {
        uint256 id = _borrow(350e6);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.ZeroAmount.selector);
        pool.removeCollateral(id, 0);
    }

    function test_removeCollateralOnClosedPositionReverts() public {
        uint256 id = _borrow(350e6);
        vm.prank(ALICE);
        pool.repay(id, 350e6);
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NoDebt.selector);
        pool.removeCollateral(id, 1e18);
    }

    /// After a legal removal the position liquidates on the REDUCED collateral — the withdrawal
    /// truly leaves the books, so a later price drop seizes against 5 shares, not the original 10.
    function test_removeCollateralThenLiquidate() public {
        uint256 id = _borrow(350e6);
        vm.prank(ALICE);
        pool.removeCollateral(id, 5e18); // remaining 5e18
        _walkPrice(120e8); // 5 @ $120 = $600; 55% = $330 < $350 owed => liquidatable
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        assertEq(pool.debtOf(id), 0, "closed via liquidation on the reduced collateral");
        assertLt(tok.balanceOf(LIQUIDATOR), 5e18, "seizure came from the 5-share remainder, not 10");
    }

    // ---------------------------------------------------------------- removeCollateral: new-risk gates

    /// removeCollateral is a risk-INCREASING action (a withdrawal), so it takes the same new-risk
    /// gates as borrow/borrowMore. A depth-oracle cap of 0 (AD-2 fail-closed) makes canBorrow false,
    /// so it blocks removeCollateral exactly as it blocks borrowMore — the earlier "removal is only
    /// LTV-gated" carve-out let a holder withdraw during a corporate-action desync at a ~2x-high price.
    function test_capZeroBlocksBorrowMoreAndRemoveCollateral() public {
        uint256 id = _borrow(350e6);
        vm.warp(block.timestamp + 25 hours); // depth reading ages out (MAX_READING_AGE 24h)
        px.set(200e8, block.timestamp); // keep the PRICE fresh (maxStaleness 25h)
        assertEq(mk.borrowCap(address(tok)), 0, "fixture: depth cap collapsed to 0");

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.borrowMore(id, 1e6);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.removeCollateral(id, 1e18); // a withdrawal is new risk -> the same closed gate blocks it
    }

    /// Off-session, removeCollateral reverts MarketClosed — the same session gate borrowMore takes.
    /// Mirrors test_borrowMoreOffSessionReverts: a borrower needing collateral back off-hours full-repays.
    function test_removeCollateralOffSessionReverts() public {
        uint256 id = _borrow(350e6);
        uint256 night = (block.timestamp / 86400) * 86400 + 1 days + 3 hours;
        vm.warp(night); px.set(200e8, night);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.removeCollateral(id, 1e18);
    }

    /// During a corporate-action desync, removeCollateral reverts MarketClosed. Uses the OBSERVED-move
    /// path (a live uiMultiplier flip with no schedule): removeCollateral's own syncMultiplier stamps
    /// the move, and the desync guard inside canBorrow then blocks it — the same FIRST-action-is-gated
    /// design the borrow/liquidate paths rely on. Dropping either syncMultiplier or canBorrow reopens
    /// the withdrawal at the ~2x-mispriced feed.
    function test_removeCollateralDuringDesyncReverts() public {
        uint256 id = _borrow(350e6); // borrow seeds seenMultiplier[tok] = 1e18
        tok.setMultiplier(2e18); // the split APPLIES: uiMultiplier flips, no schedule (newUIMultiplier stays 0)
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(EsseyPool.MarketClosed.selector, address(tok)));
        pool.removeCollateral(id, 1e18);
    }
}
