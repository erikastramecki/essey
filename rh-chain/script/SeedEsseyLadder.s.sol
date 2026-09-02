// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    EsseyLadderSeeder,
    IUniV3FactoryMin,
    IUniV3PoolMin,
    TickMath,
    FixedPoint96
} from "../src/market/EsseyLadderSeeder.sol";

/// SeedEsseyLadder — THE one-command Phase-6 liquidity step (MAINNET-GO-LIVE, before WL mint opens).
///
/// One `forge script … --broadcast` from the founder key does, in order:
///   1. deploy the EsseyLadderSeeder (locked-POL holder, no withdraw path),
///   2. transfer the 300M-ESSEY seed into it,
///   3. seeder.seed(): create + initialize the ESSEY/USDG 3000 pool at the ruled open price and
///      mint the three single-sided sell-side tranches (A/B/C) — zero USDG required,
///   4. verify on-chain (slot0 == target, three positions live, seeder drained) and print the table.
///
/// Mainnet:
///   ESSEY=<token> TREASURY=<multisig> forge script script/SeedEsseyLadder.s.sol \
///     --rpc-url rh_mainnet --broadcast --private-key $FOUNDER_PK --slow
///   (USDG + FACTORY default to the MAINNET-CONFIG verified addresses; override for rehearsals.)
///
/// ════════════════════════ FOUNDER-TUNABLE NUMBERS — the go-live sitting edits ONLY this block ═══
///
/// Opening price (L-1, RULED): $0.00002813 / ESSEY = $250,000 FDV on 8,888,888,888 supply.
///   raw pool price (token0=ESSEY, 6-dec USDG): 0.00002813 · 10^6 / 10^18 = 2.813e-17
///   exact tick:  log(2.813e-17) / log(1.0001) = −381,116.005
///   floor-aligned to tickSpacing 60 (fee 3000, verified on-chain): −381,120
///   ⇒ actual open = 1.0001^−381120 · 10^12 = $0.000028117 (−0.04% vs ruled; the nearest grid
///     point ABOVE would open +0.56% high — low side chosen: never open above the ruled price).
///
/// Tranche boundaries (ADDENDUM ladder — multiples of the open, tick offsets aligned to 60):
///     3×: ln3 /ln1.0001 = 10,986.7 → 10,980 (2.9980×)     10×: 23,027.0 → 23,040 (10.013×)
///    50×: ln50/ln1.0001 = 39,122.2 → 39,120 (49.989×)
///
/// v3 traversal law (single-sided X over [pa,pb] costs buyers X·√(pa·pb) and leaves exactly that
/// USDG as the support wall):  A: 40M → ≈$1.96k   B: 100M → ≈$15.5k   C: 160M → ≈$101.3k
/// Full ladder ≈ $118.7k of cumulative buys walks price 50× ($12.5M FDV).
/// ════════════════════════════════════════════════════════════════════════════════════════════════
contract SeedEsseyLadder is Script {
    // -------- the sitting's knobs --------
    int24 internal constant OPEN_TICK_E0 = -381120; // token0=ESSEY orientation; seeder mirrors if needed
    int24 internal constant OFF_OPEN = 0;
    int24 internal constant OFF_3X = 10980;
    int24 internal constant OFF_10X = 23040;
    int24 internal constant OFF_50X = 39120;
    uint256 internal constant AMT_A = 40_000_000e18; //  open → 3×   (discovery)
    uint256 internal constant AMT_B = 100_000_000e18; //  3×  → 10×  (mid wall)
    uint256 internal constant AMT_C = 160_000_000e18; // 10×  → 50×  (stability shelf)
    uint256 internal constant MAX_CORRECTION = 1_000_000e18; // anti-griefing ESSEY budget (extra, on top of seed)
    uint24 internal constant FEE = 3000; // matches shipped DonFeeRouter.esseyPoolFee
    // -------------------------------------

    uint256 internal constant SEED_TOTAL = AMT_A + AMT_B + AMT_C; // 300M

    // MAINNET-CONFIG verified defaults (rehearsals override via env)
    address internal constant MAINNET_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6-dec, verified
    address internal constant MAINNET_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; // verified

    function _tranches() internal pure returns (EsseyLadderSeeder.Tranche[] memory t) {
        t = new EsseyLadderSeeder.Tranche[](3);
        t[0] = EsseyLadderSeeder.Tranche(OFF_OPEN, OFF_3X, AMT_A);
        t[1] = EsseyLadderSeeder.Tranche(OFF_3X, OFF_10X, AMT_B);
        t[2] = EsseyLadderSeeder.Tranche(OFF_10X, OFF_50X, AMT_C);
    }

    function run() external virtual {
        IERC20 essey = IERC20(vm.envAddress("ESSEY"));
        IERC20 usdg = IERC20(vm.envOr("USDG", MAINNET_USDG));
        IUniV3FactoryMin factory = IUniV3FactoryMin(vm.envOr("FACTORY", MAINNET_FACTORY));
        address treasury = vm.envOr("TREASURY", msg.sender);

        vm.startBroadcast();
        EsseyLadderSeeder seeder = _broadcastSeed(essey, usdg, factory, treasury);
        vm.stopBroadcast();

        _verifyAndReport(seeder, essey, usdg);
    }

    /// The atomic sequence, shared by mainnet + rehearsal. Caller wraps in start/stopBroadcast.
    function _broadcastSeed(IERC20 essey, IERC20 usdg, IUniV3FactoryMin factory, address treasury)
        internal
        returns (EsseyLadderSeeder seeder)
    {
        seeder = new EsseyLadderSeeder(essey, usdg, factory, FEE, treasury);
        require(essey.transfer(address(seeder), SEED_TOTAL), "seed transfer failed");
        seeder.seed(OPEN_TICK_E0, _tranches(), MAX_CORRECTION);
    }

    // ================================================================== on-chain verification

    function _verifyAndReport(EsseyLadderSeeder seeder, IERC20 essey, IERC20 usdg) internal view {
        IUniV3PoolMin pool = seeder.pool();
        bool esseyIs0 = address(essey) < address(usdg);

        // 1. price == target
        (uint160 sqrtP, int24 tick,,,,,) = pool.slot0();
        int24 wantTick = esseyIs0 ? OPEN_TICK_E0 : -OPEN_TICK_E0;
        uint160 want = TickMath.getSqrtRatioAtTick(wantTick);
        require(sqrtP == want, "VERIFY: slot0 sqrtPrice != target");
        // The pool derived this tick from OUR sqrt value with ITS canonical TickMath — equality here
        // proves the vendored getSqrtRatioAtTick agrees bit-for-bit with the deployed pool bytecode.
        require(tick == wantTick, "VERIFY: slot0 tick != target tick");

        // 2. three positions live with expected liquidity, registered in the pool itself
        require(seeder.positionCount() == 3, "VERIFY: tranche count");
        uint256 esseyInPool;
        for (uint256 i = 0; i < 3; i++) {
            (,, uint128 liq, uint256 used) = seeder.positions(i);
            (uint128 poolLiq,,,,) = pool.positions(seeder.positionKey(i));
            require(poolLiq == liq && liq > 0, "VERIFY: pool position liquidity mismatch");
            esseyInPool += used;
        }

        // 3. seeder drained (locked POL is IN the pool, not loose in the holder)
        require(essey.balanceOf(address(seeder)) <= 1e18, "VERIFY: seeder not drained");
        require(usdg.balanceOf(address(seeder)) == 0, "VERIFY: seeder holds USDG?");

        _report(seeder, pool, esseyIs0, sqrtP, tick, esseyInPool);
    }

    function _report(
        EsseyLadderSeeder seeder,
        IUniV3PoolMin pool,
        bool esseyIs0,
        uint160 sqrtP,
        int24 tick,
        uint256 esseyInPool
    ) internal view {
        console.log("");
        console.log("=============== $ESSEY LIQUIDITY LADDER SEEDED ===============");
        console.log("pool (ESSEY/USDG fee 3000):", address(pool));
        console.log("seeder (locked POL holder):", address(seeder));
        console.log("ESSEY is token%s of the pool", esseyIs0 ? "0" : "1");
        console.log("slot0 tick:", tick);
        console.log("slot0 sqrtPriceX96:", sqrtP);
        console.log("open price: $%s e-18 / ESSEY", _priceE18(sqrtP, esseyIs0));
        console.log("FDV at open: $%s", (_priceE18(sqrtP, esseyIs0) * 8_888_888_888) / 1e18);
        console.log("ESSEY locked into the ladder:", esseyInPool / 1e18, "(18-dec units)");
        console.log("");
        console.log("tranche | ticks (pool-space) | liquidity | ESSEY in");
        for (uint256 i = 0; i < 3; i++) {
            (int24 lo, int24 hi, uint128 liq, uint256 used) = seeder.positions(i);
            console.log("  #%s  lo:", i, vm.toString(lo));
            console.log("       hi:", vm.toString(hi));
            console.log("       L:", liq);
            console.log("       ESSEY:", used / 1e18);
        }
        console.log("");
        console.log("expected walk (v3 law X*sqrt(pa*pb)): ~$1.96k -> 3x | +~$15.5k -> 10x | +~$101.3k -> 50x");
        console.log("=================================================================");
    }

    /// Spot USD price per whole ESSEY, scaled by 1e18, from sqrtPriceX96 (USDG 6-dec).
    /// token0=ESSEY: raw = (sqrtP/Q96)^2 [USDG-units per ESSEY-wei]; USD/ESSEY = raw · 1e12 → e18: raw·1e30.
    /// token1=ESSEY: raw is ESSEY-wei per USDG-unit; USD/ESSEY = 1e12/raw → e18: 1e30/raw.
    function _priceE18(uint160 sqrtP, bool esseyIs0) internal pure returns (uint256) {
        uint256 r96 = Math.mulDiv(sqrtP, sqrtP, FixedPoint96.Q96); // raw price in Q96
        return esseyIs0 ? Math.mulDiv(r96, 1e30, FixedPoint96.Q96) : Math.mulDiv(1e30, FixedPoint96.Q96, r96);
    }
}
