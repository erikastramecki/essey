// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Essey Private — Phase 1 on-chain proof. Deploys a fresh shielded pool and runs a real hidden-amount
// deposit -> withdraw with off-chain-generated Groth16 proofs, on Robinhood Chain testnet.
//
//   USDG=0x7461E670d44FF4397A3E48030C5b06f6163a5De2 \
//   PK=$TESTNET_DEPLOYER_PK forge script script/ProveShieldedPool.s.sol --rpc-url rh_testnet \
//     --broadcast --private-key $PK --gas-estimate-multiplier 300
import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EsseyShieldedPool, IPoolVerifier, IEsseyPoolGate} from "../src/private/pool/EsseyShieldedPool.sol";
import {EsseyPoolGate} from "../src/private/pool/EsseyPoolGate.sol";
import {Groth16Verifier} from "../src/private/pool/PoolVerifier2.sol";

interface IERC20Approve {
  function approve(address, uint256) external returns (bool);
  function balanceOf(address) external view returns (uint256);
}

contract ProveShieldedPool is Script {
  address constant RECIPIENT = 0x1111111111111111111111111111111111111111;

  function deployHasher() internal returns (address hasher) {
    bytes memory code = vm.parseBytes(_trim(vm.readFile("circuits-nova/build/Hasher2.bytecode.txt")));
    assembly {
      hasher := create(0, add(code, 0x20), mload(code))
    }
    require(hasher != address(0), "hasher deploy failed");
  }

  function run() external {
    address usdg = vm.envAddress("USDG");
    vm.startBroadcast();

    address hasher = deployHasher();
    Groth16Verifier verifier = new Groth16Verifier();
    EsseyPoolGate gate = new EsseyPoolGate(msg.sender, true);
    EsseyShieldedPool pool = new EsseyShieldedPool(
      IPoolVerifier(address(verifier)), 5, hasher, IERC20(usdg), IEsseyPoolGate(address(gate)), msg.sender, type(uint256).max
    );
    console.log("ShieldedPool", address(pool));

    // ---- DEPOSIT 100 (shield) ----
    IERC20Approve(usdg).approve(address(pool), 100);
    pool.transact(_depositProof(), _depositExt());
    console.log("after deposit, pool USDG:", IERC20Approve(usdg).balanceOf(address(pool)));

    // ---- WITHDRAW 100 to a fresh recipient (spend shielded note via real merkle path) ----
    pool.transact(_withdrawProof(), _withdrawExt());
    console.log("recipient USDG:", IERC20Approve(usdg).balanceOf(RECIPIENT));
    console.log("pool USDG after withdraw:", IERC20Approve(usdg).balanceOf(address(pool)));

    require(IERC20Approve(usdg).balanceOf(RECIPIENT) >= 100, "PROOF FAILED: recipient not paid");
    console.log("HIDDEN-AMOUNT DEPOSIT->WITHDRAW PROVEN ON-CHAIN");
    vm.stopBroadcast();
  }

  function _depositProof() internal pure returns (EsseyShieldedPool.Proof memory) {
    return EsseyShieldedPool.Proof({
      a: [
        uint256(0x0a094daee856b6e2ca9db3bd347c6383a73396ecf164418ed66668c2a734a1c9),
        uint256(0x063f8178b1292785822b4fa4aa700611883ab0b636fc99eb110c653d8a331572)
      ],
      b: [
        [
          uint256(0x0922436d871e86d84d5a7ca5eb4d7ee2a895bc680af59b9003d192059b0eb407),
          uint256(0x2377afdd9e02cb63cd1f841fd7bef82dc26b4229b15bc2ac01678b7ee712bb52)
        ],
        [
          uint256(0x1c2f0b5ba5d86a397c01683b1cdf0a6ae7bf11f9f545b6de6a7f815c9c74b352),
          uint256(0x07c0d67389108e6112669e2ab9c093b99067874a52ca2875d4e96255d12cdf90)
        ]
      ],
      c: [
        uint256(0x2d45e1a9695f0eb574ceff0b9ebffa555cdc4e33c404a43d4fefce6accb17b13),
        uint256(0x05c81b9981d3e542233f8c523935c962c18ee4b0bdd9ded29ea8261001b55d7d)
      ],
      root: bytes32(0x194191edbfb91d10f6a7afd315f33095410c7801c47175c2df6dc2cce0e3affc),
      inputNullifiers: [
        bytes32(0x259e2c17aa2bc789fa252e456545a5c4bec6ff7cf6d8fbcf2b0cb341bd7761f1),
        bytes32(0x2cb8560dc9b0bfc5213fd88ec2667cda9a87ebf615b858668aec37741e3b4cc6)
      ],
      outputCommitments: [
        bytes32(0x05c23b1e8aa4f3df1db98a729c8d155e4ac2723f8c1e94c6a144c345b13bc1cb),
        bytes32(0x17c75cea8ab5fdd6690dfef282bc7dc767de7aa4b8a177c60f4ca31b42987f22)
      ],
      publicAmount: 100,
      extDataHash: bytes32(0x008d9ffbaff3e4c3a2254578b66e772a0218b55a0e7979e299180942c827607c)
    });
  }

  function _depositExt() internal pure returns (EsseyShieldedPool.ExtData memory) {
    return EsseyShieldedPool.ExtData(address(0), int256(100), address(0), 0, hex"", hex"");
  }

  function _withdrawProof() internal pure returns (EsseyShieldedPool.Proof memory) {
    return EsseyShieldedPool.Proof({
      a: [
        uint256(0x0cee9433a2f48f5c5b61308199015b36ef0422f0eb2e7dd37fa0d164bef10a0e),
        uint256(0x10a4f662d1acdb88e7e93df8163595c71fedc43659aa81741c82b6f67a85e473)
      ],
      b: [
        [
          uint256(0x01465dbfe53657a6f2934a449ac5d527bbd7bf20fa501ae053fc90f0745199be),
          uint256(0x2ba37c5e14144422922a2aac3e30ee1694403ed1d3e03ac89b1d4a105a661085)
        ],
        [
          uint256(0x0423e7c94ea29b61008c52eecee7f58c600fe10a0b15bca917af4ae62484064a),
          uint256(0x222a41f06b315dee220d2c2ad21c7ea4e50b669de927682023ad2635c62abe75)
        ]
      ],
      c: [
        uint256(0x250f66e183222f8edcae0e0796391a492013a49728085b3ec8734106e4dd1318),
        uint256(0x2da6bd5a428a575969a5e72152aba9690b8c6db2ed235f317c77f137cec494a6)
      ],
      root: bytes32(0x0f58422911c401391a514483d5b9215e1336c22431ef5aa65be9764dd1ef5ab6),
      inputNullifiers: [
        bytes32(0x172fe27c4f1bcd2d8f5b98e5c0b479665f868eb0100b1c921ffccb9cc5b8cedd),
        bytes32(0x1060cec901a460eae3562e07c6a6dc0bea6c3bdeae5aa5e22635208f1c2de8ef)
      ],
      outputCommitments: [
        bytes32(0x2126de2d304a28bccca2b621468cc8231d042476a838b12243f7f2cf12e5c756),
        bytes32(0x1b56da8869480a3a9b87a5bc83bc7a346143ee943828d81110952860304cc22c)
      ],
      publicAmount: uint256(0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efffff9d),
      extDataHash: bytes32(0x2912ee1a618a0fdd368451ddb12eec90197a8b0b1861d282619240756ea7b27c)
    });
  }

  function _withdrawExt() internal pure returns (EsseyShieldedPool.ExtData memory) {
    return EsseyShieldedPool.ExtData(RECIPIENT, int256(-100), address(0), 0, hex"", hex"");
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
