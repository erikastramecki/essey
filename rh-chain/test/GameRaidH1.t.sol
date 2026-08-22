// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {GameBase} from "./GameBase.t.sol";
import {RaidEngine} from "../src/game/RaidEngine.sol";

/// H-1 — the defender-side free escape, pinned shut.
///
/// The finding (2026-08-16): entropy was requested at `reveal`, so the word landed in a raid whose
/// defence was still sealed. `entropyCallback` stored it WITHOUT settling, `raids` is public, and
/// settlement was blocked for a further GARRISON_TIMEOUT. That hour sat between "outcome known" and
/// "outcome applied", and inside it the defender read the roll and then chose: open the garrison to
/// flip a hit into a miss, or come home through the permissionless `MissionBoard.reclaim` and bank
/// everything. Strictly free either way.
///
/// The fix draws the roll only once the defence is FIXED, so the tests below are the assertion that
/// no such decision point exists. CONTROL is the other half of the proof: a raid against a defender
/// who does nothing must still land, or "nobody can ever be hit" would satisfy all of them.
contract GameRaidH1Test is GameBase {
    uint256 aliceHitter;
    uint256[] garrison;
    bytes32 constant G_SALT = bytes32("guard-salt");

    receive() external payable {} // this contract calls requestRoll directly, so it takes refunds

    function setUp() public override {
        super.setUp();
        _grantScrip(don.vaultOf(aliceDon), 1_400e18);
        vm.prank(alice);
        aliceHitter = hitter.mint(aliceDon);
    }

    // ---------------------------------------------------------------- harness

    /// Bob: loot in the hopper, 1,000 deployed, then AWAY behind `gHash`.
    function _bobExposedAndAway(uint64 brief, bytes32 gHash) internal returns (uint64 missionId) {
        _earnHopper(bobPk, bobDon);
        _grantScrip(don.vaultOf(bobDon), 1_100e18);
        vm.prank(bob);
        escrow.deploy(bobDon, 1_000e18);
        missionId = _depart(bobPk, bobDon, brief, 0, gHash);
    }

    /// The same, with a real two-Hitter garrison whose plaintext this test holds.
    function _bobGarrisonedAndAway() internal {
        _earnHopper(bobPk, bobDon);
        _grantScrip(don.vaultOf(bobDon), 3_100e18);
        vm.startPrank(bob);
        garrison.push(hitter.mint(bobDon));
        garrison.push(hitter.mint(bobDon));
        escrow.deploy(bobDon, 1_000e18);
        vm.stopPrank();
        _depart(bobPk, bobDon, PROOF_OF_WORK, 0, keccak256(abi.encode(garrison, G_SALT)));
    }

    function _commitAndReveal(uint256 targetDon) internal returns (uint64 raidId) {
        uint256[] memory crew = new uint256[](1);
        crew[0] = aliceHitter;
        bytes32 salt = bytes32("h1-salt");
        vm.prank(alice);
        raidId = raid.commit(aliceDon, keccak256(abi.encode(aliceDon, crew, targetDon, salt)));
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(alice);
        raid.reveal{value: ENTROPY_FEE}(raidId, crew, targetDon, salt);
    }

    function _state(uint64 raidId) internal view returns (uint8) {
        (,,,,,,,,, RaidEngine.RaidState st,,) = raid.raids(raidId);
        return uint8(st);
    }

    function _word(uint64 raidId) internal view returns (bytes32 w) {
        (,,,,,,,, w,,,) = raid.raids(raidId);
    }

    function _wordReceived(uint64 raidId) internal view returns (bool v) {
        (,,,,,,,,,, v,) = raid.raids(raidId);
    }

    function _garrisonOpen(uint64 raidId) internal view returns (bool v) {
        (,,,,,,,,,,, v) = raid.raids(raidId);
    }

    function _defense(uint64 raidId) internal view returns (uint256 v) {
        (,,,,,,, v,,,,) = raid.raids(raidId);
    }

    function _attack(uint64 raidId) internal view returns (uint256 v) {
        (,,,,,, v,,,,,) = raid.raids(raidId);
    }

    function _settled(uint64 raidId) internal view returns (bool) {
        return _state(raidId) == uint8(RaidEngine.RaidState.Settled);
    }

    /// THE FOG INVARIANT, read exactly as a chain observer would. Everything H-1 bought the defender
    /// flowed from this being false at some point in the lifecycle.
    function _assertNoReadableRoll(uint64 raidId, string memory when) internal view {
        assertFalse(_settled(raidId), string.concat("precondition: raid already settled ", when));
        assertEq(_word(raidId), bytes32(0), string.concat("H-1: roll readable ", when));
        assertFalse(_wordReceived(raidId), string.concat("H-1: word flagged ", when));
    }

    function _pHit(uint256 a, uint256 d) internal pure returns (uint256 p) {
        p = (720_000 * a) / (a + d);
        if (p < 50_000) p = 50_000;
        if (p > 700_000) p = 700_000;
    }

    function _bobWealth() internal view returns (uint256) {
        return scrip.balanceOf(don.vaultOf(bobDon)) + escrow.hopperOf(bobDon) + escrow.deployedOf(bobDon);
    }

    function _lastSettled(Vm.Log[] memory logs) internal pure returns (uint8 outcome, uint256 taken) {
        bytes32 topic = keccak256("RaidSettled(uint64,uint8,uint256,uint256,uint256)");
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == topic) {
                (uint256 o,, uint256 t,) = abi.decode(logs[i - 1].data, (uint256, uint256, uint256, uint256));
                return (uint8(o), t);
            }
        }
        revert("no RaidSettled");
    }

    // ================================================================== CONTROL

    /// Without this, "the engine can never hit anyone" would pass every test below.
    function test_Control_LegitimateHitStillLands() public {
        _bobExposedAndAway(PAPER_ROUTE, bytes32(0));
        uint64 raidId = _commitAndReveal(bobDon);
        uint256 attackerBefore = scrip.balanceOf(don.vaultOf(aliceDon));
        assertGt(escrow.hopperOf(bobDon), 0, "control needs real loot at risk");

        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(uint256(1))); // residue 1 — a hit at any defence
        (uint8 outcome, uint256 taken) = _lastSettled(vm.getRecordedLogs());

        assertEq(outcome, 1, "control: expected a COMMON hit");
        assertGt(taken, 0, "control: the hit took nothing");
        assertEq(escrow.hopperOf(bobDon), 0, "control: hopper survived a landed hit");
        assertGt(scrip.balanceOf(don.vaultOf(aliceDon)), attackerBefore, "control: attacker gained nothing");
        assertTrue(_settled(raidId));
    }

    /// The garrisoned control: the roll still runs, and the proven garrison still lowers p_hit.
    function test_Control_GarrisonedRaidStillSettles() public {
        _bobGarrisonedAndAway();
        uint64 raidId = _commitAndReveal(bobDon);
        raid.revealGarrison(raidId, garrison, G_SALT);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);

        uint256 a = _attack(raidId);
        uint256 dFloor = deed.defenseOf(bobDon) * PPM;
        assertEq(_defense(raidId), dFloor + 2 * ((50 * PPM * 9_500) / 10_000), "garrison power not credited");
        assertLt(_pHit(a, _defense(raidId)), _pHit(a, dFloor), "proving the garrison must lower p_hit");

        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(uint256(1)));
        (uint8 outcome, uint256 taken) = _lastSettled(vm.getRecordedLogs());
        assertEq(outcome, 1);
        assertGt(taken, 0, "a garrisoned target is still robbable");
    }

    // ================================================================== PoC 1 — the free escape

    /// The escape ran on information. Walk the exploit to its decision point and assert the
    /// information is not there: at the moment the defender would have read the roll and chosen to
    /// bolt, no roll exists and none can be drawn.
    function test_PoC1_EscapeDecisionPointHasNothingToReadOrDrawOn() public {
        uint64 missionId = _bobExposedAndAway(PAPER_ROUTE, keccak256(abi.encode(new uint256[](1), "never-told")));
        (,,, uint64 due,,,,,) = board.missions(missionId);
        vm.warp(uint256(due) + 2 hours + 1); // parked past due: reclaim+bank is available all the way through
        assertTrue(board.isAway(bobDon), "PoC1 needs Bob still away and therefore raidable");

        uint64 raidId = _commitAndReveal(bobDon);

        // The exploit's precondition, gone: no word, and no way to make one appear.
        _assertNoReadableRoll(raidId, "at the escape decision point");
        assertEq(raid.rollRequestedAt(raidId), 0, "H-1: a roll was drawn against a sealed garrison");
        vm.expectRevert(RaidEngine.NotYetTimedOut.selector);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);

        // And it stays gone for the entire window the escape used to live in.
        vm.warp(block.timestamp + 59 minutes);
        _assertNoReadableRoll(raidId, "59 minutes into the garrison window");
        vm.expectRevert(RaidEngine.NotYetTimedOut.selector);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);
    }

    /// The other half: a defender who does NOT act on that absent signal is hit for real. Together
    /// these say the escape is now a blind pre-emptive bank, not a priced option.
    function test_PoC1_UninformedDefenderIsStillHitForReal() public {
        uint64 missionId = _bobExposedAndAway(PAPER_ROUTE, keccak256(abi.encode(new uint256[](1), "never-told")));
        (,,, uint64 due,,,,,) = board.missions(missionId);
        vm.warp(uint256(due) + 2 hours + 1);

        uint256 wealthBefore = _bobWealth();
        uint64 raidId = _commitAndReveal(bobDon);
        uint256 attackerBefore = scrip.balanceOf(don.vaultOf(aliceDon)); // after the fee is sunk

        vm.warp(block.timestamp + 1 hours + 1);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);
        _assertNoReadableRoll(raidId, "with the roll in flight");
        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(uint256(1)));
        (uint8 outcome, uint256 taken) = _lastSettled(vm.getRecordedLogs());

        assertEq(outcome, 1);
        assertGt(taken, 0, "the suppressing defender lost nothing");
        assertLt(_bobWealth(), wealthBefore, "defender kept everything through a landed hit");
        assertGt(scrip.balanceOf(don.vaultOf(aliceDon)), attackerBefore, "attacker took nothing");
        assertGt(escrow.repairFeeOf(bobDon), 0, "repair was free: damage basis snapshotted at zero");
    }

    // ================================================================== PoC 2 — the fog

    /// No word may be visible on an unsettled raid at ANY point in the garrisoned lifecycle. PoC 1
    /// and PoC 3 are consequences of this one; pinning it directly means a later refactor cannot
    /// re-open the window by some other route.
    function test_PoC2_WordNeverReadableBeforeSettlement() public {
        _bobGarrisonedAndAway();
        uint64 raidId = _commitAndReveal(bobDon);

        _assertNoReadableRoll(raidId, "after reveal");
        assertFalse(_garrisonOpen(raidId), "garrison must still be sealed");
        assertEq(raid.rollRequestedAt(raidId), 0, "no roll may be drawn against a sealed garrison");

        raid.revealGarrison(raidId, garrison, G_SALT);
        _assertNoReadableRoll(raidId, "after the defence is fixed");
        assertEq(_state(raidId), uint8(RaidEngine.RaidState.Revealed), "opening the garrison must not settle");
        assertEq(raid.rollRequestedAt(raidId), 0, "opening the garrison must not draw the roll");

        raid.requestRoll{value: ENTROPY_FEE}(raidId);
        _assertNoReadableRoll(raidId, "with the roll in flight");
        assertEq(raid.rollRequestedAt(raidId), uint64(block.timestamp), "roll clock not stamped");

        oracle.fulfill(oracle.lastSeq(), bytes32(uint256(1)));
        assertTrue(_settled(raidId), "the word landed without settling");
        assertTrue(_wordReceived(raidId));
    }

    /// The ungarrisoned path — today's only live path — keeps its single-transaction shape: the
    /// defence is final at reveal, so the roll is drawn there and settles on delivery.
    function test_PoC2_UngarrisonedPathDrawsAtRevealAndSettlesOnDelivery() public {
        _bobExposedAndAway(PAPER_ROUTE, bytes32(0));
        uint64 raidId = _commitAndReveal(bobDon);

        assertTrue(_garrisonOpen(raidId), "an empty garrison hash fixes the defence at reveal");
        assertEq(raid.rollRequestedAt(raidId), uint64(block.timestamp), "roll must be drawn in the reveal tx");
        assertEq(_defense(raidId), deed.defenseOf(bobDon) * PPM);
        _assertNoReadableRoll(raidId, "between reveal and delivery");

        oracle.fulfill(oracle.lastSeq(), bytes32(uint256(1)));
        assertTrue(_settled(raidId));
    }

    // ================================================================== PoC 3 — the conditional garrison

    /// Opening the garrison only ever raises D, so with the word public it was a free option: hold a
    /// word that hits at House-alone odds and misses at garrisoned odds, and simply reveal. The word
    /// used here is exactly such a word — the test proves the defender must commit before it exists.
    function test_PoC3_GarrisonRevealCannotBeConditionedOnTheRoll() public {
        _bobGarrisonedAndAway();
        uint64 raidId = _commitAndReveal(bobDon);

        uint256 a = _attack(raidId);
        uint256 dFloor = deed.defenseOf(bobDon) * PPM;
        uint256 dGarrisoned = dFloor + 2 * ((50 * PPM * 9_500) / 10_000);
        uint256 pFloor = _pHit(a, dFloor);
        uint256 pGarrisoned = _pHit(a, dGarrisoned);
        assertLt(pGarrisoned, pFloor, "the garrison must actually move the odds");
        uint256 flipWord = pGarrisoned + (pFloor - pGarrisoned) / 2;
        assertGe(flipWord % PPM, pGarrisoned, "flip word must miss the garrisoned House");
        assertLt(flipWord % PPM, pFloor, "flip word must hit the bare House");

        // The decision point: the defender chooses with nothing to read and nothing drawable.
        _assertNoReadableRoll(raidId, "at the garrison decision point");
        assertEq(raid.rollRequestedAt(raidId), 0, "H-1: a roll was drawn against a sealed garrison");

        // Suppressing therefore buys no information — only the worst defence and the real roll.
        vm.warp(block.timestamp + 1 hours + 1);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);
        assertEq(_defense(raidId), dFloor, "suppression must earn zero defence credit");

        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(flipWord));
        (uint8 outcome, uint256 taken) = _lastSettled(vm.getRecordedLogs());
        assertEq(outcome, 1, "the word must resolve as the hit it is at floor odds");
        assertGt(taken, 0, "suppression dodged the transfer");
    }

    /// The converse, which is what keeps revealing self-interested: opening the garrison before the
    /// roll turns the SAME word into a miss. Blind, and therefore the honest defensive play.
    function test_PoC3_OpeningTheGarrisonEarlyStillEarnsItsDefence() public {
        _bobGarrisonedAndAway();
        uint64 raidId = _commitAndReveal(bobDon);

        uint256 a = _attack(raidId);
        uint256 dFloor = deed.defenseOf(bobDon) * PPM;
        uint256 dGarrisoned = dFloor + 2 * ((50 * PPM * 9_500) / 10_000);
        uint256 flipWord = _pHit(a, dGarrisoned) + (_pHit(a, dFloor) - _pHit(a, dGarrisoned)) / 2;

        raid.revealGarrison(raidId, garrison, G_SALT);
        assertEq(_defense(raidId), dGarrisoned, "the proven garrison must be credited");
        raid.requestRoll{value: ENTROPY_FEE}(raidId);
        assertEq(_defense(raidId), dGarrisoned, "drawing the roll must not clobber a proven defence");

        uint256 hopperBefore = escrow.hopperOf(bobDon);
        vm.recordLogs();
        oracle.fulfill(oracle.lastSeq(), bytes32(flipWord));
        (uint8 outcome, uint256 taken) = _lastSettled(vm.getRecordedLogs());
        assertEq(outcome, 0, "the same word must miss a garrisoned House");
        assertEq(taken, 0);
        assertGe(escrow.hopperOf(bobDon), hopperBefore, "a miss must not touch the hopper");
    }

    // ================================================================== the new surface

    /// One roll per raid, ever. Two live sequence numbers would hand whoever delivers entropy a
    /// choice of which word settles — a re-roll by the back door.
    function test_RequestRoll_IsOncePerRaid_Ungarrisoned() public {
        _bobExposedAndAway(PAPER_ROUTE, bytes32(0));
        uint64 raidId = _commitAndReveal(bobDon); // the reveal already drew it
        uint64 seq = oracle.lastSeq();

        vm.expectRevert(RaidEngine.WrongState.selector);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);

        oracle.fulfill(seq, bytes32(uint256(1)));
        vm.expectRevert(RaidEngine.WrongState.selector);
        raid.requestRoll{value: ENTROPY_FEE}(raidId); // and never again after settlement
    }

    function test_RequestRoll_IsOncePerRaid_Garrisoned() public {
        _bobGarrisonedAndAway();
        uint64 raidId = _commitAndReveal(bobDon);
        raid.revealGarrison(raidId, garrison, G_SALT);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);
        uint64 seq = oracle.lastSeq();

        vm.expectRevert(RaidEngine.WrongState.selector);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);

        // Nor by waiting out the garrison window and claiming the floor path a second time.
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(RaidEngine.WrongState.selector);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);
        assertEq(oracle.lastSeq(), seq, "a second entropy sequence was opened against one raid");
    }

    /// The garrison window gate, at the boundary in both directions.
    function test_RequestRoll_TimeoutBoundary() public {
        _bobGarrisonedAndAway();
        uint64 raidId = _commitAndReveal(bobDon);
        (,,, uint64 revealedAt,,,,,,,,) = raid.raids(raidId);

        vm.warp(uint256(revealedAt) + 1 hours - 1);
        vm.expectRevert(RaidEngine.NotYetTimedOut.selector);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);

        vm.warp(uint256(revealedAt) + 1 hours);
        raid.requestRoll{value: ENTROPY_FEE}(raidId); // exactly at the boundary, allowed
        assertEq(_defense(raidId), deed.defenseOf(bobDon) * PPM);
    }

    /// An opened garrison is rollable immediately — the defender who cooperates never waits an hour.
    function test_RequestRoll_NoWaitOnceTheGarrisonIsOpen() public {
        _bobGarrisonedAndAway();
        uint64 raidId = _commitAndReveal(bobDon);
        raid.revealGarrison(raidId, garrison, G_SALT);
        raid.requestRoll{value: ENTROPY_FEE}(raidId); // same second, no NotYetTimedOut
        assertEq(raid.rollRequestedAt(raidId), uint64(block.timestamp));
    }

    /// A reveal that draws no roll must hand the entropy fee straight back. Stranded ETH in a
    /// settlement contract is value nobody can reach.
    function test_Reveal_RefundsTheFeeWhenNoRollIsDrawn() public {
        _bobGarrisonedAndAway();
        uint256 aliceEthBefore = alice.balance;
        uint64 raidId = _commitAndReveal(bobDon);

        assertEq(raid.rollRequestedAt(raidId), 0);
        assertEq(alice.balance, aliceEthBefore, "the unspent entropy fee was not refunded");
        assertEq(address(raid).balance, 0, "ETH stranded in the engine");
    }

    /// No path leaves ETH behind, including the deferred draw.
    function test_NoStrandedEth_AcrossTheDeferredPath() public {
        _bobGarrisonedAndAway();
        uint64 raidId = _commitAndReveal(bobDon);
        assertEq(address(raid).balance, 0, "stranded after reveal");
        raid.revealGarrison(raidId, garrison, G_SALT);
        assertEq(address(raid).balance, 0, "stranded after garrison reveal");
        raid.requestRoll{value: ENTROPY_FEE * 3}(raidId); // deliberate overpay
        assertEq(address(raid).balance, 0, "overpaid entropy fee stranded in the engine");
        oracle.fulfill(oracle.lastSeq(), bytes32(uint256(1)));
        assertEq(address(raid).balance, 0, "stranded after settlement");
    }

    // ================================================================== the reclaim clock

    /// Ungarrisoned: the roll is drawn at reveal, so the entropy-withheld valve opens exactly
    /// RECLAIM_TIMEOUT later — unchanged from before the fix.
    function test_Reclaim_UngarrisonedClockIsUnchanged() public {
        _bobExposedAndAway(PAPER_ROUTE, bytes32(0));
        uint64 raidId = _commitAndReveal(bobDon);
        (,,, uint64 revealedAt,,,,,,,,) = raid.raids(raidId);

        vm.warp(uint256(revealedAt) + 2 hours - 1);
        vm.expectRevert(RaidEngine.NotYetTimedOut.selector);
        raid.reclaimRaid(raidId);

        vm.warp(uint256(revealedAt) + 2 hours);
        raid.reclaimRaid(raidId);
        assertTrue(_settled(raidId));
        assertEq(escrow.damageBps(bobDon), 0, "a reclaim must not damage the target");
    }

    /// Garrisoned and drawn late: the valve clocks from the DRAW, not the reveal. Clocking from the
    /// reveal would let a roll drawn at +1h59m be reclaimed as a miss a minute later — a second free
    /// escape, this time for whoever wanted the raid voided.
    function test_Reclaim_ClocksFromTheDrawNotTheReveal() public {
        _bobGarrisonedAndAway();
        uint64 raidId = _commitAndReveal(bobDon);
        (,,, uint64 revealedAt,,,,,,,,) = raid.raids(raidId);

        vm.warp(uint256(revealedAt) + 1 hours);
        raid.requestRoll{value: ENTROPY_FEE}(raidId);

        vm.warp(uint256(revealedAt) + 3 hours - 1);
        vm.expectRevert(RaidEngine.NotYetTimedOut.selector);
        raid.reclaimRaid(raidId); // only 1h59m of entropy grace if the clock started at the reveal

        vm.warp(uint256(revealedAt) + 3 hours);
        raid.reclaimRaid(raidId);
        assertTrue(_settled(raidId));
    }

    /// And a roll nobody ever draws still un-sticks, clocked from the moment it became drawable —
    /// an attacker who walks away cannot park a raid, or its heat, forever.
    function test_Reclaim_UndrawnRollStillUnsticks() public {
        _bobGarrisonedAndAway();
        uint64 raidId = _commitAndReveal(bobDon);
        (,,, uint64 revealedAt,,,,,,,,) = raid.raids(raidId);

        vm.warp(uint256(revealedAt) + 3 hours - 1);
        vm.expectRevert(RaidEngine.NotYetTimedOut.selector);
        raid.reclaimRaid(raidId);

        vm.warp(uint256(revealedAt) + 3 hours);
        raid.reclaimRaid(raidId);
        assertTrue(_settled(raidId));
        assertEq(raid.rollRequestedAt(raidId), 0);
        assertEq(escrow.hopperOf(bobDon) > 0, true, "an undrawn raid must not take anything");
    }

    /// A settled raid may never be reclaimed again. The reclaim path re-arms HEAT, so without this
    /// gate a defender could reclaim their own settled raid on a loop and hold permanent immunity.
    function test_Reclaim_CannotRunTwiceOnASettledRaid() public {
        _bobExposedAndAway(PAPER_ROUTE, bytes32(0));
        uint64 raidId = _commitAndReveal(bobDon);
        oracle.fulfill(oracle.lastSeq(), bytes32(uint256(1)));
        assertTrue(_settled(raidId));
        uint64 heatAfterSettle = raid.heatUntil(bobDon);

        vm.warp(block.timestamp + 4 hours);
        vm.expectRevert(RaidEngine.WrongState.selector);
        raid.reclaimRaid(raidId);
        assertEq(raid.heatUntil(bobDon), heatAfterSettle, "heat was re-armed by reclaiming a settled raid");
    }

    /// The same for a raid already floored through reclaim.
    function test_Reclaim_CannotRunTwiceOnAReclaimedRaid() public {
        _bobExposedAndAway(PAPER_ROUTE, bytes32(0));
        uint64 raidId = _commitAndReveal(bobDon);
        vm.warp(block.timestamp + 2 hours);
        raid.reclaimRaid(raidId);
        uint64 heatAfterReclaim = raid.heatUntil(bobDon);

        vm.warp(block.timestamp + 4 hours);
        vm.expectRevert(RaidEngine.WrongState.selector);
        raid.reclaimRaid(raidId);
        assertEq(raid.heatUntil(bobDon), heatAfterReclaim, "heat was re-armed by a second reclaim");
    }

    /// The entropy fee is a floor, not a suggestion — an underfunded draw must name its own reason
    /// rather than fall through to an arithmetic revert.
    function test_RequestRoll_RequiresTheEntropyFee() public {
        _bobGarrisonedAndAway();
        uint64 raidId = _commitAndReveal(bobDon);
        raid.revealGarrison(raidId, garrison, G_SALT);

        vm.expectRevert(RaidEngine.InsufficientFee.selector);
        raid.requestRoll{value: ENTROPY_FEE - 1}(raidId);
        assertEq(raid.rollRequestedAt(raidId), 0, "an underfunded draw stamped the roll clock");
    }

    /// A word arriving after a reclaim can never resurrect the raid.
    function test_Reclaim_LateWordCannotSettle() public {
        _bobExposedAndAway(PAPER_ROUTE, bytes32(0));
        uint64 raidId = _commitAndReveal(bobDon);
        uint64 seq = oracle.lastSeq();
        vm.warp(block.timestamp + 2 hours);
        raid.reclaimRaid(raidId);

        vm.expectRevert(RaidEngine.AlreadyDelivered.selector);
        oracle.fulfill(seq, bytes32(uint256(1)));
        assertEq(_word(raidId), bytes32(0), "a rejected delivery must not write the word");
    }

}
