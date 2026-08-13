// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {GameBase} from "./GameBase.t.sol";
import {GameController} from "../src/game/GameController.sol";
import {Scrip} from "../src/game/Scrip.sol";
import {GameRoles} from "../src/game/GameTypes.sol";

contract GameControllerScripTest is GameBase {
    // ---------------------------------------------------------------- controller: role registry

    function test_FixedRoleList_RejectsUnknownRole() public {
        vm.expectRevert(GameController.UnknownRole.selector);
        controller.setModule("MADE_UP_ROLE", address(0xBEEF));
    }

    function test_OutfitModuleSlot_ReservedAndEmpty() public view {
        // A14: the slot exists in the immutable list, unwired in Phase 0.
        assertTrue(controller.isRole(GameRoles.OUTFIT_MODULE));
        assertEq(controller.moduleOf(GameRoles.OUTFIT_MODULE), address(0));
    }

    function test_SetModule_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(GameController.NotAdmin.selector);
        controller.setModule(GameRoles.KEEPER, alice);
    }

    function test_Seal_ForcesTimelock() public {
        controller.seal();
        vm.expectRevert(GameController.AlreadySealed.selector);
        controller.setModule(GameRoles.KEEPER, address(0x1234));

        controller.queueModule(GameRoles.KEEPER, address(0x1234));
        vm.expectRevert(GameController.TimelockActive.selector);
        controller.executeModule(GameRoles.KEEPER);

        vm.warp(block.timestamp + 2 days);
        controller.executeModule(GameRoles.KEEPER);
        assertEq(controller.moduleOf(GameRoles.KEEPER), address(0x1234));
    }

    function test_QueueBeforeSeal_Reverts() public {
        vm.expectRevert(GameController.NotSealed.selector);
        controller.queueModule(GameRoles.KEEPER, address(0x1234));
    }

    function test_IsModule_ScansWiredRoles() public view {
        assertTrue(controller.isModule(address(board)));
        assertTrue(controller.isModule(address(raid)));
        assertTrue(controller.isModule(address(escrow)));
        assertTrue(controller.isModule(address(hitter)));
        assertFalse(controller.isModule(address(this)));
        assertFalse(controller.isModule(address(0)));
    }

    function test_AdminHandover_TwoStep() public {
        controller.proposeAdmin(alice);
        assertEq(controller.admin(), address(this)); // not yet
        vm.prank(bob);
        vm.expectRevert(GameController.NotPendingAdmin.selector);
        controller.acceptAdmin();
        vm.prank(alice);
        controller.acceptAdmin();
        assertEq(controller.admin(), alice);
    }

    // ---------------------------------------------------------------- scrip: module-only ledger

    function test_Scrip_MintBurnMove_ModuleOnly() public {
        vm.expectRevert(Scrip.NotModule.selector); // admin is NOT a module
        scrip.mint(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(Scrip.NotModule.selector);
        scrip.burn(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(Scrip.NotModule.selector);
        scrip.move(alice, bob, 1e18);
    }

    function test_Scrip_HasNoTransferSurface() public {
        // Non-transferability is structural: the ABI simply has no transfer/approve.
        (bool ok,) = address(scrip).call(abi.encodeWithSignature("transfer(address,uint256)", bob, 1e18));
        assertFalse(ok);
        (ok,) = address(scrip).call(abi.encodeWithSignature("approve(address,uint256)", bob, 1e18));
        assertFalse(ok);
    }

    function test_Scrip_MoveNeverMints() public {
        _grantScrip(alice, 100e18);
        uint256 supply = scrip.totalSupply();
        vm.prank(address(board));
        scrip.move(alice, bob, 40e18);
        assertEq(scrip.totalSupply(), supply); // reassignment, not emission
        assertEq(scrip.balanceOf(alice), 60e18);
        assertEq(scrip.balanceOf(bob), 40e18);
    }

    function test_Scrip_BurnTracksFeeSink() public {
        _grantScrip(alice, 100e18);
        vm.prank(address(board));
        scrip.burn(alice, 30e18);
        assertEq(scrip.totalBurned(), 30e18);
        assertEq(scrip.totalSupply(), 70e18);
    }

    function test_Scrip_InsufficientReverts() public {
        vm.prank(address(board));
        vm.expectRevert(Scrip.InsufficientScrip.selector);
        scrip.burn(alice, 1);
    }

    function test_Scrip_SeasonClose_O1Reset() public {
        // Season reset is SEASON_MODULE-only now (F2 fix). Wire a mock module pre-seal to exercise the
        // O(1) reset the Phase-2 escrow will drive.
        address seasonMod = address(0x5EA5);
        controller.setModule(GameRoles.SEASON_MODULE, seasonMod);
        _grantScrip(alice, 100e18);
        assertEq(scrip.balanceOf(alice), 100e18);
        vm.prank(seasonMod);
        scrip.closeSeason();
        assertEq(scrip.seasonId(), 2);
        assertEq(scrip.balanceOf(alice), 0); // fresh season
        assertEq(scrip.balanceOfAt(1, alice), 100e18); // archive stays readable
    }

    function test_Scrip_SeasonClose_NotRandos() public {
        vm.prank(alice);
        vm.expectRevert(Scrip.NotSeasonAuthority.selector);
        scrip.closeSeason();
    }

    /// F2 fix (fund-safety lens): the admin fallback on closeSeason was removed. In Phase 0 no
    /// SEASON_MODULE is wired, so closeSeason is uncallable — the admin can never bump the season key
    /// and strand HouseEscrow custody (its ledgers are NOT season-scoped), which would brick bank().
    function test_Scrip_SeasonClose_AdminCannot() public {
        _grantScrip(alice, 100e18);
        vm.expectRevert(Scrip.NotSeasonAuthority.selector);
        scrip.closeSeason(); // caller is the controller admin (this test contract) — still rejected
        assertEq(scrip.seasonId(), 1); // no reset happened
    }

    /// F1 fix (auth / fund-safety lenses): the KEEPER hot key must NEVER be a Scrip module. The old
    /// whole-array isModule() scan granted it mint/move/burn power — a compromised keeper could mint
    /// unbounded Scrip or drain any vault, bypassing every module-layer budget reservation.
    function test_IsModule_KeeperExcluded() public {
        assertFalse(controller.isModule(keeper)); // the hot operator key is NOT a money module
        vm.startPrank(keeper);
        vm.expectRevert(Scrip.NotModule.selector);
        scrip.mint(keeper, 1e27); // no unbacked emission
        vm.expectRevert(Scrip.NotModule.selector);
        scrip.move(address(escrow), keeper, 1); // no draining a vault
        vm.expectRevert(Scrip.NotModule.selector);
        scrip.burn(address(escrow), 1); // no burning a player's custody
        vm.stopPrank();
    }
}
