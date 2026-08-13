// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {GameBase} from "./GameBase.t.sol";
import {HouseDeed} from "../src/game/HouseDeed.sol";
import {HouseEscrow} from "../src/game/HouseEscrow.sol";

contract GameHouseTest is GameBase {
    /// First play (any depart) auto-claims the free Safehouse into the Don's vault + the stipend.
    function _firstPlay(uint256 pk, uint256 donId) internal {
        uint64 m = _depart(pk, donId, PAPER_ROUTE, 0, bytes32(0));
        _resolveWith(m, 999_999); // FAIL band — house/stipend setup is what we're after
    }

    // ---------------------------------------------------------------- deed

    function test_Safehouse_AutoClaimedAtFirstPlay() public {
        assertEq(deed.deedOf(aliceDon), 0);
        _firstPlay(alicePk, aliceDon);
        uint256 deedId = deed.deedOf(aliceDon);
        assertGt(deedId, 0);
        assertEq(deed.ownerOf(deedId), don.vaultOf(aliceDon)); // minted INTO the 6551
        assertEq(deed.tierOf(aliceDon), 0);
        assertEq(deed.deployCapOf(aliceDon), 5_000e18); // A6: $50 flat at the peg
        assertEq(deed.defenseOf(aliceDon), 40);
        assertEq(deed.garrisonSlotsOf(aliceDon), 2);
    }

    function test_Stipend_PaidOnceEver() public {
        _firstPlay(alicePk, aliceDon);
        // stipend 50 minus the 0.45 dispatch fee
        assertEq(scrip.balanceOf(don.vaultOf(aliceDon)), 50e18 - 0.45e18);
        uint256 budgetAfter = escrow.stipendBudget();
        _firstPlay(alicePk, aliceDon); // second mission: no second stipend
        assertEq(escrow.stipendBudget(), budgetAfter);
    }

    function test_Upgrade_RowHouse_FeeBurnsAndCapRises() public {
        _firstPlay(alicePk, aliceDon);
        _grantScrip(don.vaultOf(aliceDon), 2_000e18);
        uint256 supply = scrip.totalSupply();
        vm.prank(alice);
        deed.upgrade(aliceDon);
        assertEq(deed.tierOf(aliceDon), 1);
        assertEq(deed.deployCapOf(aliceDon), 15_000e18); // B4: $150 cap
        assertEq(deed.defenseOf(aliceDon), 60);
        assertEq(deed.garrisonSlotsOf(aliceDon), 3);
        assertEq(scrip.totalSupply(), supply - 1_500e18); // $15 fee, burned
    }

    function test_Upgrade_OnlyOwner_AndNotWhileAway() public {
        _firstPlay(alicePk, aliceDon);
        _grantScrip(don.vaultOf(aliceDon), 2_000e18);
        vm.prank(bob);
        vm.expectRevert(HouseDeed.NotDonOwner.selector);
        deed.upgrade(aliceDon);

        _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(HouseDeed.DonIsAway.selector); // House can't change shape mid-window
        deed.upgrade(aliceDon);
    }

    function test_Upgrade_AtMaxTierReverts() public {
        _firstPlay(alicePk, aliceDon);
        _grantScrip(don.vaultOf(aliceDon), 4_000e18);
        vm.startPrank(alice);
        deed.upgrade(aliceDon);
        vm.expectRevert(HouseDeed.AtMaxTier.selector);
        deed.upgrade(aliceDon);
        vm.stopPrank();
    }

    function test_Deed_SoulboundInPhase0() public {
        _firstPlay(alicePk, aliceDon);
        uint256 deedId = deed.deedOf(aliceDon);
        address vault = don.vaultOf(aliceDon);
        vm.prank(vault);
        vm.expectRevert(HouseDeed.SoulboundInPhase0.selector);
        deed.transferFrom(vault, bob, deedId);
    }

    function test_Safehouse_OnlyHouseModuleMints() public {
        vm.expectRevert(HouseDeed.NotHouseModule.selector);
        deed.mintSafehouse(aliceDon);
    }

    // ---------------------------------------------------------------- escrow: deploy / bank

    function test_DeployAndBank_Roundtrip_CustodyInvariant() public {
        _firstPlay(alicePk, aliceDon);
        address vault = don.vaultOf(aliceDon);
        _grantScrip(vault, 4_000e18);
        uint256 vaultBefore = scrip.balanceOf(vault);

        vm.prank(alice);
        escrow.deploy(aliceDon, 3_000e18);
        assertEq(escrow.deployedOf(aliceDon), 3_000e18);
        // The custody invariant: escrow's Scrip balance == Σ deployed + hopper.
        assertEq(scrip.balanceOf(address(escrow)), escrow.totalDeployed() + escrow.totalHopper());

        vm.prank(alice);
        escrow.bank(aliceDon, 3_000e18, 0);
        assertEq(escrow.deployedOf(aliceDon), 0);
        assertEq(scrip.balanceOf(vault), vaultBefore); // everything came home, zero fee
        assertEq(scrip.balanceOf(address(escrow)), escrow.totalDeployed() + escrow.totalHopper());
    }

    function test_Deploy_CapEnforced() public {
        _firstPlay(alicePk, aliceDon);
        _grantScrip(don.vaultOf(aliceDon), 10_000e18);
        vm.prank(alice);
        vm.expectRevert(HouseEscrow.OverDeployCap.selector);
        escrow.deploy(aliceDon, 5_001e18); // Safehouse cap is 5,000
    }

    function test_Deploy_RequiresHouse() public {
        _grantScrip(don.vaultOf(aliceDon), 100e18);
        vm.prank(alice);
        vm.expectRevert(HouseEscrow.OverDeployCap.selector); // no deed => cap 0
        escrow.deploy(aliceDon, 1e18);
    }

    function test_DeployAndBank_BlockedWhileAway() public {
        _firstPlay(alicePk, aliceDon);
        _grantScrip(don.vaultOf(aliceDon), 1_000e18);
        vm.prank(alice);
        escrow.deploy(aliceDon, 500e18);
        _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        vm.startPrank(alice);
        vm.expectRevert(HouseEscrow.DonIsAway.selector);
        escrow.deploy(aliceDon, 100e18);
        vm.expectRevert(HouseEscrow.DonIsAway.selector); // exposure holds for the window...
        escrow.bank(aliceDon, 500e18, 0);
        vm.stopPrank();
    }

    /// THE EXITS LAW: bank works with the generation closed, the House damaged, budgets drained —
    /// as long as the Don is home, the money comes home. And reclaim guarantees "home" is always
    /// reachable, so no keeper can stall an exit forever.
    function test_Bank_NeverGated() public {
        _firstPlay(alicePk, aliceDon);
        _grantScrip(don.vaultOf(aliceDon), 1_000e18);
        vm.prank(alice);
        escrow.deploy(aliceDon, 1_000e18);

        // Depart, keeper dies, generation closes mid-mission.
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        controller.close();
        vm.warp(block.timestamp + 3 hours + 3 hours); // due + grace
        board.reclaim(m); // permissionless — brings the Don home with the Partial floor

        // Everything in the hopper, including the yield the bank-tx checkpoint will realize.
        uint256 hopperNow = escrow.hopperOf(aliceDon) + escrow.pendingYieldOf(aliceDon);
        vm.prank(alice);
        escrow.bank(aliceDon, 1_000e18, hopperNow); // banks fine after close()
        assertEq(escrow.deployedOf(aliceDon), 0);
        assertEq(escrow.hopperOf(aliceDon), 0);
    }

    function test_Deploy_BlockedAfterClose() public {
        _firstPlay(alicePk, aliceDon);
        _grantScrip(don.vaultOf(aliceDon), 1_000e18);
        controller.close();
        vm.prank(alice);
        vm.expectRevert(HouseEscrow.GenerationClosed.selector); // no NEW exposure
        escrow.deploy(aliceDon, 100e18);
    }

    // ---------------------------------------------------------------- yield accrual (Bell pattern)

    function test_Yield_AccruesAt15BpsPerDay() public {
        _firstPlay(alicePk, aliceDon);
        _grantScrip(don.vaultOf(aliceDon), 4_000e18);
        vm.prank(alice);
        escrow.deploy(aliceDon, 4_000e18);

        vm.warp(block.timestamp + 1 days);
        // 15 bps/day on 4,000 = 6 Scrip
        assertApproxEqAbs(escrow.pendingYieldOf(aliceDon), 6e18, 1e12);

        // Banking realizes yield into the hopper first, then moves it home.
        uint256 vaultBefore = scrip.balanceOf(don.vaultOf(aliceDon));
        vm.prank(alice);
        escrow.bank(aliceDon, 0, 6e18);
        assertApproxEqAbs(scrip.balanceOf(don.vaultOf(aliceDon)) - vaultBefore, 6e18, 1e12);
    }

    function test_Yield_BudgetValve_StopsWhenDry() public {
        _firstPlay(alicePk, aliceDon);
        _grantScrip(don.vaultOf(aliceDon), 4_000e18);
        vm.prank(alice);
        escrow.deploy(aliceDon, 4_000e18);

        // Drain the yield budget down to almost nothing by replacing it: deploy a fresh escrow?
        // Simpler: warp far enough that demand exceeds the funded budget and check the clamp.
        // Budget 500k, rate 6/day => plenty; so instead verify the clamp math with a tiny budget:
        // accrue everything, then close the valve by exhausting via an enormous warp.
        vm.warp(block.timestamp + 200_000 days); // way past what 500k Scrip can fund
        uint256 pending = escrow.pendingYieldOf(aliceDon);
        assertLe(pending, 500_000e18); // never exceeds the funded line — refuse, don't dilute
        vm.prank(alice);
        escrow.bank(aliceDon, 0, 0); // checkpoint (mints pending) — must not revert
        assertEq(escrow.yieldBudget(), 500_000e18 - escrow.hopperOf(aliceDon));
    }

    function test_Yield_TwoHouses_ProRata() public {
        _firstPlay(alicePk, aliceDon);
        _firstPlay(bobPk, bobDon);
        _grantScrip(don.vaultOf(aliceDon), 3_000e18);
        _grantScrip(don.vaultOf(bobDon), 1_000e18);
        vm.prank(alice);
        escrow.deploy(aliceDon, 3_000e18);
        vm.prank(bob);
        escrow.deploy(bobDon, 1_000e18);

        vm.warp(block.timestamp + 1 days);
        uint256 a = escrow.pendingYieldOf(aliceDon);
        uint256 b = escrow.pendingYieldOf(bobDon);
        assertApproxEqAbs(a, 3 * b, 1e12); // pro-rata by deployed weight
    }

    // ---------------------------------------------------------------- damage & repair

    function _damageAlice() internal {
        _firstPlay(alicePk, aliceDon);
        _grantScrip(don.vaultOf(aliceDon), 4_000e18);
        vm.prank(alice);
        escrow.deploy(aliceDon, 4_000e18);
        vm.prank(address(raid));
        escrow.applyDamage(aliceDon);
    }

    function test_Damage_DebuffsEarning40pct() public {
        _damageAlice();
        vm.warp(block.timestamp + 1 days);
        // 6/day gross x 0.6 = 3.6
        assertApproxEqAbs(escrow.pendingYieldOf(aliceDon), 3.6e18, 1e12);
    }

    function test_Repair_FeeMathAndClear() public {
        _damageAlice();
        // fee = 1.5 x dailyGross (6) x damage/4000 = 9 Scrip
        assertEq(escrow.repairFeeOf(aliceDon), 9e18);
        _grantScrip(don.vaultOf(aliceDon), 20e18);
        uint256 supply = scrip.totalSupply();
        vm.prank(alice);
        escrow.repair(aliceDon);
        assertEq(scrip.totalSupply(), supply - 9e18); // burned — the sink
        assertEq(escrow.damageBps(aliceDon), 0);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(escrow.pendingYieldOf(aliceDon), 6e18, 1e12); // back to full rate
    }

    function test_Repair_NothingToRepairReverts() public {
        _firstPlay(alicePk, aliceDon);
        vm.prank(alice);
        vm.expectRevert(HouseEscrow.NotDamaged.selector);
        escrow.repair(aliceDon);
    }

    // ---------------------------------------------------------------- module gates

    function test_ModulePowers_Gated() public {
        vm.expectRevert(HouseEscrow.NotMissionModule.selector);
        escrow.creditLoot(aliceDon, 1e18);
        vm.expectRevert(HouseEscrow.NotRaidModule.selector);
        escrow.applyRaidCommon(aliceDon, bob);
        vm.expectRevert(HouseEscrow.NotRaidModule.selector);
        escrow.applyRaidBig(aliceDon, bob, 1_500);
        vm.expectRevert(HouseEscrow.NotRaidModule.selector);
        escrow.applyDamage(aliceDon);
        vm.expectRevert(HouseEscrow.NotAdmin.selector);
        vm.prank(alice);
        escrow.fundYieldBudget(1);
    }

    function test_BigSlice_HardCap30pct() public {
        vm.prank(address(raid));
        vm.expectRevert(HouseEscrow.BadConfig.selector);
        escrow.applyRaidBig(aliceDon, bob, 3_001);
    }

    /// F3 fix (fund-safety lens): the repair fee is frozen off deployed-at-damage-time. A damaged Don
    /// can no longer bank its deployed to 0 to zero the fee, repair for free, then redeploy at full
    /// weight — the "steadiest sink in the game" is no longer dodgeable at will.
    function test_RepairFee_NotDodgeableByBanking() public {
        _firstPlay(bobPk, bobDon); // free Safehouse, bob home
        _grantScrip(don.vaultOf(bobDon), 2_000e18);
        vm.prank(bob);
        escrow.deploy(bobDon, 1_000e18);

        // Damage lands with 1000 deployed -> the repair-fee basis freezes at 1000.
        vm.prank(address(raid));
        escrow.applyDamage(bobDon);
        assertEq(escrow.damageBps(bobDon), 4_000);
        assertEq(escrow.damageBaseDeployed(bobDon), 1_000e18);
        uint256 feeFrozen = escrow.repairFeeOf(bobDon);
        assertGt(feeFrozen, 0);

        // The old dodge: bank ALL deployed to 0 before repairing.
        vm.prank(bob);
        escrow.bank(bobDon, 1_000e18, 0);
        assertEq(escrow.deployedOf(bobDon), 0);

        // The fee is UNCHANGED — banking did not shrink it (pre-fix repairFeeOf would now be 0).
        assertEq(escrow.repairFeeOf(bobDon), feeFrozen);
        assertGt(escrow.repairFeeOf(bobDon), 0);
    }
}
