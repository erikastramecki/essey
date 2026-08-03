// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MintDistributor} from "../src/market/MintDistributor.sol";
import {Seat} from "../src/market/Seat.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract MintDistributorTest is Test, IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector; // reserved mints in some tests land here
    }

    MintDistributor dist;
    Seat seat;

    address admin = address(this); // the test acts as the curating admin/multisig
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint256 constant STAGE_FOUNDING = 0;
    uint256 constant STAGE_GENERAL = 1;
    uint256 constant RESERVE_CAP = 50;
    uint256 constant TIMELOCK = 2 days;
    uint256 constant MAX_SUPPLY = 2222;

    // Founding stage tree: alice=2, bob=1. General tree (separate root): carol=1.
    bytes32 aliceLeaf;
    bytes32 bobLeaf;
    bytes32 foundingRoot;

    function setUp() public {
        // Deploy order lock: distributor FIRST, then Seat with the distributor as immutable minter.
        dist = new MintDistributor(admin, RESERVE_CAP, TIMELOCK);
        seat = new Seat("Essey Seat", "SEAT", MAX_SUPPLY, address(dist));
        dist.initSeat(seat);

        aliceLeaf = _leaf(alice, STAGE_FOUNDING, 2);
        bobLeaf = _leaf(bob, STAGE_FOUNDING, 1);
        foundingRoot = _pair(aliceLeaf, bobLeaf); // 2-leaf tree

        _commitRoot(STAGE_FOUNDING, foundingRoot);
        dist.setStageOpen(STAGE_FOUNDING, true);
    }

    // ------------------------------------------------- leaf/proof helpers (mirror OZ merkle-tree)

    function _leaf(address account, uint256 stage, uint256 alloc) internal view returns (bytes32) {
        // Sanity: the contract's own view must agree with our local hashing.
        bytes32 h = keccak256(bytes.concat(keccak256(abi.encode(account, stage, alloc))));
        assertEq(h, dist.leafOf(account, stage, alloc), "leaf hashing mismatch vs contract");
        return h;
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _commitRoot(uint256 stage, bytes32 root) internal {
        dist.proposeRoot(stage, root);
        vm.warp(block.timestamp + TIMELOCK);
        dist.commitRoot(stage);
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    // ------------------------------------------------- deploy-order lock

    function test_DistributorIsSoleMinter() public view {
        assertEq(seat.minter(), address(dist), "distributor is the Seat's immutable minter");
        assertEq(address(dist.seat()), address(seat));
    }

    function test_InitSeatIsOneShot() public {
        vm.expectRevert(MintDistributor.SeatAlreadySet.selector);
        dist.initSeat(seat);
    }

    function test_InitSeatRejectsForeignSeat() public {
        MintDistributor other = new MintDistributor(admin, RESERVE_CAP, TIMELOCK);
        // `seat`'s minter is `dist`, not `other` — wiring it into `other` must fail.
        vm.expectRevert(MintDistributor.NotMinterOfSeat.selector);
        other.initSeat(seat);
    }

    function test_ClaimBeforeSeatSetReverts() public {
        MintDistributor fresh = new MintDistributor(admin, RESERVE_CAP, TIMELOCK);
        fresh.proposeRoot(STAGE_FOUNDING, foundingRoot);
        vm.warp(block.timestamp + TIMELOCK);
        fresh.commitRoot(STAGE_FOUNDING);
        fresh.setStageOpen(STAGE_FOUNDING, true);
        vm.prank(alice);
        vm.expectRevert(MintDistributor.SeatNotSet.selector);
        fresh.claim(STAGE_FOUNDING, 2, _proof(bobLeaf));
    }

    // ------------------------------------------------- Bell hook wiring (passthrough)

    function test_SetSeatHookWiresTheBell() public {
        // The distributor is the Seat's immutable minter, so ONLY this passthrough can set the hook.
        address bell = address(0xBE11);
        dist.setSeatHook(bell);
        assertEq(seat.hook(), bell, "hook wired through the distributor");
    }

    function test_SetSeatHookIsOneShot() public {
        dist.setSeatHook(address(0xBE11));
        // Seat.setHook is itself one-shot — a second attempt bubbles up HookAlreadySet.
        vm.expectRevert(Seat.HookAlreadySet.selector);
        dist.setSeatHook(address(0xBEEF));
    }

    function test_OnlyAdminSetsSeatHook() public {
        vm.prank(bob);
        vm.expectRevert(MintDistributor.NotAdmin.selector);
        dist.setSeatHook(address(0xBE11));
    }

    function test_SetSeatHookBeforeSeatSetReverts() public {
        MintDistributor fresh = new MintDistributor(admin, RESERVE_CAP, TIMELOCK);
        vm.expectRevert(MintDistributor.SeatNotSet.selector);
        fresh.setSeatHook(address(0xBE11));
    }

    // ------------------------------------------------- claim happy paths

    function test_ClaimMintsExactAllocation() public {
        vm.prank(alice);
        uint256 firstId = dist.claim(STAGE_FOUNDING, 2, _proof(bobLeaf));

        assertEq(firstId, 1, "first Seat id");
        assertEq(seat.balanceOf(alice), 2, "alice got her full allocation of 2");
        assertEq(seat.ownerOf(1), alice);
        assertEq(seat.ownerOf(2), alice);
        assertTrue(dist.claimed(STAGE_FOUNDING, alice));
    }

    function test_TwoClaimantsSameStage() public {
        vm.prank(alice);
        dist.claim(STAGE_FOUNDING, 2, _proof(bobLeaf));
        vm.prank(bob);
        dist.claim(STAGE_FOUNDING, 1, _proof(aliceLeaf));

        assertEq(seat.balanceOf(alice), 2);
        assertEq(seat.balanceOf(bob), 1);
        assertEq(seat.totalMinted(), 3);
    }

    function test_ClaimIsFreeAndCallerPaid() public {
        // No token movement, no price — only the caller receives Seats.
        vm.prank(alice);
        dist.claim(STAGE_FOUNDING, 2, _proof(bobLeaf));
        assertEq(seat.balanceOf(address(dist)), 0, "distributor holds nothing");
    }

    // ------------------------------------------------- claim guards

    function test_DoubleClaimReverts() public {
        vm.startPrank(alice);
        dist.claim(STAGE_FOUNDING, 2, _proof(bobLeaf));
        vm.expectRevert(MintDistributor.AlreadyClaimed.selector);
        dist.claim(STAGE_FOUNDING, 2, _proof(bobLeaf));
        vm.stopPrank();
    }

    function test_WrongAllocationReverts() public {
        // alice is attested for 2; claiming 1 changes the leaf → proof fails.
        vm.prank(alice);
        vm.expectRevert(MintDistributor.BadProof.selector);
        dist.claim(STAGE_FOUNDING, 1, _proof(bobLeaf));
    }

    function test_NonWhitelistedReverts() public {
        // carol is not in the founding tree.
        vm.prank(carol);
        vm.expectRevert(MintDistributor.BadProof.selector);
        dist.claim(STAGE_FOUNDING, 1, _proof(bobLeaf));
    }

    function test_StealWithSomeoneElsesProofReverts() public {
        // bob presents alice's (account,stage,alloc) proof but msg.sender is bob → leaf differs → fail.
        vm.prank(bob);
        vm.expectRevert(MintDistributor.BadProof.selector);
        dist.claim(STAGE_FOUNDING, 2, _proof(bobLeaf));
    }

    function test_ClaimClosedStageReverts() public {
        dist.setStageOpen(STAGE_FOUNDING, false);
        vm.prank(alice);
        vm.expectRevert(MintDistributor.StageClosed.selector);
        dist.claim(STAGE_FOUNDING, 2, _proof(bobLeaf));
    }

    function test_ClaimWrongStageReverts() public {
        // A valid founding proof presented against the (empty) general stage.
        dist.setStageOpen(STAGE_GENERAL, true);
        vm.prank(alice);
        vm.expectRevert(MintDistributor.BadProof.selector);
        dist.claim(STAGE_GENERAL, 2, _proof(bobLeaf));
    }

    function test_ZeroAllocationReverts() public {
        vm.prank(alice);
        vm.expectRevert(MintDistributor.ZeroAllocation.selector);
        dist.claim(STAGE_FOUNDING, 0, _proof(bobLeaf));
    }

    // ------------------------------------------------- root timelock

    function test_CommitBeforeTimelockReverts() public {
        dist.proposeRoot(STAGE_GENERAL, foundingRoot);
        vm.expectRevert(MintDistributor.TimelockNotElapsed.selector);
        dist.commitRoot(STAGE_GENERAL);
    }

    function test_CommitWithoutProposeReverts() public {
        vm.expectRevert(MintDistributor.NothingPending.selector);
        dist.commitRoot(STAGE_GENERAL);
    }

    function test_CommitClearsPending() public {
        dist.proposeRoot(STAGE_GENERAL, foundingRoot);
        vm.warp(block.timestamp + TIMELOCK);
        dist.commitRoot(STAGE_GENERAL);
        assertEq(dist.stageRoot(STAGE_GENERAL), foundingRoot);
        assertEq(dist.pendingEta(STAGE_GENERAL), 0, "pending cleared");
        // A second commit with nothing pending reverts.
        vm.expectRevert(MintDistributor.NothingPending.selector);
        dist.commitRoot(STAGE_GENERAL);
    }

    function test_ClaimBeforeRootCommittedReverts() public {
        // General stage opened but its root only proposed, never committed → root is zero → proof fails.
        dist.proposeRoot(STAGE_GENERAL, _pair(_leaf(carol, STAGE_GENERAL, 1), bytes32(uint256(1))));
        dist.setStageOpen(STAGE_GENERAL, true);
        vm.prank(carol);
        vm.expectRevert(MintDistributor.BadProof.selector);
        dist.claim(STAGE_GENERAL, 1, _proof(bytes32(uint256(1))));
    }

    // ------------------------------------------------- reserved mint (float/partners)

    function test_MintReservedWithinCap() public {
        dist.mintReserved(address(this), 5);
        assertEq(seat.balanceOf(address(this)), 5);
        assertEq(dist.reserveMinted(), 5);
        assertEq(dist.reserveRemaining(), RESERVE_CAP - 5);
    }

    function test_MintReservedRespectsCapAcrossCalls() public {
        dist.mintReserved(address(this), RESERVE_CAP - 1);
        vm.expectRevert(MintDistributor.ReserveCapExceeded.selector);
        dist.mintReserved(address(this), 2); // would total CAP+1
        // Exactly hitting the cap is fine.
        dist.mintReserved(address(this), 1);
        assertEq(dist.reserveMinted(), RESERVE_CAP);
    }

    function test_ReservedAndClaimShareSeatSupply() public {
        dist.mintReserved(address(this), 3); // ids 1..3
        vm.prank(alice);
        uint256 firstId = dist.claim(STAGE_FOUNDING, 2, _proof(bobLeaf)); // ids 4..5
        assertEq(firstId, 4, "claim continues the shared id counter");
        assertEq(seat.totalMinted(), 5);
    }

    // ------------------------------------------------- admin gating

    function test_OnlyAdminInitSeat() public {
        MintDistributor fresh = new MintDistributor(admin, RESERVE_CAP, TIMELOCK);
        Seat s2 = new Seat("S", "S", 10, address(fresh));
        vm.prank(bob);
        vm.expectRevert(MintDistributor.NotAdmin.selector);
        fresh.initSeat(s2);
    }

    function test_OnlyAdminProposeCommitOpen() public {
        vm.startPrank(bob);
        vm.expectRevert(MintDistributor.NotAdmin.selector);
        dist.proposeRoot(STAGE_GENERAL, foundingRoot);
        vm.expectRevert(MintDistributor.NotAdmin.selector);
        dist.commitRoot(STAGE_GENERAL);
        vm.expectRevert(MintDistributor.NotAdmin.selector);
        dist.setStageOpen(STAGE_GENERAL, true);
        vm.expectRevert(MintDistributor.NotAdmin.selector);
        dist.mintReserved(bob, 1);
        vm.stopPrank();
    }

    function test_ConstructorRejectsZeroAdmin() public {
        vm.expectRevert(MintDistributor.ZeroAddress.selector);
        new MintDistributor(address(0), RESERVE_CAP, TIMELOCK);
    }

    function test_ConstructorRejectsZeroTimelock() public {
        // A zero timelock would collapse the public-review window (propose+commit same block).
        vm.expectRevert(MintDistributor.ZeroTimelock.selector);
        new MintDistributor(admin, RESERVE_CAP, 0);
    }

    function test_MintReservedRejectsZeroTo() public {
        vm.expectRevert(MintDistributor.ZeroAddress.selector);
        dist.mintReserved(address(0), 1);
    }

    function test_MintReservedRejectsZeroCount() public {
        vm.expectRevert(MintDistributor.ZeroAllocation.selector);
        dist.mintReserved(address(this), 0);
    }

    // ------------------------------------------------- Seat SoldOut backstop

    function test_SeatSoldOutIsHardCeiling() public {
        // A tiny collection: cap of 2 Seats, distributor as minter.
        MintDistributor d = new MintDistributor(admin, 10, TIMELOCK);
        Seat tiny = new Seat("Tiny", "T", 2, address(d));
        d.initSeat(tiny);
        d.mintReserved(address(this), 2); // fills the collection
        vm.expectRevert(Seat.SoldOut.selector);
        d.mintReserved(address(this), 1);
    }
}
