// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EsseyPoolTest} from "./EsseyPool.t.sol";
import {EsseyPool} from "../src/EsseyPool.sol";
import {MockStock} from "./RiskModules.t.sol";
import {Note} from "../src/market/Note.sol";
import {NoteArt} from "../src/market/NoteArt.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract HostileSymbolStock is MockStock {
    function symbol() public pure override returns (string memory) {
        return "EV\"<&>\\\x01IL"; // quote, angle brackets, ampersand, backslash, control byte
    }
}

contract NoteArtTest is EsseyPoolTest {
    NoteArt art;
    Note n;

    function setUp() public override {
        super.setUp();
        n = pool.note();
        art = new NoteArt(pool, n);
        vm.prank(ADMIN);
        pool.setNoteArt(address(art));
    }

    function _fallbackUri(uint256 id) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(abi.encodePacked('{"name":"Essey Note #', Strings.toString(id), '"}'))
            )
        );
    }

    // ---------------------------------------------------------------- rendering

    /// Byte-exact content pin for a known open position: the honesty line, the live debt, and the
    /// on-chain SVG. Deliberately brittle — changing the metadata must be a conscious act.
    function test_tokenURIRendersLiveStateAndTheHonestyLine() public {
        uint256 id = _borrow(700e6); // 10e18 AAPL raw, $700 USDG debt, zero-rate pool
        bytes memory svg = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            '<rect width="400" height="400" fill="#0A0C11"/>',
            '<text x="200" y="64" text-anchor="middle" font-family="Georgia,serif" font-size="19" letter-spacing="10" fill="#98A0B0">ESSEY</text>',
            '<text x="200" y="196" text-anchor="middle" font-family="Menlo,monospace" font-size="42" fill="#E9EBF1">AAPL',
            '</text><text x="200" y="252" text-anchor="middle" font-family="Menlo,monospace" font-size="18" letter-spacing="3" fill="#E9EBF1">NOTE #1',
            '</text><text x="200" y="330" text-anchor="middle" font-family="Menlo,monospace" font-size="13" letter-spacing="2" fill="#616A7B">DEBT 700 USDG',
            "</text></svg>"
        );
        bytes memory json = abi.encodePacked(
            '{"name":"Essey Note #1","description":"A live loan against AAPL on Essey. ',
            'Whoever holds this Note is the borrower. Debt grows continuously; the position can be liquidated.",',
            '"attributes":[{"trait_type":"Market","value":"AAPL"},',
            '{"trait_type":"Collateral (raw)","value":"10000000000000000000"},',
            '{"trait_type":"Debt","value":"700 USDG"}],',
            '"image":"data:image/svg+xml;base64,', Base64.encode(svg), '"}'
        );
        string memory expected = string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
        assertEq(n.tokenURI(id), expected, "note delegates to the art");
        assertEq(art.tokenURI(id), expected, "and the art renders the live position");
    }

    function test_tokenURIDoesNotRevertOnClosedPosition() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        pool.repay(id, 700e6); // burns the Note
        string memory uri = n.tokenURI(id); // must render zeroed, not revert
        assertGt(bytes(uri).length, 0);
    }

    function test_tokenURIFallsBackWhenArtUnset() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        assertEq(p2.note().tokenURI(7), _fallbackUri(7), "unwired note serves the minimal literal");
    }

    /// Post-Cancun code cannot vanish; the etch simulates it anyway because THIS is the guard that
    /// keeps fail-open true — without it the empty-returndata decode reverts outside the catch.
    function test_tokenURIFallsBackWhenArtCodeIsGone() public {
        uint256 id = _borrow(700e6);
        vm.etch(address(art), "");
        assertEq(n.tokenURI(id), _fallbackUri(id));
    }

    function test_tokenURIFallsBackWhenArtReverts() public {
        uint256 id = _borrow(700e6);
        vm.etch(address(art), hex"fe"); // any call reverts
        assertEq(n.tokenURI(id), _fallbackUri(id));
    }

    function test_artSurvivesARevertingCollateralSymbol() public {
        uint256 id = _borrow(700e6);
        vm.etch(address(tok), hex"fe"); // collateral token's symbol() now reverts
        assertGt(bytes(art.tokenURI(id)).length, 0, "renders with a placeholder, never reverts");
    }

    /// C-L1: a hostile symbol cannot inject into the JSON or the SVG. Byte-exact pin on the
    /// escaper's output — every metacharacter becomes an entity, the control byte is stripped —
    /// through the same fields the honesty-line test pins for a benign symbol.
    function test_hostileSymbolIsEscapedInJsonAndSvg() public {
        MockStock evil = new HostileSymbolStock();
        EsseyPool p2 = new EsseyPool(usdg, address(evil), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        NoteArt art2 = new NoteArt(p2, p2.note());

        string memory esc = "EV&quot;&lt;&amp;&gt;&#92;IL"; // "EV\"<&>\ + 0x01 + IL", escaped
        bytes memory svg = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            '<rect width="400" height="400" fill="#0A0C11"/>',
            '<text x="200" y="64" text-anchor="middle" font-family="Georgia,serif" font-size="19" letter-spacing="10" fill="#98A0B0">ESSEY</text>',
            '<text x="200" y="196" text-anchor="middle" font-family="Menlo,monospace" font-size="42" fill="#E9EBF1">', esc,
            '</text><text x="200" y="252" text-anchor="middle" font-family="Menlo,monospace" font-size="18" letter-spacing="3" fill="#E9EBF1">NOTE #1',
            '</text><text x="200" y="330" text-anchor="middle" font-family="Menlo,monospace" font-size="13" letter-spacing="2" fill="#616A7B">DEBT 0 USDG',
            "</text></svg>"
        );
        bytes memory json = abi.encodePacked(
            '{"name":"Essey Note #1","description":"A live loan against ', esc, ' on Essey. ',
            'Whoever holds this Note is the borrower. Debt grows continuously; the position can be liquidated.",',
            '"attributes":[{"trait_type":"Market","value":"', esc, '"},',
            '{"trait_type":"Collateral (raw)","value":"0"},',
            '{"trait_type":"Debt","value":"0 USDG"}],',
            '"image":"data:image/svg+xml;base64,', Base64.encode(svg), '"}'
        );
        string memory expected = string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
        assertEq(art2.tokenURI(1), expected, "hostile symbol renders fully escaped");
    }

    // ---------------------------------------------------------------- wiring guards

    function test_setArtOnlyPool() public {
        vm.expectRevert(Note.NotPool.selector);
        n.setArt(address(art));
    }

    function test_setArtIsOnceOnly() public {
        NoteArt art2 = new NoteArt(pool, n);
        vm.prank(ADMIN);
        vm.expectRevert(Note.ArtAlreadySet.selector);
        pool.setNoteArt(address(art2));
    }

    function test_setArtRejectsCodelessArt() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        vm.prank(ADMIN);
        vm.expectRevert(Note.ArtNotContract.selector);
        p2.setNoteArt(makeAddr("eoa"));
    }

    /// A stranger cannot wire; the pool's own deployer can, once — the seam the deploy script
    /// routes through (the authority is spent by Note.ArtAlreadySet the moment it is used).
    function test_setNoteArtOnlyAdminOrDeployer() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        NoteArt art2 = new NoteArt(p2, p2.note());
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(EsseyPool.NotAdmin.selector);
        p2.setNoteArt(address(art2));
        p2.setNoteArt(address(art2)); // this test contract is p2's deployer
        assertEq(p2.note().art(), address(art2));
    }

    function test_noteArtRejectsAMismatchedNote() public {
        EsseyPool p2 = new EsseyPool(usdg, address(tok), mk, 0, 0, 0, 0, address(0), address(0x7EA), 0, EsseyPool.Identity("Essey Pool Share", "aUSDG", "Essey Note", "eNOTE"));
        vm.expectRevert(NoteArt.ArtMismatch.selector);
        new NoteArt(p2, n); // n belongs to `pool`, not p2
    }
}
