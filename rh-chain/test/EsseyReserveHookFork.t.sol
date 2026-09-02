// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {EsseyReserveHook, IEsseyReserve} from "../src/market/EsseyReserveHook.sol";

/// Fork test against the REAL RH-mainnet (4663) PoolManager 0x8366… — proves our hook binds to genuine
/// v4-core: the manager validates our mined permission-flag address and drives our beforeInitialize on a
/// real `initialize`. Best-effort on network: if the fork RPC is unavailable the suite skips rather than
/// failing red. A full real-swap E2E (liquidity + swap through the manager's unlock) is delegated to the
/// essey-harness on-chain proof — the seam, not this unit-level fork check.
contract EsseyReserveHookForkTest is Test {
  address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
  address constant ESSEY = 0x315790B57C19141B34C4653a91b096Cf3f071610;
  address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
  address constant RESERVE = 0xd970Ca726188e38982906Ae2284D2bdB80205A7b;

  uint24 constant POOL_FEE = 3000;
  int24 constant TICK_SPACING = 60;
  uint160 constant OPEN_PRICE = uint160(1 << 96); // pinned launch price; initialize must match it
  address constant DONS = address(0xD0);
  address constant HOLDERS = address(0x40);
  address constant GOV = address(0x60);

  bool forked;

  function setUp() public {
    try vm.createSelectFork(vm.rpcUrl("rh_mainnet")) {
      forked = true;
    } catch {
      forked = false;
    }
  }

  function _deployHook() internal returns (EsseyReserveHook) {
    bytes memory args = abi.encode(
      IPoolManager(POOL_MANAGER),
      IEsseyReserve(RESERVE),
      Currency.wrap(ESSEY),
      Currency.wrap(USDG),
      Currency.wrap(USDG), // feeCurrency = the quote
      POOL_FEE,
      TICK_SPACING,
      DONS,
      HOLDERS,
      GOV,
      uint256(100),
      uint256(9_800),
      uint256(45),
      uint256(4_500),
      uint256(4_000),
      uint256(1_500),
      OPEN_PRICE
    );
    bytes32 initHash = keccak256(abi.encodePacked(type(EsseyReserveHook).creationCode, args));
    for (uint256 s = 0; s < 500_000; s++) {
      address addr =
        address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(s), initHash)))));
      if (uint160(addr) & 0x3FFF == 0x24CC && addr.code.length == 0) {
        return new EsseyReserveHook{salt: bytes32(s)}(
          IPoolManager(POOL_MANAGER),
          IEsseyReserve(RESERVE),
          Currency.wrap(ESSEY),
          Currency.wrap(USDG),
          Currency.wrap(USDG),
          POOL_FEE,
          TICK_SPACING,
          DONS,
          HOLDERS,
          GOV,
          uint256(100),
          uint256(9_800),
          uint256(45),
          uint256(4_500),
          uint256(4_000),
          uint256(1_500),
          OPEN_PRICE
        );
      }
    }
    revert("no salt");
  }

  function test_fork_real_manager_accepts_hook_and_initializes() public {
    if (!forked) {
      emit log("SKIP: rh_mainnet fork unavailable");
      return;
    }
    EsseyReserveHook hook = _deployHook();
    assertEq(hook.poolManager() == IPoolManager(POOL_MANAGER), true, "not bound to real manager");
    assertEq(uint160(address(hook)) & 0x3FFF, 0x24CC, "flags not encoded in address");

    PoolKey memory key = PoolKey({
      currency0: Currency.wrap(ESSEY),
      currency1: Currency.wrap(USDG),
      fee: POOL_FEE,
      tickSpacing: TICK_SPACING,
      hooks: IHooks(address(hook))
    });

    // The genuine v4-core manager validates the hook address flags AND drives beforeInitialize; a fork
    // that rejected our hook or a wrong beforeInitialize would revert here.
    int24 tick = IPoolManager(POOL_MANAGER).initialize(key, OPEN_PRICE);
    assertEq(tick, 0, "tick0 for price 1");
    assertEq(hook.launchTime(), 0, "clock must NOT be stamped at initialize; it is stamped at the atomic seed");
  }

  function test_fork_wrong_key_rejected_by_hook_on_real_manager() public {
    if (!forked) {
      emit log("SKIP: rh_mainnet fork unavailable");
      return;
    }
    EsseyReserveHook hook = _deployHook();
    PoolKey memory bad = PoolKey({
      currency0: Currency.wrap(ESSEY),
      currency1: Currency.wrap(USDG),
      fee: 500, // not the pinned POOL_FEE
      tickSpacing: TICK_SPACING,
      hooks: IHooks(address(hook))
    });
    vm.expectRevert(); // manager bubbles the hook's WrongPoolKey through beforeInitialize
    IPoolManager(POOL_MANAGER).initialize(bad, uint160(1 << 96));
  }
}
