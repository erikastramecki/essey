// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Transfer hook the Seat collection calls on every true ownership transfer (not mint or burn).
/// The Bell implements it to clear a Seat's Tier when it changes hands — the activation fee is
/// per-owner, mirroring the reference desk' "activation clears on true ownership transfer".
interface ISeatHook {
    function onSeatTransfer(uint256 id, address from, address to) external;
}
