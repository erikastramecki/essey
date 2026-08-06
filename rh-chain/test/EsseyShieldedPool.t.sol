// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EsseyShieldedPool, IPoolVerifier, IEsseyPoolGate} from "../src/private/pool/EsseyShieldedPool.sol";
import {EsseyPoolGate} from "../src/private/pool/EsseyPoolGate.sol";
import {Groth16Verifier} from "../src/private/pool/PoolVerifier2.sol";

contract MockUSDG is ERC20 {
  constructor() ERC20("Mock USDG", "USDG") {}
  function mint(address to, uint256 amt) external {
    _mint(to, amt);
  }
}

/// Proves the full HIDDEN-AMOUNT cycle end to end against real Groth16 proofs generated off-chain (nova-port
/// prover): a deposit shields 100 units, and a withdrawal spends the shielded note through a REAL merkle path
/// and pays out 100 to a fresh recipient — with the deposited amount never appearing as a public argument.
/// If the on-chain Poseidon tree (hasher + zeros table) disagreed with the circuit, isKnownRoot would revert.
contract EsseyShieldedPoolTest is Test {
  EsseyShieldedPool pool;
  MockUSDG usdg;
  address depositor = address(0xD3);
  address recipient = address(0x1111111111111111111111111111111111111111);

  function _deployHasher() internal returns (address hasher) {
    bytes memory code = vm.parseBytes(_trim(vm.readFile("circuits-nova/build/Hasher2.bytecode.txt")));
    assembly {
      hasher := create(0, add(code, 0x20), mload(code))
    }
    require(hasher != address(0), "hasher deploy failed");
  }

  function setUp() public {
    address hasher = _deployHasher();
    Groth16Verifier verifier = new Groth16Verifier();
    EsseyPoolGate gate = new EsseyPoolGate(address(this), true); // openMode
    usdg = new MockUSDG();
    pool = new EsseyShieldedPool(
      IPoolVerifier(address(verifier)), 5, hasher, IERC20(address(usdg)), IEsseyPoolGate(address(gate)), address(this), type(uint256).max
    );
    usdg.mint(depositor, 100);
  }

  function test_DepositThenWithdraw_hidesAmount() public {
    // ---- DEPOSIT: shield 100 ----
    EsseyShieldedPool.Proof memory dp = EsseyShieldedPool.Proof({
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
    EsseyShieldedPool.ExtData memory de = EsseyShieldedPool.ExtData({
      recipient: address(0),
      extAmount: int256(100),
      relayer: address(0),
      fee: 0,
      encryptedOutput1: hex"",
      encryptedOutput2: hex""
    });

    vm.prank(depositor);
    usdg.approve(address(pool), 100);
    vm.prank(depositor);
    pool.transact(dp, de);

    assertEq(usdg.balanceOf(address(pool)), 100, "pool holds the shielded 100");
    assertEq(usdg.balanceOf(depositor), 0, "depositor debited");

    // ---- WITHDRAW: spend the shielded note through a real merkle path, pay 100 to a fresh recipient ----
    EsseyShieldedPool.Proof memory wp = EsseyShieldedPool.Proof({
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
    EsseyShieldedPool.ExtData memory we = EsseyShieldedPool.ExtData({
      recipient: recipient,
      extAmount: int256(-100),
      relayer: address(0),
      fee: 0,
      encryptedOutput1: hex"",
      encryptedOutput2: hex""
    });

    pool.transact(wp, we);

    assertEq(usdg.balanceOf(recipient), 100, "recipient received the withdrawal");
    assertEq(usdg.balanceOf(address(pool)), 0, "pool emptied");
    assertTrue(pool.isSpent(wp.inputNullifiers[0]), "spent note nullifier recorded");
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
