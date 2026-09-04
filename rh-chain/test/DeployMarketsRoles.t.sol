// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployMarkets} from "../script/DeployMarkets.s.sol";

contract RolesHarness is DeployMarkets {
    function check(bool testnet, Roles memory r) external view returns (Roles memory) {
        return _checkRoles(testnet, r);
    }
}

/// G-LEND MED-2. The deploy script used to warn about a single-key posture with a `console.log` and
/// broadcast anyway. `EsseyMarkets.guardian` and `EsseyPool.reserveTreasury` are immutable, so that
/// posture shipped once was shipped forever, and one compromised deploy key was simultaneously
/// market admin, market guardian, liveness keeper, liveness guardian, depth keeper, health admin
/// and the reserve treasury. The separation has to be a revert, not a log line.
///
/// The rule is exercised through `_checkRoles` rather than through `vm.setEnv`: the process
/// environment is global and forge runs test cases concurrently, so an env-driven fixture here
/// races every other suite. The env NAMES are wired one layer up in `_roles`; a typo there fails
/// the mainnet deploy closed, on the very requires below.
contract DeployMarketsRolesTest is Test {
    RolesHarness h;

    /// `_roleKey` compares against `msg.sender`, and the harness's caller is this test — so this
    /// contract stands in for the deploy key.
    function setUp() public {
        h = new RolesHarness();
    }

    function _split() internal pure returns (DeployMarkets.Roles memory) {
        return DeployMarkets.Roles({
            guardian: address(0xA0),
            livenessKeeper: address(0xA1),
            livenessGuardian: address(0xA2),
            depthKeeper: address(0xA3),
            reserveTreasury: address(0xA4)
        });
    }

    /// Index the five fields positionally, so "each role" below means each role and not the first
    /// one five times.
    function _withRole(uint256 i, address a) internal pure returns (DeployMarkets.Roles memory r) {
        r = _split();
        if (i == 0) r.guardian = a;
        else if (i == 1) r.livenessKeeper = a;
        else if (i == 2) r.livenessGuardian = a;
        else if (i == 3) r.depthKeeper = a;
        else r.reserveTreasury = a;
    }

    string[5] NAMES = ["GUARDIAN", "LIVENESS_KEEPER", "LIVENESS_GUARDIAN", "DEPTH_KEEPER", "RESERVE_TREASURY"];

    function test_aFullySplitMainnetConfigIsAccepted() public view {
        DeployMarkets.Roles memory r = h.check(false, _split());
        assertEq(r.guardian, address(0xA0));
        assertEq(r.livenessKeeper, address(0xA1));
        assertEq(r.livenessGuardian, address(0xA2));
        assertEq(r.depthKeeper, address(0xA3));
        assertEq(r.reserveTreasury, address(0xA4));
    }

    /// Each role, one at a time — an "all five are required" check that only ever exercised the
    /// first would pass with the other four dropped.
    function test_everyMainnetRoleIsRequired() public {
        for (uint256 i; i < NAMES.length; i++) {
            vm.expectRevert(bytes(string.concat(NAMES[i], " is required on mainnet - refusing to deploy")));
            h.check(false, _withRole(i, address(0)));
        }
    }

    /// Present-but-shared is the posture that actually shipped, and it must be refused just as hard
    /// as absent.
    function test_noMainnetRoleMayBeTheDeployKey() public {
        for (uint256 i; i < NAMES.length; i++) {
            vm.expectRevert(bytes(string.concat(NAMES[i], " must not be the deploy key - refusing to deploy")));
            h.check(false, _withRole(i, address(this)));
        }
    }

    /// The liveness guardian's only power is rotating the liveness keeper. Held by the same address,
    /// that rotation is not a recovery path from anything.
    function test_theLivenessKeeperMayNotBeItsOwnGuardian() public {
        vm.expectRevert(bytes("LIVENESS_KEEPER must not be its own guardian - refusing to deploy"));
        h.check(false, _withRole(2, address(0xA1))); // livenessGuardian == livenessKeeper
    }

    /// Testnet keeps working single-key: the friction is bought for mainnet, not for a throwaway.
    function test_testnetFallsBackToTheDeployKey() public view {
        DeployMarkets.Roles memory empty;
        DeployMarkets.Roles memory r = h.check(true, empty);
        assertEq(r.guardian, address(this), "this test contract is the deploy key");
        assertEq(r.livenessKeeper, address(this));
        assertEq(r.livenessGuardian, address(this));
        assertEq(r.depthKeeper, address(this));
        assertEq(r.reserveTreasury, address(this));
    }
}
