// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IQuest {
    function registered(address) external view returns (bool);
    function referralCount(address) external view returns (uint256);
}

/// TESTNET QuestLens — the single, swappable, on-chain definition of "did this wallet really test the
/// club." Stateless and read-only: it just reads balances across the deployed market contracts, so a
/// leaderboard can score hundreds of wallets in one call (qualifiedMany) instead of hundreds of reads.
///
/// SCALABILITY BY DESIGN. "What counts" lives here, in one place. When a new feature ships, redeploy
/// this lens (it holds no state, costs nothing to replace) and point the frontend at the new address —
/// both the quest checklist and the leaderboard update at once. New milestones are added by extending
/// `qualified` / adding fields to `status`, never by touching the money contracts.
///
/// "QUALIFIED" (a real-activity bar that resists sybil farming): the wallet opted into the quest AND
/// committed capital in two independent ways — it owns a Seat (bought on the Exchange, faucet-gated)
/// and it has supplied to the lending pool. Both cost real (test) money and gas per wallet, so a
/// referral only counts once a friend genuinely used the protocol — not for spawning empty wallets.
contract QuestLens {
    IQuest public immutable quest;
    IERC721 public immutable seat;
    IERC20 public immutable pool; // ERC-4626 share token: balance > 0 ⇒ supplied
    IERC20 public immutable aapl;
    IERC20 public immutable nvda;

    constructor(IQuest quest_, IERC721 seat_, IERC20 pool_, IERC20 aapl_, IERC20 nvda_) {
        quest = quest_;
        seat = seat_;
        pool = pool_;
        aapl = aapl_;
        nvda = nvda_;
    }

    struct Status {
        bool registered;
        bool ownsSeat;
        bool supplied;
        bool wonStock;
        uint256 referrals; // raw registrations crediting this wallet
    }

    function status(address a) public view returns (Status memory s) {
        s.registered = quest.registered(a);
        s.ownsSeat = seat.balanceOf(a) > 0;
        s.supplied = pool.balanceOf(a) > 0;
        s.wonStock = aapl.balanceOf(a) + nvda.balanceOf(a) > 0;
        s.referrals = quest.referralCount(a);
    }

    /// The leaderboard's qualification bar. Kept as its own function so it can tighten/loosen without
    /// changing `status`'s shape.
    function qualified(address a) public view returns (bool) {
        return quest.registered(a) && seat.balanceOf(a) > 0 && pool.balanceOf(a) > 0;
    }

    /// Batch: one call returns qualification for a whole set — the primitive the leaderboard scales on.
    function qualifiedMany(address[] calldata addrs) external view returns (bool[] memory out) {
        out = new bool[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            out[i] = qualified(addrs[i]);
        }
    }
}
