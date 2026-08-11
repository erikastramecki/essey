// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ISeatArt} from "./ISeatArt.sol";
import {Don} from "./Don.sol";

/// DonArt — the Dons' metadata renderer. The Don wires it exactly once (`setArt` is one-shot, via the
/// distributor's passthrough), so THIS contract must never rot: the 8,888 layered PFPs are far too heavy
/// to draw on-chain, so `tokenURI` points at the metadata service (`baseURI` + id) — and because domains
/// change while the one-shot can never be re-aimed, the pointer is ROTATABLE here: an admin (a multisig
/// in production) may `setBaseURI` at any time, loudly (event), without touching the collection.
///
/// Never blank: when the baseURI is unset (pre-launch, or deliberately cleared in an emergency), tokenURI
/// degrades to a fully on-chain data URI — the Don's name, its committed trait-combo hash, its lock
/// state, and the hallmark placeholder image. A minted Don always renders, even with every server dark.
/// The combo hash in that fallback is the SAME commitment the off-chain renderer decodes (`Don.traits`),
/// so anyone can verify the served art against chain truth: the server can only describe the combo the
/// chain committed, or be caught lying.
contract DonArt is ISeatArt {
    using Strings for uint256;

    Don public immutable don;

    /// The baseURI rotator (a multisig in production). Deliberately the ONLY power in this contract:
    /// it can re-aim where metadata is served from, never what combo a Don committed on-chain.
    /// NOT immutable — the Don's setArt one-shot means this contract can never be replaced, so the
    /// rotator itself must survive a multisig migration: two-step handoff (propose + accept), which
    /// also makes a fat-fingered transfer unable to brick rotation forever.
    address public admin;
    address public pendingAdmin;

    /// Metadata service prefix; tokenURI = baseURI + id. Empty = render the on-chain fallback.
    string public baseURI;

    event BaseURISet(string baseURI);
    event AdminProposed(address indexed pending);
    event AdminAccepted(address indexed admin);

    error ZeroDon();
    error DonNotContract();
    error ZeroAdmin();
    error NotAdmin();
    error NotPendingAdmin();

    constructor(Don don_, address admin_, string memory baseURI_) {
        if (address(don_) == address(0)) revert ZeroDon();
        // A codeless don would BRICK the fallback render forever (empty-returndata decode reverts
        // outside any try/catch — the SeatArt audit lesson). Loud deploy failure instead.
        if (address(don_).code.length == 0) revert DonNotContract();
        if (admin_ == address(0)) revert ZeroAdmin();
        don = don_;
        admin = admin_;
        baseURI = baseURI_;
        emit BaseURISet(baseURI_);
    }

    /// Re-aim the metadata service (domains change; the Don's setArt one-shot cannot). Setting "" is the
    /// emergency brake: every Don falls back to the on-chain data URI until a new base is set.
    function setBaseURI(string calldata baseURI_) external {
        if (msg.sender != admin) revert NotAdmin();
        baseURI = baseURI_;
        emit BaseURISet(baseURI_);
    }

    /// Two-step admin handoff. Propose address(0) to cancel a pending handoff.
    function proposeAdmin(address pending_) external {
        if (msg.sender != admin) revert NotAdmin();
        pendingAdmin = pending_;
        emit AdminProposed(pending_);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin || msg.sender == address(0)) revert NotPendingAdmin();
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminAccepted(msg.sender);
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        if (bytes(baseURI).length != 0) return string.concat(baseURI, id.toString());
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(_json(id))));
    }

    /// JSON assembly split into small frames — one giant encodePacked is a stack-depth trap.
    function _json(uint256 id) internal view returns (bytes memory) {
        return abi.encodePacked(
            _jsonHead(id),
            '"attributes":[{"trait_type":"Combo","value":"', uint256(don.traits(id)).toHexString(32),
            '"},{"trait_type":"Locked","value":"', don.locked(id) ? "Yes" : "No",
            '"}],"image":"data:image/svg+xml;base64,', Base64.encode(bytes(_svg(_pad4(id)))), '"}'
        );
    }

    function _jsonHead(uint256 id) internal view returns (bytes memory) {
        return abi.encodePacked(
            '{"name":"Don #', id.toString(),
            '","description":"A Don of the Essey Dons \\u2014 one of ', uint256(don.maxSupply()).toString(),
            ", the seat at the table. Its trait combo is committed on-chain as the hash in Combo; the",
            " rendered art decodes that commitment once the metadata base is set. Traits stay mutable",
            ' until the Don is staked \\u2014 staking locks the art forever.",'
        );
    }

    /// Don numbers read like certificate numbers: 0001..8888.
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

    /// The hallmark placeholder, in the brand system SeatArt shipped: gold hex + E monogram on ink,
    /// the Don's certificate number, and an honest one-liner about where the art lives.
    function _svg(string memory num) internal pure returns (string memory) {
        return string(abi.encodePacked(
            _svgChrome(),
            '<text x="200" y="322" text-anchor="middle" font-family="Menlo,monospace" font-size="21" letter-spacing="3" fill="#E9EBF1">DON N&#186; ', num, '</text>',
            '<text x="200" y="376" text-anchor="middle" font-family="Menlo,monospace" font-size="11" letter-spacing="2" fill="#616A7B">TRAITS SEALED ON-CHAIN</text>',
            '</svg>'
        ));
    }

    /// Static chrome: defs, ground, wordmark, hallmark — separate frame, same stack-depth reasoning.
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
}
