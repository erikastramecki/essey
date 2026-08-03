// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ISeatArt} from "./ISeatArt.sol";
import {Seat} from "./Seat.sol";
import {Bell} from "./Bell.sol";

/// SeatArt — fully on-chain metadata for the Seats: the hexagon hallmark E-monogram in gold on ink,
/// the Seat number in the mono voice, and a LIVE Tier read from the Bell so an upgraded Seat looks
/// upgraded everywhere the NFT renders. No IPFS, no server, no bait-and-switch surface: the image is
/// computed from chain state at read time, forever.
///
/// Honesty notes baked into the metadata itself: the description names the Vault (the part of a
/// Seat's value marketplaces can't see) and reminds buyers the Tier clears on transfer — the two
/// facts a secondary buyer most needs and is least likely to know.
contract SeatArt is ISeatArt {
    using Strings for uint256;
    using Strings for address;

    Seat public immutable seat;
    /// address(0) = no Bell wired (all Seats render as Base). Immutable: the renderer is set on the
    /// Seat one-shot, so its own wiring must be fixed at construction too.
    Bell public immutable bell;

    error ZeroSeat();
    error BellNotContract();
    error BellIsNotTheHook();

    constructor(Seat seat_, Bell bell_) {
        if (address(seat_) == address(0)) revert ZeroSeat();
        if (address(bell_) != address(0)) {
            // Two deploy-integrity guards, both learned in audit round 1:
            // - A codeless bell address would BRICK tokenURI for the whole collection forever: the
            //   staticcall to empty code "succeeds" with empty returndata and the tuple decode then
            //   reverts OUTSIDE the try/catch (Solidity >=0.8.10 omits the extcodesize check when
            //   return data is decoded). Loud deploy failure instead.
            if (address(bell_).code.length == 0) revert BellNotContract();
            // - The art must read the SAME Bell the Seat's transfer hook clears, or a sold Seat
            //   would permanently render a tier that never clears — the exact lie the metadata
            //   description promises can't happen. This also pins deploy order: hook before art.
            if (seat_.hook() != address(bell_)) revert BellIsNotTheHook();
        }
        seat = seat_;
        bell = bell_;
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        uint8 tier = _tierOf(id);
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(_json(id, tier))));
    }

    /// JSON assembly split into small frames — one giant encodePacked is a stack-depth trap.
    function _json(uint256 id, uint8 tier) internal view returns (bytes memory) {
        string memory tierName = _tierName(tier);
        return abi.encodePacked(
            _jsonHead(id),
            '"attributes":[{"trait_type":"Tier","value":"', tierName,
            '"},{"trait_type":"Seat","value":', id.toString(),
            '},{"trait_type":"Vault","value":"', seat.vaultOf(id).toHexString(),
            '"}],"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_svg(_pad4(id), tier, tierName))), '"}'
        );
    }

    function _jsonHead(uint256 id) internal view returns (bytes memory) {
        return abi.encodePacked(
            '{"name":"Seat N\\u00ba ', _pad4(id),
            '","description":"A seat on the Essey Exchange \\u2014 one of ', uint256(seat.maxSupply()).toString(), '. Carries its own Vault (',
            seat.vaultOf(id).toHexString(),
            '): every Payout it has ever earned travels with it. Tier is staked by the current owner and clears on transfer.",'
        );
    }

    /// Tier from the Bell, fail-open to Base: metadata must render even if the Bell is unwired or a
    /// read reverts — a marketplace page is no place for a fail-closed oracle posture.
    function _tierOf(uint256 id) internal view returns (uint8) {
        // code.length check subsumes address(0) AND keeps fail-open genuinely true: a decode of
        // empty returndata would revert outside the catch (audit round 1, found independently by
        // two lenses). Post-Cancun code cannot vanish, so this is belt over the constructor guard.
        if (address(bell).code.length == 0) return 0;
        try bell.seats(id) returns (uint8 tier, uint248, uint256, uint256) {
            return tier;
        } catch {
            return 0;
        }
    }

    function _tierName(uint8 tier) internal pure returns (string memory) {
        if (tier == 0) return "Base";
        if (tier == 1) return "Tier I";
        if (tier == 2) return "Tier II";
        if (tier == 3) return "Tier III";
        if (tier == 4) return "Tier IV";
        return string(abi.encodePacked("Tier ", uint256(tier).toString()));
    }

    /// Seat numbers read like certificate numbers: 0001..2222.
    function _pad4(uint256 id) internal pure returns (string memory) {
        bytes memory b = bytes(id.toString());
        if (b.length >= 4) return string(b);
        bytes memory out = new bytes(4);
        uint256 pad = 4 - b.length;
        for (uint256 i = 0; i < 4; i++) {
            out[i] = i < pad ? bytes1("0") : b[i - pad];
        }
        return string(out);
    }

    /// The hallmark, as shipped in the brand system: outer hex in a gold gradient, faint inset hex,
    /// the serif E, "ESSEY" letterspaced above and the certificate line below. Tier renders as gold
    /// pips under the number — an upgraded Seat literally carries more gold.
    function _svg(string memory num, uint8 tier, string memory tierName) internal pure returns (string memory) {
        return string(abi.encodePacked(
            _svgChrome(),
            '<text x="200" y="322" text-anchor="middle" font-family="Menlo,monospace" font-size="21" letter-spacing="3" fill="#E9EBF1">SEAT N&#186; ', num, '</text>',
            _pips(tier),
            '<text x="200" y="376" text-anchor="middle" font-family="Menlo,monospace" font-size="11" letter-spacing="2" fill="#616A7B">', tierName, ' &#183; THE EXCHANGE</text>',
            '</svg>'
        ));
    }

    /// The static chrome: defs, ground, wordmark, and the hallmark itself (brand path in 100x100
    /// space, translated+scaled to sit at 200,190). Separate frame — one giant encodePacked is a
    /// stack-depth trap.
    function _svgChrome() internal pure returns (bytes memory) {
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">',
            '<stop offset="0" stop-color="#E7C57A"/><stop offset="1" stop-color="#B8923E"/></linearGradient>',
            '<radialGradient id="bg" cx="0.5" cy="0.32" r="0.9">',
            '<stop offset="0" stop-color="#161A24"/><stop offset="1" stop-color="#0A0C11"/></radialGradient></defs>',
            '<rect width="400" height="400" fill="url(#bg)"/>',
            '<text x="200" y="64" text-anchor="middle" font-family="Georgia,serif" font-size="19" letter-spacing="10" fill="#98A0B0">ESSEY</text>',
            '<g transform="translate(110,100) scale(1.8)">',
            '<path d="M50 7.81 L89.06 28.13 L89.06 71.88 L50 92.19 L10.94 71.88 L10.94 28.13 Z" fill="rgba(212,169,78,0.07)" stroke="url(#g)" stroke-width="3.4" stroke-linejoin="round"/>',
            '<path d="M50 16.4 L81.4 32.7 L81.4 67.3 L50 83.6 L18.6 67.3 L18.6 32.7 Z" stroke="rgba(231,197,122,0.20)" stroke-width="1.1" stroke-linejoin="round" fill="none"/>',
            '<text x="50" y="51.5" text-anchor="middle" dominant-baseline="central" font-family="Didot,Georgia,serif" font-size="50" fill="url(#g)">E</text>',
            '</g>'
        );
    }

    /// One gold diamond per Tier, centered. Base = none: unstaked Seats stay quiet.
    function _pips(uint8 tier) internal pure returns (string memory) {
        if (tier == 0) return "";
        if (tier > 8) tier = 8; // cap the row; the label always carries the exact number
        string memory out = "";
        // pip CENTERS run x0, x0+18, ...; midpoint must sit at 200 -> x0 = 200 - 9*(tier-1)
        // (audit round 1: the old left-edge formula sat the row 6px left of the number above it)
        uint256 x = 200 - 9 * (uint256(tier) - 1);
        for (uint8 i = 0; i < tier; i++) {
            out = string(abi.encodePacked(
                out,
                '<rect x="', (x - 4).toString(), '" y="340" width="9" height="9" transform="rotate(45 ',
                x.toString(), ' 344)" fill="url(#g)"/>'
            ));
            x += 18;
        }
        return out;
    }
}
