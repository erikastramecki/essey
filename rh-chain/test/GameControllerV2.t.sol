// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {GameControllerV2} from "../src/game/GameControllerV2.sol";
import {GameRoles} from "../src/game/GameTypes.sol";

/// The v2 registry. The tests that matter are the two that motivated the rebuild — a new money module
/// CAN exist, and the keeper still cannot touch Scrip — plus proof that the frozen-list property v1
/// relied on for safety was preserved rather than traded away.
contract GameControllerV2Test is Test {
    GameControllerV2 c;
    address admin = address(0xA11CE);

    // The v2 stack: the five v1 money modules, the new money modules that v1 had no room for, and the
    // powerless roles. Declared here the way a deploy script would declare them.
    bytes32 constant FIXERS_BOOK = "FIXERS_BOOK";
    bytes32 constant FEE_ROUTER = "FEE_ROUTER";
    bytes32 constant PAYMASTER = "PAYMASTER";
    bytes32 constant SPECIALIST = "SPECIALIST";

    function _specs() internal pure returns (GameControllerV2.RoleSpec[] memory s) {
        s = new GameControllerV2.RoleSpec[](11);
        s[0] = GameControllerV2.RoleSpec(GameRoles.MISSION_MODULE, true);
        s[1] = GameControllerV2.RoleSpec(GameRoles.RAID_MODULE, true);
        s[2] = GameControllerV2.RoleSpec(GameRoles.HOUSE_MODULE, true);
        s[3] = GameControllerV2.RoleSpec(GameRoles.DEED_MODULE, true);
        s[4] = GameControllerV2.RoleSpec(GameRoles.HITTER_MODULE, true);
        s[5] = GameControllerV2.RoleSpec(FIXERS_BOOK, true);
        s[6] = GameControllerV2.RoleSpec(FEE_ROUTER, true);
        s[7] = GameControllerV2.RoleSpec(PAYMASTER, true);
        s[8] = GameControllerV2.RoleSpec(SPECIALIST, true);
        s[9] = GameControllerV2.RoleSpec(GameRoles.OUTFIT_MODULE, false);
        s[10] = GameControllerV2.RoleSpec(GameRoles.KEEPER, false);
    }

    function setUp() public {
        c = new GameControllerV2(admin, _specs());
    }

    // ---------------------------------------------------------------- the reason for the rebuild

    /// v1 could not express this at all: every money role was a hardcoded branch, so an insurance
    /// fund or a fee router could never have moved a unit of Scrip.
    function test_newMoneyModule_canMoveScrip() public {
        address book = address(0xB00C);
        vm.prank(admin);
        c.setModule(FIXERS_BOOK, book);
        assertTrue(c.isModule(book), "a declared money module must pass the Scrip gate");
    }

    /// The v1 audit fix, preserved. The keeper is a hot operator key; it must never hold emission or
    /// transfer power, no matter how it is wired.
    function test_keeper_neverMovesScrip() public {
        address keeper = address(0xC0FFEE);
        vm.prank(admin);
        c.setModule(GameRoles.KEEPER, keeper);
        assertFalse(c.isModule(keeper), "the keeper must never pass the Scrip gate");
    }

    /// Powerless roles stay powerless even when re-pointed after a seal and timelock.
    function test_powerlessRole_staysPowerlessAfterRepoint() public {
        address outfit = address(0x0F17);
        vm.startPrank(admin);
        c.seal();
        c.queueModule(GameRoles.OUTFIT_MODULE, outfit);
        vm.warp(block.timestamp + c.TIMELOCK());
        c.executeModule(GameRoles.OUTFIT_MODULE);
        vm.stopPrank();
        assertEq(c.moduleOf(GameRoles.OUTFIT_MODULE), outfit);
        assertFalse(c.isModule(outfit), "re-pointing cannot confer money power the role never had");
    }

    // ---------------------------------------------------------------- the preserved v1 property

    /// The security property v1 documented: a module can be re-pointed, a new POWER cannot be
    /// invented. There is no function that adds a role, so this is checkable by absence — the list
    /// length can never change after construction.
    function test_roleList_isFrozenAtDeploy() public {
        uint256 before = c.roleCount();
        address any = address(0xBEEF);
        vm.startPrank(admin);
        c.setModule(GameRoles.MISSION_MODULE, any); // the most invasive thing an admin can do
        vm.stopPrank();
        assertEq(c.roleCount(), before, "the role list must never grow after construction");
        vm.expectRevert(GameControllerV2.UnknownRole.selector);
        vm.prank(admin);
        c.setModule("INVENTED_ROLE", any);
    }

    function test_declaredPowers_areReadableBack() public view {
        uint256 n = c.roleCount();
        uint256 moneyRoles;
        for (uint256 i = 0; i < n; i++) {
            (bytes32 role, bool money,) = c.roleAt(i);
            assertTrue(c.isRole(role));
            if (money) moneyRoles++;
        }
        assertEq(n, 11);
        assertEq(moneyRoles, 9, "a deployment's money powers must be auditable from the chain");
    }

    function test_duplicateRole_reverts() public {
        GameControllerV2.RoleSpec[] memory s = new GameControllerV2.RoleSpec[](2);
        s[0] = GameControllerV2.RoleSpec(GameRoles.MISSION_MODULE, true);
        s[1] = GameControllerV2.RoleSpec(GameRoles.MISSION_MODULE, false);
        vm.expectRevert(GameControllerV2.DuplicateRole.selector);
        new GameControllerV2(admin, s);
    }

    function test_tooManyRoles_reverts() public {
        uint256 n = c.MAX_ROLES() + 1;
        GameControllerV2.RoleSpec[] memory s = new GameControllerV2.RoleSpec[](n);
        for (uint256 i = 0; i < n; i++) s[i] = GameControllerV2.RoleSpec(bytes32(i + 1), false);
        vm.expectRevert(GameControllerV2.TooManyRoles.selector);
        new GameControllerV2(admin, s);
    }

    function test_zeroRole_reverts() public {
        GameControllerV2.RoleSpec[] memory s = new GameControllerV2.RoleSpec[](1);
        s[0] = GameControllerV2.RoleSpec(bytes32(0), true);
        vm.expectRevert(GameControllerV2.BadConfig.selector);
        new GameControllerV2(admin, s);
    }

    // ---------------------------------------------------------------- wiring discipline (v1 parity)

    function test_setModule_revertsAfterSeal() public {
        vm.startPrank(admin);
        c.seal();
        vm.expectRevert(GameControllerV2.AlreadySealed.selector);
        c.setModule(GameRoles.MISSION_MODULE, address(0x1));
        vm.stopPrank();
    }

    function test_queueModule_requiresSeal() public {
        vm.prank(admin);
        vm.expectRevert(GameControllerV2.NotSealed.selector);
        c.queueModule(GameRoles.MISSION_MODULE, address(0x1));
    }

    function test_executeModule_respectsTimelock() public {
        vm.startPrank(admin);
        c.seal();
        c.queueModule(GameRoles.MISSION_MODULE, address(0x1));
        vm.expectRevert(GameControllerV2.TimelockActive.selector);
        c.executeModule(GameRoles.MISSION_MODULE);
        vm.stopPrank();
    }

    function test_onlyAdmin() public {
        vm.expectRevert(GameControllerV2.NotAdmin.selector);
        c.setModule(GameRoles.MISSION_MODULE, address(0x1));
    }

    function test_adminHandover_isTwoStep() public {
        address next = address(0xDEC0DE);
        vm.prank(admin);
        c.proposeAdmin(next);
        assertEq(c.admin(), admin, "proposing must not transfer");
        vm.prank(next);
        c.acceptAdmin();
        assertEq(c.admin(), next);
    }

    // ---------------------------------------------------------------- fuzz

    /// However the admin wires things, only addresses sitting in a money-declared role may move Scrip.
    function testFuzz_onlyMoneyRolesPassTheGate(address a, uint8 which) public {
        vm.assume(a != address(0));
        uint256 n = c.roleCount();
        (bytes32 role, bool money,) = c.roleAt(which % n);
        vm.prank(admin);
        c.setModule(role, a);
        assertEq(c.isModule(a), money, "the gate must follow the declared flag, nothing else");
    }
}
