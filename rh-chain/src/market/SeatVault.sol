// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

/// SeatVault — a Seat's token-bound wallet (ERC-6551 style). It is *owned by whoever holds the Seat
/// NFT*: `owner()` reads the NFT's current owner, and only that owner may move assets out. So the Vault,
/// and everything sealed inside it (collateral, earned Payouts), travels with the Seat on transfer —
/// the "position-as-a-wallet" primitive borrowed from the reference desk, on Essey's rails.
///
/// Deployed as a minimal-proxy clone per tokenId (see Seat), so its address is deterministic and the
/// binding is set once at initialization.
///
/// NOTE (mainnet): for wallet/marketplace interop we intend to also register Vaults through the
/// canonical ERC-6551 registry (0x000000006551c19487814612e58FE06813775758) so tools recognise them;
/// this contract is the account implementation either path uses.
contract SeatVault is IERC721Receiver, IERC1155Receiver {
    address public tokenContract;
    uint256 public tokenId;
    bool private _initialized;

    /// Bumped on every execute — lets indexers and future lien logic observe Vault activity, matching
    /// the ERC-6551 `state()` convention.
    uint256 public state;

    error AlreadyInitialized();
    error NotOwner();
    error CallFailed(bytes ret);

    /// Called once by the deployer (Seat) immediately after cloning, atomically with the mint.
    function initialize(address tokenContract_, uint256 tokenId_) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        tokenContract = tokenContract_;
        tokenId = tokenId_;
    }

    /// Control follows the NFT: the Vault's owner is always the current holder of the bound Seat.
    function owner() public view returns (address) {
        return IERC721(tokenContract).ownerOf(tokenId);
    }

    /// Execute an arbitrary call from the Vault (move a token, approve, etc.). Only the current Seat
    /// holder may call. A future phase gates this with the lending pool's lien so collateral cannot
    /// leave while a Note's loan is open (see docs/DESIGN-seats-market-layer.md, improvement #2).
    function execute(address to, uint256 value, bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != owner()) revert NotOwner();
        unchecked {
            ++state;
        }
        bool ok;
        (ok, result) = to.call{value: value}(data);
        if (!ok) revert CallFailed(result);
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IERC721Receiver).interfaceId
            || id == type(IERC1155Receiver).interfaceId;
    }
}
