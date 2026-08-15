// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAffinityRegistry, IDonTraits} from "../src/game/IAffinityRegistry.sol";
import {AffinityRegistry} from "../src/game/AffinityRegistry.sol";
import {AffinityTraits} from "../src/game/AffinityTraits.sol";
import {GameBase} from "./GameBase.t.sol";
import {MissionBoard} from "../src/game/MissionBoard.sol";
import {IEntropy} from "../src/market/EsseyCasesDegen.sol";
import {
    IDonLike, IGameController, IScrip, IHouseEscrow, GameRoles
} from "../src/game/GameTypes.sol";

contract GameMissionBoardTest is GameBase {
    function _fund(uint256 donId, uint256 amount) internal {
        _grantScrip(don.vaultOf(donId), amount);
    }

    // ---------------------------------------------------------------- briefs

    function test_PostBrief_AdminOnly_AndImmutableRows() public {
        vm.prank(alice);
        vm.expectRevert(MissionBoard.NotAdmin.selector);
        board.postBrief("X", 1, 1 hours, 500_000, 900_000, 10e18, 4e18, 0.1e18, 5e18, 10_000);
        // There is no edit/retire surface at all — the 4 seeded rows are permanent.
        assertEq(board.briefCount(), 4);
    }

    function test_PostBrief_LadderValidation() public {
        // Degen BadConfig battery, mission flavor: bands must strictly increase inside PPM…
        vm.expectRevert(MissionBoard.BadBrief.selector);
        board.postBrief("X", 1, 1 hours, 0, 900_000, 10e18, 4e18, 0, 0, 0); // zero success band
        vm.expectRevert(MissionBoard.BadBrief.selector);
        board.postBrief("X", 1, 1 hours, 900_000, 900_000, 10e18, 4e18, 0, 0, 0); // not increasing
        vm.expectRevert(MissionBoard.BadBrief.selector);
        board.postBrief("X", 1, 1 hours, 500_000, 1_000_001, 10e18, 4e18, 0, 0, 0); // past PPM
        // …and the floor must be a real but strictly-worse payout (reclaim can't beat a roll).
        vm.expectRevert(MissionBoard.BadBrief.selector);
        board.postBrief("X", 1, 1 hours, 500_000, 900_000, 10e18, 0, 0, 0, 0); // zero floor
        vm.expectRevert(MissionBoard.BadBrief.selector);
        board.postBrief("X", 1, 1 hours, 500_000, 900_000, 10e18, 10e18, 0, 0, 0); // floor == success
    }

    // ---------------------------------------------------------------- depart

    function test_Depart_ChargesFeeAndReserves() public {
        _fund(aliceDon, 100e18);
        uint256 budgetBefore = board.missionBudget();
        uint256 supplyBefore = scrip.totalSupply();

        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 10e18, bytes32("g"));
        assertTrue(board.isAway(aliceDon));
        assertEq(board.garrisonHashOf(aliceDon), bytes32("g"));

        // Fee (0.45) + provision (10) burned, net of the 50 first-play stipend mint.
        assertEq(scrip.totalSupply(), supplyBefore + 50e18 - 0.45e18 - 10e18);
        // Worst case reserved: 36 + 10 x 1.1538 = 47.538.
        uint256 worst = 36e18 + (10e18 * 11_538) / 10_000;
        assertEq(board.missionBudget(), budgetBefore - worst);
        assertEq(board.outstandingReserved(), worst);
        (,,,,,, uint256 reserved,,) = board.missions(m);
        assertEq(reserved, worst);
    }

    function test_Depart_WhileAwayReverts() public {
        _fund(aliceDon, 100e18);
        _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        MissionBoard.Loadout memory l = _loadout(aliceDon, PAPER_ROUTE, 0, bytes32(0));
        bytes memory sig = _sign(alicePk, l);
        vm.prank(alice);
        vm.expectRevert(MissionBoard.AlreadyAway.selector);
        board.depart(l, sig);
    }

    function test_Depart_OverProvisionCap() public {
        _fund(aliceDon, 100e18);
        MissionBoard.Loadout memory l = _loadout(aliceDon, PAPER_ROUTE, 15e18 + 1, bytes32(0));
        bytes memory sig = _sign(alicePk, l);
        vm.prank(alice);
        vm.expectRevert(MissionBoard.OverProvisionCap.selector);
        board.depart(l, sig);
    }

    function test_Depart_ClosedGeneration() public {
        _fund(aliceDon, 100e18);
        controller.close();
        MissionBoard.Loadout memory l = _loadout(aliceDon, PAPER_ROUTE, 0, bytes32(0));
        bytes memory sig = _sign(alicePk, l);
        vm.prank(alice);
        vm.expectRevert(MissionBoard.GenerationClosed.selector);
        board.depart(l, sig);
    }

    /// The reservation law: a depart the budget can't cover in the worst case must revert.
    function test_Depart_InsufficientBudgetReverts() public {
        // Fresh board with an empty budget, re-pointed as the MISSION module (unsealed controller).
        MissionBoard poor = new MissionBoard(
            IGameController(address(controller)),
            IScrip(address(scrip)),
            IDonLike(address(don)),
            IHouseEscrow(address(escrow)),
            IEntropy(address(oracle)),
            address(0xDACE),
            200_000
        ,
            IAffinityRegistry(address(0))
        );
        poor.postBrief("PAPER ROUTE", 1, 3 hours, 780_000, 930_000, 36e18, 14.4e18, 0.45e18, 15e18, 11_538);
        controller.setModule(GameRoles.MISSION_MODULE, address(poor));
        _grantScripVia(address(poor), don.vaultOf(aliceDon), 100e18);

        MissionBoard.Loadout memory l = MissionBoard.Loadout({
            donId: aliceDon,
            briefId: 1,
            provision: 0,
            garrisonHash: bytes32(0),
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
        bytes32 structHash = keccak256(
            abi.encode(poor.LOADOUT_TYPEHASH(), l.donId, l.briefId, l.provision, l.garrisonHash, l.nonce, l.deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", poor.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        vm.prank(alice);
        vm.expectRevert(MissionBoard.InsufficientBudget.selector);
        poor.depart(l, abi.encodePacked(r, s, v));
    }

    function _grantScripVia(address module_, address to, uint256 amount) internal {
        vm.prank(module_);
        scrip.mint(to, amount);
    }

    // ---------------------------------------------------------------- the EIP-712 loadout

    function test_Loadout_WrongSignerRejected() public {
        _fund(aliceDon, 100e18);
        MissionBoard.Loadout memory l = _loadout(aliceDon, PAPER_ROUTE, 0, bytes32(0));
        bytes memory sig = _sign(bobPk, l); // bob signs alice's Don
        vm.prank(bob);
        vm.expectRevert(MissionBoard.NotOwnerSignature.selector);
        board.depart(l, sig);
    }

    function test_Loadout_ExpiredDeadline() public {
        _fund(aliceDon, 100e18);
        MissionBoard.Loadout memory l = _loadout(aliceDon, PAPER_ROUTE, 0, bytes32(0));
        l.deadline = block.timestamp - 1;
        bytes memory sig = _sign(alicePk, l);
        vm.prank(alice);
        vm.expectRevert(MissionBoard.LoadoutExpired.selector);
        board.depart(l, sig);
    }

    function test_Loadout_NonceMonotonic() public {
        _fund(aliceDon, 200e18);
        MissionBoard.Loadout memory l = _loadout(aliceDon, PAPER_ROUTE, 0, bytes32(0));
        bytes memory sig = _sign(alicePk, l);
        vm.prank(alice);
        board.depart(l, sig);
        // Bring the Don home, then try replaying the very same signed loadout.
        vm.warp(block.timestamp + 3 hours);
        vm.prank(keeper);
        board.resolve{value: ENTROPY_FEE}(1);
        oracle.fulfill(oracle.lastSeq(), bytes32(0));
        vm.prank(alice);
        vm.expectRevert(MissionBoard.StaleNonce.selector);
        board.depart(l, sig); // replay dies on the per-token nonce
    }

    /// Transfer kills the seller's signatures with zero epoch bookkeeping: the settle-time check is
    /// against the CURRENT owner.
    function test_Loadout_OldOwnerSigDiesOnTransfer() public {
        _fund(aliceDon, 100e18);
        MissionBoard.Loadout memory l = _loadout(aliceDon, PAPER_ROUTE, 0, bytes32(0));
        bytes memory sig = _sign(alicePk, l);
        don.transfer(aliceDon, bob); // sold
        vm.prank(alice);
        vm.expectRevert(MissionBoard.NotOwnerSignature.selector);
        board.depart(l, sig);
    }

    /// A relayer may SUBMIT a signed loadout — the signature, not the sender, is the authority
    /// (session-key rail, the gas law) — and it can only execute exactly what was signed.
    function test_Loadout_RelayableButBindsTerms() public {
        _fund(aliceDon, 100e18);
        MissionBoard.Loadout memory l = _loadout(aliceDon, PAPER_ROUTE, 5e18, bytes32("g"));
        bytes memory sig = _sign(alicePk, l);
        // Relay tampers with the provision => digest changes => not the owner's signature.
        // (Rebuilt field-by-field: memory-struct assignment aliases, it doesn't copy.)
        MissionBoard.Loadout memory tampered = MissionBoard.Loadout({
            donId: l.donId,
            briefId: l.briefId,
            provision: 15e18,
            garrisonHash: l.garrisonHash,
            nonce: l.nonce,
            deadline: l.deadline
        });
        vm.prank(bob);
        vm.expectRevert(MissionBoard.NotOwnerSignature.selector);
        board.depart(tampered, sig);
        // Untampered relay goes through.
        vm.prank(bob);
        board.depart(l, sig);
        assertTrue(board.isAway(aliceDon));
    }

    // ---------------------------------------------------------------- resolve

    function test_Resolve_NotBeforeDue() public {
        _fund(aliceDon, 100e18);
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        vm.expectRevert(MissionBoard.NotDue.selector);
        board.resolve{value: ENTROPY_FEE}(m);
    }

    function test_Resolve_SuccessPaysWageAndProvisionBoost() public {
        _fund(aliceDon, 100e18);
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 15e18, bytes32(0));
        uint256 budgetAfterDepart = board.missionBudget();
        _resolveWith(m, 0); // roll 0 < 780000 => SUCCESS
        // payout = 36 + 15 x 1.1538 = 53.307
        uint256 expected = 36e18 + (15e18 * 11_538) / 10_000;
        assertEq(escrow.hopperOf(aliceDon), expected);
        assertFalse(board.isAway(aliceDon)); // home
        // Reservation released exactly: worst == success payout here.
        assertEq(board.missionBudget(), budgetAfterDepart);
        assertEq(board.outstandingReserved(), 0);
        // Custody invariant: the payout physically sits at the escrow.
        assertEq(scrip.balanceOf(address(escrow)), escrow.totalDeployed() + escrow.totalHopper());
    }

    function test_Resolve_PartialPaysFloor() public {
        _fund(aliceDon, 100e18);
        uint256 budget0 = board.missionBudget();
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        _resolveWith(m, 800_000); // 780000 <= roll < 930000 => PARTIAL
        assertEq(escrow.hopperOf(aliceDon), 14.4e18);
        // Unspent reservation returned: budget only down by the actual payout.
        assertEq(board.missionBudget(), budget0 - 14.4e18);
    }

    function test_Resolve_FailPaysNothing_ProvisionAlreadyGone() public {
        _fund(aliceDon, 100e18);
        uint256 budget0 = board.missionBudget();
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 15e18, bytes32(0));
        _resolveWith(m, 999_999); // FAIL
        assertEq(escrow.hopperOf(aliceDon), 0);
        assertEq(board.missionBudget(), budget0); // full reservation returned
        assertEq(board.outstandingReserved(), 0);
    }

    function test_Resolve_T4LotteryShape() public {
        _fund(aliceDon, 300e18);
        uint64 m = _depart(alicePk, aliceDon, ABSOLUTE_ZERO, 200e18, bytes32(0));
        _resolveWith(m, 100_000); // < 120000 => JACKPOT
        // 2,775 + 200 x 7.5 = 4,275 — the long-con jackpot with full provision boost.
        assertEq(escrow.hopperOf(aliceDon), 2_775e18 + 1_500e18);
    }

    function test_Resolve_DoubleRequestReverts() public {
        _fund(aliceDon, 100e18);
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        vm.warp(block.timestamp + 3 hours);
        board.resolve{value: ENTROPY_FEE}(m);
        vm.expectRevert(MissionBoard.AlreadyRequested.selector);
        board.resolve{value: ENTROPY_FEE}(m);
    }

    function test_Resolve_RefundsExcessFee() public {
        _fund(aliceDon, 100e18);
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        vm.warp(block.timestamp + 3 hours);
        uint256 balBefore = keeper.balance;
        vm.prank(keeper);
        board.resolve{value: 1 ether}(m);
        assertEq(balBefore - keeper.balance, ENTROPY_FEE); // Degen refund pattern
    }

    // ---------------------------------------------------------------- reclaim (the floor valve)

    function test_Reclaim_FloorsAtPartial_AndUnlocks() public {
        _fund(aliceDon, 100e18);
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 15e18, bytes32(0));
        vm.warp(block.timestamp + 3 hours + 2 hours); // due + grace
        vm.prank(bob); // ANYONE — permissionless liveness
        board.reclaim(m);
        assertEq(escrow.hopperOf(aliceDon), 14.4e18); // the Partial floor: never zero…
        assertLt(uint256(14.4e18), uint256(36e18)); // …never better than a real success
        assertFalse(board.isAway(aliceDon));
        assertEq(board.outstandingReserved(), 0); // drains to zero — the retire discipline
    }

    function test_Reclaim_NotBeforeGrace() public {
        _fund(aliceDon, 100e18);
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        vm.warp(block.timestamp + 3 hours + 1 hours);
        vm.expectRevert(MissionBoard.NotYetReclaimable.selector);
        board.reclaim(m);
    }

    function test_Reclaim_BeatsWithheldCallback() public {
        _fund(aliceDon, 100e18);
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        vm.warp(block.timestamp + 3 hours);
        board.resolve{value: ENTROPY_FEE}(m);
        uint64 seq = oracle.lastSeq();
        // Keeper withholds; after the grace anyone floors it…
        vm.warp(block.timestamp + 2 hours);
        board.reclaim(m);
        // …and the late reveal can no longer change the outcome.
        vm.expectRevert(MissionBoard.AlreadySettledMission.selector);
        oracle.fulfill(seq, bytes32(0));
    }

    // ---------------------------------------------------------------- the kit (keeper-attested)

    function test_Kit_KeeperAttests_LatchesForever() public {
        _fund(aliceDon, 100e18);
        _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        vm.prank(keeper);
        board.attestKit(aliceDon, 3);
        assertTrue(board.kitClaimed(aliceDon));
        assertEq(board.kitClassOf(aliceDon), 3);
        // One kit per Don, EVER — no re-attest, no revoke.
        vm.prank(keeper);
        vm.expectRevert(MissionBoard.KitAlreadyClaimed.selector);
        board.attestKit(aliceDon, 1);
    }

    function test_Kit_KeeperOnly_AndRequiresFirstDispatch() public {
        vm.prank(keeper);
        vm.expectRevert(MissionBoard.NeverDispatched.selector);
        board.attestKit(aliceDon, 1); // never played
        _fund(aliceDon, 100e18);
        _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(MissionBoard.NotKeeper.selector);
        board.attestKit(aliceDon, 1);
    }

    // ---------------------------------------------------------------- fuzz: the reservation law

    /// For ANY provision and ANY roll, the settled payout never exceeds what was reserved, and the
    /// budget accounting closes exactly (reserved - payout returns).
    function testFuzz_PayoutNeverExceedsReservation(uint256 provision, uint256 word) public {
        provision = bound(provision, 0, 200e18); // T4 cap
        _fund(aliceDon, 300e18);
        uint256 budget0 = board.missionBudget();
        uint64 m = _depart(alicePk, aliceDon, ABSOLUTE_ZERO, provision, bytes32(0));
        uint256 reserved = board.outstandingReserved();
        _resolveWith(m, word);
        uint256 payout = escrow.hopperOf(aliceDon);
        assertLe(payout, reserved);
        assertEq(board.outstandingReserved(), 0);
        assertEq(board.missionBudget(), budget0 - payout);
    }

    // ================================================================== NRV shifts real outcomes

    /// Attest `aliceDon` to a Windsor sheet — 5 Suit/Windsor grants 2 sp NRV, i.e. +2pp success.
    function _attestWindsor(uint256 donId) internal returns (uint256 nrvBps) {
        bytes memory pre = bytes("male\n5 Suit/Windsor");
        don.setTraits(donId, AffinityTraits.commitmentOf(pre));
        affinity.attest(donId, pre);
        nrvBps = uint256(affinity.statsOf(donId).nrvBps);
    }

    /// The claim: a roll that lands in PARTIAL on the published ladder lands in SUCCESS once the
    /// Don's NRV widens the band. PAPER ROUTE publishes success < 780000; +2pp moves it to 800000,
    /// so 790000 is PARTIAL bare and SUCCESS attested.
    function test_Nerve_WidensSuccessBand_FlipsPartialToSuccess() public {
        uint256 nrvBps = _attestWindsor(aliceDon);
        assertEq(nrvBps, 200, "Windsor must grant 2sp NRV or the rest of this test proves nothing");

        _fund(aliceDon, 100e18);
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        _resolveWith(m, 790_000);
        assertEq(escrow.hopperOf(aliceDon), 36e18, "nerve did not widen the success band");
    }

    /// The other direction, which is what makes the test above mean anything: the SAME roll on the
    /// SAME board with an UNATTESTED Don still reads the published ladder and lands in PARTIAL.
    function test_Nerve_UnattestedDonKeepsPublishedOdds() public {
        _fund(bobDon, 100e18);
        uint64 m = _depart(bobPk, bobDon, PAPER_ROUTE, 0, bytes32(0));
        _resolveWith(m, 790_000);
        assertEq(escrow.hopperOf(bobDon), 14.4e18, "an unattested Don must get exactly the published odds");
    }

    /// NRV may shrink PARTIAL to nothing but must never eat into FAIL: success is capped at the
    /// published cumPartialPpm, so a roll past that band fails however much nerve a Don has.
    function test_Nerve_CannotReachIntoTheFailBand() public {
        _attestWindsor(aliceDon);
        _fund(aliceDon, 100e18);
        uint64 m = _depart(alicePk, aliceDon, PAPER_ROUTE, 0, bytes32(0));
        _resolveWith(m, 950_000);
        assertEq(escrow.hopperOf(aliceDon), 0, "nerve must not convert a FAIL into a payout");
    }
}
