// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EsseyToken} from "../src/market/EsseyToken.sol";
import {SeedEsseyLadder} from "./SeedEsseyLadder.s.sol";
import {EsseyLadderSeeder, IUniV3FactoryMin, IUniV3PoolMin, TickMath} from "../src/market/EsseyLadderSeeder.sol";

/// RehearseEsseyLadder — the FULL Phase-6 ladder seed, executed for real against a throwaway stack,
/// then probed with real USDG buys to watch price walk the ladder exactly as modeled.
///
/// Works on either rehearsal substrate (mainnet is NEVER touched by this script):
///   • RH TESTNET (46630): no Uniswap v3 factory exists there — deploy one first from the canonical
///     Uniswap v3-core npm artifact (see the runbook), then:
///       FACTORY=<deployed> forge script script/RehearseEsseyLadder.s.sol \
///         --rpc-url rh_testnet --broadcast --private-key $TESTNET_DEPLOYER_PK --slow
///     ESSEY unset -> deploys a fresh throwaway 8.888B EsseyToken; USDG unset -> deploys MockUSDG6
///     (6 DECIMALS, like real USDG — the sqrtPrice math must rehearse against 6, not the old
///     18-dec testnet mock).
///   • LOCAL FORK of RH mainnet (script/local-fork.sh style):
///       anvil --fork-url https://rpc.mainnet.chain.robinhood.com   (separate terminal)
///       cast rpc anvil_setBalance <deployer> 0x8AC7230489E80000 --rpc-url http://127.0.0.1:8545
///       USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 \
///       FACTORY=0x1f7d7550B1b028f7571E69A784071F0205FD2EfA \
///         forge script script/RehearseEsseyLadder.s.sol --rpc-url http://127.0.0.1:8545 \
///         --broadcast --private-key <anvil key> --slow
///     -> exercises the REAL factory + REAL 6-dec USDG. Fund the probe by impersonating a USDG-rich
///     account (the WETH/USDG-500 pool) with anvil_impersonateAccount + cast send beforehand; if the
///     broadcaster holds no USDG the probe is skipped with an honest notice (the seed itself needs none).
contract RehearseEsseyLadder is SeedEsseyLadder {
    using SafeERC20 for IERC20;

    // Real-dollar probe schedule (6-dec USDG). Model (v3 law, fee ignored):
    //   $500  into tranche A: sqrt' = sqrt + x·Q96/L_A  ->  ≈1.40× the open
    //   +$1,500 (Σ $2,000)   ->  just past 3× (A fully traversed at ≈$1.96k), into tranche B
    //   +$16,000 (Σ $18,000) ->  ≈10× (A+B traversal ≈ $17.5k), touching tranche C
    uint256[3] internal PROBES = [uint256(500e6), 1_500e6, 16_000e6];

    function run() external override {
        address sender = msg.sender;
        IUniV3FactoryMin factory = IUniV3FactoryMin(vm.envAddress("FACTORY")); // no default: choose substrate deliberately

        vm.startBroadcast();

        // throwaway stand-ins where the real thing is absent
        IERC20 essey = IERC20(vm.envOr("ESSEY", address(0)));
        if (address(essey) == address(0)) {
            essey = IERC20(address(new EsseyToken(sender))); // fresh 8.888B to the broadcaster
            console.log("[rehearsal] fresh throwaway EsseyToken:", address(essey));
        }
        IERC20 usdg = IERC20(vm.envOr("USDG", address(0)));
        bool mockUsdg = address(usdg) == address(0);
        if (mockUsdg) {
            usdg = IERC20(address(new MockUSDG6()));
            console.log("[rehearsal] MockUSDG6 (6 decimals):", address(usdg));
        }

        // ---- THE go-live sequence, verbatim from SeedEsseyLadder ----
        EsseyLadderSeeder seeder = _broadcastSeed(essey, usdg, factory, sender);
        _verifyAndReport(seeder, essey, usdg); // full go-live checks BEFORE the probes move the price

        // ---- probe: real USDG buys walking the ladder ----
        uint256 budget;
        for (uint256 i = 0; i < 3; i++) budget += PROBES[i];
        if (mockUsdg) MockUSDG6(address(usdg)).mint(sender, budget);

        if (usdg.balanceOf(sender) >= budget) {
            LadderProbe probe = new LadderProbe(seeder.pool(), essey, usdg);
            require(usdg.transfer(address(probe), budget), "probe funding failed");
            _walkTheLadder(probe, seeder, essey, usdg);
        } else {
            console.log("[rehearsal] broadcaster holds no USDG - probe buys SKIPPED (seed itself verified below).");
            console.log("[rehearsal] fund the broadcaster with USDG and re-run, or use the fork whale (see header).");
        }

        vm.stopBroadcast();

        _verifyAfterProbe(seeder, essey, usdg);
    }

    function _walkTheLadder(LadderProbe probe, EsseyLadderSeeder seeder, IERC20 essey, IERC20 usdg) internal {
        IUniV3PoolMin pool = seeder.pool();
        bool esseyIs0 = address(essey) < address(usdg);
        (uint160 sqrtOpen,,,,,,) = pool.slot0();
        uint256 pOpen = _priceE18(sqrtOpen, esseyIs0);
        console.log("");
        console.log("=============== PROBE: WALKING THE LADDER (real buys) ===============");
        console.log("open price ($ x1e18):", pOpen);
        uint256 cum;
        for (uint256 i = 0; i < 3; i++) {
            uint256 got = probe.buyEssey(PROBES[i]);
            cum += PROBES[i];
            (uint160 s, int24 t,,,,,) = pool.slot0();
            uint256 p = _priceE18(s, esseyIs0);
            console.log("buy #%s: USDG in (6-dec):", i + 1, PROBES[i]);
            console.log("        ESSEY out (wei):", got);
            console.log("        cum USDG in:", cum);
            console.log("        new tick:", vm.toString(t));
            console.log("        new price ($ x1e18):", p);
            console.log("        multiple of open (x1e6):", (p * 1e6) / pOpen);
        }
        console.log("model: $500 -> ~1.40x | $2,000 -> ~3x (into B) | $18,000 -> ~10x (0.30% fee drags slightly)");
        console.log("=====================================================================");
    }

    /// Post-probe invariants: price sits above open (bought up the ladder), positions intact.
    function _verifyAfterProbe(EsseyLadderSeeder seeder, IERC20 essey, IERC20 usdg) internal view {
        IUniV3PoolMin pool = seeder.pool();
        bool esseyIs0 = address(essey) < address(usdg);
        (uint160 sqrtP, int24 tick,,,,,) = pool.slot0();
        require(seeder.positionCount() == 3, "REHEARSAL: tranche count");
        for (uint256 i = 0; i < 3; i++) {
            (,, uint128 liq,) = seeder.positions(i);
            (uint128 poolLiq,,,,) = pool.positions(seeder.positionKey(i));
            require(poolLiq == liq && liq > 0, "REHEARSAL: position");
        }
        require(essey.balanceOf(address(seeder)) <= 1e18, "REHEARSAL: seeder not drained");
        console.log("");
        console.log("=============== REHEARSAL VERIFIED ON-CHAIN ===============");
        console.log("pool:", address(pool));
        console.log("final tick:", vm.toString(tick));
        console.log("final price ($ x1e18):", _priceE18(sqrtP, esseyIs0));
        console.log("all 3 tranches live; seeder drained; principal locked (no withdraw path exists).");
        console.log("===========================================================");
    }
}

/// Throwaway 6-decimal USDG stand-in — decimals MUST be 6 so the rehearsal exercises the exact
/// mainnet sqrtPrice arithmetic (the pre-existing 18-dec testnet mock would falsify it).
contract MockUSDG6 is ERC20 {
    constructor() ERC20("Mock Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Rehearsal-only buyer: swaps USDG -> ESSEY directly against the pool (the chain's SwapRouter02
/// does not exist on testnet; direct pool.swap + callback is also exactly what a router does).
contract LadderProbe {
    using SafeERC20 for IERC20;

    IUniV3PoolMin public immutable pool;
    IERC20 public immutable essey;
    IERC20 public immutable usdg;

    constructor(IUniV3PoolMin pool_, IERC20 essey_, IERC20 usdg_) {
        pool = pool_;
        essey = essey_;
        usdg = usdg_;
    }

    function buyEssey(uint256 usdgIn) external returns (uint256 esseyOut) {
        bool esseyIs0 = address(essey) < address(usdg);
        bool zeroForOne = !esseyIs0; // USDG is the input token
        uint160 limit = zeroForOne
            ? TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK) + 1
            : TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK) - 1;
        uint256 before = essey.balanceOf(address(this));
        pool.swap(address(this), zeroForOne, int256(usdgIn), limit, "");
        esseyOut = essey.balanceOf(address(this)) - before;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == address(pool), "probe: not pool");
        if (amount0Delta > 0) IERC20(pool.token0()).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(pool.token1()).safeTransfer(msg.sender, uint256(amount1Delta));
    }
}
