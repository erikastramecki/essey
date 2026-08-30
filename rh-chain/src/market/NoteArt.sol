// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EsseyPool} from "../EsseyPool.sol";
import {Note} from "./Note.sol";

/// NoteArt — fully on-chain metadata for loan Notes: live debt and collateral read from the pool at
/// render time. SeatArt's three rules carried verbatim: code.length check before any staticcall,
/// try/catch around ALL live reads (an empty-returndata decode reverts OUTSIDE try/catch on solc
/// >=0.8.10), small abi.encodePacked frames.
contract NoteArt {
    using Strings for uint256;

    EsseyPool public immutable pool;
    Note public immutable note;
    uint8 internal immutable assetDec;
    string internal assetSym; // read once at deploy; no hardcoded currency

    error ArtMismatch();

    constructor(EsseyPool pool_, Note note_) {
        // The art must read the SAME pool this Note belongs to, or a Note would render another
        // market's debt forever (SeatArt's Bell-is-not-the-hook guard, same shape).
        if (address(pool_.note()) != address(note_)) revert ArtMismatch();
        pool = pool_;
        note = note_;
        assetDec = IERC20Metadata(pool_.asset()).decimals();
        assetSym = _escape(IERC20Metadata(pool_.asset()).symbol());
    }

    /// Token symbols are attacker-adjacent strings that land in BOTH the JSON fields and the SVG
    /// text node, so escape once at the read: the five metacharacters become entities (valid in
    /// SVG, inert literals in JSON) and control bytes are stripped (C-L1).
    function _escape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out;
        for (uint256 i; i < b.length; i++) {
            bytes1 c = b[i];
            if (c < 0x20 || c == 0x7f) continue;
            if (c == "&") out = abi.encodePacked(out, "&amp;");
            else if (c == "\"") out = abi.encodePacked(out, "&quot;");
            else if (c == "\\") out = abi.encodePacked(out, "&#92;");
            else if (c == "<") out = abi.encodePacked(out, "&lt;");
            else if (c == ">") out = abi.encodePacked(out, "&gt;");
            else out = abi.encodePacked(out, c);
        }
        return string(out);
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        (uint256 collateralRaw, uint256 debt) = _position(id);
        string memory sym = _symbol();
        return string(
            abi.encodePacked("data:application/json;base64,", Base64.encode(_json(id, sym, collateralRaw, debt)))
        );
    }

    function _position(uint256 id) internal view returns (uint256 collateralRaw, uint256 debt) {
        try pool.positions(id) returns (address, uint256 cr, uint256, uint256, uint256) {
            collateralRaw = cr;
        } catch {}
        try pool.debtOf(id) returns (uint256 d) {
            debt = d;
        } catch {}
    }

    function _symbol() internal view returns (string memory) {
        address token = pool.collateralToken();
        if (token.code.length == 0) return "?";
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return _escape(s);
        } catch {
            return "?";
        }
    }

    function _json(uint256 id, string memory sym, uint256 collateralRaw, uint256 debt)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            '{"name":"Essey Note #', id.toString(),
            '","description":"A live loan against ', sym,
            ' on Essey. Whoever holds this Note is the borrower. Debt grows continuously; the position can be liquidated.",',
            '"attributes":[{"trait_type":"Market","value":"', sym,
            '"},{"trait_type":"Collateral (raw)","value":"', collateralRaw.toString(),
            '"},{"trait_type":"Debt","value":"', _amount(debt),
            '"}],"image":"data:image/svg+xml;base64,', Base64.encode(_svg(id, sym, debt)), '"}'
        );
    }

    function _amount(uint256 debt) internal view returns (string memory) {
        return string(abi.encodePacked((debt / 10 ** assetDec).toString(), " ", assetSym));
    }

    /// A dark card: market symbol, note number, live debt. Deliberately spare.
    function _svg(uint256 id, string memory sym, uint256 debt) internal view returns (bytes memory) {
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            '<rect width="400" height="400" fill="#0A0C11"/>',
            '<text x="200" y="64" text-anchor="middle" font-family="Georgia,serif" font-size="19" letter-spacing="10" fill="#98A0B0">ESSEY</text>',
            '<text x="200" y="196" text-anchor="middle" font-family="Menlo,monospace" font-size="42" fill="#E9EBF1">', bytes(sym),
            '</text><text x="200" y="252" text-anchor="middle" font-family="Menlo,monospace" font-size="18" letter-spacing="3" fill="#E9EBF1">NOTE #', id.toString(),
            '</text><text x="200" y="330" text-anchor="middle" font-family="Menlo,monospace" font-size="13" letter-spacing="2" fill="#616A7B">DEBT ', _amount(debt),
            "</text></svg>"
        );
    }
}
