// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Renderer for Seat metadata. External to the Seat so the art can be iterated up to deploy and the
/// gated collection contract stays minimal; the Seat wires it exactly once (`setArt`), after which
/// the art is as immutable as the Seat itself.
interface ISeatArt {
    function tokenURI(uint256 id) external view returns (string memory);
}
