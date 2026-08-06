// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Essey Private — Phase 1. Deploys the shielded USDG pool (Nova core, de-bridged) + its front door.
//
//   USDG=0x7461E670d44FF4397A3E48030C5b06f6163a5De2 \
//   PK=$TESTNET_DEPLOYER_PK forge script script/DeployShieldedPool.s.sol --rpc-url rh_testnet \
//     --broadcast --private-key $PK --gas-estimate-multiplier 300
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EsseyShieldedPool, IPoolVerifier, IEsseyPoolGate} from "../src/private/pool/EsseyShieldedPool.sol";
import {EsseyPoolGate} from "../src/private/pool/EsseyPoolGate.sol";
import {Groth16Verifier} from "../src/private/pool/PoolVerifier2.sol";

contract DeployShieldedPool is Script {
  // Production depth. LEVELS is bound to the compiled circuit (transaction2.circom Transaction(20,...)):
  // a depth-20 tree holds 2^20 = 1,048,576 leaves = ~524k transactions over the pool's life (every
  // deposit/withdraw/transfer inserts 2 leaves). To change depth, recompile the circuit + regenerate the
  // zkey + PoolVerifier2.sol and set LEVELS to match (contract zeros() supports up to 23).
  // NOTE: the deployed zkey still uses a single-contributor setup — a real multi-party trusted-setup
  // ceremony remains a pre-mainnet gate (see src/private/pool/README.md).
  uint32 internal constant LEVELS = 20;

  /// Deploy the circomlib-generated Poseidon(2) hasher from its raw creation bytecode.
  function deployHasher() internal returns (address hasher) {
    bytes memory code = vm.parseBytes(_trim(vm.readFile("circuits-nova/build/Hasher2.bytecode.txt")));
    assembly {
      hasher := create(0, add(code, 0x20), mload(code))
    }
    require(hasher != address(0), "hasher deploy failed");
  }

  function run() external {
    address usdg = vm.envAddress("USDG");
    address operator = msg.sender; // the ASP role; openMode=true on testnet so anyone can deposit
    uint256 maxDeposit = type(uint256).max;

    vm.startBroadcast();
    address hasher = deployHasher();
    Groth16Verifier verifier = new Groth16Verifier();
    EsseyPoolGate gate = new EsseyPoolGate(operator, true);
    EsseyShieldedPool pool = new EsseyShieldedPool(
      IPoolVerifier(address(verifier)), LEVELS, hasher, IERC20(usdg), IEsseyPoolGate(address(gate)), msg.sender, maxDeposit
    );
    vm.stopBroadcast();

    console.log("PoolHasher  ", hasher);
    console.log("PoolVerifier", address(verifier));
    console.log("PoolGate    ", address(gate));
    console.log("ShieldedPool", address(pool));
  }

  /// Strip trailing whitespace/newline from the bytecode file so vm.parseBytes gets clean 0x hex.
  function _trim(string memory s) internal pure returns (string memory) {
    bytes memory b = bytes(s);
    uint256 end = b.length;
    while (end > 0 && (b[end - 1] == 0x0a || b[end - 1] == 0x0d || b[end - 1] == 0x20)) {
      end--;
    }
    bytes memory out = new bytes(end);
    for (uint256 i = 0; i < end; i++) {
      out[i] = b[i];
    }
    return string(out);
  }
}
