// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Seat} from "../src/market/Seat.sol";
import {SeatVault} from "../src/market/SeatVault.sol";
import {Bell} from "../src/market/Bell.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract BellTest is Test {
    Seat seat;
    Bell bell;
    ERC20Mock essey; // tier-fee token (burn/treasury sink)
    ERC20Mock usdg; // reward/pot token

    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address ringer = address(0x41194);

    address constant BURN = 0x000000000000000000000000000000000000dEaD;

    // Tiers: fees 100/250/500/1500 $ESSEY, weights 100/160/200/333 (StonkBrokers-shaped).
    uint256[] fees = [100e18, 250e18, 500e18, 1500e18];
    uint256[] weights = [100, 160, 200, 333];

    function setUp() public {
        seat = new Seat("Essey Seat", "SEAT", 4444, address(this));
        essey = new ERC20Mock();
        usdg = new ERC20Mock();
        bell = new Bell(seat, essey, usdg, treasury, 100e18, 100, fees, weights, IConverter(address(0))); // minRing 100, tip 1%
        seat.setHook(address(bell));

        for (uint256 i = 0; i < 3; i++) {
            address who = [alice, bob, carol][i];
            essey.mint(who, 10_000e18);
            vm.prank(who);
            essey.approve(address(bell), type(uint256).max);
        }
    }

    function _fund(uint256 amount) internal {
        usdg.mint(address(bell), amount); // fees arrive by plain transfer — pot() detects them
    }

    /// Activation: owner-only, fee split 50% burn / 50% treasury, weight registered.
    function test_ActivateFeeSplitAndAuth() public {
        uint256 id = seat.mint(alice);

        vm.prank(bob);
        vm.expectRevert(Bell.NotSeatOwner.selector);
        bell.activate(id, 1);

        vm.prank(alice);
        bell.activate(id, 2); // fee 250
        assertEq(essey.balanceOf(BURN), 125e18, "half burned");
        assertEq(essey.balanceOf(treasury), 125e18, "half to treasury");
        assertEq(bell.totalWeight(), 160);

        vm.prank(alice);
        vm.expectRevert(Bell.AlreadyActive.selector);
        bell.activate(id, 3);
    }

    /// The core flow: fees accrue -> anyone rings (earns tip) -> claims land in the Seats' Vaults
    /// pro-rata by tier weight.
    function test_RingDistributesByWeight() public {
        uint256 a = seat.mint(alice); // T1, weight 100
        uint256 b = seat.mint(bob); // T3, weight 200
        vm.prank(alice);
        bell.activate(a, 1);
        vm.prank(bob);
        bell.activate(b, 3);

        _fund(3000e18);
        vm.prank(ringer);
        bell.ring();

        // Tip: 1% of 3000 = 30. Distributed: 2970 across weight 300 -> 9.9/weight.
        assertEq(usdg.balanceOf(ringer), 30e18, "ringer tip");

        bell.claim(a); // permissionless, pays only to the vault
        bell.claim(b);
        assertEq(usdg.balanceOf(seat.vaultOf(a)), 990e18, "weight 100 share");
        assertEq(usdg.balanceOf(seat.vaultOf(b)), 1980e18, "weight 200 share");
        assertEq(bell.reserved(), 0, "all credited rewards claimed");
    }

    /// Ring guards: pot below threshold reverts; no active seats reverts (pot keeps accruing).
    function test_RingGuards() public {
        _fund(99e18);
        vm.expectRevert(Bell.PotBelowMinimum.selector);
        bell.ring();

        _fund(1e18); // pot now exactly minRing, but nobody active
        vm.expectRevert(Bell.NoActiveSeats.selector);
        bell.ring();
    }

    /// A Seat activated AFTER a ring gets nothing retroactively.
    function test_NoRetroactiveRewards() public {
        uint256 a = seat.mint(alice);
        vm.prank(alice);
        bell.activate(a, 1);

        _fund(1000e18);
        bell.ring();

        uint256 b = seat.mint(bob);
        vm.prank(bob);
        bell.activate(b, 4); // huge weight, but late
        assertEq(bell.pendingOf(b), 0, "late activation earns nothing from past rings");
        assertGt(bell.pendingOf(a), 0);
    }

    /// Upgrade: pays only the fee delta; rewards accrued at the old weight are preserved; future rings
    /// pay at the new weight.
    function test_UpgradePreservesPendingAndReweights() public {
        uint256 a = seat.mint(alice);
        uint256 b = seat.mint(bob);
        vm.prank(alice);
        bell.activate(a, 1); // weight 100
        vm.prank(bob);
        bell.activate(b, 1); // weight 100

        _fund(2000e18);
        bell.ring(); // 1980 over 200 weight -> 990 each
        uint256 pendingBefore = bell.pendingOf(a);
        assertEq(pendingBefore, 990e18);

        uint256 burnBefore = essey.balanceOf(BURN);
        vm.prank(alice);
        bell.upgrade(a, 3); // delta fee 500-100 = 400
        assertEq(essey.balanceOf(BURN) - burnBefore, 200e18, "half the delta burned");
        assertEq(bell.pendingOf(a), pendingBefore, "old rewards unchanged by upgrade");

        _fund(3000e18);
        bell.ring(); // 2970 over 300 weight (200 + 100)
        bell.claim(a);
        bell.claim(b);
        assertEq(usdg.balanceOf(seat.vaultOf(a)), 990e18 + 1980e18, "990 old + 2/3 of new ring");
        assertEq(usdg.balanceOf(seat.vaultOf(b)), 990e18 + 990e18, "990 old + 1/3 of new ring");
    }

    /// The per-owner rule: transferring a Seat clears its Tier (buyer re-activates), but rewards the
    /// Seat already earned stay claimable — into the Vault that travelled with it.
    function test_TransferClearsTierKeepsRewards() public {
        uint256 a = seat.mint(alice);
        vm.prank(alice);
        bell.activate(a, 2);

        _fund(1000e18);
        bell.ring();
        uint256 earned = bell.pendingOf(a);
        assertEq(earned, 990e18);

        vm.prank(alice);
        seat.transferFrom(alice, bob, a);

        (uint8 tier, uint248 weight,,) = bell.seats(a);
        assertEq(tier, 0, "tier cleared on transfer");
        assertEq(weight, 0);
        assertEq(bell.totalWeight(), 0, "weight deregistered");
        assertEq(bell.pendingOf(a), earned, "earned rewards survive the transfer");

        bell.claim(a);
        assertEq(usdg.balanceOf(seat.vaultOf(a)), earned, "rewards land in the vault bob now holds");

        // Bob must pay his own activation to earn from future rings.
        _fund(1000e18);
        vm.expectRevert(Bell.NoActiveSeats.selector);
        bell.ring();
        vm.prank(bob);
        bell.activate(a, 1);
        bell.ring();
        assertGt(bell.pendingOf(a), earned - 1, "accrues again once re-activated");
    }

    /// Accounting stays exact across multiple rings with interleaved claims: reserved tracks what is
    /// owed, pot() only ever sees new fees.
    function test_MultiRingAccounting() public {
        uint256 a = seat.mint(alice);
        uint256 b = seat.mint(bob);
        vm.prank(alice);
        bell.activate(a, 1);
        vm.prank(bob);
        bell.activate(b, 1);

        _fund(1000e18);
        bell.ring();
        bell.claim(a); // claim one seat only

        _fund(500e18);
        bell.ring();
        bell.claim(a);
        bell.claim(b);

        // Total in: 1500. Tips: 10 + 5. Distributed: 1485, split evenly (equal weights).
        assertEq(usdg.balanceOf(seat.vaultOf(a)), 742.5e18);
        assertEq(usdg.balanceOf(seat.vaultOf(b)), 742.5e18);
        assertEq(bell.reserved(), 0);
        assertEq(bell.pot(), 0, "nothing stranded");
    }

    /// Only the Seat contract may invoke the transfer hook.
    function test_HookAuth() public {
        vm.expectRevert(Bell.NotSeatContract.selector);
        bell.onSeatTransfer(1, alice, bob);
    }

    /// Rescue without trust: mis-sent tokens are recoverable by anyone, only to the treasury — and the
    /// reward token (the pot + reserved rewards) can never be swept.
    function test_SweepRecoversMisSentButNeverThePot() public {
        uint256 a = seat.mint(alice);
        vm.prank(alice);
        bell.activate(a, 1);
        _fund(1000e18);
        bell.ring(); // some of the balance is now reserved for claims

        // Mis-send a random token; anyone can sweep it to the treasury.
        ERC20Mock stray = new ERC20Mock();
        stray.mint(address(bell), 77e18);
        vm.prank(bob); // no privileged caller
        bell.sweep(stray);
        assertEq(stray.balanceOf(treasury), 77e18, "mis-sent token recovered to treasury");

        // The reward token is untouchable — pot and owed rewards cannot be drained.
        vm.expectRevert(Bell.CannotSweepReward.selector);
        bell.sweep(usdg);
        bell.claim(a);
        assertEq(usdg.balanceOf(seat.vaultOf(a)), 990e18, "owed rewards unaffected");
    }
}
