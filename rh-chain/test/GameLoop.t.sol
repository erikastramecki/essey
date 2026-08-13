// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {GameBase} from "./GameBase.t.sol";

/// The Phase-0 answer to "is the loop playable": one full session across two players —
/// depart -> exposed -> robbed-or-paid -> repair -> bank — every leg on-chain, Scrip only.
contract GameLoopTest is GameBase {
    function test_FullSession_DepartExposedRobbedRepairBank() public {
        // ---- Bob: play a mission, keep the loot exposed, deploy capital, go out again.
        uint64 m1 = _depart(bobPk, bobDon, PAPER_ROUTE, 5e18, bytes32(0)); // first play: free Safehouse + stipend
        _resolveWith(m1, 0); // SUCCESS: 36 + 5 x 1.2857-ish boost lands in the hopper
        uint256 loot = escrow.hopperOf(bobDon);
        assertGt(loot, 36e18);

        _grantScrip(don.vaultOf(bobDon), 1_000e18);
        vm.prank(bob);
        escrow.deploy(bobDon, 1_000e18);
        _depart(bobPk, bobDon, PROOF_OF_WORK, 0, bytes32(0)); // away 12h, House lit up on the Tape

        // ---- Alice: kit up and hit the exposed House.
        _grantScrip(don.vaultOf(aliceDon), 1_000e18);
        vm.prank(alice);
        uint256 goon = hitter.mint(aliceDon);
        uint256[] memory crew = new uint256[](1);
        crew[0] = goon;
        bytes32 salt = bytes32("s");
        bytes32 h = keccak256(abi.encode(aliceDon, crew, bobDon, salt));
        vm.prank(alice);
        uint64 raidId = raid.commit(aliceDon, h);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(alice);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, bobDon, salt);
        // p_hit for one fresh L1 hitter vs a Safehouse: 0.72 x 50/(50+40).
        uint256 pHit = (720_000 * (50 * PPM)) / ((50 + 40) * PPM);
        oracle.fulfill(oracle.lastSeq(), bytes32(_findRaidWord(pHit, true, false))); // common hit

        assertEq(escrow.hopperOf(bobDon), 0); // cracked the back office
        assertEq(escrow.damageBps(bobDon), 4_000);
        uint256 aliceGain = scrip.balanceOf(don.vaultOf(aliceDon));
        assertGt(aliceGain, 0); // the raider ate (via the vault), minus the 7.5% tax

        // ---- Bob comes home, repairs, banks what's left. Exits free, forever.
        (,,, uint64 due,,,,,) = board.missions(board.activeMissionOf(bobDon));
        vm.warp(due);
        vm.prank(keeper);
        board.resolve{value: ENTROPY_FEE}(board.activeMissionOf(bobDon));
        oracle.fulfill(oracle.lastSeq(), bytes32(uint256(0))); // mission itself succeeded: 236 lands

        vm.prank(bob);
        escrow.repair(bobDon); // clear the -40% debuff
        assertEq(escrow.damageBps(bobDon), 0);

        uint256 hopperAll = escrow.hopperOf(bobDon) + escrow.pendingYieldOf(bobDon);
        vm.prank(bob);
        escrow.bank(bobDon, 1_000e18, hopperAll);
        assertEq(escrow.deployedOf(bobDon), 0);
        assertEq(escrow.hopperOf(bobDon), 0);
        assertGt(scrip.balanceOf(don.vaultOf(bobDon)), 1_000e18); // capital + the T3 pay came home

        // ---- The custody invariant closes the books.
        assertEq(scrip.balanceOf(address(escrow)), escrow.totalDeployed() + escrow.totalHopper());

        // ---- Keeper attests bob's kit off the first dispatch (the Phase-0 ritual).
        vm.prank(keeper);
        board.attestKit(bobDon, 2);
        assertTrue(board.kitClaimed(bobDon));
    }
}
