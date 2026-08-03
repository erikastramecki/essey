// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// TESTNET quest registry — the one piece of the whitelist quest that isn't already on-chain: an
/// explicit opt-in and a tamper-resistant referral graph. Everything else the quest scores (buying a
/// Seat, staking, ringing, claiming, opening a Case, supplying) is already recorded by the market
/// contracts' own events; this just records "I'm in" and "who invited me" so the off-chain scorer
/// (indexer → Merkle root → MintDistributor, per docs/DESIGN-whitelist-onboarding.md) can build the
/// referral tree and the final allowlist. Holds no funds; nothing here mints or promises a Seat.
contract QuestRegistry {
    mapping(address => bool) public registered;
    mapping(address => address) public referrerOf; // 0 = joined without a referral
    mapping(address => uint256) public referralCount; // how many joined with you as referrer
    uint256 public totalRegistered;

    event Registered(address indexed participant, address indexed referrer);

    error AlreadyRegistered();
    error SelfReferral();

    /// Join the quest once, optionally crediting whoever referred you. The referrer need not have
    /// registered first (they may register later); the scorer resolves the graph off-chain. A bad or
    /// sybil referrer only affects that referrer's own (curated, anti-sybil-reviewed) priority — it
    /// can never take a spot from anyone else, since selection is off-chain and reviewed.
    function register(address referrer) external {
        if (registered[msg.sender]) revert AlreadyRegistered();
        if (referrer == msg.sender) revert SelfReferral();
        registered[msg.sender] = true;
        totalRegistered += 1;
        if (referrer != address(0)) {
            referrerOf[msg.sender] = referrer;
            referralCount[referrer] += 1;
        }
        emit Registered(msg.sender, referrer);
    }
}
