// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EsseyPoolTest} from "./EsseyPool.t.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {Note} from "../src/market/Note.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// The bearer-note property: a position is a transferable deed. Subclasses the pool's own harness so
/// every scenario runs against the exact market/oracle/liveness configuration the audited suite uses.
contract NoteTest is EsseyPoolTest {
    address BOB;

    function setUp() public override {
        super.setUp();
        BOB = makeAddr("bob");
        usdg.mint(BOB, 100_000e6);
        vm.prank(BOB);
        usdg.approve(address(pool), type(uint256).max);
    }

    function test_NoteMintedToBorrowerOnBorrow() public {
        uint256 id = _borrow(700e6);
        Note n = pool.note();
        assertEq(n.ownerOf(id), ALICE, "deed minted to the borrower");
        assertEq(n.pool(), address(pool));
    }

    /// The headline: sell the position mid-life. The buyer becomes the borrower — repays, and
    /// receives the collateral.
    function test_SoldNote_NewOwnerRepaysAndReceivesCollateral() public {
        uint256 id = _borrow(700e6);
        Note n = pool.note();
        vm.prank(ALICE);
        n.transferFrom(ALICE, BOB, id);

        // The seller is no longer the borrower.
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.repay(id, 700e6);

        uint256 bobStockBefore = tok.balanceOf(BOB);
        vm.prank(BOB);
        pool.repay(id, 700e6);
        assertEq(tok.balanceOf(BOB) - bobStockBefore, 10e18, "collateral released to the deed holder");
        assertEq(tok.balanceOf(ALICE), 990e18, "seller got nothing back");
    }

    /// A spent deed cannot exist: the Note burns in the pool's single close path.
    function test_NoteBurnedOnClose() public {
        uint256 id = _borrow(700e6);
        Note n = pool.note();
        vm.startPrank(ALICE);
        pool.repay(id, 700e6);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        n.ownerOf(id);

        // And the closed position still rejects a second repay, exactly as before the Note existed.
        vm.prank(ALICE);
        vm.expectRevert(EsseyPool.NotBorrower.selector);
        pool.repay(id, 700e6);
    }

    /// F3 carried into bearer semantics: the liquidation surplus goes to whoever HOLDS the deed at
    /// liquidation time, and the deed burns with the position.
    function test_LiquidationRefundsCurrentHolder() public {
        uint256 id = _borrow(700e6);
        Note n = pool.note();
        vm.prank(ALICE);
        n.transferFrom(ALICE, BOB, id);

        _walkPrice(125e8); // $2000 -> $1250 collateral: underwater at 55% threshold
        _beat();

        uint256 bobBefore = tok.balanceOf(BOB);
        vm.prank(LIQUIDATOR);
        pool.liquidate(id);
        assertGt(tok.balanceOf(BOB) - bobBefore, 0, "surplus refunded to the current deed holder");
        assertEq(tok.balanceOf(ALICE), 990e18, "seller receives nothing");

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        n.ownerOf(id);
    }

    /// Only the pool can mint or burn deeds.
    function test_NoteMintBurnPoolOnly() public {
        Note n = pool.note();
        vm.expectRevert(Note.NotPool.selector);
        n.mint(ALICE, 999);
        vm.expectRevert(Note.NotPool.selector);
        n.burn(1);
    }
}
