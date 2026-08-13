// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GameController} from "../src/game/GameController.sol";
import {Scrip} from "../src/game/Scrip.sol";
import {HouseDeed} from "../src/game/HouseDeed.sol";
import {HouseEscrow} from "../src/game/HouseEscrow.sol";
import {MissionBoard} from "../src/game/MissionBoard.sol";
import {RaidEngine} from "../src/game/RaidEngine.sol";
import {HitterNFT} from "../src/game/HitterNFT.sol";
import {MockEntropy} from "../src/testnet/MockEntropy.sol";
import {Don} from "../src/market/Don.sol";
import {DonDistributor} from "../src/market/DonDistributor.sol";

/// GameE2E — the adversarial wallet harness for the D.O.N. Skirmish Phase-0 game stack on Robinhood
/// Chain testnet (46630). Follows the DonE2E precedent: N ephemeral wallets from a FIXED seed, each
/// funded with a small gas budget, every game flow driven from the RELEVANT wallet as a real user,
/// with on-chain state asserted after each leg.
///
/// UNLIKE DonE2E this stack is TIME-GATED everywhere (mission durations, the [10,40]min raid reveal
/// window, garrison/entropy timeouts), and one forge run cannot span wall-clock time (simulation
/// and broadcast happen back-to-back). The harness is therefore PHASED: each external function is
/// one broadcastable phase, and script/game-e2e.sh sequences them with real sleeps between the
/// gates. Deterministic wallet keys + salts make every phase reconstructible in a fresh process.
///
/// ENTROPY-DIVERGENCE RULE: MockEntropy's word depends on blockhash/timestamp, so the simulated
/// outcome of any fulfill differs from the broadcast outcome. Phases that fulfill entropy therefore
/// assert only outcome-AGNOSTIC state (settled flags, custody invariant); outcome-DEPENDENT checks
/// (payout band, hopper deltas, raid loot/tax) are done post-hoc by the orchestrator from receipts
/// + events + fresh eth_calls against the REAL chain state.
///
/// Two harness briefs (E2E SPRINT 75s / E2E WINDOW 20min) are posted by the game admin in setup():
/// the four launch briefs run 3h-24h, which no live harness can farm. postBrief is an admin power
/// by design (the board is append-only content); the launch briefs are untouched and immutable.
/// The hero first-play flow still runs on launch brief 1 (PAPER ROUTE) and resolves at its real 3h due.
///
/// Time-gated flows a live chain cannot reach (>2h waits: mission reclaim, raid reclaim/floorSettle,
/// the 30-day favor force-reveal) are proven in forkProofs() — a NON-broadcast fork simulation
/// (vm.warp/prank/deal), the DonE2E liquidationFork() precedent. Run WITHOUT --broadcast.
///
/// ENV: TESTNET_DEPLOYER_PK (funder / game admin / keeper — read, NEVER logged).
///      Stack addresses default to the live 2026-08 testnet deploy; overridable per-address.
contract GameE2E is Script {
    // ---- the deployed game stack (env-overridable, defaults = live testnet) ----
    GameController controller;
    Scrip scrip;
    HouseDeed deed;
    HouseEscrow escrow;
    MissionBoard board;
    RaidEngine raid;
    HitterNFT hitter;
    MockEntropy mock;
    Don don;
    DonDistributor dist;

    uint256 deployerPk;
    address deployer;

    // ---- ephemeral actors (fixed seed, reproducible — the DonE2E scheme) ----
    // 0 HERO (launch-brief first play), 1 GRINDER (upgrade + yield + garrison defender),
    // 2 ATTACKER (hitters + raids), 3 TARGETS (owns the raidable Dons), 4 RANDO (negative checks).
    uint256 constant N_WALLETS = 5;
    bytes32 seed;
    uint256[] walletPk;
    address[] wallet;

    // harness brief ids (posted by setup(); asserted by codename before use)
    uint64 constant BRIEF_PAPER_ROUTE = 1;
    uint64 SPRINT; // 75s farm brief
    uint64 WINDOW; // 20min raid-window brief

    uint256 constant PPM = 1_000_000;

    // ================================================================ shared load

    function _load() internal {
        deployerPk = vm.envUint("TESTNET_DEPLOYER_PK");
        deployer = vm.addr(deployerPk);

        controller = GameController(vm.envOr("GAME_CONTROLLER", address(0xe2BEA5db063EA57F73D6bA8294592d7f60CBec9f)));
        scrip = Scrip(vm.envOr("SCRIP", address(0xAE8AEB1E0eA9A6E6A55b469107DD5c7cbf28F1F6)));
        deed = HouseDeed(vm.envOr("HOUSE_DEED", address(0xe180dbda25966Cd6AE372C967200F0EB6D003368)));
        escrow = HouseEscrow(vm.envOr("HOUSE_ESCROW", address(0x869cbc012C37F7655FA5eA8F655E862Aa631C93C)));
        board = MissionBoard(vm.envOr("MISSION_BOARD", address(0xA4839CA4b595c768636E05bF37E32b167e482d99)));
        raid = RaidEngine(vm.envOr("RAID_ENGINE", address(0xf497AAb709952FF061AEC34390Dad281649D1a2a)));
        hitter = HitterNFT(vm.envOr("HITTER_NFT", address(0x219fafE26FB865b8dA4F55EF38ee99a91Ef969Cf)));
        mock = MockEntropy(vm.envOr("GAME_ENTROPY", address(0xc9e6B140C10e6DcDAE7a2d2a9FdD1BB82Ca1F047)));
        don = Don(vm.envOr("DON", address(0x582E4B8E3A783B1FE09409AEDa3C6533782dB53c)));
        dist = DonDistributor(vm.envOr("DISTRIBUTOR", address(0x9F9928E1FDa97f67d54A9E7b7fFedC003C669103)));

        seed = vm.envOr("GAME_E2E_SEED", keccak256("don-game-e2e-v1"));
        for (uint256 i = 0; i < N_WALLETS; i++) {
            uint256 pk = uint256(keccak256(abi.encode(seed, i)));
            if (pk == 0) pk = 1;
            walletPk.push(pk);
            wallet.push(vm.addr(pk));
        }

        // Resolve the harness briefs if already posted (idempotent phases).
        uint64 n = board.briefCount();
        for (uint64 b = 5; b <= n; b++) {
            uint32 dur = _briefDur(b);
            if (dur == 75) SPRINT = b;
            if (dur == 1200) WINDOW = b;
        }
    }

    function _briefDur(uint64 b) internal view returns (uint32 dur) {
        (,, dur,,,,,,,,) = board.briefs(b);
    }

    function _briefPartialPay(uint64 b) internal view returns (uint256 pp) {
        (,,,,,, pp,,,,) = board.briefs(b);
    }

    function _vault(uint256 donId) internal view returns (address) {
        return don.vaultOf(donId);
    }

    function _custody() internal view {
        require(
            scrip.balanceOf(address(escrow)) == escrow.totalDeployed() + escrow.totalHopper(),
            "INVARIANT: escrow custody broken"
        );
    }

    // ================================================================ phase: sweep old E2E wallets
    /// Reclaim residual gas ETH from the 18 DonE2E wallets (fixed seed essey-don-e2e-v1) back to the
    /// deployer — the native budget for this harness. Valueless throwaway keys, rederived not stored.
    function sweepOld() external {
        _load();
        bytes32 oldSeed = keccak256("essey-don-e2e-v1");
        uint256 reclaimed;
        for (uint256 i = 0; i < 18; i++) {
            uint256 pk = uint256(keccak256(abi.encode(oldSeed, i)));
            address a = vm.addr(pk);
            uint256 bal = a.balance;
            if (bal <= 5e12) continue; // dust — not worth a tx
            uint256 send = bal - 2e12; // leave a generous fee buffer
            vm.startBroadcast(pk);
            (bool ok,) = deployer.call{value: send}("");
            require(ok, "SWEEP: send failed");
            vm.stopBroadcast();
            reclaimed += send;
        }
        console.log("[SWEEP] reclaimed wei", reclaimed);
        console.log("[SWEEP] deployer now ", deployer.balance);
    }

    // ================================================================ phase: setup
    /// Deployer: gas-fund the 5 actors + post the two harness briefs (admin, append-only board).
    function setup() external {
        _load();
        uint256[N_WALLETS] memory targetWei =
            [uint256(6e13), uint256(9e13), uint256(26e13), uint256(9e13), uint256(3e13)];

        vm.startBroadcast(deployerPk);
        for (uint256 i = 0; i < N_WALLETS; i++) {
            if (wallet[i].balance < targetWei[i]) {
                (bool ok,) = wallet[i].call{value: targetWei[i] - wallet[i].balance}("");
                require(ok, "SETUP: fund failed");
            }
        }
        if (SPRINT == 0) {
            SPRINT = board.postBrief("E2E SPRINT", 1, 75, 985_000, 999_500, 6_000e18, 2_400e18, 1e18, 0, 0);
        }
        if (WINDOW == 0) {
            WINDOW = board.postBrief("E2E WINDOW", 1, 1200, 985_000, 999_500, 100e18, 40e18, 1e18, 0, 0);
        }
        vm.stopBroadcast();

        console.log("[SETUP] SPRINT brief", SPRINT);
        console.log("[SETUP] WINDOW brief", WINDOW);
        for (uint256 i = 0; i < N_WALLETS; i++) {
            console.log("[SETUP] wallet", i, wallet[i]);
            console.log("        wei   ", wallet[i].balance);
        }
    }

    // ================================================================ phase: mint the cast of Dons
    /// W0 x1 (hero), W1 x1 (grinder/defender), W2 x1 (attacker), W3 x4 (raid targets). Custom mint
    /// via the live distributor (testnet fee = 0). Logs the ids the orchestrator feeds to later phases.
    function mintDons() external {
        _load();
        uint256[N_WALLETS] memory counts = [uint256(1), 1, 1, 4, 0];
        for (uint256 w = 0; w < N_WALLETS; w++) {
            for (uint256 k = 0; k < counts[w]; k++) {
                bytes32 combo = keccak256(abi.encode(seed, "don", w, k));
                vm.startBroadcast(walletPk[w]);
                uint256 id = dist.mintCustom{value: dist.customFee()}(combo);
                vm.stopBroadcast();
                require(don.ownerOf(id) == wallet[w], "MINT: owner mismatch");
                require(_vault(id) != address(0), "MINT: no vault");
                console.log("[MINT] wallet", w);
                console.log("       donId ", id);
            }
        }
    }

    // ================================================================ EIP-712 depart helper

    function _departAs(uint256 w, uint256 donId, uint64 briefId, uint256 provision, bytes32 gHash)
        internal
        returns (uint64 missionId)
    {
        MissionBoard.Loadout memory l = MissionBoard.Loadout({
            donId: donId,
            briefId: briefId,
            provision: provision,
            garrisonHash: gHash,
            nonce: board.lastSettledNonce(donId) + 1,
            deadline: block.timestamp + 2 hours
        });
        bytes32 structHash = keccak256(
            abi.encode(board.LOADOUT_TYPEHASH(), l.donId, l.briefId, l.provision, l.garrisonHash, l.nonce, l.deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", board.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletPk[w], digest);
        vm.startBroadcast(walletPk[w]);
        missionId = board.depart(l, abi.encodePacked(r, s, v));
        vm.stopBroadcast();
    }

    // ================================================================ phase: hero first play (brief 1)
    /// Flow 2 — first depart on the LAUNCH brief (PAPER ROUTE, 3h) with a real provision. Asserts the
    /// whole first-play funnel: free Safehouse auto-claim, one-time stipend, dispatch fee + provision
    /// burned, worst-case budget reservation, soft lock.
    function heroDepart(uint256 heroDon) external {
        _load();
        address v = _vault(heroDon);
        require(deed.deedOf(heroDon) == 0, "HERO: already has a house");
        require(scrip.balanceOf(v) == 0, "HERO: vault not fresh");
        uint256 budget0 = board.missionBudget();
        uint256 reserved0 = board.outstandingReserved();
        uint256 burned0 = scrip.totalBurned();

        uint256 provision = 5e18;
        uint64 m = _departAs(0, heroDon, BRIEF_PAPER_ROUTE, provision, bytes32(0));

        // First-play funnel: Safehouse + stipend BEFORE the charge.
        require(deed.deedOf(heroDon) != 0, "HERO: no Safehouse");
        require(deed.tierOf(heroDon) == 0 && deed.defenseOf(heroDon) == 40, "HERO: bad Safehouse stats");
        require(deed.deployCapOf(heroDon) == 5_000e18, "HERO: bad Safehouse cap");
        require(escrow.stipendPaid(heroDon), "HERO: stipend not latched");
        // 50 stipend - 0.45 fee - 5 provision = 44.55 Scrip left in the vault.
        require(scrip.balanceOf(v) == 44.55e18, "HERO: vault != 44.55");
        require(scrip.totalBurned() - burned0 == 5.45e18, "HERO: fee+provision not burned");
        // Worst-case reservation: 36 + 5 * 1.1538.
        uint256 worst = 36e18 + (provision * 11_538) / 10_000;
        require(budget0 - board.missionBudget() == worst, "HERO: budget reservation wrong");
        require(board.outstandingReserved() - reserved0 == worst, "HERO: outstanding wrong");
        require(board.isAway(heroDon) && board.activeMissionOf(heroDon) == m, "HERO: not away");
        console.log("[HERO] missionId", m);
        console.log("[HERO] reserved ", worst);
    }

    // ================================================================ phase: sprint/farm depart
    /// First-play-aware SPRINT depart for any actor Don (stipend asserts on first play only).
    function sprintDepart(uint256 w, uint256 donId) external {
        _load();
        require(SPRINT != 0, "no SPRINT brief");
        address v = _vault(donId);
        bool first = deed.deedOf(donId) == 0;
        uint256 bal0 = scrip.balanceOf(v);
        uint256 budget0 = board.missionBudget();

        uint64 m = _departAs(w, donId, SPRINT, 0, bytes32(0));

        if (first) {
            require(escrow.stipendPaid(donId), "SPRINT: stipend not latched");
            require(scrip.balanceOf(v) == bal0 + 50e18 - 1e18, "SPRINT: first-play vault wrong");
        } else {
            require(scrip.balanceOf(v) == bal0 - 1e18, "SPRINT: fee not burned");
            require(deed.deedOf(donId) != 0, "SPRINT: house vanished");
        }
        require(budget0 - board.missionBudget() == 6_000e18, "SPRINT: reservation wrong");
        require(board.isAway(donId), "SPRINT: not away");
        console.log("[SPRINT] wallet", w);
        console.log("         donId ", donId);
        console.log("         missionId", m);
    }

    // ================================================================ phase: window depart (raid bait)
    /// Depart on the 20-min WINDOW brief, optionally with a frozen garrison commit (defender-side
    /// plaintext = (gIds, deterministic salt) — reconstructible by the defender wallet in any phase).
    function windowDepart(uint256 w, uint256 donId, uint256[] calldata gIds) external {
        _load();
        require(WINDOW != 0, "no WINDOW brief");
        bytes32 gHash = gIds.length == 0
            ? bytes32(0)
            : keccak256(abi.encode(gIds, keccak256(abi.encode(seed, "garrison-salt", donId))));
        bool first = deed.deedOf(donId) == 0;
        uint64 m = _departAs(w, donId, WINDOW, 0, gHash);
        require(board.isAway(donId), "WINDOW: not away");
        require(board.garrisonHashOf(donId) == gHash, "WINDOW: garrison commit not frozen");
        if (first) require(escrow.stipendPaid(donId), "WINDOW: stipend not latched");
        console.log("[WINDOW] donId", donId);
        console.log("         missionId", m);
        console.log("         garrisoned", gIds.length);
    }

    // ================================================================ phase: keeper resolve + fulfill
    /// The keeper leg (flow 3): resolve() every due unsettled mission (permissionless, entropy fee in
    /// ETH) then drive MockEntropy.fulfill for every pending seq. Outcome-agnostic asserts only —
    /// the orchestrator checks payout bands post-hoc from the Resolved events (sim/broadcast words differ).
    function resolveDue() external {
        _load();
        vm.startBroadcast(deployerPk);
        uint64 n = board.missionCount();
        uint256 fee = board.entropyFee();
        for (uint64 m = 1; m <= n; m++) {
            (, , , uint64 due, , , , bool requested, bool settled) = board.missions(m);
            if (settled || requested || block.timestamp < due) continue;
            board.resolve{value: fee}(m);
            console.log("[RESOLVE] mission", m);
        }
        _fulfillAll();
        vm.stopBroadcast();

        for (uint64 m = 1; m <= n; m++) {
            (uint256 dId, , , uint64 due, , , , , bool settled) = board.missions(m);
            if (block.timestamp >= due) {
                require(settled, "RESOLVE: due mission not settled");
                require(!board.isAway(dId) || board.activeMissionOf(dId) != m, "RESOLVE: don still locked");
            }
        }
        _custody();
    }

    /// Keeper sweep: deliver every pending MockEntropy word (missions, raids, favors alike).
    function _fulfillAll() internal {
        uint64 next = mock.nextSeq();
        for (uint64 s = 1; s < next; s++) {
            if (mock.consumerOf(s) != address(0) && !mock.fulfilled(s)) {
                mock.fulfill(s);
                console.log("[FULFILL] seq", s);
            }
        }
    }

    /// Standalone keeper fulfill (used when a phase needs the word without new resolves).
    function fulfillOnly() external {
        _load();
        vm.startBroadcast(deployerPk);
        _fulfillAll();
        vm.stopBroadcast();
        _custody();
    }

    // ================================================================ phase: bank (the sacred exit)
    /// Flow 5 — partial or full House->Vault. Asserts the exit is FREE (vault credited 1:1, no fee)
    /// and custody holds. fromDeployed/fromHopper = type(uint256).max means "all".
    function bankPhase(uint256 w, uint256 donId, uint256 fromDeployed, uint256 fromHopper) external {
        _load();
        if (fromDeployed == type(uint256).max) fromDeployed = escrow.deployedOf(donId);
        if (fromHopper == type(uint256).max) fromHopper = escrow.hopperOf(donId);
        address v = _vault(donId);
        uint256 bal0 = scrip.balanceOf(v);
        uint256 dep0 = escrow.deployedOf(donId);
        uint256 hop0 = escrow.hopperOf(donId);

        vm.startBroadcast(walletPk[w]);
        escrow.bank(donId, fromDeployed, fromHopper);
        vm.stopBroadcast();

        // The zero-fee exit law: every unit leaves the House and lands at the vault, plus any yield
        // the pre-bank checkpoint realized into the hopper (>= is exact when weight/budget is zero).
        require(scrip.balanceOf(v) >= bal0 + fromDeployed + fromHopper, "BANK: exit not free");
        require(escrow.deployedOf(donId) == dep0 - fromDeployed, "BANK: deployed wrong");
        require(escrow.hopperOf(donId) + fromHopper >= hop0, "BANK: hopper wrong");
        _custody();
        console.log("[BANK] donId", donId);
        console.log("       fromDeployed", fromDeployed);
        console.log("       fromHopper ", fromHopper);
        console.log("       vault now  ", scrip.balanceOf(v));
    }

    // ================================================================ phase: deploy into the House
    /// Flow 4 — Vault->House working capital, capped by the deed.
    function deployPhase(uint256 w, uint256 donId, uint256 amount) external {
        _load();
        address v = _vault(donId);
        uint256 bal0 = scrip.balanceOf(v);
        uint256 dep0 = escrow.deployedOf(donId);

        vm.startBroadcast(walletPk[w]);
        escrow.deploy(donId, amount);
        vm.stopBroadcast();

        require(escrow.deployedOf(donId) == dep0 + amount, "DEPLOY: ledger wrong");
        require(scrip.balanceOf(v) == bal0 - amount, "DEPLOY: vault not debited");
        require(escrow.weightOf(donId) > 0, "DEPLOY: no earning weight");
        _custody();
        console.log("[DEPLOY] donId", donId);
        console.log("         deployed", escrow.deployedOf(donId));
    }

    // ================================================================ phase: yield checkpoint
    /// Flow 6 — assert accrued yield is pending, then land it with the bank(0,0) checkpoint.
    function checkpointPhase(uint256 w, uint256 donId) external {
        _load();
        require(escrow.pendingYieldOf(donId) > 0, "YIELD: nothing pending");
        uint256 hop0 = escrow.hopperOf(donId);

        vm.startBroadcast(walletPk[w]);
        escrow.bank(donId, 0, 0);
        vm.stopBroadcast();

        require(escrow.hopperOf(donId) > hop0, "YIELD: checkpoint landed nothing");
        _custody();
        console.log("[YIELD] donId", donId);
        console.log("        hopper delta", escrow.hopperOf(donId) - hop0);
    }

    // ================================================================ phase: house upgrade
    /// Flow 7 — Safehouse -> Row House: 1,500 Scrip burned from the vault, tier/defense/cap step up.
    function upgradePhase(uint256 w, uint256 donId) external {
        _load();
        address v = _vault(donId);
        uint256 bal0 = scrip.balanceOf(v);
        uint256 burned0 = scrip.totalBurned();
        require(deed.tierOf(donId) == 0, "UPGRADE: not a Safehouse");

        vm.startBroadcast(walletPk[w]);
        deed.upgrade(donId);
        vm.stopBroadcast();

        require(deed.tierOf(donId) == 1, "UPGRADE: tier not 1");
        require(deed.deployCapOf(donId) == 15_000e18, "UPGRADE: cap not 15k");
        require(deed.defenseOf(donId) == 60, "UPGRADE: defense not 60");
        require(deed.garrisonSlotsOf(donId) == 3, "UPGRADE: slots not 3");
        require(scrip.balanceOf(v) == bal0 - 1_500e18, "UPGRADE: fee not taken");
        require(scrip.totalBurned() - burned0 == 1_500e18, "UPGRADE: fee not burned");
        console.log("[UPGRADE] donId", donId, "-> Row House");
    }

    // ================================================================ phase: hitter mints
    /// Flow 8 — n sealed Hitters at 900 Scrip each, burned from the payer Don's vault.
    function hittersPhase(uint256 w, uint256 donId, uint256 n) external {
        _load();
        address v = _vault(donId);
        uint256 bal0 = scrip.balanceOf(v);
        uint256 burned0 = scrip.totalBurned();
        uint256 id0 = hitter.totalMinted();

        vm.startBroadcast(walletPk[w]);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = hitter.mint(donId);
            console.log("[HITTER] minted", id);
        }
        vm.stopBroadcast();

        require(hitter.totalMinted() == id0 + n, "HITTER: count wrong");
        for (uint256 id = id0 + 1; id <= id0 + n; id++) {
            require(hitter.ownerOf(id) == wallet[w], "HITTER: owner wrong");
            require(hitter.sealed_(id), "HITTER: not sealed");
        }
        require(scrip.balanceOf(v) == bal0 - 900e18 * n, "HITTER: price not taken");
        require(scrip.totalBurned() - burned0 == 900e18 * n, "HITTER: price not burned");
    }

    // ================================================================ phase: favor reveal
    /// Flow 9 — owner opens the sealed slot (entropy fee in ETH), keeper delivers the word. Band is
    /// entropy-dependent -> asserted post-hoc from the FavorRevealed event; here: envelope opened.
    function favorPhase(uint256 w, uint256 hitterId) external {
        _load();
        require(hitter.sealed_(hitterId), "FAVOR: not sealed");
        vm.startBroadcast(walletPk[w]);
        uint64 s = hitter.revealFavor{value: hitter.entropyFee()}(hitterId);
        vm.stopBroadcast();
        console.log("[FAVOR] seq", s);

        vm.startBroadcast(deployerPk);
        _fulfillAll();
        vm.stopBroadcast();
        require(!hitter.sealed_(hitterId), "FAVOR: still sealed");
        require(!hitter.revealPending(hitterId), "FAVOR: still pending");
        console.log("[FAVOR] band (SIM-ONLY, real band from event)", hitter.favorOf(hitterId));
    }

    // ================================================================ raids

    function _raidSalt(uint256 attackerDon, uint256 targetDon) internal view returns (bytes32) {
        return keccak256(abi.encode(seed, "raid-salt", attackerDon, targetDon));
    }

    /// Flow 10a — commit. 50-Scrip fee moves vault -> engine; hash hides the target.
    function commitPhase(uint256 w, uint256 attackerDon, uint256[] calldata hitterIds, uint256 targetDon) external {
        _load();
        address v = _vault(attackerDon);
        uint256 bal0 = scrip.balanceOf(v);
        uint256 eng0 = scrip.balanceOf(address(raid));
        bytes32 h = keccak256(abi.encode(attackerDon, hitterIds, targetDon, _raidSalt(attackerDon, targetDon)));

        vm.startBroadcast(walletPk[w]);
        uint64 raidId = raid.commit(attackerDon, h);
        vm.stopBroadcast();

        require(scrip.balanceOf(v) == bal0 - 50e18, "COMMIT: fee not taken");
        require(scrip.balanceOf(address(raid)) == eng0 + 50e18, "COMMIT: fee not held");
        console.log("[COMMIT] raidId", raidId);
        console.log("         attackerDon", attackerDon);
    }

    /// Flow 10b — reveal in the [10,40]min window + keeper fulfill. Deterministic asserts only
    /// (state, powers, fee burn); loot/tax/hospital are post-hoc from RaidSettled/HitterDown events.
    function revealPhase(uint256 w, uint64 raidId, uint256 attackerDon, uint256[] calldata hitterIds, uint256 targetDon)
        external
    {
        _load();
        uint256 burned0 = scrip.totalBurned();

        vm.startBroadcast(walletPk[w]);
        uint64 s = raid.reveal{value: raid.entropyFee()}(raidId, hitterIds, targetDon, _raidSalt(attackerDon, targetDon));
        vm.stopBroadcast();
        console.log("[REVEAL] raidId", raidId);
        console.log("         seq", s);

        (,,,,,, uint256 attackPower, uint256 defensePower,, RaidEngine.RaidState st,, bool gRevealed) = raid.raids(raidId);
        require(st == RaidEngine.RaidState.Revealed, "REVEAL: not revealed");
        require(attackPower > 0, "REVEAL: no attack power");
        require(scrip.totalBurned() - burned0 == 50e18, "REVEAL: commit fee not burned");
        require(raid.heatUntil(targetDon) > block.timestamp, "REVEAL: heat not claimed at reveal");
        bool ungarrisoned = board.garrisonHashOf(targetDon) == bytes32(0);
        if (ungarrisoned) {
            require(gRevealed && defensePower == deed.defenseOf(targetDon) * PPM, "REVEAL: house-alone defense wrong");
        }

        vm.startBroadcast(deployerPk);
        _fulfillAll();
        vm.stopBroadcast();

        (,,,,,,,,, RaidEngine.RaidState st2, bool word2,) = raid.raids(raidId);
        if (ungarrisoned) {
            require(st2 == RaidEngine.RaidState.Settled, "REVEAL: not settled on word");
        } else {
            require(word2, "REVEAL: word not delivered");
        }
        _custody();
    }

    /// Flow 11b — defender opens the frozen garrison commit; settle runs if the word already landed.
    function garrisonPhase(uint256 w, uint64 raidId, uint256[] calldata gIds) external {
        _load();
        (, uint256 targetDon,,,,,,,,, bool word0,) = raid.raids(raidId);
        bytes32 salt = keccak256(abi.encode(seed, "garrison-salt", targetDon));

        vm.startBroadcast(walletPk[w]);
        raid.revealGarrison(raidId, gIds, salt);
        vm.stopBroadcast();

        (,,,,,,, uint256 defensePower,, RaidEngine.RaidState st, bool word1, bool gRev) = raid.raids(raidId);
        require(gRev, "GARRISON: not revealed");
        // Fresh, defender-owned garrison: house defense + 47.5 power per Hitter (x1e6).
        uint256 expected = deed.defenseOf(targetDon) * PPM + gIds.length * 50 * PPM * 9_500 / 10_000;
        require(defensePower == expected, "GARRISON: defense power wrong");
        if (word0) require(st == RaidEngine.RaidState.Settled, "GARRISON: word landed but not settled");

        if (!word1) {
            vm.startBroadcast(deployerPk);
            _fulfillAll();
            vm.stopBroadcast();
            (,,,,,,,,, RaidEngine.RaidState st2,,) = raid.raids(raidId);
            require(st2 == RaidEngine.RaidState.Settled, "GARRISON: not settled");
        }
        _custody();
        console.log("[GARRISON] raidId", raidId);
        console.log("           defensePower", defensePower);
    }

    /// Abandoned-commit cleanup (bonus liveness flow): past the reveal window the held fee burns.
    function forfeitPhase(uint256 w, uint64 raidId) external {
        _load();
        uint256 burned0 = scrip.totalBurned();
        uint256 eng0 = scrip.balanceOf(address(raid));
        vm.startBroadcast(walletPk[w]);
        raid.forfeit(raidId);
        vm.stopBroadcast();
        (,,,,,,,,, RaidEngine.RaidState st,,) = raid.raids(raidId);
        require(st == RaidEngine.RaidState.Forfeited, "FORFEIT: state wrong");
        require(scrip.totalBurned() - burned0 == 50e18, "FORFEIT: fee not burned");
        require(scrip.balanceOf(address(raid)) == eng0 - 50e18, "FORFEIT: fee not released");
        console.log("[FORFEIT] raidId", raidId);
    }

    // ================================================================ phase: F3 repair-fee + full exit
    /// Flow 14 (F3 audit fix) — on a DAMAGED, home Don: bank EVERYTHING to the vault (the full sacred
    /// exit) and assert repairFeeOf is UNCHANGED (basis frozen at damage time), then repair and assert
    /// the debuff clears and the fee burns.
    function repairPhase(uint256 w, uint256 donId) external {
        _load();
        require(escrow.damageBps(donId) == 4_000, "REPAIR: not damaged");
        uint256 fee0 = escrow.repairFeeOf(donId);
        require(fee0 > 0, "REPAIR: zero fee (no deployed at damage time)");
        address v = _vault(donId);

        vm.startBroadcast(walletPk[w]);
        escrow.bank(donId, escrow.deployedOf(donId), escrow.hopperOf(donId));
        // The bank checkpoint realizes pending yield into the hopper in the same tx; with deployed
        // now 0 the weight is 0, so a second bank drains that residual exactly.
        if (escrow.hopperOf(donId) > 0) escrow.bank(donId, 0, escrow.hopperOf(donId));
        vm.stopBroadcast();

        require(escrow.deployedOf(donId) == 0 && escrow.hopperOf(donId) == 0, "REPAIR: not emptied");
        require(escrow.repairFeeOf(donId) == fee0, "REPAIR-DODGE POSSIBLE: fee changed after bank-to-zero");

        uint256 bal0 = scrip.balanceOf(v);
        uint256 burned0 = scrip.totalBurned();
        vm.startBroadcast(walletPk[w]);
        escrow.repair(donId);
        vm.stopBroadcast();

        require(escrow.damageBps(donId) == 0, "REPAIR: debuff not cleared");
        require(scrip.balanceOf(v) == bal0 - fee0, "REPAIR: fee not taken");
        require(scrip.totalBurned() - burned0 == fee0, "REPAIR: fee not burned");
        _custody();
        console.log("[REPAIR] donId", donId);
        console.log("         fee burned", fee0);
    }

    // ================================================================ phase: invariants (view-only)
    /// Flow 15 — run any time; strict=true additionally requires every reservation drained.
    function verifyState(bool strict) external {
        _load();
        _custody();
        uint64 n = board.missionCount();
        uint256 unsettled;
        for (uint64 m = 1; m <= n; m++) {
            (,,,,,,, , bool settled) = board.missions(m);
            if (!settled) unsettled++;
        }
        if (strict) {
            require(unsettled == 0, "VERIFY: unsettled missions remain");
            require(board.outstandingReserved() == 0, "VERIFY: outstandingReserved != 0");
        }
        console.log("[VERIFY] custody OK: escrow bal == totalDeployed + totalHopper");
        console.log("[VERIFY] scrip escrow bal ", scrip.balanceOf(address(escrow)));
        console.log("[VERIFY] totalDeployed    ", escrow.totalDeployed());
        console.log("[VERIFY] totalHopper      ", escrow.totalHopper());
        console.log("[VERIFY] missionCount     ", n);
        console.log("[VERIFY] unsettled        ", unsettled);
        console.log("[VERIFY] outstandingResv  ", board.outstandingReserved());
        console.log("[VERIFY] missionBudget    ", board.missionBudget());
        console.log("[VERIFY] scrip totalSupply", scrip.totalSupply());
        console.log("[VERIFY] scrip burned     ", scrip.totalBurned());
        console.log("[VERIFY] yieldBudget      ", escrow.yieldBudget());
        console.log("[VERIFY] stipendBudget    ", escrow.stipendBudget());
    }

    // ================================================================ FORK PROOFS (no broadcast!)
    //
    // The >2h time-gated liveness valves, proven on a fork of the live stack with vm.warp/prank/deal
    // (the DonE2E.liquidationFork precedent):
    //
    //   forge script script/GameE2E.s.sol:GameE2E --sig "forkProofs()" --rpc-url rh_testnet -vv
    //
    //   F-A mission reclaim   (entropy withheld, due+2h  -> PARTIAL floor, Don comes home)
    //   F-B raid floorSettle  (garrison never revealed, word+1h -> real roll, house defends alone)
    //   F-C raid reclaim      (entropy withheld, reveal+2h -> MISS, no transfers, fee stays sunk)
    //   F-D favor force-reveal (sealed 30d -> anyone floors it at Common)
    //   F-E reveal-too-late   (past the 40-min window -> revert, then forfeit burns the fee)

    uint256 constant FORK_A_PK = uint256(keccak256("game-e2e-fork-actor-A"));
    uint256 constant FORK_B_PK = uint256(keccak256("game-e2e-fork-actor-B"));

    function forkProofs() external {
        _load();
        require(SPRINT != 0 && WINDOW != 0, "FORK: harness briefs missing (run setup first)");
        address A = vm.addr(FORK_A_PK); // defender-side actor
        address B = vm.addr(FORK_B_PK); // attacker-side actor
        vm.deal(A, 1 ether);
        vm.deal(B, 1 ether);

        // Cast: two Dons for A (reclaim + floorSettle targets), one for B (attacker), all fork-fresh.
        uint256 donA1 = _forkMint(A, "fork-don-a1");
        uint256 donA2 = _forkMint(A, "fork-don-a2");
        uint256 donB = _forkMint(B, "fork-don-b");

        // Fund the vaults directly (fork-only shortcut: impersonate the MISSION module, a real minter).
        vm.startPrank(address(board));
        scrip.mint(don.vaultOf(donA1), 5_000e18);
        scrip.mint(don.vaultOf(donA2), 5_000e18);
        scrip.mint(don.vaultOf(donB), 5_000e18);
        vm.stopPrank();

        _forkMissionReclaim(A, donA1);
        // A fresh Hitter per raid (a miss can hospitalize it 48h — never reuse across raids).
        _forkFloorSettle(A, donA2, B, donB, _forkHitter(B, donB));
        _forkRaidReclaim(A, donA1, B, donB, _forkHitter(B, donB));
        _forkForceReveal(B, donB);
        _forkRevealTooLate(B, donB);

        console.log("=== FORK PROOFS: ALL PASSED (fork sim, vm.warp, NOT live txs) ===");
    }

    function _forkMint(address who, string memory tag) internal returns (uint256 id) {
        uint256 fee = dist.customFee();
        bytes32 combo = keccak256(abi.encode(seed, tag, block.timestamp, gasleft()));
        vm.prank(who);
        id = dist.mintCustom{value: fee}(combo);
    }

    function _forkHitter(address who, uint256 payerDon) internal returns (uint256 id) {
        vm.prank(who);
        id = hitter.mint(payerDon);
    }

    /// EIP-712 depart with an arbitrary pk (fork actors).
    function _forkDepart(uint256 pk, uint256 donId, uint64 briefId, bytes32 gHash) internal returns (uint64 m) {
        MissionBoard.Loadout memory l = MissionBoard.Loadout({
            donId: donId,
            briefId: briefId,
            provision: 0,
            garrisonHash: gHash,
            nonce: board.lastSettledNonce(donId) + 1,
            deadline: block.timestamp + 2 hours
        });
        bytes32 structHash = keccak256(
            abi.encode(board.LOADOUT_TYPEHASH(), l.donId, l.briefId, l.provision, l.garrisonHash, l.nonce, l.deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", board.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        vm.prank(vm.addr(pk));
        m = board.depart(l, abi.encodePacked(r, s, v));
    }

    /// F-A: keeper dead at resolve time -> after due+2h anyone reclaims at the PARTIAL floor.
    function _forkMissionReclaim(address A, uint256 donId) internal {
        uint64 m = _forkDepart(FORK_A_PK, donId, SPRINT, bytes32(0));
        uint256 pp = _briefPartialPay(SPRINT);
        uint256 hop0 = escrow.hopperOf(donId);
        uint256 resv0 = board.outstandingReserved();

        vm.warp(block.timestamp + 75 + 2 hours + 1);
        vm.prank(makeAddr("anyone"));
        board.reclaim(m);

        (,,,,,,,, bool settled) = board.missions(m);
        require(settled, "F-A: not settled");
        require(!board.isAway(donId), "F-A: Don stranded");
        require(escrow.hopperOf(donId) - hop0 == pp, "F-A: partial floor not paid");
        require(resv0 - board.outstandingReserved() == 6_000e18, "F-A: reservation not drained");
        console.log("[FORK A] mission reclaim -> PARTIAL floor OK, payout", pp);
        require(A == don.ownerOf(donId), "F-A: owner sanity");
    }

    /// F-B: garrison suppressed -> after word+1h the REAL roll runs with the house defending alone.
    function _forkFloorSettle(address A, uint256 targetDon, address B, uint256 attackerDon, uint256 hitId) internal {
        // Defender departs with an unrevealable commit (plaintext never published).
        _forkDepart(FORK_A_PK, targetDon, WINDOW, keccak256("garbage-nobody-knows"));

        bytes32 salt = keccak256("fork-b-salt");
        uint256[] memory crew = new uint256[](1);
        crew[0] = hitId;
        vm.prank(B);
        uint64 raidId = raid.commit(attackerDon, keccak256(abi.encode(attackerDon, crew, targetDon, salt)));
        vm.warp(block.timestamp + 11 minutes);
        uint256 rfee = raid.entropyFee();
        vm.prank(B);
        raid.reveal{value: rfee}(raidId, crew, targetDon, salt);
        mock.fulfill(mock.nextSeq() - 1); // word lands; garrison still sealed

        (,,,,,,,,, RaidEngine.RaidState st0, bool word0, bool g0) = raid.raids(raidId);
        require(st0 == RaidEngine.RaidState.Revealed && word0 && !g0, "F-B: precondition wrong");

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(B); // the attacker claims the roll a stalling defender tried to deny
        raid.floorSettle(raidId);

        (,,,,,,, uint256 dp,, RaidEngine.RaidState st1,, bool g1) = raid.raids(raidId);
        require(st1 == RaidEngine.RaidState.Settled && g1, "F-B: not settled");
        require(dp == deed.defenseOf(targetDon) * PPM, "F-B: garrison credited despite suppression");
        _custody();
        console.log("[FORK B] floorSettle -> real roll, house alone, defense", dp);
    }

    /// F-C: entropy withheld -> after reveal+2h anyone reclaims: MISS, no transfers, fee stays sunk.
    function _forkRaidReclaim(address A, uint256 targetDon, address B, uint256 attackerDon, uint256 hitId) internal {
        // Fresh away window for the same defender Don (mission from F-A settled; heat from F-B is on donA2).
        _forkDepart(FORK_A_PK, targetDon, WINDOW, bytes32(0));
        bytes32 salt = keccak256("fork-c-salt");
        uint256[] memory crew = new uint256[](1);
        crew[0] = hitId; // cooldown-diminished from F-B — allowed by design (diminished odds, not a gate)
        vm.prank(B);
        uint64 raidId = raid.commit(attackerDon, keccak256(abi.encode(attackerDon, crew, targetDon, salt)));
        vm.warp(block.timestamp + 10 minutes + 1);
        uint256 rfee = raid.entropyFee();
        vm.prank(B);
        raid.reveal{value: rfee}(raidId, crew, targetDon, salt);
        // Keeper goes dark: NO fulfill.

        uint256 hop0 = escrow.hopperOf(targetDon);
        uint256 dep0 = escrow.deployedOf(targetDon);
        uint256 atk0 = scrip.balanceOf(don.vaultOf(attackerDon));

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(makeAddr("anyone"));
        raid.reclaimRaid(raidId);

        (,,,,,,,,, RaidEngine.RaidState st,,) = raid.raids(raidId);
        require(st == RaidEngine.RaidState.Settled, "F-C: not settled");
        require(escrow.hopperOf(targetDon) == hop0 && escrow.deployedOf(targetDon) == dep0, "F-C: transfers on miss");
        require(scrip.balanceOf(don.vaultOf(attackerDon)) == atk0, "F-C: attacker paid on reclaim");
        require(raid.heatUntil(targetDon) > block.timestamp, "F-C: heat not set");
        require(A == don.ownerOf(targetDon), "F-C: owner sanity");
        console.log("[FORK C] reclaimRaid -> MISS, no transfers, fee sunk");
    }

    /// F-D: a Hitter sealed past 30 days -> ANYONE floors it at Common.
    function _forkForceReveal(address B, uint256 payerDon) internal {
        uint256 id = _forkHitter(B, payerDon);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(makeAddr("anyone"));
        hitter.forceRevealFloor(id);
        require(!hitter.sealed_(id), "F-D: still sealed");
        require(hitter.favorOf(id) == 0, "F-D: floor is not Common");
        console.log("[FORK D] forceRevealFloor -> Common (the floor band)");
    }

    /// F-E: reveal past the 40-min window reverts; forfeit then burns the held fee.
    function _forkRevealTooLate(address B, uint256 attackerDon) internal {
        bytes32 salt = keccak256("fork-e-salt");
        uint256[] memory crew = new uint256[](1);
        crew[0] = 1;
        vm.prank(B);
        uint64 raidId = raid.commit(attackerDon, keccak256(abi.encode(attackerDon, crew, uint256(1), salt)));
        vm.warp(block.timestamp + 41 minutes);
        vm.prank(B);
        vm.expectRevert(RaidEngine.RevealTooLate.selector);
        raid.reveal(raidId, crew, 1, salt); // reverts on the window check before any fee is read

        uint256 burned0 = scrip.totalBurned();
        vm.prank(makeAddr("anyone"));
        raid.forfeit(raidId);
        require(scrip.totalBurned() - burned0 == 50e18, "F-E: fee not burned");
        console.log("[FORK E] reveal-too-late reverted; forfeit burned the fee");
    }
}
