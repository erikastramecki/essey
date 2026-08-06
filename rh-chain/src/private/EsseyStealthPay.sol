// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC5564Announcer} from "./EsseyStealthAnnouncer.sol";

/// Private pay (Essey Private, Phase 0). Send an ERC-20 to a recipient's one-time STEALTH address and post
/// the ERC-5564 announcement in a single transaction. The stealth address + ephemeral pubkey are computed
/// off-chain by the sender (secp256k1 ECDH against the recipient's registered meta-address); this contract
/// only moves the token and announces where to find it.
///
/// CUSTODY: none. The transfer is `msg.sender -> stealthAddress` directly — funds never enter this contract,
/// so there is nothing to drain, freeze, or misaccount. The contract holds no balances and has no privileges.
/// It's a thin atomic wrapper so the transfer and the announcement can't desync (a transfer with no
/// announcement would strand funds the recipient can't find; an announcement with no transfer is a lie).
contract EsseyStealthPay is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant SECP256K1 = 1; // ERC-5564 schemeId

    IERC5564Announcer public immutable announcer;

    event PrivatePaid(address indexed from, address indexed stealthAddress, address indexed token, uint256 amount);

    error BadStealthAddress();
    error ZeroAmount();

    constructor(IERC5564Announcer announcer_) {
        announcer = announcer_;
    }

    /// Pull `amount` of `token` from the caller straight to `stealthAddress`, then announce it so the
    /// recipient can scan, identify, and spend. `ephemeralPubKey`/`metadata` are the ERC-5564 fields the
    /// recipient needs (view tag lives in `metadata`).
    function pay(
        IERC20 token,
        address stealthAddress,
        uint256 amount,
        bytes calldata ephemeralPubKey,
        bytes calldata metadata
    ) external nonReentrant {
        if (stealthAddress == address(0)) revert BadStealthAddress();
        if (amount == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, stealthAddress, amount);
        announcer.announce(SECP256K1, stealthAddress, ephemeralPubKey, metadata);
        emit PrivatePaid(msg.sender, stealthAddress, address(token), amount);
    }
}
