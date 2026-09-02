// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GameLedger} from "../src/game/GameLedger.sol";
import {GameControllerV2} from "../src/game/GameControllerV2.sol";
import {IGameController, GameRoles} from "../src/game/GameTypes.sol";

contract TestStock is ERC20 {
    constructor() ERC20("Robinhood Stock", "STK") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// GameLedger paired with the REAL GameControllerV2 (not a mock). Proves the custody gate reads the
/// controller's money-power filter end to end: a money-power module runs the full deposit/credit/move/
/// withdraw cycle, and a powerless KEEPER — installed through the same real registry — is rejected at
/// every value path. The mock-only suite could not witness the isModule money-power scan.
contract GameLedgerControllerV2Test is Test {
    GameControllerV2 controller;
    GameLedger ledger;
    TestStock stk;

    address admin = address(0xA11CE);
    address module = address(0x510D); // wired to a money-power role
    address keeper = address(0xC0FFEE); // wired to KEEPER (powerless)
    address feeSink = address(0xFEE5);
    address player = address(0x1111);

    address constant VAULT_A = address(0xAA01); // SINGLE_PARTY
    address constant DEPLOYED = address(0xC001); // CONTESTED
    address constant HOPPER = address(0xC002); // CONTESTED

    function _specs() internal pure returns (GameControllerV2.RoleSpec[] memory s) {
        s = new GameControllerV2.RoleSpec[](3);
        s[0] = GameControllerV2.RoleSpec(GameRoles.MISSION_MODULE, true);
        s[1] = GameControllerV2.RoleSpec(GameRoles.RAID_MODULE, true);
        s[2] = GameControllerV2.RoleSpec(GameRoles.KEEPER, false);
    }

    function setUp() public {
        controller = new GameControllerV2(admin, _specs());
        vm.startPrank(admin);
        controller.setModule(GameRoles.MISSION_MODULE, module);
        controller.setModule(GameRoles.KEEPER, keeper);
        ledger = new GameLedger(IGameController(address(controller)), feeSink);
        stk = new TestStock();
        ledger.addToken(address(stk));
        vm.stopPrank();

        vm.startPrank(module);
        ledger.registerAccount(VAULT_A, GameLedger.Domain.SINGLE_PARTY);
        ledger.registerAccount(DEPLOYED, GameLedger.Domain.CONTESTED);
        ledger.registerAccount(HOPPER, GameLedger.Domain.CONTESTED);
        vm.stopPrank();
    }

    function _approve(address who, uint256 amt) internal {
        stk.mint(who, amt);
        vm.prank(who);
        stk.approve(address(ledger), amt);
    }

    // ---------------------------------------------------------------- interop (real controller answers)

    function test_realController_satisfiesLedgerInterface() public view {
        assertEq(address(ledger.controller()), address(controller));
        assertEq(ledger.controller().admin(), admin);
        assertTrue(controller.isModule(module)); // money-power role -> passes the custody gate
        assertFalse(controller.isModule(keeper)); // powerless role -> rejected by the same scan
    }

    // ---------------------------------------------------------------- full custody cycle (money module)

    /// A money-power module drives the whole value cycle through the real controller and every balance
    /// lands exactly; solvency holds after each step. fund seeds the surplus that credit draws.
    function test_moneyModule_fullCycle_depositCreditMoveWithdraw_balancesExact() public {
        _approve(player, 160e18);

        vm.startPrank(module);
        ledger.deposit(address(stk), player, DEPLOYED, 100e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), DEPLOYED), 100e18);
        assertTrue(ledger.isSolvent(address(stk)));

        ledger.fund(address(stk), player, 60e18);
        assertEq(ledger.surplusOf(address(stk)), 60e18);
        assertTrue(ledger.isSolvent(address(stk)));

        ledger.credit(address(stk), HOPPER, 60e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), HOPPER), 60e18);
        assertEq(ledger.surplusOf(address(stk)), 0);
        assertTrue(ledger.isSolvent(address(stk)));

        ledger.move(address(stk), DEPLOYED, HOPPER, 40e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), DEPLOYED), 60e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), HOPPER), 100e18);
        assertTrue(ledger.isSolvent(address(stk)));

        ledger.withdraw(address(stk), HOPPER, player, 50e18);
        vm.stopPrank();

        assertEq(stk.balanceOf(player), 50e18); // real tokens left custody to the player
        assertEq(ledger.effectiveBalanceOf(address(stk), HOPPER), 50e18);
        assertEq(ledger.effectiveTotalOf(address(stk)), 110e18); // 60 deployed + 50 hopper
        assertEq(stk.balanceOf(address(ledger)), 110e18); // real backing == effective total
        assertTrue(ledger.isSolvent(address(stk)));
    }

    // ---------------------------------------------------------------- the load-bearing security property

    /// A powerless KEEPER wired through the real controller passes NEITHER onlyModule gate: EVERY value
    /// path reverts with the exact NotModule selector. This is the property the mock could not prove — a
    /// role can hold the KEEPER slot and still be excluded from custody by the money-power scan.
    function test_keeper_rejectedAtEveryValuePath_onlyModuleReverts() public {
        _approve(keeper, 1e18);
        vm.startPrank(keeper);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.registerAccount(address(0x9999), GameLedger.Domain.CONTESTED);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.deposit(address(stk), keeper, VAULT_A, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.fund(address(stk), keeper, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.withdraw(address(stk), VAULT_A, keeper, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.collectFee(address(stk), VAULT_A, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.move(address(stk), DEPLOYED, HOPPER, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.cross(address(stk), VAULT_A, DEPLOYED, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.credit(address(stk), HOPPER, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.debit(address(stk), HOPPER, 1e18);
        vm.stopPrank();
    }

    /// admin() is not a module: holding the controller's admin key confers zero custody power. Every
    /// value path reverts NotModule when called by admin, so admin can never move a player's tokens.
    function test_admin_notAModule_valueFunctionsRevertNotModule() public {
        _approve(admin, 1e18);
        vm.startPrank(admin);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.deposit(address(stk), admin, VAULT_A, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.fund(address(stk), admin, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.withdraw(address(stk), VAULT_A, admin, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.collectFee(address(stk), VAULT_A, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.move(address(stk), DEPLOYED, HOPPER, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.cross(address(stk), VAULT_A, DEPLOYED, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.credit(address(stk), HOPPER, 1e18);
        vm.expectRevert(GameLedger.NotModule.selector);
        ledger.debit(address(stk), HOPPER, 1e18);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- real seal + timelock installation

    /// A money module installed through the REAL seal -> queue -> 2-day timelock -> execute flow holds
    /// custody power and runs a deposit/withdraw cycle solvently. Pins that the timelocked re-point path
    /// (not just pre-seal setModule) produces a working custodian.
    function test_timelockInstalledMoneyModule_runsCustodyCycle() public {
        address newMod = address(0xBEEF);
        vm.startPrank(admin);
        controller.seal();
        controller.queueModule(GameRoles.RAID_MODULE, newMod);
        vm.warp(block.timestamp + controller.TIMELOCK());
        controller.executeModule(GameRoles.RAID_MODULE);
        vm.stopPrank();

        assertTrue(controller.isModule(newMod));

        _approve(player, 100e18);
        vm.startPrank(newMod);
        ledger.registerAccount(DEPLOYED, GameLedger.Domain.CONTESTED); // idempotent: same domain
        ledger.deposit(address(stk), player, DEPLOYED, 100e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), DEPLOYED), 100e18);
        assertTrue(ledger.isSolvent(address(stk)));
        ledger.withdraw(address(stk), DEPLOYED, player, 100e18);
        vm.stopPrank();

        assertEq(stk.balanceOf(player), 100e18);
        assertEq(ledger.effectiveBalanceOf(address(stk), DEPLOYED), 0);
        assertTrue(ledger.isSolvent(address(stk)));
    }
}
