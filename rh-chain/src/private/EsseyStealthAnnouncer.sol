// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC5564Announcer {
    function announce(uint256 schemeId, address stealthAddress, bytes memory ephemeralPubKey, bytes memory metadata)
        external;
}

/// ERC-5564 stealth-payment announcer — the canonical announcement channel for Essey Private (Phase 0).
/// Anyone may announce a payment to a one-time stealth address; recipients scan `Announcement` events with
/// their viewing key to find funds meant for them and derive the key to spend. Holds no funds, has no owner
/// or privileges — a pure, permissionless event bus. The privacy comes from the stealth address itself
/// (secp256k1 ECDH, computed client-side); this contract only publishes where to look.
contract EsseyStealthAnnouncer is IERC5564Announcer {
    /// @param schemeId       the stealth scheme (1 = secp256k1, per ERC-5564)
    /// @param stealthAddress the one-time address the funds were sent to
    /// @param caller         whoever posted the announcement (informational)
    /// @param ephemeralPubKey the sender's ephemeral public key the recipient needs to derive the shared secret
    /// @param metadata       view tag + optional token/amount hints (ERC-5564 metadata layout)
    event Announcement(
        uint256 indexed schemeId,
        address indexed stealthAddress,
        address indexed caller,
        bytes ephemeralPubKey,
        bytes metadata
    );

    function announce(uint256 schemeId, address stealthAddress, bytes memory ephemeralPubKey, bytes memory metadata)
        external
    {
        emit Announcement(schemeId, stealthAddress, msg.sender, ephemeralPubKey, metadata);
    }
}
