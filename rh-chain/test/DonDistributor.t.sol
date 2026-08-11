// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Don} from "../src/market/Don.sol";
import {DonDistributor} from "../src/market/DonDistributor.sol";
import {Bell, ISeatLike} from "../src/market/Bell.sol";
import {IConverter} from "../src/market/IConverter.sol";

/// A sink that refuses ETH — used to prove a broken sink halts the fee split loudly.
contract RevertingSink {
    receive() external payable {
        revert("no thanks");
    }
}

/// Tries to reenter the distributor from the _safeMint callback of its own custom mint.
contract ReentrantMinter is IERC721Receiver {
    DonDistributor immutable dist;
    uint256 immutable fee;
    bool armed;

    constructor(DonDistributor dist_, uint256 fee_) payable {
        dist = dist_;
        fee = fee_;
    }

    function attack(bytes32 combo) external {
        armed = true;
        dist.mintCustom{value: fee}(combo);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (armed) {
            armed = false;
            dist.mintCustom{value: fee}(keccak256("reenter")); // must be blocked by the guard
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract DonDistributorTest is Test {
    Don don;
    DonDistributor dist;

    address admin = address(this);
    address feeSink = address(0x51CC);
    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    uint256 constant CAP = 20;
    uint256 constant RESERVE_CAP = 5;
    uint256 constant TIMELOCK = 2 days;
    uint256 constant REROLL_FEE = 0.001 ether;
    uint256 constant CUSTOM_FEE = 0.003 ether;
    uint256 constant STAGE = 0;

    bytes32 aliceLeaf;
    bytes32 bobLeaf;
    bytes32 root;

    bytes32 constant C1 = keccak256("combo-1");
    bytes32 constant C2 = keccak256("combo-2");
    bytes32 constant C3 = keccak256("combo-3");

    function setUp() public {
        dist = new DonDistributor(admin, RESERVE_CAP, TIMELOCK, REROLL_FEE, CUSTOM_FEE, 0);
        don = new Don("Essey Don", "DON", CAP, address(dist), treasury, 500);
        dist.initDon(don);
        dist.setFeeSink(feeSink);

        aliceLeaf = dist.leafOf(alice, STAGE, 2);
        bobLeaf = dist.leafOf(bob, STAGE, 1);
        root = _pair(aliceLeaf, bobLeaf);
        _commitRoot(STAGE, root);
        dist.setStageOpen(STAGE, true);

        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(carol, 1 ether);
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _commitRoot(uint256 stage, bytes32 r) internal {
        dist.proposeRoot(stage, r);
        vm.warp(block.timestamp + TIMELOCK);
        dist.commitRoot(stage);
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function _combos2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory c) {
        c = new bytes32[](2);
        c[0] = a;
        c[1] = b;
    }

    function _combos1(bytes32 a) internal pure returns (bytes32[] memory c) {
        c = new bytes32[](1);
        c[0] = a;
    }

    function _aliceClaims() internal returns (uint256 firstId) {
        vm.prank(alice);
        firstId = dist.claimWL(STAGE, 2, _proof(bobLeaf), _combos2(C1, C2));
    }

    // ---------------------------------------------------------------- wiring

    function test_DeployOrderLock() public {
        assertEq(don.minter(), address(dist), "distributor is the Don's immutable minter");
        vm.expectRevert(DonDistributor.DonAlreadySet.selector);
        dist.initDon(don);

        DonDistributor other = new DonDistributor(admin, RESERVE_CAP, TIMELOCK, REROLL_FEE, CUSTOM_FEE, 0);
        vm.expectRevert(DonDistributor.NotMinterOfDon.selector);
        other.initDon(don); // don's minter is `dist`, not `other`
    }

    function test_ConstructorGuards() public {
        vm.expectRevert(DonDistributor.ZeroAddress.selector);
        new DonDistributor(address(0), RESERVE_CAP, TIMELOCK, REROLL_FEE, CUSTOM_FEE, 0);
        vm.expectRevert(DonDistributor.ZeroTimelock.selector);
        new DonDistributor(admin, RESERVE_CAP, 0, REROLL_FEE, CUSTOM_FEE, 0);
        vm.expectRevert(DonDistributor.BadSplit.selector);
        new DonDistributor(admin, RESERVE_CAP, TIMELOCK, REROLL_FEE, CUSTOM_FEE, 10_001);
    }

    // ---------------------------------------------------------------- free WL claim

    function test_ClaimWLMintsAllocationWithCombos() public {
        uint256 first = _aliceClaims();
        assertEq(first, 1);
        assertEq(don.ownerOf(1), alice);
        assertEq(don.ownerOf(2), alice);
        assertEq(don.traits(1), C1);
        assertEq(don.traits(2), C2);
        assertTrue(dist.usedCombo(C1));
        assertTrue(dist.usedCombo(C2));
        assertEq(dist.comboOf(1), C1);
        assertTrue(dist.claimed(STAGE, alice));
    }

    function test_ClaimWLGates() public {
        // combos length must equal the attested allocation
        vm.prank(alice);
        vm.expectRevert(DonDistributor.AllocationMismatch.selector);
        dist.claimWL(STAGE, 2, _proof(bobLeaf), _combos1(C1));

        // wrong allocation breaks the proof (combos padded to match, so the length gate passes)
        bytes32[] memory three = new bytes32[](3);
        three[0] = C1;
        three[1] = C2;
        three[2] = C3;
        vm.prank(alice);
        vm.expectRevert(DonDistributor.BadProof.selector);
        dist.claimWL(STAGE, 3, _proof(bobLeaf), three);

        // someone else can't claim alice's leaf
        vm.prank(carol);
        vm.expectRevert(DonDistributor.BadProof.selector);
        dist.claimWL(STAGE, 2, _proof(bobLeaf), _combos2(C1, C2));

        // closed stage
        dist.setStageOpen(STAGE, false);
        vm.prank(alice);
        vm.expectRevert(DonDistributor.StageClosed.selector);
        dist.claimWL(STAGE, 2, _proof(bobLeaf), _combos2(C1, C2));
        dist.setStageOpen(STAGE, true);

        // once per (stage, account)
        _aliceClaims();
        vm.prank(alice);
        vm.expectRevert(DonDistributor.AlreadyClaimed.selector);
        dist.claimWL(STAGE, 2, _proof(bobLeaf), _combos2(keccak256("x"), keccak256("y")));
    }

    /// Duplicate combos INSIDE one claim are caught by the ledger — the second _take reverts.
    function test_ClaimWLRejectsDuplicateCombosInOneCall() public {
        vm.prank(alice);
        vm.expectRevert(DonDistributor.ComboTaken.selector);
        dist.claimWL(STAGE, 2, _proof(bobLeaf), _combos2(C1, C1));
    }

    /// Cross-path collision: a WL claim whose combo was already custom-minted reverts whole. (This is the
    /// documented griefing surface — the victim retries with fresh combos; no funds are lost.)
    function test_ClaimWLCollidesWithCustomMint() public {
        dist.setPublicOpen(true);
        vm.prank(carol);
        dist.mintCustom{value: CUSTOM_FEE}(C1); // carol grabs C1 first

        vm.prank(alice);
        vm.expectRevert(DonDistributor.ComboTaken.selector);
        dist.claimWL(STAGE, 2, _proof(bobLeaf), _combos2(C1, C2));

        // retry with a fresh combo succeeds — the claim itself was not consumed
        vm.prank(alice);
        dist.claimWL(STAGE, 2, _proof(bobLeaf), _combos2(C3, C2));
        assertEq(don.ownerOf(2), alice);
    }

    // ---------------------------------------------------------------- reroll

    function test_RerollSwapsComboAndReleasesOld() public {
        _aliceClaims(); // alice holds #1 (C1), #2 (C2)

        vm.prank(alice);
        dist.reroll{value: REROLL_FEE}(1, C3);
        assertEq(don.traits(1), C3);
        assertEq(dist.comboOf(1), C3);
        assertTrue(dist.usedCombo(C3));
        assertFalse(dist.usedCombo(C1), "old combo released for anyone to take");
        assertEq(feeSink.balance, REROLL_FEE, "teamBps 0 -> 100% of the fee to the stock sink");
    }

    function test_RerollGates() public {
        _aliceClaims();

        vm.prank(bob);
        vm.expectRevert(DonDistributor.NotOwner.selector);
        dist.reroll{value: REROLL_FEE}(1, C3);

        vm.prank(alice);
        vm.expectRevert(DonDistributor.WrongFee.selector);
        dist.reroll{value: REROLL_FEE - 1}(1, C3);

        // rerolling INTO a combo someone holds reverts — including your own current combo
        vm.prank(alice);
        vm.expectRevert(DonDistributor.ComboTaken.selector);
        dist.reroll{value: REROLL_FEE}(1, C2);
        vm.prank(alice);
        vm.expectRevert(DonDistributor.ComboTaken.selector);
        dist.reroll{value: REROLL_FEE}(1, C1); // no self-release loophole: take runs before release
    }

    /// THE double-mint ledger invariant: across claim + reroll + custom churn, every live Don holds a
    /// distinct combo, every held combo is marked used, and every released combo is genuinely free.
    function test_UniquenessLedgerSurvivesRerollChurn() public {
        _aliceClaims(); // #1=C1, #2=C2
        dist.setPublicOpen(true);

        vm.prank(alice);
        dist.reroll{value: REROLL_FEE}(1, C3); // C1 released

        vm.prank(carol);
        uint256 carols = dist.mintCustom{value: CUSTOM_FEE}(C1); // released combo re-minted — INTENDED
        assertEq(don.traits(carols), C1);

        vm.prank(alice);
        vm.expectRevert(DonDistributor.ComboTaken.selector);
        dist.reroll{value: REROLL_FEE}(1, C1); // can't roll back onto carol's combo

        // ledger exact: each live token's combo unique + used
        uint256 n = don.totalMinted();
        for (uint256 i = 1; i <= n; i++) {
            bytes32 ci = dist.comboOf(i);
            assertTrue(dist.usedCombo(ci), "every held combo marked used");
            for (uint256 j = i + 1; j <= n; j++) {
                assertTrue(ci != dist.comboOf(j), "no two Dons share a combo");
            }
        }
    }

    // ---------------------------------------------------------------- custom mint

    function test_MintCustomGatesAndFee() public {
        vm.prank(carol);
        vm.expectRevert(DonDistributor.PublicClosed.selector);
        dist.mintCustom{value: CUSTOM_FEE}(C1);

        dist.setPublicOpen(true);
        vm.prank(carol);
        vm.expectRevert(DonDistributor.WrongFee.selector);
        dist.mintCustom{value: CUSTOM_FEE + 1}(C1);

        vm.prank(carol);
        uint256 id = dist.mintCustom{value: CUSTOM_FEE}(C1);
        assertEq(don.ownerOf(id), carol);
        assertEq(don.traits(id), C1);
        assertEq(feeSink.balance, CUSTOM_FEE);

        vm.prank(bob);
        vm.expectRevert(DonDistributor.ComboTaken.selector);
        dist.mintCustom{value: CUSTOM_FEE}(C1); // exact-combo double mint impossible
    }

    function test_ReentrancyBlockedOnMintCustom() public {
        dist.setPublicOpen(true);
        ReentrantMinter attacker = new ReentrantMinter{value: 1 ether}(dist, CUSTOM_FEE);
        vm.expectRevert(); // inner call trips the guard, unwinding the whole mint
        attacker.attack(C1);
        assertEq(don.totalMinted(), 0, "nothing minted through the reentrant path");
        assertFalse(dist.usedCombo(C1));
    }

    // ---------------------------------------------------------------- fee split

    function test_TeamSplitRoutesBothWays() public {
        dist.setPublicOpen(true);
        dist.setTeamBps(4000);
        vm.expectRevert(DonDistributor.BadSplit.selector);
        dist.setTeamBps(10_001);

        // teamBps set but treasury unwired -> loud failure, not silent misroute
        vm.prank(carol);
        vm.expectRevert(DonDistributor.SinksUnset.selector);
        dist.mintCustom{value: CUSTOM_FEE}(C1);

        dist.setTreasury(treasury);
        vm.prank(carol);
        dist.mintCustom{value: CUSTOM_FEE}(C1);
        assertEq(treasury.balance, (CUSTOM_FEE * 4000) / 10_000, "40% team");
        assertEq(feeSink.balance, CUSTOM_FEE - treasury.balance, "60% stock");
    }

    function test_RevertingSinkHaltsMint() public {
        DonDistributor d2 = new DonDistributor(admin, RESERVE_CAP, TIMELOCK, REROLL_FEE, CUSTOM_FEE, 0);
        Don don2 = new Don("D", "D", CAP, address(d2), treasury, 500);
        d2.initDon(don2);
        d2.setFeeSink(address(new RevertingSink()));
        d2.setPublicOpen(true);
        vm.prank(carol);
        vm.expectRevert(DonDistributor.TransferFailed.selector);
        d2.mintCustom{value: CUSTOM_FEE}(C1);
    }

    // ---------------------------------------------------------------- roots (timelocked)

    function test_RootTimelockLifecycle() public {
        bytes32 newRoot = keccak256("new root");
        vm.expectRevert(DonDistributor.NothingPending.selector);
        dist.commitRoot(1);

        dist.proposeRoot(1, newRoot);
        vm.expectRevert(DonDistributor.TimelockNotElapsed.selector);
        dist.commitRoot(1);

        vm.warp(block.timestamp + TIMELOCK);
        dist.commitRoot(1);
        assertEq(dist.stageRoot(1), newRoot);
        assertEq(dist.pendingEta(1), 0, "pending slot cleared");

        vm.prank(alice);
        vm.expectRevert(DonDistributor.NotAdmin.selector);
        dist.proposeRoot(1, newRoot);
    }

    // ---------------------------------------------------------------- reserve

    function test_ReserveCapBoundsAdminMints() public {
        bytes32[] memory combos = new bytes32[](RESERVE_CAP);
        for (uint256 i = 0; i < RESERVE_CAP; i++) combos[i] = keccak256(abi.encode("r", i));
        dist.mintReserved(bob, combos);
        assertEq(don.totalMinted(), RESERVE_CAP);
        assertEq(dist.reserveRemaining(), 0);

        vm.expectRevert(DonDistributor.ReserveCapExceeded.selector);
        dist.mintReserved(bob, _combos1(keccak256("over")));

        vm.prank(alice);
        vm.expectRevert(DonDistributor.NotAdmin.selector);
        dist.mintReserved(alice, _combos1(keccak256("nope")));
    }

    // ---------------------------------------------------------------- lockOnStake (art-lock)

    function _wireBell() internal returns (Bell bell) {
        ERC20Mock essey = new ERC20Mock();
        uint256[] memory tierFees = new uint256[](1);
        tierFees[0] = 100e18;
        uint256[] memory tierWeights = new uint256[](1);
        tierWeights[0] = 100;
        bell = new Bell(
            ISeatLike(address(don)), essey, new ERC20Mock(), treasury, 1e18, 0, tierFees, tierWeights,
            IConverter(address(0)), address(0)
        );
        dist.setDonHook(address(bell));
        dist.setBell(address(bell));
        essey.mint(alice, 1000e18);
        essey.mint(bob, 1000e18);
        vm.prank(alice);
        essey.approve(address(bell), type(uint256).max);
        vm.prank(bob);
        essey.approve(address(bell), type(uint256).max);
    }

    function test_LockOnStakeRequiresActivation() public {
        _aliceClaims();
        vm.expectRevert(DonDistributor.BellUnset.selector);
        dist.lockOnStake(1);

        Bell bell = _wireBell();
        vm.expectRevert(DonDistributor.NotStaked.selector);
        dist.lockOnStake(1); // not activated — nobody can force-lock someone's art

        vm.prank(alice);
        bell.activate(1, 1);

        // The reroll gate closes the instant the Don activates - BEFORE lockOnStake finalizes the
        // on-chain lock - so "staking locks the art" holds with no keeper-timing window.
        vm.prank(alice);
        vm.expectRevert(DonDistributor.StakedNoReroll.selector);
        dist.reroll{value: REROLL_FEE}(1, C3);

        dist.lockOnStake(1); // permissionless once the condition is on-chain
        assertTrue(don.locked(1), "staking locked the art");

        vm.prank(alice);
        vm.expectRevert(DonDistributor.StakedNoReroll.selector);
        dist.reroll{value: REROLL_FEE}(1, C3); // still staked -> still blocked (before Don's own lock even matters)
    }

    function test_SetBellIsOneShot() public {
        Bell bell = _wireBell(); // sets bell once
        vm.expectRevert(DonDistributor.BellAlreadySet.selector);
        dist.setBell(address(bell)); // cannot be re-pointed at a fake Bell to force-lock unstaked Dons

        // regression: a Don with no Bell wired yet can still be rerolled freely
        DonDistributor d2 = new DonDistributor(admin, RESERVE_CAP, TIMELOCK, REROLL_FEE, CUSTOM_FEE, 0);
        Don don2 = new Don("D", "D", CAP, address(d2), treasury, 500);
        d2.initDon(don2);
        d2.setFeeSink(feeSink);
        d2.setPublicOpen(true);
        uint256 id = don2.totalMinted() + 1; // view first — don't let it consume the prank
        vm.prank(carol);
        d2.mintCustom{value: CUSTOM_FEE}(keccak256(abi.encode("pre-bell", id)));
        vm.prank(carol);
        d2.reroll{value: REROLL_FEE}(id, keccak256("post")); // bell unset -> reroll unaffected
    }

    /// Regression: transfer clears the tier but NOT the lock; the buyer re-activates and a second
    /// lockOnStake is a harmless no-op — nothing bricks.
    function test_LockSurvivesTransferAndRelockIsNoop() public {
        _aliceClaims();
        Bell bell = _wireBell();
        vm.prank(alice);
        bell.activate(1, 1);
        dist.lockOnStake(1);

        vm.prank(alice);
        don.transferFrom(alice, bob, 1); // hook clears the tier
        (uint8 tier,,,) = bell.seats(1);
        assertEq(tier, 0);
        assertTrue(don.locked(1), "one-way lock survives the transfer");

        vm.prank(bob);
        bell.activate(1, 1); // re-activation must not brick on the existing lock
        dist.lockOnStake(1); // idempotent no-op
        assertTrue(don.locked(1));
    }

    // ---------------------------------------------------------------- admin config

    function test_AdminOnlyConfig() public {
        vm.startPrank(alice);
        vm.expectRevert(DonDistributor.NotAdmin.selector);
        dist.setFees(1, 2);
        vm.expectRevert(DonDistributor.NotAdmin.selector);
        dist.setFeeSink(alice);
        vm.expectRevert(DonDistributor.NotAdmin.selector);
        dist.setPublicOpen(true);
        vm.expectRevert(DonDistributor.NotAdmin.selector);
        dist.setBell(alice);
        vm.stopPrank();

        dist.setFees(1 wei, 2 wei);
        assertEq(dist.rerollFee(), 1 wei);
        assertEq(dist.customFee(), 2 wei);
    }

    // ---------------------------------------------------------------- marketplace passthroughs

    /// Royalty re-point flows admin -> distributor -> Don (the immutable minter). Non-admin is rejected at
    /// the distributor, and the Don caps the rate at its 10% ceiling.
    function test_SetDonRoyaltyPassthrough() public {
        dist.setDonRoyalty(bob, 300);
        (address receiver, uint256 amount) = don.royaltyInfo(1, 10_000);
        assertEq(receiver, bob, "receiver re-pointed via the passthrough");
        assertEq(amount, 300, "3% of 10000");

        vm.prank(alice);
        vm.expectRevert(DonDistributor.NotAdmin.selector);
        dist.setDonRoyalty(alice, 100);

        vm.expectRevert(Don.BadRoyalty.selector);
        dist.setDonRoyalty(bob, 1001); // Don caps at 10%
    }

    /// Collection metadata rotates admin -> distributor -> Don, emitting the ERC-7572 signal; non-admin rejected.
    function test_SetDonContractURIPassthrough() public {
        assertEq(don.contractURI(), "", "empty until set");

        vm.expectEmit(false, false, false, false, address(don));
        emit Don.ContractURIUpdated();
        dist.setDonContractURI("ipfs://dons-collection");
        assertEq(don.contractURI(), "ipfs://dons-collection");

        vm.prank(alice);
        vm.expectRevert(DonDistributor.NotAdmin.selector);
        dist.setDonContractURI("ipfs://evil");
    }
}
