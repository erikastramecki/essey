// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// Note — an Essey loan position as a transferable bearer NFT. Minted by the pool on borrow (token id
/// == position id), burned by the pool the moment the position closes (repay or liquidation), inside
/// the pool's single close path.
///
/// Whoever holds the Note IS the borrower: repay authority, returned collateral, and any liquidation
/// surplus all follow `ownerOf` at execution time — so a position can be sold or transferred mid-life
/// and the debt + collateral claim travel together. Burning on close means a spent Note cannot exist:
/// nobody can be sold a claim on a position that already ended.
///
/// Contrast with StonkBrokers' LoanVault, which escrows the whole NFT for the life of the loan (the
/// asset goes dead while borrowed). Here the position itself stays live, transferable, and composable.
contract Note is ERC721 {
    address public immutable pool;

    error NotPool();

    constructor() ERC721("Essey Note", "eNOTE") {
        pool = msg.sender; // deployed by the pool's constructor; the binding is permanent
    }

    function mint(address to, uint256 id) external {
        if (msg.sender != pool) revert NotPool();
        // Plain _mint, not _safeMint: the borrower initiated the borrow themselves, and skipping the
        // onERC721Received callback removes a reentrancy surface from the pool's borrow path.
        _mint(to, id);
    }

    function burn(uint256 id) external {
        if (msg.sender != pool) revert NotPool();
        _burn(id);
    }
}
