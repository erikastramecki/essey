// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IEntropy} from "../src/market/EsseyCasesDegen.sol";
import {GameController} from "../src/game/GameController.sol";
import {Scrip} from "../src/game/Scrip.sol";
import {HouseDeed} from "../src/game/HouseDeed.sol";
import {HouseEscrow} from "../src/game/HouseEscrow.sol";
import {MissionBoard} from "../src/game/MissionBoard.sol";
import {RaidEngine} from "../src/game/RaidEngine.sol";
import {HitterNFT} from "../src/game/HitterNFT.sol";
import {
    IDonLike,
    IGameController,
    IScrip,
    IHouseDeed,
    IHouseEscrow,
    IMissionBoard,
    IHitterGame,
    GameRoles
} from "../src/game/GameTypes.sol";

/// Minimal Don stand-in: ownerOf + deterministic vaultOf (the two things the game reads). Vaults are
/// plain addresses — Scrip is a ledger, so any address holds a balance.
contract MockDon {
    uint256 public nextId;
    mapping(uint256 => address) internal _owner;

    function mint(address to) external returns (uint256 id) {
        id = ++nextId;
        _owner[id] = to;
    }

    /// True-transfer stand-in (tests the stale-signature-dies-on-transfer property).
    function transfer(uint256 id, address to) external {
        _owner[id] = to;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _owner[id];
    }

    function vaultOf(uint256 id) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("don-vault", id)))));
    }
}

interface IEntropyConsumerLike {
    function _entropyCallback(uint64 sequenceNumber, address provider, bytes32 randomNumber) external;
}

/// Dice/Pyth-compatible entropy mock (the Degen test idiom): `fulfill` drives the consumer through
/// the real external `_entropyCallback` dispatch path with a CHOSEN word.
contract MockGameEntropy is IEntropy {
    uint64 public nextSeq = 1;
    uint256 public fee;
    mapping(uint64 => address) public consumerOf;

    constructor(uint256 fee_) {
        fee = fee_;
    }

    function getFeeV2(address, uint32) external view returns (uint256) {
        return fee;
    }

    function requestV2(address, bytes32, uint32) external payable returns (uint64 seq) {
        seq = nextSeq++;
        consumerOf[seq] = msg.sender;
    }

    function lastSeq() external view returns (uint64) {
        return nextSeq - 1;
    }

    function fulfill(uint64 seq, bytes32 random) external {
        IEntropyConsumerLike(consumerOf[seq])._entropyCallback(seq, address(0), random);
    }
}

/// Shared Phase-0 stack harness. No test functions here — concrete suites inherit.
abstract contract GameBase is Test {
    uint256 constant START_TS = 1_760_000_000;
    uint256 constant ENTROPY_FEE = 0.000025 ether;
    uint256 constant PPM = 1_000_000;

    GameController controller;
    Scrip scrip;
    HouseDeed deed;
    HouseEscrow escrow;
    MissionBoard board;
    RaidEngine raid;
    HitterNFT hitter;
    MockDon don;
    MockGameEntropy oracle;

    address keeper = address(0xC0FFEE);

    // Two players with signing keys (loadouts are EIP-712 signed).
    uint256 alicePk = 0xA11CE;
    uint256 bobPk = 0xB0B;
    address alice;
    address bob;
    uint256 aliceDon;
    uint256 bobDon;

    // Brief ids as seeded (1-based).
    uint64 constant PAPER_ROUTE = 1; // T1 3h
    uint64 constant GLASS_HARVEST = 2; // T2 5h
    uint64 constant PROOF_OF_WORK = 3; // T3 12h
    uint64 constant ABSOLUTE_ZERO = 4; // T4 24h

    function setUp() public virtual {
        vm.warp(START_TS);
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(keeper, 10 ether);

        don = new MockDon();
        oracle = new MockGameEntropy(ENTROPY_FEE);
        controller = new GameController(address(this));
        scrip = new Scrip(IGameController(address(controller)));
        deed = new HouseDeed(IGameController(address(controller)), IDonLike(address(don)), IScrip(address(scrip)));
        escrow = new HouseEscrow(
            IGameController(address(controller)),
            IScrip(address(scrip)),
            IDonLike(address(don)),
            IHouseDeed(address(deed))
        );
        board = new MissionBoard(
            IGameController(address(controller)),
            IScrip(address(scrip)),
            IDonLike(address(don)),
            IHouseEscrow(address(escrow)),
            IEntropy(address(oracle)),
            address(0xDACE),
            200_000
        );
        hitter = new HitterNFT(
            IGameController(address(controller)),
            IScrip(address(scrip)),
            IDonLike(address(don)),
            IEntropy(address(oracle)),
            address(0xDACE),
            200_000
        );
        raid = new RaidEngine(
            IGameController(address(controller)),
            IScrip(address(scrip)),
            IDonLike(address(don)),
            IHouseDeed(address(deed)),
            IHouseEscrow(address(escrow)),
            IMissionBoard(address(board)),
            IHitterGame(address(hitter)),
            IEntropy(address(oracle)),
            address(0xDACE),
            200_000
        );

        controller.setModule(GameRoles.MISSION_MODULE, address(board));
        controller.setModule(GameRoles.RAID_MODULE, address(raid));
        controller.setModule(GameRoles.HOUSE_MODULE, address(escrow));
        controller.setModule(GameRoles.DEED_MODULE, address(deed));
        controller.setModule(GameRoles.HITTER_MODULE, address(hitter));
        controller.setModule(GameRoles.KEEPER, keeper);

        board.fundMissionBudget(1_000_000e18);
        escrow.fundYieldBudget(500_000e18);
        escrow.fundStipendBudget(50_000e18);
        _seedBriefs();

        aliceDon = don.mint(alice);
        bobDon = don.mint(bob);
    }

    function _seedBriefs() internal {
        board.postBrief("PAPER ROUTE", 1, 3 hours, 780_000, 930_000, 36e18, 14.4e18, 0.45e18, 15e18, 11_538);
        board.postBrief("GLASS HARVEST - RUSH", 2, 5 hours, 700_000, 880_000, 75e18, 30e18, 0.87e18, 30e18, 12_857);
        board.postBrief("PROOF OF WORK", 3, 12 hours, 600_000, 820_000, 236e18, 94.4e18, 2.44e18, 80e18, 15_000);
        board.postBrief("ABSOLUTE ZERO", 4, 24 hours, 120_000, 350_000, 2_775e18, 222e18, 5.76e18, 200e18, 75_000);
    }

    // ---------------------------------------------------------------- helpers

    /// Mint Scrip straight to an account by impersonating a registered module (test-only shortcut).
    function _grantScrip(address to, uint256 amount) internal {
        vm.prank(address(board));
        scrip.mint(to, amount);
    }

    function _sign(uint256 pk, MissionBoard.Loadout memory l) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                board.LOADOUT_TYPEHASH(), l.donId, l.briefId, l.provision, l.garrisonHash, l.nonce, l.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", board.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _loadout(uint256 donId, uint64 briefId, uint256 provision, bytes32 garrisonHash)
        internal
        view
        returns (MissionBoard.Loadout memory)
    {
        return MissionBoard.Loadout({
            donId: donId,
            briefId: briefId,
            provision: provision,
            garrisonHash: garrisonHash,
            nonce: board.lastSettledNonce(donId) + 1,
            deadline: block.timestamp + 1 days
        });
    }

    /// Sign + depart in one step (submitted by the owner, though anyone could relay).
    function _depart(uint256 pk, uint256 donId, uint64 briefId, uint256 provision, bytes32 garrisonHash)
        internal
        returns (uint64 missionId)
    {
        MissionBoard.Loadout memory l = _loadout(donId, briefId, provision, garrisonHash);
        bytes memory sig = _sign(pk, l);
        vm.prank(vm.addr(pk));
        missionId = board.depart(l, sig);
    }

    /// Warp past due, request the roll, and deliver a chosen word.
    function _resolveWith(uint64 missionId, uint256 word) internal {
        (,,, uint64 due,,,,,) = board.missions(missionId);
        if (block.timestamp < due) vm.warp(due);
        vm.prank(keeper);
        board.resolve{value: ENTROPY_FEE}(missionId);
        oracle.fulfill(oracle.lastSeq(), bytes32(word));
    }

    /// Run a full successful T1 mission for `donId` so loot lands in the hopper (word 0 < 780000).
    function _earnHopper(uint256 pk, uint256 donId) internal returns (uint256 hopperAmount) {
        uint64 m = _depart(pk, donId, PAPER_ROUTE, 0, bytes32(0));
        uint256 before = escrow.hopperOf(donId);
        _resolveWith(m, 0);
        hopperAmount = escrow.hopperOf(donId) - before;
    }

    // -------- raid word engineering: recompute the engine's partitions and search for a word

    function _tierRoll(uint256 word) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(word, uint8(1)))) % PPM;
    }

    function _uRoll(uint256 word) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(word, uint8(2)))) % PPM;
    }

    function _killRoll(uint256 word, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(word, uint8(100), i))) % PPM;
    }

    /// Find a word producing the wanted (hit, big) shape at hit-probability pPpm.
    /// Misses: any word whose PPM residue clears the 70% p_hit ceiling. Hits: small residues,
    /// scanned until the second-band partition matches.
    function _findRaidWord(uint256 pPpm, bool wantHit, bool wantBig) internal pure returns (uint256) {
        if (!wantHit) return 999_999; // >= P_MAX (700000) — always a miss
        for (uint256 w = 1; w < 50_000 && w < pPpm; w++) {
            if ((_tierRoll(w) >= 920_000) == wantBig) return w;
        }
        revert("no word found");
    }

    /// Find a certain-miss word whose slot-0 kill partition lands the wanted way.
    function _findMissWord(uint256 pKillPpm, bool wantKill) internal pure returns (uint256) {
        for (uint256 j = 0; j < 5_000; j++) {
            uint256 w = 999_999 + j * PPM; // residue 999999: always a miss
            if ((_killRoll(w, 0) < pKillPpm) == wantKill) return w;
        }
        revert("no miss word found");
    }
}
