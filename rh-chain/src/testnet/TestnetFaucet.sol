// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMintableMock {
    function mint(address to, uint256 amount) external;
}

/// TESTNET ONLY — never deploy near real value. Drips play money so anyone can test the Market: a
/// $ESSEY grant from this contract's balance plus freshly-minted mock USDG (the fixture token's mint
/// is public anyway; this just saves testers a second transaction). A per-address cooldown keeps the
/// drip from being scripted dry; there is nothing else to protect.
///
/// The drip amounts and cooldown are OWNER-SETTABLE (behind a hard sanity cap) so ops can retune what
/// testers get — e.g. enough $ESSEY to activate a Bell tier — without a redeploy. The owner can also
/// recover leftover $ESSEY (to move it to a new faucet). No path lets a non-owner take more than one
/// cooldown-gated drip, and no path can move real value — this holds only testnet play money.
contract TestnetFaucet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable essey;
    IMintableMock public immutable usdg;

    address public owner;
    uint256 public esseyDrip;
    uint256 public usdgDrip;
    uint256 public cooldown;

    /// Sanity ceilings so a fat-fingered setter can't hand out an absurd grant in one drip.
    uint256 public constant MAX_ESSEY_DRIP = 10_000_000e18;
    uint256 public constant MAX_USDG_DRIP = 1_000_000e18;

    mapping(address => uint256) public lastDrip;

    event Dripped(address indexed to, uint256 essey, uint256 usdg);
    event DripsSet(uint256 esseyDrip, uint256 usdgDrip, uint256 cooldown);
    event OwnerSet(address indexed owner);
    event Recovered(address indexed to, uint256 amount);

    error TooSoon(uint256 secondsLeft);
    error NotOwner();
    error TooLarge();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        IERC20 essey_,
        IMintableMock usdg_,
        address owner_,
        uint256 esseyDrip_,
        uint256 usdgDrip_,
        uint256 cooldown_
    ) {
        if (address(essey_) == address(0) || address(usdg_) == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        if (esseyDrip_ > MAX_ESSEY_DRIP || usdgDrip_ > MAX_USDG_DRIP) revert TooLarge();
        essey = essey_;
        usdg = usdg_;
        owner = owner_;
        esseyDrip = esseyDrip_;
        usdgDrip = usdgDrip_;
        cooldown = cooldown_;
    }

    /// One drip per address per `cooldown`. $ESSEY comes from this contract's balance (reverts when
    /// dry — refill or lower); mock USDG is freshly minted. Effects (the cooldown stamp) are written
    /// before the transfers, and the whole call is nonReentrant.
    function drip() external nonReentrant {
        // First drip (never dripped) is always allowed; subsequent ones wait out the cooldown. Keying on
        // `last != 0` means the gate doesn't depend on block.timestamp exceeding `cooldown` on a fresh chain.
        uint256 last = lastDrip[msg.sender];
        if (last != 0 && block.timestamp < last + cooldown) revert TooSoon(last + cooldown - block.timestamp);
        lastDrip[msg.sender] = block.timestamp;
        if (esseyDrip > 0) essey.safeTransfer(msg.sender, esseyDrip);
        if (usdgDrip > 0) usdg.mint(msg.sender, usdgDrip);
        emit Dripped(msg.sender, esseyDrip, usdgDrip);
    }

    /// Retune what a drip hands out (owner/ops). Both amounts are capped; cooldown is free (0 = none).
    function setDrips(uint256 esseyDrip_, uint256 usdgDrip_, uint256 cooldown_) external onlyOwner {
        if (esseyDrip_ > MAX_ESSEY_DRIP || usdgDrip_ > MAX_USDG_DRIP) revert TooLarge();
        esseyDrip = esseyDrip_;
        usdgDrip = usdgDrip_;
        cooldown = cooldown_;
        emit DripsSet(esseyDrip_, usdgDrip_, cooldown_);
    }

    function setOwner(address owner_) external onlyOwner {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerSet(owner_);
    }

    /// Recover leftover $ESSEY to the owner — e.g. to re-point testers to a fresh faucet. Owner-only,
    /// and it can only ever move this faucet's own $ESSEY balance to the owner.
    function recover(uint256 amount) external onlyOwner {
        essey.safeTransfer(owner, amount);
        emit Recovered(owner, amount);
    }
}
