// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {GameBase} from "./GameBase.t.sol";
import {HitterNFT} from "../src/game/HitterNFT.sol";

contract GameHitterTest is GameBase {
    uint256 constant MINT_PRICE = 900e18;

    function _mintFor(uint256 pk, uint256 donId) internal returns (uint256 id) {
        _grantScrip(don.vaultOf(donId), MINT_PRICE);
        vm.prank(vm.addr(pk));
        id = hitter.mint(donId);
    }

    // ---------------------------------------------------------------- mint

    function test_Mint_PriceBurnsFromDonVault() public {
        _grantScrip(don.vaultOf(aliceDon), 1_000e18);
        uint256 supply = scrip.totalSupply();
        vm.prank(alice);
        uint256 id = hitter.mint(aliceDon);
        assertEq(hitter.ownerOf(id), alice);
        assertEq(scrip.totalSupply(), supply - MINT_PRICE); // $9 SKU, burned (the sink)
        assertEq(scrip.balanceOf(don.vaultOf(aliceDon)), 100e18);
        assertTrue(hitter.sealed_(id)); // every mint carries the sealed Favor
        assertTrue(hitter.favorCommit(id) != bytes32(0)); // committed in the mint tx
    }

    function test_Mint_OnlyDonOwnerPays() public {
        _grantScrip(don.vaultOf(aliceDon), 1_000e18);
        vm.prank(bob);
        vm.expectRevert(HitterNFT.NotDonOwner.selector);
        hitter.mint(aliceDon);
    }

    function test_Mint_BlockedAfterClose() public {
        _grantScrip(don.vaultOf(aliceDon), 1_000e18);
        controller.close();
        vm.prank(alice);
        vm.expectRevert(HitterNFT.GenerationClosed.selector);
        hitter.mint(aliceDon);
    }

    // ---------------------------------------------------------------- the Favor

    function _expectedBand(uint256 word, bytes32 commit) internal pure returns (uint8) {
        uint256 roll = uint256(keccak256(abi.encodePacked(bytes32(word), commit))) % 1_000_000;
        if (roll < 700_000) return 0;
        if (roll < 900_000) return 1;
        if (roll < 985_000) return 2;
        return 3;
    }

    function test_Favor_RevealMapsPublishedBands() public {
        uint256 id = _mintFor(alicePk, aliceDon);
        bytes32 commit = hitter.favorCommit(id);
        vm.prank(alice);
        hitter.revealFavor{value: ENTROPY_FEE}(id);
        uint256 word = 42;
        oracle.fulfill(oracle.lastSeq(), bytes32(word));
        assertFalse(hitter.sealed_(id));
        assertEq(hitter.favorOf(id), _expectedBand(word, commit));
    }

    /// Every band of the 70/20/8.5/1.5 ladder is reachable (words searched per band).
    function test_Favor_AllBandsReachable() public {
        bool[4] memory seen;
        uint256 found;
        for (uint256 w = 1; w < 3_000 && found < 4; w++) {
            uint256 id = _mintFor(alicePk, aliceDon);
            uint8 expect = _expectedBand(w, hitter.favorCommit(id));
            if (seen[expect]) continue;
            vm.prank(alice);
            hitter.revealFavor{value: ENTROPY_FEE}(id);
            oracle.fulfill(oracle.lastSeq(), bytes32(w));
            assertEq(hitter.favorOf(id), expect);
            seen[expect] = true;
            found++;
        }
        assertEq(found, 4);
    }

    function test_Favor_OnlyOwnerReveals_OnceOnly() public {
        uint256 id = _mintFor(alicePk, aliceDon);
        vm.prank(bob);
        vm.expectRevert(HitterNFT.NotHitterOwner.selector);
        hitter.revealFavor{value: ENTROPY_FEE}(id);

        vm.prank(alice);
        hitter.revealFavor{value: ENTROPY_FEE}(id);
        vm.prank(alice);
        vm.expectRevert(HitterNFT.RevealInFlight.selector);
        hitter.revealFavor{value: ENTROPY_FEE}(id);

        oracle.fulfill(oracle.lastSeq(), bytes32(uint256(7)));
        vm.prank(alice);
        vm.expectRevert(HitterNFT.AlreadyRevealed.selector);
        hitter.revealFavor{value: ENTROPY_FEE}(id);
    }

    function test_Favor_ForceRevealFloor_AfterTimeoutOnly() public {
        uint256 id = _mintFor(alicePk, aliceDon);
        vm.expectRevert(HitterNFT.NotYetForceable.selector);
        hitter.forceRevealFloor(id);

        vm.warp(block.timestamp + 30 days);
        hitter.forceRevealFloor(id); // ANYONE — the reclaim valve
        assertFalse(hitter.sealed_(id));
        assertEq(hitter.favorOf(id), 0); // the FLOOR band — forcing can't be gamed upward
    }

    function test_Favor_WithheldRevealStillFloors() public {
        uint256 id = _mintFor(alicePk, aliceDon);
        vm.prank(alice);
        hitter.revealFavor{value: ENTROPY_FEE}(id);
        uint64 seq = oracle.lastSeq();
        // Provider withholds; the floor valve still opens the envelope…
        vm.warp(block.timestamp + 30 days);
        hitter.forceRevealFloor(id);
        assertEq(hitter.favorOf(id), 0);
        // …and the late reveal can't re-roll it.
        vm.expectRevert(HitterNFT.AlreadyRevealed.selector);
        oracle.fulfill(seq, bytes32(uint256(1)));
    }

    // ---------------------------------------------------------------- game flags

    function test_Flags_RaidModuleOnly() public {
        uint256 id = _mintFor(alicePk, aliceDon);
        vm.expectRevert(HitterNFT.NotRaidModule.selector);
        hitter.noteAttempt(id);
        vm.expectRevert(HitterNFT.NotRaidModule.selector);
        hitter.hospitalize(id);

        vm.prank(address(raid));
        hitter.noteAttempt(id);
        assertEq(hitter.lastAttemptAt(id), uint64(block.timestamp));
        vm.prank(address(raid));
        hitter.hospitalize(id);
        assertEq(hitter.hospitalUntil(id), uint64(block.timestamp) + 48 hours);
    }

    // ---------------------------------------------------------------- metadata

    function test_TokenURI_Redacted() public {
        uint256 id = _mintFor(alicePk, aliceDon);
        assertTrue(_contains(hitter.tokenURI(id), "REDACTED"));
        assertTrue(_contains(hitter.tokenURI(id), "sealed"));
        vm.warp(block.timestamp + 30 days);
        hitter.forceRevealFloor(id);
        assertTrue(_contains(hitter.tokenURI(id), "Empty envelope"));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
