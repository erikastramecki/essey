// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Seat} from "../src/market/Seat.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {SeatArt} from "../src/market/SeatArt.sol";
import {MintDistributor} from "../src/market/MintDistributor.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

contract SeatArtTest is Test, IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    Seat seat;
    ERC20Mock essey;
    ERC20Mock usdg;
    Bell bell;
    SeatArt art;

    address treasury = address(0x7EA);
    address alice = address(0xA11CE);

    function setUp() public {
        seat = new Seat("Essey Seat", "SEAT", 2222, address(this));
        essey = new ERC20Mock();
        usdg = new ERC20Mock();
        uint256[] memory fees = new uint256[](3);
        fees[0] = 100e18;
        fees[1] = 200e18;
        fees[2] = 400e18;
        uint256[] memory weights = new uint256[](3);
        weights[0] = 160;
        weights[1] = 200;
        weights[2] = 333;
        bell = new Bell(ISeatLike(address(seat)), essey, usdg, treasury, 1e18, 100, fees, weights, IConverter(address(0)), address(0));
        seat.setHook(address(bell));
        art = new SeatArt(seat, bell);
        seat.setArt(address(art));
    }

    // ---------------------------------------------------------------- wiring

    function test_ArtIsOneShotAndMinterGated() public {
        vm.expectRevert(Seat.ArtAlreadySet.selector);
        seat.setArt(address(0xBEEF));
        Seat s2 = new Seat("S", "S", 10, address(this));
        vm.prank(alice);
        vm.expectRevert(Seat.NotMinter.selector);
        s2.setArt(address(art));
    }

    function test_UnsetArtRendersEmpty() public {
        Seat s2 = new Seat("S", "S", 10, address(this));
        uint256 id = s2.mint(address(this));
        assertEq(s2.tokenURI(id), "", "no renderer wired: empty, never a broken link");
    }

    function test_NonexistentSeatReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        seat.tokenURI(99);
    }

    function test_DistributorPassthroughWiresArt() public {
        MintDistributor dist = new MintDistributor(address(this), 10, 2 days);
        Seat s2 = new Seat("S", "S", 10, address(dist));
        dist.initSeat(s2);
        SeatArt a2 = new SeatArt(s2, Bell(address(0)));
        dist.setSeatArt(address(a2));
        assertEq(s2.art(), address(a2), "the immutable minter's passthrough is the only wiring path");
        vm.expectRevert(Seat.ArtAlreadySet.selector);
        dist.setSeatArt(address(0xBEEF));
        vm.prank(alice);
        vm.expectRevert(MintDistributor.NotAdmin.selector);
        dist.setSeatArt(address(a2));
    }

    // ---------------------------------------------------------------- rendering

    function test_UriShapeAndDeterminism() public {
        uint256 id = seat.mint(address(this));
        string memory uri = seat.tokenURI(id);
        assertEq(_prefix(uri), "data:application/json;base64,", "on-chain data URI, no server anywhere");
        assertEq(keccak256(bytes(uri)), keccak256(bytes(seat.tokenURI(id))), "deterministic");
    }

    /// Golden pin for the metadata head: the JSON must open with the certificate name for Seat 0001.
    /// (A format regression should fail a test, not surface on a marketplace.)
    function test_JsonOpensWithCertificateName() public {
        uint256 id = seat.mint(address(this));
        string memory uri = seat.tokenURI(id);
        // First 24 bytes of the JSON: {"name":"Seat Nº 0001 -> base64 of a prefix is a prefix of the base64.
        string memory expectedStart = Base64.encode(bytes('{"name":"Seat N\\u00ba 0001'));
        // Base64 works in 3-byte blocks; compare on a block boundary (24 chars of payload = 32 b64 chars).
        assertEq(_slice(uri, 29, 32), _slice(expectedStart, 0, 32), "name head must match the certificate format");
    }

    /// The art is ALIVE: activating a Tier changes the rendered metadata; the resale clear (hook)
    /// reverts it to the Base render — an upgraded Seat looks upgraded exactly while it is.
    function test_TierReactiveRender() public {
        uint256 id = seat.mint(alice);
        string memory baseUri = seat.tokenURI(id);

        essey.mint(alice, 1_000e18);
        vm.startPrank(alice);
        essey.approve(address(bell), type(uint256).max);
        bell.activate(id, 2);
        vm.stopPrank();
        string memory tierUri = seat.tokenURI(id);
        assertTrue(keccak256(bytes(tierUri)) != keccak256(bytes(baseUri)), "Tier II renders differently");

        // Transfer clears the Tier (the Bell hook) -> render returns to Base, byte-identical.
        vm.prank(alice);
        seat.transferFrom(alice, address(this), id);
        assertEq(keccak256(bytes(seat.tokenURI(id))), keccak256(bytes(baseUri)), "resale clears the gold");
    }

    /// No Bell wired: every Seat renders Base, and rendering can never revert.
    function test_NoBellRendersBase() public {
        Seat s2 = new Seat("S", "S", 10, address(this));
        SeatArt a2 = new SeatArt(s2, Bell(address(0)));
        s2.setArt(address(a2));
        uint256 id = s2.mint(address(this));
        string memory uri = s2.tokenURI(id);
        assertEq(_prefix(uri), "data:application/json;base64,");
    }

    function test_ConstructorRejectsZeroSeat() public {
        vm.expectRevert(SeatArt.ZeroSeat.selector);
        new SeatArt(Seat(address(0)), bell);
    }

    /// A codeless bell would BRICK tokenURI forever (empty-returndata decode reverts OUTSIDE the
    /// try/catch) — the constructor makes that mis-deploy loud instead (audit round 1, two lenses).
    function test_ConstructorRejectsCodelessBell() public {
        Seat s2 = new Seat("S", "S", 10, address(this));
        vm.expectRevert(SeatArt.BellNotContract.selector);
        new SeatArt(s2, Bell(address(0xDEAD)));
    }

    /// The art must read the SAME Bell the Seat's hook clears, or a sold Seat would permanently
    /// render a tier that never clears.
    function test_ConstructorRejectsBellThatIsNotTheHook() public {
        Seat s2 = new Seat("S", "S", 10, address(this));
        s2.setHook(address(essey)); // some other (contract) hook — just not the bell
        vm.expectRevert(SeatArt.BellIsNotTheHook.selector);
        new SeatArt(s2, bell);
    }

    /// A codeless hook would brick every transfer with the one-shot consumed (audit round-2 F6) —
    /// same guard class as the renderer.
    function test_SetHookRejectsCodelessHook() public {
        Seat s2 = new Seat("S", "S", 10, address(this));
        vm.expectRevert(Seat.HookNotContract.selector);
        s2.setHook(address(0xDEAD));
    }

    function test_SetArtRejectsCodelessRenderer() public {
        Seat s2 = new Seat("S", "S", 10, address(this));
        vm.expectRevert(Seat.ArtNotContract.selector);
        s2.setArt(address(0xBEEF));
    }

    function test_PassthroughRejectsZeroArt() public {
        MintDistributor dist = new MintDistributor(address(this), 10, 2 days);
        Seat s2 = new Seat("S", "S", 10, address(dist));
        dist.initSeat(s2);
        vm.expectRevert(MintDistributor.ZeroAddress.selector);
        dist.setSeatArt(address(0));
    }

    /// Upgrade raises the render; ring+claim (pendingStored churn) must NOT move it.
    function test_UpgradeChangesRenderButClaimsDoNot() public {
        uint256 id = seat.mint(alice);
        essey.mint(alice, 10_000e18);
        vm.startPrank(alice);
        essey.approve(address(bell), type(uint256).max);
        bell.activate(id, 1);
        vm.stopPrank();
        string memory tier1 = seat.tokenURI(id);

        vm.prank(alice);
        bell.upgrade(id, 3);
        string memory tier3 = seat.tokenURI(id);
        assertTrue(keccak256(bytes(tier3)) != keccak256(bytes(tier1)), "upgrade must re-render");

        // Fee churn into the pot, ring, claim: pendingStored moves, tier does not, render must not.
        usdg.mint(address(bell), 50e18);
        bell.ring();
        bell.claim(id);
        assertEq(keccak256(bytes(seat.tokenURI(id))), keccak256(bytes(tier3)), "claims never move the art");
    }

    /// Emit one full URI so the SVG can be decoded and eyeballed off-chain (design review artifact).
    function test_EmitSampleUriForVisualReview() public {
        uint256 id = seat.mint(alice);
        essey.mint(alice, 1_000e18);
        vm.startPrank(alice);
        essey.approve(address(bell), type(uint256).max);
        bell.activate(id, 3);
        vm.stopPrank();
        console.log(seat.tokenURI(id));
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
