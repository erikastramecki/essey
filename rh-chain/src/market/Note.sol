// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface INoteArt {
    function tokenURI(uint256 id) external view returns (string memory);
}

/// Note — an Essey loan position as a transferable bearer NFT. Minted by the pool on borrow (token id
/// == position id), burned by the pool the moment the position closes (repay or liquidation), inside
/// the pool's single close path.
///
/// Whoever holds the Note IS the borrower: repay authority, returned collateral, and any liquidation
/// surplus all follow `ownerOf` at execution time — so a position can be sold or transferred mid-life
/// and the debt + collateral claim travel together. Burning on close means a spent Note cannot exist:
/// nobody can be sold a claim on a position that already ended.
///
/// Contrast with the reference desk' LoanVault, which escrows the whole NFT for the life of the loan (the
/// asset goes dead while borrowed). Here the position itself stays live, transferable, and composable.
contract Note is ERC721 {
    address public immutable pool;
    /// The metadata renderer, wired ONCE by the pool right after deploy. address(0) = fallback JSON.
    address public art;

    error NotPool();
    error ArtAlreadySet();
    error ArtNotContract();

    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {
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

    function setArt(address art_) external {
        if (msg.sender != pool) revert NotPool();
        if (art != address(0)) revert ArtAlreadySet();
        // A codeless renderer would brick tokenURI forever: the staticcall to empty code "succeeds"
        // with empty returndata and the decode reverts OUTSIDE the try/catch (solc >=0.8.10 omits
        // the extcodesize check when return data is decoded). Loud wiring failure instead.
        if (art_.code.length == 0) revert ArtNotContract();
        art = art_;
    }

    /// Fail-open, never reverts — a marketplace page is no place for a fail-closed oracle posture.
    /// The code.length check is belt over the setArt guard (see there), and deliberately no
    /// _requireOwned: a closed position's Note must render (zeroed), not revert.
    function tokenURI(uint256 id) public view override returns (string memory) {
        if (art.code.length != 0) {
            try INoteArt(art).tokenURI(id) returns (string memory uri) {
                return uri;
            } catch {}
        }
        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(abi.encodePacked('{"name":"Essey Note #', Strings.toString(id), '"}'))
            )
        );
    }
}
