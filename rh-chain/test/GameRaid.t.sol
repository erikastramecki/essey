// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AffinityTraits} from "../src/game/AffinityTraits.sol";
import {Vm} from "forge-std/Vm.sol";
import {GameBase} from "./GameBase.t.sol";
import {RaidEngine} from "../src/game/RaidEngine.sol";

contract GameRaidTest is GameBase {
    uint256 charliePk = 0xCA41;
    address charlie;
    uint256 charlieDon;

    uint256 aliceHitter;

    function setUp() public override {
        super.setUp();
        charlie = vm.addr(charliePk);
        vm.deal(charlie, 10 ether);
        charlieDon = don.mint(charlie);

        // Attacker kit: alice mints one Hitter and keeps 500 banked Scrip for commit fees.
        _grantScrip(don.vaultOf(aliceDon), 1_400e18);
        vm.prank(alice);
        aliceHitter = hitter.mint(aliceDon);
    }

    /// Stand up bob as a target: first play + loot in the hopper (36 Scrip mission pay), 1,000
    /// deployed, then AWAY on a 12h PROOF OF WORK with the given garrison commit.
    function _targetAway(bytes32 garrisonHash) internal {
        _earnHopper(bobPk, bobDon); // success T1: hopper 36, safehouse, stipend
        _grantScrip(don.vaultOf(bobDon), 1_000e18);
        vm.prank(bob);
        escrow.deploy(bobDon, 1_000e18);
        _grantScrip(don.vaultOf(bobDon), 10e18); // fee money for the next depart
        _depart(bobPk, bobDon, PROOF_OF_WORK, 0, garrisonHash);
    }

    function _commitAndReveal(uint256 attackerDon, uint256 pk, uint256 hitterId, uint256 targetDon)
        internal
        returns (uint64 raidId)
    {
        uint256[] memory crew = new uint256[](1);
        crew[0] = hitterId;
        bytes32 salt = bytes32("salt");
        bytes32 h = keccak256(abi.encode(attackerDon, crew, targetDon, salt));
        vm.prank(vm.addr(pk));
        raidId = raid.commit(attackerDon, h);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(vm.addr(pk));
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, targetDon, salt);
    }

    /// p_hit for a single fresh L1 hitter (A = 50e6) vs HD-only defense.
    function _pSolo(uint256 hd) internal pure returns (uint256) {
        uint256 a = 50 * 1_000_000;
        uint256 d = hd * 1_000_000;
        uint256 p = (720_000 * a) / (a + d);
        if (p < 50_000) p = 50_000;
        if (p > 700_000) p = 700_000;
        return p;
    }

    /// Decode the last RaidSettled event (outcome, pHit, taken, tax) from recorded logs.
    function _lastSettled(Vm.Log[] memory logs)
        internal
        pure
        returns (uint8 outcome, uint256 pHit, uint256 taken, uint256 tax)
    {
        bytes32 topic = keccak256("RaidSettled(uint64,uint8,uint256,uint256,uint256)");
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == topic) {
                (uint256 o, uint256 p, uint256 t, uint256 x) =
                    abi.decode(logs[i - 1].data, (uint256, uint256, uint256, uint256));
                return (uint8(o), p, t, x);
            }
        }
        revert("no RaidSettled");
    }

    // ---------------------------------------------------------------- commit / reveal mechanics

    function test_Commit_HoldsFee_ClosedGenerationBlocks() public {
        uint256 vaultBefore = scrip.balanceOf(don.vaultOf(aliceDon));
        vm.prank(alice);
        raid.commit(aliceDon, bytes32("h"));
        assertEq(scrip.balanceOf(address(raid)), 50e18); // $0.50 at the peg, held
        assertEq(vaultBefore - scrip.balanceOf(don.vaultOf(aliceDon)), 50e18);

        controller.close();
        vm.prank(alice);
        vm.expectRevert(RaidEngine.GenerationClosed.selector);
        raid.commit(aliceDon, bytes32("h2"));
    }

    function test_Reveal_WindowEnforced() public {
        _targetAway(bytes32(0));
        uint256[] memory crew = new uint256[](1);
        crew[0] = aliceHitter;
        bytes32 h = keccak256(abi.encode(aliceDon, crew, bobDon, bytes32("s")));
        vm.prank(alice);
        uint64 raidId = raid.commit(aliceDon, h);

        vm.prank(alice); // too early (< 10 min)
        vm.expectRevert(RaidEngine.RevealTooEarly.selector);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, bobDon, bytes32("s"));

        vm.warp(block.timestamp + 41 minutes); // too late (> 40 min)
        vm.prank(alice);
        vm.expectRevert(RaidEngine.RevealTooLate.selector);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, bobDon, bytes32("s"));
    }

    function test_Reveal_CommitMismatch() public {
        _targetAway(bytes32(0));
        uint256[] memory crew = new uint256[](1);
        crew[0] = aliceHitter;
        bytes32 h = keccak256(abi.encode(aliceDon, crew, bobDon, bytes32("s")));
        vm.prank(alice);
        uint64 raidId = raid.commit(aliceDon, h);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(alice);
        vm.expectRevert(RaidEngine.CommitMismatch.selector);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, bobDon, bytes32("WRONG"));
    }

    /// THE AWAY-WINDOW LAW: a home Don's House is untouchable.
    function test_Reveal_TargetMustBeAway() public {
        _earnHopper(bobPk, bobDon); // bob is HOME with a full hopper
        uint256[] memory crew = new uint256[](1);
        crew[0] = aliceHitter;
        bytes32 h = keccak256(abi.encode(aliceDon, crew, bobDon, bytes32("s")));
        vm.prank(alice);
        uint64 raidId = raid.commit(aliceDon, h);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(alice);
        vm.expectRevert(RaidEngine.TargetNotAway.selector);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, bobDon, bytes32("s"));
    }

    function test_Reveal_CrewValidation() public {
        _targetAway(bytes32(0));
        // Someone else's hitter.
        _grantScrip(don.vaultOf(bobDon), 900e18);
        vm.prank(bob);
        uint256 bobHitter = hitter.mint(bobDon);
        uint256[] memory crew = new uint256[](1);
        crew[0] = bobHitter;
        bytes32 h = keccak256(abi.encode(aliceDon, crew, bobDon, bytes32("s")));
        vm.prank(alice);
        uint64 raidId = raid.commit(aliceDon, h);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(alice);
        vm.expectRevert(RaidEngine.HitterUnavailable.selector);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, bobDon, bytes32("s"));

        // Duplicate ids (non-increasing) are rejected — no double-counting one goon.
        uint256[] memory dup = new uint256[](2);
        dup[0] = aliceHitter;
        dup[1] = aliceHitter;
        bytes32 h2 = keccak256(abi.encode(aliceDon, dup, bobDon, bytes32("s")));
        vm.prank(alice);
        uint64 raid2 = raid.commit(aliceDon, h2);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(alice);
        vm.expectRevert(RaidEngine.BadCrew.selector);
        raid.reveal{value: ENTROPY_FEE}(raid2, dup, bobDon, bytes32("s"));
    }

    // ---------------------------------------------------------------- outcomes

    function test_CommonHit_TransfersHopper_TaxConservation() public {
        _targetAway(bytes32(0));
        uint256 word = _findRaidWord(_pSolo(40), true, false);

        uint64 raidId = _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        // Fee is sunk at reveal: nothing held in the engine.
        assertEq(scrip.balanceOf(address(raid)), 0);

        uint256 pendingYield = escrow.pendingYieldOf(bobDon);
        uint256 victimValue = escrow.hopperOf(bobDon) + pendingYield;
        uint256 attackerBefore = scrip.balanceOf(don.vaultOf(aliceDon));
        uint256 supplyBefore = scrip.totalSupply();

        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(word));
        (uint8 outcome, uint256 pHit, uint256 taken, uint256 tax) = _lastSettled(vm.getRecordedLogs());

        assertEq(outcome, 1); // COMMON
        assertEq(pHit, _pSolo(40));
        assertEq(taken, victimValue); // the whole hopper (incl. just-realized yield), nothing more
        assertEq(tax, (taken * 750) / 10_000); // 7.5% hit tax
        // CONSERVATION: victim's loss == attacker gain + burned tax; the raid itself minted nothing
        // (the only mint in the tx is the checkpoint realizing the victim's pending yield).
        assertEq(scrip.balanceOf(don.vaultOf(aliceDon)) - attackerBefore, taken - tax);
        assertEq(supplyBefore + pendingYield - scrip.totalSupply(), tax);
        assertEq(escrow.hopperOf(bobDon), 0);
        assertEq(escrow.deployedOf(bobDon), 1_000e18); // common hits NEVER touch principal
        assertEq(escrow.damageBps(bobDon), 4_000); // -40% until repaired
        assertEq(raid.heatUntil(bobDon), uint64(block.timestamp) + 8 hours);
        assertEq(scrip.balanceOf(address(escrow)), escrow.totalDeployed() + escrow.totalHopper());
        (,,,,,,,,, RaidEngine.RaidState state,,) = raid.raids(raidId);
        assertEq(uint8(state), uint8(RaidEngine.RaidState.Settled));
    }

    function test_BigScore_SlicesDeployedInBand_SetsLockout() public {
        _targetAway(bytes32(0));
        uint256 p = _pSolo(40);
        uint256 word = _findRaidWord(p, true, true);

        _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        uint256 deployedBefore = escrow.deployedOf(bobDon);

        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(word));
        (uint8 outcome,, uint256 taken, uint256 tax) = _lastSettled(vm.getRecordedLogs());

        assertEq(outcome, 2); // BIG SCORE
        // slice = 15% + 15%·u² — recompute the engine's partition and check the exact amount.
        uint256 u = _uRoll(word);
        uint256 sliceBps = 1_500 + (1_500 * ((u * u) / PPM)) / PPM;
        assertGe(sliceBps, 1_500); // band floor 15%…
        assertLe(sliceBps, 3_000); // …band ceiling 30% (the Scrip band, mean 20%)
        assertEq(taken, (deployedBefore * sliceBps) / 10_000);
        assertEq(escrow.deployedOf(bobDon), deployedBefore - taken); // DEPLOYED only
        assertEq(tax, (taken * 750) / 10_000);
        // 48h per-House principal-drain lockout armed.
        assertEq(raid.bigLockUntil(bobDon), uint64(block.timestamp) + 48 hours);
    }

    function test_BigScore_LockoutDowngradesToCommon() public {
        _targetAway(bytes32(0));
        uint256 p = _pSolo(40);
        uint256 bigWord = _findRaidWord(p, true, true);
        _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        oracle.fulfill(oracle.lastSeq(), bytes32(bigWord)); // big score #1 arms the lockout

        // Second big roll INSIDE the lockout, from a different attacker (heat: wait 9h too).
        _grantScrip(don.vaultOf(charlieDon), 1_000e18);
        vm.prank(charlie);
        uint256 charlieHitter = hitter.mint(charlieDon);
        vm.warp(block.timestamp + 9 hours); // heat (8h) passed; lockout (48h) still armed
        assertTrue(board.isAway(bobDon)); // 12h mission still running

        uint256 deployedBefore = escrow.deployedOf(bobDon);
        _commitAndReveal(charlieDon, charliePk, charlieHitter, bobDon);
        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(bigWord));
        (uint8 outcome,,,) = _lastSettled(vm.getRecordedLogs());
        assertEq(outcome, 1); // downgraded — "the safe got moved"
        assertEq(escrow.deployedOf(bobDon), deployedBefore); // principal untouched
    }

    function test_Miss_KillRoll_Hospitalizes() public {
        _targetAway(bytes32(0));
        // A word that misses AND kills crew slot 0: pKill = 0.15 + 0.35 x D/(A+D).
        uint256 pKill = 150_000 + (350_000 * (40 * PPM)) / ((50 + 40) * PPM);
        uint256 word = _findMissWord(pKill, true);

        _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        uint256 attackerBefore = scrip.balanceOf(don.vaultOf(aliceDon));
        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(word));
        (uint8 outcome,, uint256 taken,) = _lastSettled(vm.getRecordedLogs());

        assertEq(outcome, 0); // MISS
        assertEq(taken, 0);
        assertEq(scrip.balanceOf(don.vaultOf(aliceDon)), attackerBefore); // nothing gained
        assertEq(hitter.hospitalUntil(aliceHitter), uint64(block.timestamp) + 48 hours);
        assertEq(escrow.hopperOf(bobDon) > 0, true); // defender kept everything
        assertEq(escrow.damageBps(bobDon), 0); // no damage on a miss
    }

    function test_HospitalizedHitter_CannotRide() public {
        test_Miss_KillRoll_Hospitalizes();
        vm.warp(block.timestamp + 9 hours); // heat passed, hospital (48h) not
        uint256[] memory crew = new uint256[](1);
        crew[0] = aliceHitter;
        // The hospital gate, checked against a FRESH target (charlie, away) so no other cap fires.
        _grantScrip(don.vaultOf(charlieDon), 100e18);
        _depart(charliePk, charlieDon, PAPER_ROUTE, 0, bytes32(0)); // charlie away
        bytes32 h2 = keccak256(abi.encode(aliceDon, crew, charlieDon, bytes32("s")));
        vm.prank(alice);
        uint64 raidId = raid.commit(aliceDon, h2);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(alice);
        vm.expectRevert(RaidEngine.HitterUnavailable.selector);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, charlieDon, bytes32("s"));
    }

    // ---------------------------------------------------------------- cooldown & caps

    /// The (t/20h)^2 curve: a second attempt 10h10m after the first runs at ~26% power — diminished
    /// odds, not a revert (patience strictly dominates).
    function test_Cooldown_DiminishedOdds_NotAGate() public {
        _targetAway(bytes32(0));
        // A miss word whose kill-partition also spares crew slot 0 (deterministic un-killed path).
        uint256 pKill = 150_000 + (350_000 * (40 * PPM)) / ((50 + 40) * PPM);
        uint256 missWord = _findMissWord(pKill, false);
        _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        uint64 attemptAt = uint64(block.timestamp);
        oracle.fulfill(oracle.lastSeq(), bytes32(missWord));
        assertEq(hitter.hospitalUntil(aliceHitter), 0); // survived, only cooled down

        // 10h later: raid CHARLIE (fresh pair) with the cooled-down hitter.
        vm.warp(attemptAt + 10 hours);
        _grantScrip(don.vaultOf(charlieDon), 100e18);
        _depart(charliePk, charlieDon, PAPER_ROUTE, 0, bytes32(0));
        uint256[] memory crew = new uint256[](1);
        crew[0] = aliceHitter;
        bytes32 h = keccak256(abi.encode(aliceDon, crew, charlieDon, bytes32("s2")));
        vm.prank(alice);
        uint64 raidId = raid.commit(aliceDon, h);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(alice);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, charlieDon, bytes32("s2"));

        // Expected: elapsed 10h10m of 20h => m = (0.508…)² ≈ 0.258 => A = 50 x m.
        uint256 elapsed = 10 hours + 10 minutes;
        uint256 lin = (elapsed * PPM) / 20 hours;
        uint256 a = 50 * ((lin * lin) / PPM);
        uint256 d = 40 * PPM;
        uint256 expectedP = (720_000 * a) / (a + d);
        if (expectedP < 50_000) expectedP = 50_000;

        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(uint256(999_999))); // certain miss at these odds
        (, uint256 pHit,,) = _lastSettled(vm.getRecordedLogs());
        assertEq(pHit, expectedP);
        assertLt(pHit, _pSolo(40)); // strictly worse than a patient attempt
    }

    function test_Heat_8hImmunityAfterSettle() public {
        _targetAway(bytes32(0));
        uint256 word = _findRaidWord(_pSolo(40), true, false);
        _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        oracle.fulfill(oracle.lastSeq(), bytes32(word)); // settled => heat armed

        _grantScrip(don.vaultOf(charlieDon), 1_000e18);
        vm.prank(charlie);
        uint256 charlieHitter = hitter.mint(charlieDon);
        uint256[] memory crew = new uint256[](1);
        crew[0] = charlieHitter;
        bytes32 h = keccak256(abi.encode(charlieDon, crew, bobDon, bytes32("s")));
        vm.prank(charlie);
        uint64 raidId = raid.commit(charlieDon, h);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(charlie);
        vm.expectRevert(RaidEngine.TargetOnHeat.selector);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, bobDon, bytes32("s"));
    }

    function test_PairCooldown_24h() public {
        _targetAway(bytes32(0));
        uint256 missWord = _findRaidWord(_pSolo(40), false, false);
        _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        oracle.fulfill(oracle.lastSeq(), bytes32(missWord));

        // 9h later (heat clear, pair NOT clear — 24h): same attacker, same target.
        vm.warp(block.timestamp + 9 hours);
        assertTrue(board.isAway(bobDon));
        uint256[] memory crew = new uint256[](1);
        crew[0] = aliceHitter;
        bytes32 h = keccak256(abi.encode(aliceDon, crew, bobDon, bytes32("s3")));
        vm.prank(alice);
        uint64 raidId = raid.commit(aliceDon, h);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(alice);
        vm.expectRevert(RaidEngine.PairCooldown.selector);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, bobDon, bytes32("s3"));
    }

    // ---------------------------------------------------------------- garrison

    function test_Garrison_FrozenAtDepart_RevealedByAnyone_RaisesDefense() public {
        // Bob garrisons two hitters; the commit freezes into his depart.
        _earnHopper(bobPk, bobDon);
        _grantScrip(don.vaultOf(bobDon), 3_000e18);
        vm.startPrank(bob);
        uint256 g1 = hitter.mint(bobDon);
        uint256 g2 = hitter.mint(bobDon);
        escrow.deploy(bobDon, 1_000e18);
        vm.stopPrank();
        uint256[] memory garrison = new uint256[](2);
        garrison[0] = g1;
        garrison[1] = g2;
        bytes32 salt = bytes32("guard-salt");
        bytes32 gHash = keccak256(abi.encode(garrison, salt));
        _depart(bobPk, bobDon, PROOF_OF_WORK, 0, gHash);
        assertEq(board.garrisonHashOf(bobDon), gHash);

        uint64 raidId = _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        assertEq(raid.rollRequestedAt(raidId), 0, "no roll may be drawn against a sealed garrison");

        // Wrong plaintext can't open it.
        vm.expectRevert(RaidEngine.GarrisonMismatch.selector);
        raid.revealGarrison(raidId, garrison, bytes32("wrong"));

        // ANYONE with the plaintext reveals (keeper normally) — and only THEN is the roll drawn.
        raid.revealGarrison(raidId, garrison, salt);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);
        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(uint256(999_999)));
        (, uint256 pHit,,) = _lastSettled(vm.getRecordedLogs());
        // D = 40 + 2 x 50 x 0.95 = 135 => p = 0.72 x 50/185.
        uint256 a = 50 * PPM;
        uint256 d = 40 * PPM + 2 * ((50 * PPM * 9_500) / 10_000);
        assertEq(pHit, (720_000 * a) / (a + d));
        assertLt(pHit, _pSolo(40)); // garrisoning measurably hardened the House
    }

    /// H-1 fix (logic lens, 2026-08-12): suppressing the garrison reveal is no longer a free pass.
    /// An un-openable garrison hash earns ZERO defense credit — the House stands ALONE at its worst
    /// p_hit — and the REAL roll runs (transfer + kills), not the old damage-only floor. Before the fix
    /// a rational defender committed an un-openable hash on every depart and never lost loot or
    /// principal, only a cheap repairable debuff; the whole loot/big-score economy was opt-out.
    function test_Garrison_TimeoutFloor_RealRoll_SuppressionNotDominant() public {
        _earnHopper(bobPk, bobDon);
        _grantScrip(don.vaultOf(bobDon), 1_500e18);
        vm.prank(bob);
        escrow.deploy(bobDon, 1_000e18);
        bytes32 gHash = keccak256(abi.encode(new uint256[](1), bytes32("never-told")));
        _depart(bobPk, bobDon, PROOF_OF_WORK, 0, gHash);

        uint64 raidId = _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        // A common-hit word at the HOUSE-ONLY p_hit (unrevealed garrison => D = HD 40 alone).
        uint256 word = _findRaidWord(_pSolo(40), true, false);

        vm.expectRevert(RaidEngine.NotYetTimedOut.selector);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);

        uint256 attackerBefore = scrip.balanceOf(don.vaultOf(aliceDon));
        uint256 hopperBefore = escrow.hopperOf(bobDon);
        assertGt(hopperBefore, 0); // there IS loot to lose
        vm.warp(block.timestamp + 1 hours);
        // Permissionless — the attacker claims the roll a staller tried to deny.
        raid.requestRoll{value: ENTROPY_FEE}(raidId);
        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(word));
        (uint8 outcome, uint256 pHit, uint256 taken,) = _lastSettled(vm.getRecordedLogs());

        assertEq(outcome, 1); // COMMON hit — a REAL settlement, not the old damage-only floor
        assertEq(pHit, _pSolo(40)); // the House defended ALONE — the unproven garrison earned no credit
        assertGt(taken, 0); // the hopper WAS taken
        assertGt(scrip.balanceOf(don.vaultOf(aliceDon)), attackerBefore); // raider gained: suppression FAILED
        assertEq(escrow.hopperOf(bobDon), 0); // defender lost the loot despite hiding the garrison
        assertEq(escrow.damageBps(bobDon), 4_000); // and still takes the debuff
    }

    // ---------------------------------------------------------------- liveness valves

    function test_ReclaimRaid_EntropyWithheld_MissOutcome() public {
        _targetAway(bytes32(0));
        uint64 raidId = _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        uint64 seq = oracle.lastSeq();

        vm.expectRevert(RaidEngine.NotYetTimedOut.selector);
        raid.reclaimRaid(raidId);

        vm.warp(block.timestamp + 2 hours);
        raid.reclaimRaid(raidId); // anyone
        // Fee stays sunk, cooldown stands, target unharmed, heat armed.
        assertEq(scrip.balanceOf(address(raid)), 0);
        assertGt(hitter.lastAttemptAt(aliceHitter), 0);
        assertEq(escrow.damageBps(bobDon), 0);
        assertGt(raid.heatUntil(bobDon), block.timestamp);
        // The late word can't resurrect it.
        vm.expectRevert(RaidEngine.AlreadyDelivered.selector);
        oracle.fulfill(seq, bytes32(uint256(1)));
    }

    function test_Forfeit_NoReveal_FeeBurns() public {
        vm.prank(alice);
        uint64 raidId = raid.commit(aliceDon, bytes32("never-revealed"));
        uint256 supply = scrip.totalSupply();

        vm.expectRevert(RaidEngine.NotYetTimedOut.selector);
        raid.forfeit(raidId);

        vm.warp(block.timestamp + 41 minutes);
        raid.forfeit(raidId);
        assertEq(scrip.totalSupply(), supply - 50e18); // abandoning costs the full fee
        assertEq(scrip.balanceOf(address(raid)), 0);

        // A forfeited commit can't be revealed.
        uint256[] memory crew = new uint256[](1);
        crew[0] = aliceHitter;
        vm.prank(alice);
        vm.expectRevert(RaidEngine.WrongState.selector);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, bobDon, bytes32("s"));
    }

    // ================================================================== traits move raid power

    /// 5 Suit/The General grants 2 sp RP — the attack stat.
    function _attestGeneral(uint256 donId) internal {
        bytes memory pre = bytes("male\n5 Suit/The General");
        don.setTraits(donId, AffinityTraits.commitmentOf(pre));
        affinity.attest(donId, pre);
    }

    function _attackPowerOf(uint64 raidId) internal view returns (uint256 ap) {
        (,,,,,, ap,,,,,) = raid.raids(raidId);
    }

    function _defensePowerOf(uint64 raidId) internal view returns (uint256 dp) {
        (,,,,,,, dp,,,,) = raid.raids(raidId);
    }

    /// The claim: RP raises the raider's crew power. Same Don, same crew, same target — attested
    /// second. The p_hit curve is untouched; only the A it consumes moves.
    function test_Traits_AttackRaisesCrewPower() public {
        _targetAway(bytes32(0));
        uint64 bare = _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        uint256 bareAttack = _attackPowerOf(bare);

        _attestGeneral(aliceDon);
        vm.warp(block.timestamp + 30 hours); // clear the per-pair cooldown
        uint64 buffed = _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);

        assertGt(_attackPowerOf(buffed), bareAttack, "RP did not raise the raider's crew power");
    }

    /// And the defender's side: an unattested target defends at exactly the House number, so the
    /// attack test above cannot be passing because defense silently moved.
    function test_Traits_UnattestedTargetDefendsAtHouseValue() public {
        _targetAway(bytes32(0));
        uint64 r = _commitAndReveal(aliceDon, alicePk, aliceHitter, bobDon);
        assertEq(_defensePowerOf(r), deed.defenseOf(bobDon) * 1_000_000, "unattested defense must be the House alone");
    }
}
