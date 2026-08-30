// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EsseyMarkets} from "../EsseyMarkets.sol";
import {EsseyPool} from "../EsseyPool.sol";
import {Note} from "./Note.sol";
import {NoteArt} from "./NoteArt.sol";

/// Pure discovery registry: the deploy script constructs pool + NoteArt and records the result
/// here. Embedding both creation codes put the old deployPool factory at 30,576 runtime bytes —
/// over the EIP-170 limit of 24,576 — and aborted the testnet broadcast. Registering instead of
/// deploying also removes the factory's only write into the pools: it holds no authority at all.
///
/// F1 (round 6): a slot MIRRORS `markets.activePool` — the timelocked authority — instead of the
/// old first-come-forever PoolExists rule, which made a same-token successor permanently
/// undiscoverable. Only the current active pool registers (commit already verified its token and
/// registry bindings there, which is also what keeps `poolFor` squat-proof); re-registering it is
/// allowed and re-emits PoolDeployed, so the keeper discovers successors from logs.
///
/// ACCEPTED (audit round-4 A-1): register() duck-types the pool — it cannot prove canonical
/// EsseyPool bytecode the way the old in-factory `new` could (immutables make every pool's
/// runtime hash unique, so extcodehash pinning is impossible). Registration is admin-only and
/// discovery-only, and nothing on chain routes funds by poolFor today. ESCALATION TRIGGER: the
/// day any contract or UI routes deposits by poolFor or PoolDeployed, this acceptance expires —
/// a pinned-initcode CREATE2 deployer restores the guarantee if that day comes.
contract PoolFactory {
    error NotAdmin();
    error NotActivePool(address collateralToken, address activePool, address pool);
    error ArtNotWired();
    error ArtMismatch();

    event PoolDeployed(address indexed collateralToken, address indexed pool, address note, address art);

    EsseyMarkets public immutable markets;
    mapping(address => address) public poolFor;

    constructor(EsseyMarkets markets_) {
        markets = markets_;
    }

    function register(address collateralToken, address pool) external {
        if (msg.sender != markets.admin()) revert NotAdmin();
        address active = markets.activePool(collateralToken);
        // The zero clause keeps a never-committed token loud: without it, register(token, 0)
        // would sail past the equality and die decoding note() on an empty account.
        if (pool == address(0) || pool != active) revert NotActivePool(collateralToken, active, pool);

        Note note = EsseyPool(pool).note();
        address art = note.art();
        if (art == address(0)) revert ArtNotWired();
        if (address(NoteArt(art).pool()) != pool) revert ArtMismatch();

        poolFor[collateralToken] = pool;
        // Event name + fields kept verbatim: the keeper enumerates PoolDeployed logs for its
        // token list, and the indexer keys on this exact signature.
        emit PoolDeployed(collateralToken, pool, address(note), art);
    }
}
