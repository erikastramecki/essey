// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EsseyStealthAnnouncer, IERC5564Announcer} from "../src/private/EsseyStealthAnnouncer.sol";
import {EsseyStealthRegistry} from "../src/private/EsseyStealthRegistry.sol";
import {EsseyStealthPay} from "../src/private/EsseyStealthPay.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract EsseyStealthTest is Test {
    EsseyStealthAnnouncer announcer;
    EsseyStealthRegistry registry;
    EsseyStealthPay payer;
    ERC20Mock usdg;

    address alice = address(0xA11CE);
    address stealth = address(0x57EA17); // a pretend one-time stealth address

    bytes32 constant TYPE_HASH = keccak256("Erc6538RegistryEntry(uint256 schemeId,bytes stealthMetaAddress,uint256 nonce)");

    event Announcement(
        uint256 indexed schemeId, address indexed stealthAddress, address indexed caller, bytes ephemeralPubKey, bytes metadata
    );
    event StealthMetaAddressSet(address indexed registrant, uint256 indexed schemeId, bytes stealthMetaAddress);

    function setUp() public {
        announcer = new EsseyStealthAnnouncer();
        registry = new EsseyStealthRegistry();
        payer = new EsseyStealthPay(IERC5564Announcer(address(announcer)));
        usdg = new ERC20Mock();
    }

    // Canonical ERC-6538 EIP-712 digest: the struct binds (schemeId, meta, nonce); the registrant is bound by
    // whoever signs (SignatureChecker verifies recovery == registrant).
    function _digest(uint256 schemeId, uint256 nonce, bytes memory meta) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                registry.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(TYPE_HASH, schemeId, keccak256(meta), nonce))
            )
        );
    }

    function _sig(uint256 pk, uint256 schemeId, uint256 nonce, bytes memory meta) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(schemeId, nonce, meta));
        return abi.encodePacked(r, s, v);
    }

    function test_RegisterSelf() public {
        bytes memory meta = hex"deadbeef";
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit StealthMetaAddressSet(alice, 1, meta);
        registry.registerKeys(1, meta);
        assertEq(registry.stealthMetaAddressOf(alice, 1), meta);
    }

    function test_RegisterOnBehalf_thenReplayReverts() public {
        (address reg, uint256 pk) = makeAddrAndKey("registrant");
        bytes memory meta = hex"c0ffee";
        bytes memory sig = _sig(pk, 1, 0, meta);

        registry.registerKeysOnBehalf(reg, 1, sig, meta); // relayer submits
        assertEq(registry.stealthMetaAddressOf(reg, 1), meta);
        assertEq(registry.nonceOf(reg), 1);

        vm.expectRevert(EsseyStealthRegistry.InvalidSignature.selector); // nonce consumed -> replay fails
        registry.registerKeysOnBehalf(reg, 1, sig, meta);
    }

    function test_RegisterOnBehalf_badSigReverts() public {
        (address reg,) = makeAddrAndKey("registrant");
        (, uint256 wrongPk) = makeAddrAndKey("attacker");
        bytes memory meta = hex"c0ffee";
        bytes memory sig = _sig(wrongPk, 1, 0, meta); // signed by the wrong key
        vm.expectRevert(EsseyStealthRegistry.InvalidSignature.selector);
        registry.registerKeysOnBehalf(reg, 1, sig, meta);
    }

    function test_IncrementNonce_invalidatesPendingSig() public {
        (address reg, uint256 pk) = makeAddrAndKey("registrant");
        bytes memory meta = hex"c0ffee";
        bytes memory sig = _sig(pk, 1, 0, meta); // signed over nonce 0

        vm.prank(reg);
        registry.incrementNonce(); // registrant burns nonce 0
        assertEq(registry.nonceOf(reg), 1);

        vm.expectRevert(EsseyStealthRegistry.InvalidSignature.selector); // the pending sig is now stale
        registry.registerKeysOnBehalf(reg, 1, sig, meta);
    }

    function test_Announce() public {
        vm.expectEmit(true, true, true, true);
        emit Announcement(1, stealth, address(this), hex"aa", hex"bb");
        announcer.announce(1, stealth, hex"aa", hex"bb");
    }

    function test_Pay_movesToStealth() public {
        usdg.mint(alice, 1000e18);
        vm.prank(alice);
        usdg.approve(address(payer), type(uint256).max);

        vm.prank(alice);
        payer.pay(usdg, stealth, 100e18, hex"aa", hex"bb");

        assertEq(usdg.balanceOf(stealth), 100e18, "funds delivered to the stealth address");
        assertEq(usdg.balanceOf(address(payer)), 0, "payer custodies nothing");
        assertEq(usdg.balanceOf(alice), 900e18, "debited from sender");
    }

    function test_Pay_zeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(EsseyStealthPay.BadStealthAddress.selector);
        payer.pay(usdg, address(0), 1, hex"", hex"");
    }

    function test_Pay_zeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(EsseyStealthPay.ZeroAmount.selector);
        payer.pay(usdg, stealth, 0, hex"", hex"");
    }
}
