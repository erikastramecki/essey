// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IEntropy} from "../market/EsseyCasesDegen.sol";

interface IEntropyConsumerLike {
    function _entropyCallback(uint64 sequenceNumber, address provider, bytes32 randomNumber) external;
}

/// TESTNET-ONLY stand-in for Dice Protocol / Pyth Entropy — used on Robinhood Chain testnet (46630),
/// where the real Dice oracle (mainnet 4663) isn't confirmed. Implements the same request surface;
/// `fulfill(seq)` is a permissionless keeper trigger that settles a pending request with blockhash-
/// derived pseudo-randomness (adequate for a testnet playground; NEVER for mainnet, where the real
/// commit-reveal oracle is used instead). The frontend or a keeper calls `fulfill` right after `buy`.
contract MockEntropy is IEntropy {
    uint64 public nextSeq = 1;
    uint256 public immutable fee;
    address public immutable provider;

    mapping(uint64 => address) public consumerOf;
    mapping(uint64 => bytes32) public userRandomOf;
    mapping(uint64 => bool) public fulfilled;

    event Requested(uint64 indexed seq, address indexed consumer);
    event Fulfilled(uint64 indexed seq, bytes32 random);

    constructor(uint256 fee_, address provider_) {
        fee = fee_;
        provider = provider_;
    }

    function getFeeV2(address, uint32) external view returns (uint256) {
        return fee;
    }

    function requestV2(address, bytes32 userRandom, uint32) external payable returns (uint64 seq) {
        seq = nextSeq++;
        consumerOf[seq] = msg.sender;
        userRandomOf[seq] = userRandom;
        emit Requested(seq, msg.sender);
    }

    /// Permissionless keeper: settle a pending request (must be a separate tx from buy — the consumer's
    /// callback is nonReentrant). Pseudo-random from the committed user-random + a future-ish blockhash.
    function fulfill(uint64 seq) external {
        address consumer = consumerOf[seq];
        require(consumer != address(0) && !fulfilled[seq], "MockEntropy: bad seq");
        fulfilled[seq] = true;
        bytes32 rand = keccak256(abi.encodePacked(userRandomOf[seq], blockhash(block.number - 1), seq, block.timestamp));
        IEntropyConsumerLike(consumer)._entropyCallback(seq, provider, rand);
        emit Fulfilled(seq, rand);
    }
}
