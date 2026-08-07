// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Essey Private — deploy the SHIELDED LENDING SUPPLY pool (wraps the ERC-4626 EsseyPool). Reuses the depth-20
// verifier + Poseidon hasher. Notes are share-denominated; yield accrues privately.
//
//   USDG=0x7461E6... LENDING_POOL=0x283a4891... PK=$TESTNET_DEPLOYER_PK \
//   forge script script/DeployShieldedSupply.s.sol --rpc-url rh_testnet --broadcast --private-key $PK \
//     --gas-estimate-multiplier 300
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EsseyShieldedSupply, ILendingPool} from "../src/private/pool/EsseyShieldedSupply.sol";
import {IPoolVerifier, IEsseyPoolGate} from "../src/private/pool/EsseyShieldedPool.sol";
import {EsseyPoolGate} from "../src/private/pool/EsseyPoolGate.sol";
import {Groth16Verifier} from "../src/private/pool/PoolVerifier2.sol";

contract DeployShieldedSupply is Script {
  uint32 internal constant LEVELS = 20;

  function deployHasher() internal returns (address hasher) {
    bytes memory code = vm.parseBytes(_trim(vm.readFile("circuits-nova/build/Hasher2.bytecode.txt")));
    assembly {
      hasher := create(0, add(code, 0x20), mload(code))
    }
    require(hasher != address(0), "hasher deploy failed");
  }

  function run() external {
    address usdg = vm.envAddress("USDG");
    address lendingPool = vm.envAddress("LENDING_POOL");
    vm.startBroadcast();
    address hasher = deployHasher();
    Groth16Verifier verifier = new Groth16Verifier();
    EsseyPoolGate gate = new EsseyPoolGate(msg.sender, true); // openMode on testnet
    EsseyShieldedSupply pool = new EsseyShieldedSupply(
      IPoolVerifier(address(verifier)), LEVELS, hasher, IERC20(usdg), ILendingPool(lendingPool), IEsseyPoolGate(address(gate)), msg.sender, 0
    );
    vm.stopBroadcast();
    console.log("SupplyHasher  ", hasher);
    console.log("SupplyVerifier", address(verifier));
    console.log("SupplyGate    ", address(gate));
    console.log("ShieldedSupply", address(pool));
  }

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
