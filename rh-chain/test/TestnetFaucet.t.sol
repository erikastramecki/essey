// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestnetFaucet, IMintableMock} from "../src/testnet/TestnetFaucet.sol";

contract MockUSDG is ERC20 {
    constructor() ERC20("Mock USDG", "USDG") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract EsseyLike is ERC20 {
    constructor() ERC20("Essey", "ESSEY") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract TestnetFaucetTest is Test {
    EsseyLike essey;
    MockUSDG usdg;
    TestnetFaucet faucet;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant ESSEY_DRIP = 100_000e18; // enough to activate Bell tier 1 (66,666)
    uint256 constant USDG_DRIP = 1_000e18;
    uint256 constant COOLDOWN = 8 hours;

    function setUp() public {
        essey = new EsseyLike();
        usdg = new MockUSDG();
        faucet = new TestnetFaucet(IERC20(address(essey)), IMintableMock(address(usdg)), owner, ESSEY_DRIP, USDG_DRIP, COOLDOWN);
        essey.mint(address(faucet), 50_000_000e18); // fund the faucet
    }

    function test_ConstructorGuards() public {
        vm.expectRevert(TestnetFaucet.ZeroAddress.selector);
        new TestnetFaucet(IERC20(address(essey)), IMintableMock(address(usdg)), address(0), ESSEY_DRIP, USDG_DRIP, COOLDOWN);
        vm.expectRevert(TestnetFaucet.TooLarge.selector);
        new TestnetFaucet(IERC20(address(essey)), IMintableMock(address(usdg)), owner, 10_000_001e18, USDG_DRIP, COOLDOWN);
        vm.expectRevert(TestnetFaucet.TooLarge.selector);
        new TestnetFaucet(IERC20(address(essey)), IMintableMock(address(usdg)), owner, ESSEY_DRIP, 1_000_001e18, COOLDOWN);
    }

    function test_DripPaysEsseyAndMintsUsdg() public {
        vm.prank(alice);
        faucet.drip();
        assertEq(essey.balanceOf(alice), ESSEY_DRIP, "100k ESSEY dripped from the faucet balance");
        assertEq(usdg.balanceOf(alice), USDG_DRIP, "1k USDG minted");
        assertGe(essey.balanceOf(alice), 66_666e18, "enough to activate Bell tier 1");
    }

    function test_CooldownGates() public {
        vm.prank(alice);
        faucet.drip();
        vm.prank(alice);
        vm.expectRevert(); // TooSoon
        faucet.drip();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice);
        faucet.drip(); // allowed after the cooldown
        assertEq(essey.balanceOf(alice), 2 * ESSEY_DRIP);
    }

    function test_SetDripsOwnerOnlyAndCapped() public {
        vm.prank(alice);
        vm.expectRevert(TestnetFaucet.NotOwner.selector);
        faucet.setDrips(200_000e18, USDG_DRIP, COOLDOWN);

        faucet.setDrips(250_000e18, 2_000e18, 1 hours); // owner retunes — no redeploy
        vm.prank(bob);
        faucet.drip();
        assertEq(essey.balanceOf(bob), 250_000e18, "new amount takes effect immediately");
        assertEq(usdg.balanceOf(bob), 2_000e18);

        vm.expectRevert(TestnetFaucet.TooLarge.selector);
        faucet.setDrips(10_000_001e18, USDG_DRIP, COOLDOWN); // cap holds on the setter too
    }

    function test_ZeroDripLegsAreSkipped() public {
        faucet.setDrips(ESSEY_DRIP, 0, COOLDOWN); // USDG off
        vm.prank(alice);
        faucet.drip();
        assertEq(essey.balanceOf(alice), ESSEY_DRIP);
        assertEq(usdg.balanceOf(alice), 0, "zero USDG leg minted nothing");
    }

    function test_OwnerTransferAndRecover() public {
        vm.prank(alice);
        vm.expectRevert(TestnetFaucet.NotOwner.selector);
        faucet.recover(1e18);

        uint256 before = essey.balanceOf(owner);
        faucet.recover(1_000_000e18); // move leftover $ESSEY back to owner (re-point to a new faucet)
        assertEq(essey.balanceOf(owner) - before, 1_000_000e18);

        faucet.setOwner(bob);
        assertEq(faucet.owner(), bob);
        vm.expectRevert(TestnetFaucet.NotOwner.selector);
        faucet.setDrips(1, 1, 1); // old owner locked out
    }

    function test_DripRevertsWhenDry() public {
        faucet.recover(essey.balanceOf(address(faucet))); // drain the faucet
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance
        faucet.drip();
    }
}
