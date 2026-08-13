// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Deploy the D.O.N. Skirmish Phase-0 game stack (Scrip-only) against the LIVE testnet Dons stack.
//
//   DON=0x582E4B8E3A783B1FE09409AEDa3C6533782dB53c \
//   KEEPER=0x... \
//   forge script script/DeployGame.s.sol --rpc-url rh_testnet \
//     --private-key $TESTNET_DEPLOYER_PK --broadcast --gas-estimate-multiplier 300
//
// (The coordinator broadcasts; --gas-estimate-multiplier 300 is deploy-checklist law on this chain —
// CREATEs whose constructors make external calls under-estimate.)
//
// Env:
//   DON              — the Don ERC721 (default: live testnet v3 Don)
//   KEEPER           — resolve/attest/garrison-reveal operator (default: deployer)
//   GAME_ADMIN       — GameController admin (default: deployer; multisig in production)
//   ENTROPY          — real Dice on mainnet (0xd8a0…0a0c); unset => deploy MockEntropy (testnet)
//   ENTROPY_PROVIDER — provider address (default 0xDACE, the Degen testnet convention)
//   MISSION_BUDGET / YIELD_BUDGET / STIPEND_BUDGET — Scrip emission lines (S_declared; defaults below)
//
// Seeds the 4 Phase-0 briefs (one per duration tier, lore codenames), wires all roles, funds the
// budgets, and SEALS the controller (all later re-points go through the 2-day timelock).
import {Script, console} from "forge-std/Script.sol";
import {IEntropy} from "../src/market/EsseyCasesDegen.sol";
import {MockEntropy} from "../src/testnet/MockEntropy.sol";
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

contract DeployGame is Script {
    uint32 constant CALLBACK_GAS = 200_000; // the Degen deploy convention

    // Script state (not locals) — keeps run() off the legacy pipeline's stack ceiling.
    address donAddr;
    address entropy;
    address provider;
    GameController controller;
    Scrip scrip;
    HouseDeed deed;
    HouseEscrow escrow;
    MissionBoard board;
    HitterNFT hitter;
    RaidEngine raid;

    function run() external {
        donAddr = vm.envOr("DON", address(0x582E4B8E3A783B1FE09409AEDa3C6533782dB53c));
        address keeper = vm.envOr("KEEPER", msg.sender);

        vm.startBroadcast();

        // Entropy: real Dice on mainnet, else the testnet MockEntropy keeper (Degen pattern).
        entropy = vm.envOr("ENTROPY", address(0));
        provider = vm.envOr("ENTROPY_PROVIDER", address(0xDACE));
        if (entropy == address(0)) {
            entropy = address(new MockEntropy(0.000025 ether, provider));
        }

        _deployCore();

        // Wire the fixed role list (OUTFIT_MODULE + SEASON_MODULE stay reserved/empty per A14).
        controller.setModule(GameRoles.MISSION_MODULE, address(board));
        controller.setModule(GameRoles.RAID_MODULE, address(raid));
        controller.setModule(GameRoles.HOUSE_MODULE, address(escrow));
        controller.setModule(GameRoles.DEED_MODULE, address(deed));
        controller.setModule(GameRoles.HITTER_MODULE, address(hitter));
        controller.setModule(GameRoles.KEEPER, keeper);

        // Fund the emission lines (the visible S_declared events) + seed the launch board.
        // NOTE: budget funding + brief posting are admin-only, so this script assumes
        // GAME_ADMIN == deployer for the initial assembly (the default).
        board.fundMissionBudget(vm.envOr("MISSION_BUDGET", uint256(1_000_000e18)));
        escrow.fundYieldBudget(vm.envOr("YIELD_BUDGET", uint256(500_000e18)));
        escrow.fundStipendBudget(vm.envOr("STIPEND_BUDGET", uint256(50_000e18))); // 1,000 first plays
        _seedBriefs(board);

        // End of assembly: every later re-point takes the 2-day public timelock.
        controller.seal();

        vm.stopBroadcast();

        console.log("GameController ", address(controller));
        console.log("Scrip          ", address(scrip));
        console.log("HouseDeed      ", address(deed));
        console.log("HouseEscrow    ", address(escrow));
        console.log("MissionBoard   ", address(board));
        console.log("RaidEngine     ", address(raid));
        console.log("HitterNFT      ", address(hitter));
        console.log("Entropy        ", entropy);
        console.log("Keeper         ", keeper);
    }

    function _deployCore() internal {
        controller = new GameController(vm.envOr("GAME_ADMIN", msg.sender));
        scrip = new Scrip(IGameController(address(controller)));
        deed = new HouseDeed(IGameController(address(controller)), IDonLike(donAddr), IScrip(address(scrip)));
        escrow = new HouseEscrow(
            IGameController(address(controller)),
            IScrip(address(scrip)),
            IDonLike(donAddr),
            IHouseDeed(address(deed))
        );
        board = new MissionBoard(
            IGameController(address(controller)),
            IScrip(address(scrip)),
            IDonLike(donAddr),
            IHouseEscrow(address(escrow)),
            IEntropy(entropy),
            provider,
            CALLBACK_GAS
        );
        hitter = new HitterNFT(
            IGameController(address(controller)),
            IScrip(address(scrip)),
            IDonLike(donAddr),
            IEntropy(entropy),
            provider,
            CALLBACK_GAS
        );
        raid = new RaidEngine(
            IGameController(address(controller)),
            IScrip(address(scrip)),
            IDonLike(donAddr),
            IHouseDeed(address(deed)),
            IHouseEscrow(address(escrow)),
            IMissionBoard(address(board)),
            IHitterGame(address(hitter)),
            IEntropy(entropy),
            provider,
            CALLBACK_GAS
        );
    }

    /// The Phase-0 board: 4 permanent rows, one per duration tier, with fixed disclosed
    /// odds and lore codenames. betaBps carries the full 90%
    /// marginal-RTP provisioning return on the payout leg (the Phase-0 fold of the odds-shift).
    function _seedBriefs(MissionBoard board_) internal {
        // T1 "Errand" — PAPER ROUTE (Treasury Run, SGOV, 3h): 78/15/7, pays 36 / 14.4 Scrip.
        board_.postBrief("PAPER ROUTE", 1, 3 hours, 780_000, 930_000, 36e18, 14.4e18, 0.45e18, 15e18, 11_538);
        // T2 "Job" — GLASS HARVEST · RUSH (Chip-Fab, NVDA, 5h): 70/18/12, pays 75 / 30 Scrip.
        board_.postBrief("GLASS HARVEST - RUSH", 2, 5 hours, 700_000, 880_000, 75e18, 30e18, 0.87e18, 30e18, 12_857);
        // T3 "Score" — PROOF OF WORK (The Rig, CLSK, 12h): 60/22/18, pays 236 / 94.4 Scrip.
        board_.postBrief("PROOF OF WORK", 3, 12 hours, 600_000, 820_000, 236e18, 94.4e18, 2.44e18, 80e18, 15_000);
        // T4 "Long Con" — ABSOLUTE ZERO (Quantum Grab, IONQ, 24h lottery): 12/23/65,
        // jackpot 2,775 / consolation 222 Scrip (the lottery shape, jackpot = 7.2x EV).
        board_.postBrief("ABSOLUTE ZERO", 4, 24 hours, 120_000, 350_000, 2_775e18, 222e18, 5.76e18, 200e18, 75_000);
    }
}
