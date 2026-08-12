// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DonDistributor} from "../src/market/DonDistributor.sol";
import {DonReserve} from "../src/market/DonReserve.sol";
import {DonExchange} from "../src/market/DonExchange.sol";
import {DonLoan} from "../src/market/DonLoan.sol";
import {Bell} from "../src/market/Bell.sol";
import {Don} from "../src/market/Don.sol";
import {TestnetFaucet} from "../src/testnet/TestnetFaucet.sol";

/// DonE2E — a deterministic, multi-wallet END-TO-END exerciser for the Essey "Don" v3 market on Robinhood
/// Chain testnet (chainId 46630). It spins up N ephemeral wallets from a FIXED seed (reproducible; no
/// randomness), funds each with a small native-ETH gas budget from the deployer, and drives EVERY user
/// journey from the RELEVANT wallet so every flow is proven under a real, distinct actor:
///
///   MINT (custom path)  •  FAUCET drip  •  STAKE (Bell tier + upgrade)  •  BORROW (7d & 365d) + REPAY  •
///   DESK buy / snipe / sell round-trips (fee-split asserted)  •  DonReserve fund + redeem
///
/// LIQUIDATION is a CALENDAR default (expiry + 30-day grace) — it needs time travel, which a live chain
/// can't do, so it lives in a SEPARATE fork-simulated entrypoint `liquidationFork()` (vm.warp/prank/deal;
/// NOT broadcast). See the "how to run" note at the bottom of this file.
///
/// Every state-changing call is a real broadcast tx from the actor wallet; forge records each hash in
/// broadcast/DonE2E.s.sol/46630/run-latest.json, which script/don-e2e-report.mjs turns into an
/// explorer-linked markdown report (docs/TESTNET-E2E.md). Each leg also console.logs a labeled line, and
/// asserts with clear revert strings that name the flow + the wallet so a broken journey fails loudly.
///
/// Nothing here is hardcoded value-wise: the stack addresses, the funder key, and the sizing all come from
/// env. The private key is read but NEVER logged or hardcoded.
///
/// ENV (all addresses; key from TESTNET_DEPLOYER_PK):
///   DISTRIBUTOR, ESSEY, USDG, BELL, EXCHANGE, RESERVE, LOAN, FAUCET   (required)
///   DON            (optional — defaults to DISTRIBUTOR.don())
///   FEEROUTER      (optional — informational; the fee sink is read from the exchange itself)
///   TESTNET_DEPLOYER_PK  (required — the gas funder + stack admin/treasury/seeder)
///   N_WALLETS [18], N_DONS [40], E2E_SEED [fixed], WALLET_ETH [0.02e18]
///   RESERVE_FUND [2_666_666_666e18], LOAN_FUND [100_000_000e18]
///   FAUCET_ESSEY_DRIP [1_000_000e18], FAUCET_USDG_DRIP [1_000e6]
contract DonE2E is Script {
    // ---- resolved stack handles (state, so helpers stay shallow — avoids stack-too-deep) ----
    DonDistributor dist;
    Don don;
    DonReserve reserve;
    DonExchange exchange;
    DonLoan loan;
    Bell bell;
    IERC20 essey;
    IERC20 usdg;
    TestnetFaucet faucet;

    address feeSink; // exchange.feeSink() — where 70% of trade fees route
    address treasury; // exchange.treasury() — the other 30%

    uint256 deployerPk;
    address deployer;

    // ---- sizing / config ----
    uint256 nWallets;
    uint256 nDons;
    uint256 walletEth;
    uint256 reserveFund;
    uint256 loanFund;
    uint256 esseyDrip;
    uint256 usdgDrip;
    bytes32 seed;

    // ---- ephemeral actors ----
    uint256[] walletPk;
    address[] wallet;

    // Number of wallets that CUSTOM-MINT their own Don (indices 0..5). The rest either trade on the desk
    // (buy/snipe/sell) or fund/redeem the reserve, so the desk seed makes up the remainder of N_DONS.
    uint256 constant CUSTOM_MINTERS = 6;

    uint256 constant YEAR = 365 days;

    // ================================================================= entrypoint (live broadcast)

    function run() external {
        _load();
        _deriveWallets();
        _setup(); // deployer: fund wallets, fund reserve/loan/faucet, open mint, seed the desk
        _journeys(); // per-wallet: drip + role
        _summary();
    }

    // ----------------------------------------------------------------- load + derive

    function _load() internal {
        deployerPk = vm.envUint("TESTNET_DEPLOYER_PK");
        deployer = vm.addr(deployerPk);

        dist = DonDistributor(vm.envAddress("DISTRIBUTOR"));
        reserve = DonReserve(vm.envAddress("RESERVE"));
        exchange = DonExchange(vm.envAddress("EXCHANGE"));
        loan = DonLoan(vm.envAddress("LOAN"));
        bell = Bell(vm.envAddress("BELL"));
        essey = IERC20(vm.envAddress("ESSEY"));
        usdg = IERC20(vm.envAddress("USDG"));
        faucet = TestnetFaucet(vm.envAddress("FAUCET"));
        don = Don(vm.envOr("DON", address(dist.don())));

        feeSink = exchange.feeSink();
        treasury = exchange.treasury();

        nWallets = vm.envOr("N_WALLETS", uint256(18));
        nDons = vm.envOr("N_DONS", uint256(40));
        walletEth = vm.envOr("WALLET_ETH", uint256(0.02 ether));
        reserveFund = vm.envOr("RESERVE_FUND", uint256(2_666_666_666e18));
        loanFund = vm.envOr("LOAN_FUND", uint256(100_000_000e18));
        esseyDrip = vm.envOr("FAUCET_ESSEY_DRIP", uint256(1_000_000e18));
        usdgDrip = vm.envOr("FAUCET_USDG_DRIP", uint256(1_000e6));
        seed = vm.envOr("E2E_SEED", keccak256("essey-don-e2e-v1"));

        require(nWallets >= 12, "E2E: need >= 12 wallets to cover every role");
    }

    function _deriveWallets() internal {
        for (uint256 i = 0; i < nWallets; i++) {
            // Deterministic, reproducible keys from a fixed seed — NO randomness. keccak output is a valid
            // secp256k1 key with overwhelming probability; guard the (astronomically unlikely) zero.
            uint256 pk = uint256(keccak256(abi.encode(seed, i)));
            if (pk == 0) pk = 1;
            walletPk.push(pk);
            wallet.push(vm.addr(pk));
        }
    }

    // ----------------------------------------------------------------- SETUP (deployer broadcast)

    function _setup() internal {
        vm.startBroadcast(deployerPk);

        // 1. Gas budget to every ephemeral wallet (covers mint/reroll ETH fees + trivial testnet gas).
        for (uint256 i = 0; i < nWallets; i++) {
            (bool ok,) = wallet[i].call{value: walletEth}("");
            require(ok, "SETUP: wallet ETH fund failed");
        }

        // 2. Fund the DonReserve so there is a live floor (price + maxBorrow read off it). Idempotent with a
        //    pre-seeded stack: only fund when the floor is still zero.
        if (reserve.floorPerDon() == 0 && reserveFund > 0) {
            essey.approve(address(reserve), reserveFund);
            reserve.fund(reserveFund);
        }
        require(reserve.floorPerDon() > 0, "SETUP: reserve unfunded -> no floor");

        // 3. Fund the DonLoan pot so borrows can be disbursed.
        if (loan.lendable() < loanFund && loanFund > 0) {
            essey.approve(address(loan), loanFund);
            loan.fund(loanFund);
        }

        // 4. Faucet: retune drips + top up its $ESSEY balance (owner-gated). Skip cleanly if the deployer
        //    isn't the faucet owner (documented precondition: the coordinator deploys it owner=deployer).
        if (faucet.owner() == deployer) {
            faucet.setDrips(esseyDrip, usdgDrip, 0); // cooldown 0 — each fresh wallet drips once anyway
            essey.transfer(address(faucet), nWallets * esseyDrip);
        }
        require(faucet.esseyDrip() >= 66_666e18, "SETUP: faucet drip too small to reach Bell tier-1");

        // 5. Open the $10 custom mint (admin-gated).
        if (!dist.publicOpen()) dist.setPublicOpen(true);

        // 6. Seed the desk: mintReserved the AMM float to the deployer (seeder) and seed the exchange with
        //    it, so N_DONS total mint out across desk + custom mints and buyers have inventory.
        uint256 deskSeed = nDons > CUSTOM_MINTERS ? nDons - CUSTOM_MINTERS : 8;
        bytes32[] memory combos = new bytes32[](deskSeed);
        uint256 base = don.totalMinted();
        for (uint256 i = 0; i < deskSeed; i++) {
            combos[i] = keccak256(abi.encode("e2e-desk-float", seed, base + i + 1));
        }
        dist.mintReserved(deployer, combos);
        uint256[] memory ids = new uint256[](deskSeed);
        for (uint256 i = 0; i < deskSeed; i++) ids[i] = base + i + 1;
        don.setApprovalForAll(address(exchange), true);
        exchange.seed(ids);

        vm.stopBroadcast();

        console.log("[SETUP] deployer      ", deployer);
        console.log("[SETUP] floorPerDon   ", reserve.floorPerDon() / 1e18, "ESSEY");
        console.log("[SETUP] desk inventory", exchange.inventoryCount());
        console.log("[SETUP] loan pot       ", loan.lendable() / 1e18, "ESSEY");
    }

    // ----------------------------------------------------------------- per-wallet journeys

    function _journeys() internal {
        for (uint256 i = 0; i < nWallets; i++) {
            vm.startBroadcast(walletPk[i]);
            _faucet(i); // FAUCET — every wallet drips
            _role(i); // its assigned journey
            vm.stopBroadcast();
        }
    }

    /// FAUCET: drip() -> receive ESSEY (+ USDG). Assert both landed.
    function _faucet(uint256 i) internal {
        uint256 e0 = essey.balanceOf(wallet[i]);
        uint256 u0 = usdg.balanceOf(wallet[i]);
        faucet.drip();
        require(essey.balanceOf(wallet[i]) - e0 == faucet.esseyDrip(), _err("FAUCET essey", i));
        require(usdg.balanceOf(wallet[i]) - u0 == faucet.usdgDrip(), _err("FAUCET usdg", i));
        console.log("[FAUCET] wallet", i, wallet[i]);
    }

    /// Dispatch each wallet to a coherent, non-conflicting journey (one Don, one story per wallet):
    ///   0,1 borrow 7d + repay     2 borrow 365d + repay     3 stake t1     4 stake t1 -> upgrade t2
    ///   5 reroll     6 buy + redeem     7 fund the floor     8+ desk round-trips (even buy, odd snipe) + sell
    function _role(uint256 i) internal {
        if (i == 0 || i == 1) {
            _mintBorrowRepay(i, loan.MIN_TERM());
        } else if (i == 2) {
            _mintBorrowRepay(i, YEAR);
        } else if (i == 3) {
            _mintStake(i, false);
        } else if (i == 4) {
            _mintStake(i, true);
        } else if (i == 5) {
            _mintReroll(i);
        } else if (i == 6) {
            _buyRedeem(i);
        } else if (i == 7) {
            _fundFloor(i);
        } else {
            _deskRoundTrip(i, i % 2 == 1); // odd index snipes, even buys
        }
    }

    // ---- MINT (custom path) + BORROW + REPAY ----

    function _mintCustom(uint256 i) internal returns (uint256 id) {
        bytes32 combo = keccak256(abi.encode("e2e-mint", seed, wallet[i]));
        id = dist.mintCustom{value: dist.customFee()}(combo);
        require(don.ownerOf(id) == wallet[i], _err("MINT owner", i));
        require(don.traits(id) == combo, _err("MINT traits", i));
        console.log("[MINT] wallet", i, "don");
        console.log("       id", id);
    }

    function _mintBorrowRepay(uint256 i, uint256 term) internal {
        uint256 id = _mintCustom(i);

        // BORROW: full draw of ltvBps of the live floor, disbursed in ESSEY; interest prepaid in ETH.
        uint256 want = loan.maxBorrow();
        uint256 prepaid = loan.prepaidEth(term);
        uint256 e0 = essey.balanceOf(wallet[i]);
        loan.borrow{value: prepaid}(id, term);
        require(don.liened(id), _err("BORROW lien", i));
        require(don.ownerOf(id) == wallet[i], _err("BORROW left wallet", i));
        require(loan.debtOf(id) == want, _err("BORROW debt!=principal", i));
        require(essey.balanceOf(wallet[i]) - e0 == want, _err("BORROW proceeds!=maxBorrow", i));
        console.log("[BORROW] wallet", i, "termSeconds");
        console.log("         term", term);
        console.log("         principal", want / 1e18);

        // REPAY: 1:1 flat principal; lien releases, Don transferable again.
        uint256 debt = loan.debtOf(id);
        essey.approve(address(loan), debt);
        loan.repay(id, type(uint256).max);
        require(loan.debtOf(id) == 0, _err("REPAY debt stuck", i));
        require(!don.liened(id), _err("REPAY lien stuck", i));
        console.log("[REPAY] wallet", i, "cleared");
    }

    // ---- STAKE (Bell tier) + optional upgrade ----

    function _mintStake(uint256 i, bool doUpgrade) internal {
        uint256 id = _mintCustom(i);

        uint256 fee1 = bell.tierFees(0); // tier-1 threshold (66,666 ESSEY)
        essey.approve(address(bell), fee1);
        bell.activate(id, 1);
        (uint8 t1,,,) = bell.seats(id);
        require(t1 == 1, _err("STAKE tier!=1", i));
        console.log("[STAKE] wallet", i, "tier=1");

        if (doUpgrade) {
            uint256 delta = bell.tierFees(1) - bell.tierFees(0);
            essey.approve(address(bell), delta);
            bell.upgrade(id, 2);
            (uint8 t2,,,) = bell.seats(id);
            require(t2 == 2, _err("UPGRADE tier!=2", i));
            console.log("[UPGRADE] wallet", i, "tier=2");
        }
    }

    // ---- REROLL (paid, pre-stake) ----

    function _mintReroll(uint256 i) internal {
        uint256 id = _mintCustom(i);
        bytes32 newCombo = keccak256(abi.encode("e2e-reroll", seed, wallet[i], id));
        dist.reroll{value: dist.rerollFee()}(id, newCombo);
        require(don.traits(id) == newCombo, _err("REROLL traits", i));
        console.log("[REROLL] wallet", i, "combo rerolled");
    }

    // ---- DESK: buy then redeem (exercises DonReserve.redeem) ----

    function _buyRedeem(uint256 i) internal {
        uint256 id = _buy(i);

        // REDEEM: lock the Don in the reserve for its pro-rata floor share.
        uint256 e0 = essey.balanceOf(wallet[i]);
        don.approve(address(reserve), id);
        uint256 paid = reserve.redeem(id);
        require(paid > 0, _err("REDEEM zero", i));
        require(don.ownerOf(id) == address(reserve), _err("REDEEM not seized", i));
        require(essey.balanceOf(wallet[i]) - e0 == paid, _err("REDEEM proceeds", i));
        console.log("[REDEEM] wallet", i, "paid");
        console.log("         paid", paid / 1e18);
    }

    // ---- DESK: fund the floor (exercises DonReserve.fund from a user) ----

    function _fundFloor(uint256 i) internal {
        uint256 amt = 100_000e18;
        uint256 f0 = reserve.floorPerDon();
        essey.approve(address(reserve), amt);
        reserve.fund(amt);
        require(reserve.floorPerDon() >= f0, _err("FUND floor fell", i));
        console.log("[FUND-FLOOR] wallet", i, "floor raised");
    }

    // ---- DESK: buy/snipe then sell back (round-trip so the desk is not drained) ----

    function _deskRoundTrip(uint256 i, bool doSnipe) internal {
        uint256 id = doSnipe ? _snipe(i) : _buy(i);
        _sell(i, id);
    }

    /// BUY the next Don at price + 8% fee. Assert cost, receipt, and 70/30 fee routing to feeSink/treasury.
    function _buy(uint256 i) internal returns (uint256 id) {
        uint256 p = exchange.price();
        uint256 fee = exchange.feeOn(exchange.swapFeeBps());
        uint256 cost = p + fee;
        uint256 e0 = essey.balanceOf(wallet[i]);
        (uint256 s0, uint256 t0) = _sinkBalances();

        essey.approve(address(exchange), cost);
        id = exchange.buy(cost);

        require(don.ownerOf(id) == wallet[i], _err("BUY not received", i));
        require(e0 - essey.balanceOf(wallet[i]) == cost, _err("BUY cost mismatch", i));
        _assertFeeRouted(s0, t0, fee, "BUY", i);
        console.log("[BUY] wallet", i, "don");
        console.log("      id", id);
    }

    /// SNIPE a specific Don (inventoryAt(0)) at price + 12% fee. Same fee-routing assertion, premium rate.
    function _snipe(uint256 i) internal returns (uint256 id) {
        id = exchange.inventoryAt(0);
        uint256 p = exchange.price();
        uint256 fee = exchange.feeOn(exchange.snipeFeeBps());
        uint256 cost = p + fee;
        uint256 e0 = essey.balanceOf(wallet[i]);
        (uint256 s0, uint256 t0) = _sinkBalances();

        essey.approve(address(exchange), cost);
        exchange.snipe(id, cost);

        require(don.ownerOf(id) == wallet[i], _err("SNIPE not received", i));
        require(e0 - essey.balanceOf(wallet[i]) == cost, _err("SNIPE cost mismatch", i));
        _assertFeeRouted(s0, t0, fee, "SNIPE", i);
        console.log("[SNIPE] wallet", i, "don");
        console.log("        id", id);
    }

    /// SELL a Don back at price - 8% fee. Assert net proceeds and 70/30 fee routing.
    function _sell(uint256 i, uint256 id) internal {
        uint256 p = exchange.price();
        uint256 fee = exchange.feeOn(exchange.swapFeeBps());
        uint256 net = p - fee;
        uint256 e0 = essey.balanceOf(wallet[i]);
        (uint256 s0, uint256 t0) = _sinkBalances();

        don.approve(address(exchange), id);
        exchange.sell(id, net);

        require(essey.balanceOf(wallet[i]) - e0 == net, _err("SELL net mismatch", i));
        require(don.ownerOf(id) == address(exchange), _err("SELL not returned", i));
        _assertFeeRouted(s0, t0, fee, "SELL", i);
        console.log("[SELL] wallet", i, "don returned");
        console.log("       id", id);
    }

    // ----------------------------------------------------------------- fee-routing assertion

    function _sinkBalances() internal view returns (uint256 s, uint256 t) {
        s = essey.balanceOf(feeSink);
        t = essey.balanceOf(treasury);
    }

    /// Assert the 8%/12% fee split. 70% -> feeSink (the fee->stock router), 30% -> treasury. When the sink
    /// and treasury are the SAME address (interim testnet wiring: feeSink=treasury until the DonFeeRouter is
    /// wired), the combined credit must equal the whole fee.
    function _assertFeeRouted(uint256 s0, uint256 t0, uint256 fee, string memory tag, uint256 i) internal view {
        uint256 toStock = (fee * exchange.stockShareBps()) / 10_000;
        uint256 toTreasury = fee - toStock;
        if (feeSink == treasury) {
            require(essey.balanceOf(feeSink) - s0 == fee, _err(string.concat(tag, " fee!=sink+treasury"), i));
        } else {
            require(essey.balanceOf(feeSink) - s0 == toStock, _err(string.concat(tag, " 70% !-> feeSink"), i));
            require(essey.balanceOf(treasury) - t0 == toTreasury, _err(string.concat(tag, " 30% !-> treasury"), i));
        }
    }

    // ----------------------------------------------------------------- summary

    function _summary() internal view {
        console.log("");
        console.log("=== DON E2E COMPLETE ===");
        console.log("wallets        ", nWallets);
        console.log("total minted   ", don.totalMinted());
        console.log("desk inventory ", exchange.inventoryCount());
        console.log("floorPerDon    ", reserve.floorPerDon() / 1e18, "ESSEY");
        console.log("feeSink        ", feeSink);
        console.log("feeSink ESSEY  ", essey.balanceOf(feeSink) / 1e18);
        console.log("NOTE: feeSink->Bell USDG conversion is a keeper flush (needs a live Uni-V3 pool); the");
        console.log("      harness proves fees REACH the sink, not the swap leg. Liquidation: run liquidationFork().");
    }

    function _err(string memory what, uint256 i) internal pure returns (string memory) {
        return string.concat("DonE2E:", what, " wallet#", vm.toString(i));
    }

    // ================================================================= LIQUIDATION (fork sim ONLY)
    //
    // The calendar-default liquidation needs to fast-forward past expiry + the 30-day grace, which a live
    // chain cannot do. This entrypoint is therefore a FORK SIMULATION: it uses vm.warp / vm.prank / vm.deal
    // and MUST be run WITHOUT --broadcast, against a fork of the seeded stack:
    //
    //   forge script script/DonE2E.s.sol:DonE2E --sig "liquidationFork()" \
    //     --rpc-url rh_testnet   # (a fork; no --broadcast, no keys used)
    //
    // It borrows against a Don, warps past default, has a DIFFERENT actor liquidate, and asserts the Don is
    // seized+redeemed, the caller gets the 1% tip, and the surplus returns to the borrower.
    address liqBorrower;
    address liqLiquidator;

    function liquidationFork() external {
        _load();
        liqBorrower = address(uint160(uint256(keccak256("e2e-liq-borrower"))));
        liqLiquidator = address(uint160(uint256(keccak256("e2e-liq-caller"))));

        _liqEnsureFunds();
        uint256 id = _liqMintAndBorrow();
        _liqWarpAndSettle(id);
    }

    /// Best run against a fork of the SEEDED stack (reserve + loan already funded). If the fork isn't seeded,
    /// top up by impersonating the treasury (holds the ESSEY supply on a fresh deploy) — a local-sim-only
    /// move (vm.prank), never a broadcast.
    function _liqEnsureFunds() internal {
        if (reserve.floorPerDon() == 0 && essey.balanceOf(treasury) >= reserveFund) {
            vm.prank(treasury);
            essey.transfer(address(reserve), reserveFund);
        }
        require(reserve.floorPerDon() > 0, "LIQ: fork has no floor (seed the stack first)");
        uint256 want = loan.maxBorrow();
        if (loan.lendable() < want && essey.balanceOf(treasury) >= want * 2) {
            vm.prank(treasury);
            essey.transfer(address(loan), want * 2);
        }
        require(loan.lendable() >= want, "LIQ: fork loan pot too thin (seed the stack first)");
    }

    /// Mint a Don to the borrower (via the impersonated distributor admin) and BORROW against it.
    function _liqMintAndBorrow() internal returns (uint256 id) {
        bytes32[] memory combos = new bytes32[](1);
        combos[0] = keccak256(abi.encode("e2e-liq-don", block.timestamp));
        vm.prank(dist.admin());
        dist.mintReserved(liqBorrower, combos);
        id = don.totalMinted();
        require(don.ownerOf(id) == liqBorrower, "LIQ: mint to borrower failed");

        uint256 term = loan.MIN_TERM();
        uint256 prepaid = loan.prepaidEth(term);
        vm.deal(liqBorrower, prepaid + 1 ether);
        vm.prank(liqBorrower);
        loan.borrow{value: prepaid}(id, term);
        require(don.liened(id), "LIQ: not liened");
    }

    /// Warp past expiry + grace, liquidate from a DIFFERENT wallet, and assert the seize/redeem waterfall:
    /// Don locked in the reserve, 1% caller tip, surplus back to the borrower.
    function _liqWarpAndSettle(uint256 id) internal {
        uint256 principal = loan.debtOf(id);
        (,, uint64 expiry,) = loan.loans(id);
        vm.warp(uint256(expiry) + loan.defaultGraceSeconds() + 1);

        uint256 proceeds = reserve.floorPerDon(); // redeem pays the floor
        uint256 tip = (proceeds * loan.liqTipBps()) / 10_000;
        uint256 surplus = proceeds - tip - principal; // available - principalRecovered
        uint256 bBefore = essey.balanceOf(liqBorrower);
        uint256 lBefore = essey.balanceOf(liqLiquidator);

        vm.prank(liqLiquidator);
        loan.liquidate(id);

        require(loan.debtOf(id) == 0, "LIQ: loan not cleared");
        require(don.ownerOf(id) == address(reserve), "LIQ: Don not seized/redeemed");
        require(essey.balanceOf(liqLiquidator) - lBefore == tip, "LIQ: caller tip wrong");
        require(essey.balanceOf(liqBorrower) - bBefore == surplus, "LIQ: surplus to borrower wrong");

        console.log("=== LIQUIDATION FORK SIM PASSED ===");
        console.log("don id     ", id);
        console.log("principal  ", principal / 1e18, "ESSEY");
        console.log("proceeds   ", proceeds / 1e18, "ESSEY");
        console.log("caller tip ", tip / 1e18, "ESSEY (1%)");
        console.log("surplus    ", surplus / 1e18, "ESSEY -> borrower");
    }
}
