// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EsseyToken} from "../src/market/EsseyToken.sol";
import {Seat} from "../src/market/Seat.sol";
import {Bell} from "../src/market/Bell.sol";
import {IConverter} from "../src/market/IConverter.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

contract EsseyTokenTest is Test {
    EsseyToken essey;
    address treasury = address(0x7EA);
    address alice;
    uint256 alicePk;

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("alice");
        essey = new EsseyToken(treasury);
    }

    /// Fixed supply, minted once to the treasury; zero-address treasury rejected.
    function test_FixedSupplyToTreasury() public {
        assertEq(essey.totalSupply(), 2_222_222_222e18);
        assertEq(essey.balanceOf(treasury), 2_222_222_222e18, "entire supply at the treasury");
        assertEq(essey.decimals(), 18);

        vm.expectRevert(EsseyToken.TreasuryZero.selector);
        new EsseyToken(address(0));
    }

    /// There is no mint path after construction — the contract exposes no mint function, so supply can
    /// only ever go DOWN (burn). This asserts the burn actually reduces totalSupply.
    function test_BurnReducesSupplyForever() public {
        vm.prank(treasury);
        essey.burn(1_000_000e18);
        assertEq(essey.totalSupply(), 2_222_222_222e18 - 1_000_000e18);

        // burnFrom respects allowances.
        vm.prank(treasury);
        essey.approve(alice, 5e18);
        vm.prank(alice);
        essey.burnFrom(treasury, 5e18);
        assertEq(essey.totalSupply(), 2_222_222_222e18 - 1_000_005e18);
    }

    /// Permit: gasless approval by signature (EIP-2612), so Tier activation can be one transaction.
    function test_PermitApprovesBySignature() public {
        vm.prank(treasury);
        essey.transfer(alice, 100e18);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alice,
                address(this),
                42e18,
                essey.nonces(alice),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", essey.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        essey.permit(alice, address(this), 42e18, deadline, v, r, s);
        assertEq(essey.allowance(alice, address(this)), 42e18, "signature-approved allowance");
        essey.transferFrom(alice, address(this), 42e18);
        assertEq(essey.balanceOf(address(this)), 42e18);
    }

    /// End-to-end with the shipped Bell: $ESSEY pays a Tier activation, 50% burns to 0xdEaD, 50% to the
    /// Bell's treasury — the real sink path, using the real token.
    function test_WorksAsTheBellsFeeToken() public {
        Seat seat = new Seat("Essey Seat", "SEAT", 2222, address(this));
        ERC20Mock usdg = new ERC20Mock();
        uint256[] memory fees = new uint256[](1);
        fees[0] = 100e18;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;
        Bell bell = new Bell(seat, essey, usdg, treasury, 100e18, 100, fees, weights, IConverter(address(0)));
        seat.setHook(address(bell));

        vm.prank(treasury);
        essey.transfer(alice, 1_000e18);
        uint256 id = seat.mint(alice);
        vm.startPrank(alice);
        essey.approve(address(bell), type(uint256).max);
        bell.activate(id, 1);
        vm.stopPrank();

        assertEq(essey.balanceOf(0x000000000000000000000000000000000000dEaD), 50e18, "half sunk");
        assertEq(essey.balanceOf(treasury), 2_222_222_222e18 - 1_000e18 + 50e18, "half to treasury");
    }
}
