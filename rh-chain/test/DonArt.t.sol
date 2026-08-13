// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Don} from "../src/market/Don.sol";
import {DonArt} from "../src/market/DonArt.sol";
import {DonDistributor} from "../src/market/DonDistributor.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

contract DonArtTest is Test, IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    DonDistributor dist;
    Don don;
    DonArt art;

    address alice = address(0xA11CE);

    bytes32 constant COMBO_A = keccak256("fedora/cigar/pinstripe");
    bytes32 constant COMBO_B = keccak256("homburg/ring/trench");

    string constant BASE = "https://essey.xyz/api/don/";

    function setUp() public {
        // The production wiring shape: distributor is the Don's immutable minter; art wires through it.
        dist = new DonDistributor(address(this), 10, 2 days, 0, 0, 0);
        don = new Don("Essey Don", "DON", 8888, address(dist), address(0x7EE), 500);
        dist.initDon(don);
        art = new DonArt(don, address(this), "");
        dist.setDonArt(address(art));

        bytes32[] memory combos = new bytes32[](1);
        combos[0] = COMBO_A;
        dist.mintReserved(address(this), combos); // Don #1 exists
    }

    /// A Don whose minter is this test directly — for exercising reroll/lock renders without the
    /// distributor's fee/Bell ceremony.
    function _directDon() internal returns (Don d, DonArt a, uint256 id) {
        d = new Don("D", "D", 10, address(this), address(0x7EE), 500);
        a = new DonArt(d, address(this), "");
        d.setArt(address(a));
        id = d.mint(alice, COMBO_A);
    }

    // ---------------------------------------------------------------- wiring

    function test_DistributorPassthroughWiresArtOneShot() public {
        assertEq(don.art(), address(art), "the immutable minter's passthrough is the only wiring path");
        vm.expectRevert(Don.ArtAlreadySet.selector);
        dist.setDonArt(address(art));
        vm.prank(alice);
        vm.expectRevert(DonDistributor.NotAdmin.selector);
        dist.setDonArt(address(art));
        vm.expectRevert(Don.NotMinter.selector);
        don.setArt(address(art));
    }

    function test_UnsetArtRendersEmpty() public {
        Don d2 = new Don("D", "D", 10, address(this), address(0x7EE), 500);
        uint256 id = d2.mint(address(this), COMBO_A);
        assertEq(d2.tokenURI(id), "", "no renderer wired: empty, never a broken link");
    }

    function test_NonexistentDonReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        don.tokenURI(99);
    }

    // ---------------------------------------------------------------- constructor guards

    function test_ConstructorRejectsZeroDon() public {
        vm.expectRevert(DonArt.ZeroDon.selector);
        new DonArt(Don(address(0)), address(this), "");
    }

    /// A codeless don would BRICK the fallback render forever (empty-returndata decode reverts outside
    /// any try/catch) — the constructor makes that mis-deploy loud instead (the SeatArt audit lesson).
    function test_ConstructorRejectsCodelessDon() public {
        vm.expectRevert(DonArt.DonNotContract.selector);
        new DonArt(Don(address(0xDEAD)), address(this), "");
    }

    function test_ConstructorRejectsZeroAdmin() public {
        vm.expectRevert(DonArt.ZeroAdmin.selector);
        new DonArt(don, address(0), "");
    }

    // ---------------------------------------------------------------- baseURI rotation

    function test_SetBaseURIAdminGatedRotatableAndLoud() public {
        vm.expectEmit(address(art));
        emit DonArt.BaseURISet(BASE);
        art.setBaseURI(BASE);
        assertEq(don.tokenURI(1), string.concat(BASE, "1"), "tokenURI = baseURI + id");

        // Rotatable: domains change, the Don's one-shot cannot — this pointer can, forever.
        art.setBaseURI("https://dons.example/meta/");
        assertEq(don.tokenURI(1), "https://dons.example/meta/1");

        vm.prank(alice);
        vm.expectRevert(DonArt.NotAdmin.selector);
        art.setBaseURI(BASE);
    }

    function test_ClearingBaseURIFallsBackOnChain() public {
        art.setBaseURI(BASE);
        art.setBaseURI(""); // the emergency brake
        assertEq(_prefix(don.tokenURI(1)), "data:application/json;base64,", "cleared base = on-chain fallback, never blank");
    }

    /// The rotator must outlive any one multisig: two-step handoff, cancelable, never brickable by a
    /// fat-fingered address (the wrong proposee simply can't accept).
    function test_AdminHandoffIsTwoStepAndCancelable() public {
        vm.prank(alice);
        vm.expectRevert(DonArt.NotAdmin.selector);
        art.proposeAdmin(alice);

        art.proposeAdmin(alice);
        vm.expectRevert(DonArt.NotPendingAdmin.selector);
        art.acceptAdmin(); // proposer is not the pending admin

        art.proposeAdmin(address(0)); // cancel
        vm.prank(alice);
        vm.expectRevert(DonArt.NotPendingAdmin.selector);
        art.acceptAdmin();

        art.proposeAdmin(alice);
        vm.expectEmit(address(art));
        emit DonArt.AdminAccepted(alice);
        vm.prank(alice);
        art.acceptAdmin();
        assertEq(art.admin(), alice);
        assertEq(art.pendingAdmin(), address(0));

        // Power moved with the handoff: old admin locked out, new admin rotates.
        vm.expectRevert(DonArt.NotAdmin.selector);
        art.setBaseURI(BASE);
        vm.prank(alice);
        art.setBaseURI(BASE);
        assertEq(don.tokenURI(1), string.concat(BASE, "1"));
    }

    function test_ConstructorMayShipWithBaseSet() public {
        DonArt a2 = new DonArt(don, address(this), BASE);
        assertEq(a2.tokenURI(1), string.concat(BASE, "1"));
    }

    // ---------------------------------------------------------------- on-chain fallback

    function test_FallbackShapeGoldenNameAndDeterminism() public {
        string memory uri = don.tokenURI(1);
        assertEq(_prefix(uri), "data:application/json;base64,", "on-chain data URI when no base is set");
        // Golden pin: JSON must open {"name":"Don #1 — compare on a base64 block boundary (12 bytes = 16 chars).
        string memory expectedStart = Base64.encode(bytes('{"name":"Don #1'));
        assertEq(_slice(uri, 29, 16), _slice(expectedStart, 0, 16), "name head must match the certificate format");
        assertEq(keccak256(bytes(uri)), keccak256(bytes(don.tokenURI(1))), "deterministic");
    }

    /// The fallback embeds the LIVE combo commitment: a reroll re-renders, and the lock flips the
    /// Locked attribute — chain truth, not a stale snapshot.
    function test_FallbackTracksRerollAndLock() public {
        (Don d, , uint256 id) = _directDon();
        string memory uriA = d.tokenURI(id);

        d.reroll(id, COMBO_B);
        string memory uriB = d.tokenURI(id);
        assertTrue(keccak256(bytes(uriB)) != keccak256(bytes(uriA)), "reroll must re-render the combo hash");

        d.lockTraits(id);
        string memory uriLocked = d.tokenURI(id);
        assertTrue(keccak256(bytes(uriLocked)) != keccak256(bytes(uriB)), "locking must flip the Locked attribute");
    }

    /// Launch-grade invariant: with the renderer wired, a minted Don NEVER has an empty tokenURI —
    /// served URL when the base is set, on-chain data URI when it isn't.
    function test_MintedDonAlwaysHasMetadata() public {
        assertGt(bytes(don.tokenURI(1)).length, 0, "fallback path is non-empty");
        art.setBaseURI(BASE);
        assertGt(bytes(don.tokenURI(1)).length, 0, "served path is non-empty");
    }

    /// Emit one full URI so the JSON/SVG can be decoded and eyeballed off-chain (design review artifact).
    function test_EmitSampleUriForVisualReview() public view {
        console.log(don.tokenURI(1));
    }

    // ---------------------------------------------------------------- helpers

    function _prefix(string memory s) internal pure returns (string memory) {
        return _slice(s, 0, 29);
    }

    function _slice(string memory s, uint256 start, uint256 len) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }
}
