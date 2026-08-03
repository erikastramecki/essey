// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Seat} from "../src/market/Seat.sol";
import {SeatVault} from "../src/market/SeatVault.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SeatTest is Test {
    Seat seat;
    ERC20Mock stock; // stand-in for a Robinhood Stock Token held as collateral/reward

    address minter = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        seat = new Seat("Essey Seat", "SEAT", 4444, minter);
        stock = new ERC20Mock();
    }

    /// The core primitive: mint -> the Vault exists and is owned by the Seat holder -> assets sealed in
    /// the Vault travel with the Seat on transfer, and control follows ownership.
    function test_VaultTravelsWithSeat() public {
        uint256 id = seat.mint(alice);
        address vault = seat.vaultOf(id);

        // The Vault is owned by whoever holds the Seat.
        assertEq(SeatVault(payable(vault)).owner(), alice, "vault owner is Seat holder");

        // Seal collateral into the Vault.
        stock.mint(vault, 1000e18);
        assertEq(stock.balanceOf(vault), 1000e18);

        // The holder can move assets out of their own Vault.
        vm.prank(alice);
        SeatVault(payable(vault)).execute(address(stock), 0, abi.encodeCall(IERC20.transfer, (alice, 100e18)));
        assertEq(stock.balanceOf(alice), 100e18, "holder can withdraw");
        assertEq(stock.balanceOf(vault), 900e18);

        // A non-holder cannot touch someone else's Vault.
        vm.prank(bob);
        vm.expectRevert(SeatVault.NotOwner.selector);
        SeatVault(payable(vault)).execute(address(stock), 0, abi.encodeCall(IERC20.transfer, (bob, 1)));

        // Transfer the Seat -> the Vault (and its 900 stock) travel with it; control moves to bob.
        vm.prank(alice);
        seat.transferFrom(alice, bob, id);
        assertEq(SeatVault(payable(vault)).owner(), bob, "control follows the Seat");
        assertEq(stock.balanceOf(vault), 900e18, "contents stay sealed in the Vault");

        // Alice can no longer touch it; bob now can.
        vm.prank(alice);
        vm.expectRevert(SeatVault.NotOwner.selector);
        SeatVault(payable(vault)).execute(address(stock), 0, abi.encodeCall(IERC20.transfer, (alice, 1)));

        vm.prank(bob);
        SeatVault(payable(vault)).execute(address(stock), 0, abi.encodeCall(IERC20.transfer, (bob, 900e18)));
        assertEq(stock.balanceOf(bob), 900e18, "new holder controls the sealed collateral");
    }

    /// The Vault address is deterministic and its binding is correct.
    function test_DeterministicVaultBinding() public {
        uint256 id = seat.mint(alice);
        address vault = seat.vaultOf(id);
        assertEq(SeatVault(payable(vault)).tokenContract(), address(seat));
        assertEq(SeatVault(payable(vault)).tokenId(), id);
    }

    /// The Vault is initialized exactly once, at mint — a second attempt reverts.
    function test_VaultInitializedOnce() public {
        uint256 id = seat.mint(alice);
        address vault = seat.vaultOf(id);
        vm.expectRevert(SeatVault.AlreadyInitialized.selector);
        SeatVault(payable(vault)).initialize(address(seat), id);
    }

    /// Only the designated minter can mint; the collection is capped.
    function test_MintAuthAndCap() public {
        vm.prank(bob);
        vm.expectRevert(Seat.NotMinter.selector);
        seat.mint(bob);

        Seat small = new Seat("Tiny", "TINY", 1, address(this));
        small.mint(alice);
        vm.expectRevert(Seat.SoldOut.selector);
        small.mint(alice);
    }
}
