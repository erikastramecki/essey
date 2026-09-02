// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {EsseyReserveHook, IEsseyReserve} from "../src/market/EsseyReserveHook.sol";

/// Deploy-prep for the Option-B hooked $ESSEY/USDG V4 pool on RH mainnet (4663). PREP ONLY — the founder
/// runs the broadcast. One on-chain action when broadcast:
///   1. CREATE2-deploy EsseyReserveHook at a mined address whose low 14 bits == 0x24CC (beforeInitialize |
///      afterAddLiquidity | beforeSwap | afterSwap | beforeSwapReturnsDelta | afterSwapReturnsDelta — the
///      flags the constructor's validateHookPermissions enforces). Constructor args are fixed BEFORE mining —
///      they change the init-code hash and therefore the address.
///
/// NOT done here: initialize AND seed. Both happen atomically in LaunchSeeder.seed() — initialize alone would
/// leave a live-but-empty pool window between init and seed, so the script deliberately deploys only the hook
/// (LOW-2). Option A's EsseyLadderSeeder is Uniswap-V3-native (pool.mint) and cannot seed a V4 pool; the
/// single-sided V4 ladder seeder (LaunchSeeder) is a SEPARATE deliverable that inits+seeds in one call.
///
/// Run (founder):
///   FOUNDRY_PROFILE=v4 SQRT_PRICE_X96=<opening price> DONS_SINK=0x.. HOLDERS_SINK=0x.. GOVERNOR=0x.. \
///     forge script script/DeployEsseyV4Pool.s.sol --rpc-url rh_mainnet --broadcast
contract DeployEsseyV4Pool is Script {
  // RH mainnet 4663 anchors (docs/OPTION-B-V4-AUDIT.md, VERIFIED on-chain 2026-08-30).
  address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
  address constant ESSEY = 0x315790B57C19141B34C4653a91b096Cf3f071610; // currency0 (18 dec)
  address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // currency1 (6 dec)
  address constant RESERVE = 0xd970Ca726188e38982906Ae2284D2bdB80205A7b; // adminless EsseyReserve
  // Foundry's deterministic CREATE2 factory — the deployer `new{salt:}` routes through in --broadcast.
  address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

  // Economics (docs/OPTION-B-V4-ECON.md §1/§2). Founder-tunable; immutable once deployed.
  uint24 constant POOL_FEE = 3000; // pool LP fee; the hook's tax is separate
  int24 constant TICK_SPACING = 60; // matches fee 3000 / the ESSEY/USDG ladder
  uint256 constant BASE_FEE_BPS = 100; // 1%
  // base + snipe MUST be < 10000: the buy path skims the quote out of the swap INPUT in beforeSwap, so a
  // 100% fee would zero the swapped amount and revert. 9800 keeps a ~99% launch surcharge with headroom.
  uint256 constant SNIPE_START_BPS = 9_800; // 98% (cap 9900 < BPS)
  uint256 constant SNIPE_SECONDS = 45; // 30–60s window at RH's ~0.1s blocks
  // Fee-model v2 default split of the BASE fee (docs/ESSEY-FEE-MODEL-V2-HOLDER-AIRDROP-SCOPE.md §0). Three
  // buckets; ops and POL eliminated. The holder-airdrop bucket funds the HolderDistributor.
  // PENDING FOUNDER CONFIRMATION: exact split numbers are the economist's proposal, not yet founder-final.
  uint256 constant RESERVE_SHARE_BPS = 4_500;
  uint256 constant HOLDERS_SHARE_BPS = 4_000;
  uint256 constant DONS_SHARE_BPS = 1_500;

  function run() external {
    address donsSink = vm.envAddress("DONS_SINK");
    address holdersSink = vm.envAddress("HOLDERS_SINK"); // the HolderDistributor the holder-airdrop bucket routes to
    address governor = vm.envAddress("GOVERNOR"); // bounded split governor; renounced by lock()
    // Founder-set launch price. Single source of truth: it is pinned into the hook's constructor AND passed to
    // initialize below, so beforeInitialize's WrongOpeningPrice check can only match the founder's own tx.
    uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96")); // opening price; no default, must be set

    (Currency c0, Currency c1) = (Currency.wrap(ESSEY), Currency.wrap(USDG));
    require(ESSEY < USDG, "sort"); // currency0 < currency1

    bytes memory args = abi.encode(
      IPoolManager(POOL_MANAGER),
      IEsseyReserve(RESERVE),
      c0,
      c1,
      c1, // feeCurrency = USDG (the quote) — every skim lands here, never in $ESSEY
      POOL_FEE,
      TICK_SPACING,
      donsSink,
      holdersSink,
      governor,
      BASE_FEE_BPS,
      SNIPE_START_BPS,
      SNIPE_SECONDS,
      RESERVE_SHARE_BPS,
      HOLDERS_SHARE_BPS,
      DONS_SHARE_BPS,
      sqrtPriceX96
    );
    // beforeInitialize | afterAddLiquidity | beforeSwap | afterSwap | beforeSwapReturnsDelta | afterSwapReturnsDelta
    uint160 flags = uint160(0x24CC);
    (address mined, bytes32 salt) =
      HookMiner.find(CREATE2_DEPLOYER, flags, type(EsseyReserveHook).creationCode, args);

    console2.log("mined hook address", mined);
    console2.logBytes32(salt);

    vm.startBroadcast();
    EsseyReserveHook hook = new EsseyReserveHook{salt: salt}(
      IPoolManager(POOL_MANAGER),
      IEsseyReserve(RESERVE),
      c0,
      c1,
      c1,
      POOL_FEE,
      TICK_SPACING,
      donsSink,
      holdersSink,
      governor,
      BASE_FEE_BPS,
      SNIPE_START_BPS,
      SNIPE_SECONDS,
      RESERVE_SHARE_BPS,
      HOLDERS_SHARE_BPS,
      DONS_SHARE_BPS,
      sqrtPriceX96
    );
    require(address(hook) == mined, "mined mismatch");
    vm.stopBroadcast();

    // init+seed is one atomic tx via LaunchSeeder.seed() (no empty-pool window). The founder deploys the
    // seeder against this hook's PoolKey and calls seed() with the pre-funded ESSEY ladder.
    console2.log("hook deployed (pool NOT initialized here; LaunchSeeder.seed inits+seeds atomically)", address(hook));
  }
}
