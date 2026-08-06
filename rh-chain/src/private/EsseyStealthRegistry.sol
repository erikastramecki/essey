// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// ERC-6538 stealth meta-address registry (Essey Private, Phase 0), implemented to the canonical spec so
/// off-the-shelf stealth-address SDKs interoperate with it unchanged. Maps an account to its stealth
/// meta-address (per scheme) so a sender can look up where to derive the recipient's one-time stealth
/// address. Self-registration, or signature-based registration (EIP-712 typed data via SignatureChecker,
/// so both EOAs *and* ERC-1271 smart-contract wallets can authorize a relayer to register gaslessly).
/// Holds no funds, has no privileged roles.
contract EsseyStealthRegistry {
    /// registrant => schemeId => stealth meta-address (the recipient's spend + view public keys, packed)
    mapping(address => mapping(uint256 => bytes)) public stealthMetaAddressOf;

    /// EIP-712 typehash for a signed registration entry (canonical ERC-6538).
    bytes32 public constant ERC6538REGISTRY_ENTRY_TYPE_HASH =
        keccak256("Erc6538RegistryEntry(uint256 schemeId,bytes stealthMetaAddress,uint256 nonce)");

    /// Per-registrant nonce — consumed by `registerKeysOnBehalf`; a user can burn one via `incrementNonce`
    /// to invalidate any outstanding signed authorization (e.g. before/after a self-update).
    mapping(address => uint256) public nonceOf;

    /// EIP-712 domain separator (name "ERC6538Registry", version "1.0"), pinned to this chain + address.
    bytes32 public immutable DOMAIN_SEPARATOR;

    event StealthMetaAddressSet(address indexed registrant, uint256 indexed schemeId, bytes stealthMetaAddress);
    event NonceIncremented(address indexed registrant, uint256 newNonce);

    error InvalidSignature();

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("ERC6538Registry")),
                keccak256(bytes("1.0")),
                block.chainid,
                address(this)
            )
        );
    }

    /// Register (or update) the caller's own stealth meta-address for a scheme.
    function registerKeys(uint256 schemeId, bytes calldata stealthMetaAddress) external {
        stealthMetaAddressOf[msg.sender][schemeId] = stealthMetaAddress;
        emit StealthMetaAddressSet(msg.sender, schemeId, stealthMetaAddress);
    }

    /// Register on behalf of `registrant`, authorized by their EIP-712 signature over the entry (which binds
    /// schemeId, the meta-address, and the registrant's current nonce). Consuming the nonce blocks replay;
    /// SignatureChecker accepts EOA (ECDSA) and ERC-1271 signatures. Lets a relayer onboard a user gaslessly.
    function registerKeysOnBehalf(
        address registrant,
        uint256 schemeId,
        bytes memory signature,
        bytes calldata stealthMetaAddress
    ) external {
        bytes32 dataHash;
        unchecked {
            dataHash = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR,
                    keccak256(
                        abi.encode(
                            ERC6538REGISTRY_ENTRY_TYPE_HASH,
                            schemeId,
                            keccak256(stealthMetaAddress),
                            nonceOf[registrant]++
                        )
                    )
                )
            );
        }
        if (!SignatureChecker.isValidSignatureNow(registrant, dataHash, signature)) revert InvalidSignature();

        stealthMetaAddressOf[registrant][schemeId] = stealthMetaAddress;
        emit StealthMetaAddressSet(registrant, schemeId, stealthMetaAddress);
    }

    /// Invalidate any outstanding signed authorization by burning a nonce.
    function incrementNonce() external {
        unchecked {
            nonceOf[msg.sender]++;
        }
        emit NonceIncremented(msg.sender, nonceOf[msg.sender]);
    }
}
