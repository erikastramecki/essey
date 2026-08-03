// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintableMock {
    function mint(address to, uint256 amount) external;
}

/// TESTNET ONLY — never deploy near real value. Drips play money so anyone can test the Market:
/// a fixed $ESSEY grant from this contract's balance plus freshly-minted mock USDG (the fixture
/// token's mint is public anyway; this just saves testers a second transaction). Cooldown per
/// address keeps the drip from being scripted dry in a minute; there is nothing else to protect.
contract TestnetFaucet {
    IERC20 public immutable essey;
    IMintableMock public immutable usdg;
    uint256 public constant ESSEY_DRIP = 5_000e18;
    uint256 public constant USDG_DRIP = 1_000e18; // mock USDG is 18-dec on testnet
    uint256 public constant COOLDOWN = 8 hours;

    mapping(address => uint256) public lastDrip;

    error TooSoon(uint256 secondsLeft);

    constructor(IERC20 essey_, IMintableMock usdg_) {
        essey = essey_;
        usdg = usdg_;
    }

    function drip() external {
        uint256 next = lastDrip[msg.sender] + COOLDOWN;
        if (block.timestamp < next) revert TooSoon(next - block.timestamp);
        lastDrip[msg.sender] = block.timestamp;
        essey.transfer(msg.sender, ESSEY_DRIP); // reverts when the faucet runs dry — refill or lower
        usdg.mint(msg.sender, USDG_DRIP);
    }
}
