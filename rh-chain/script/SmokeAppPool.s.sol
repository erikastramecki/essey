// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Smoke test: submit a real depth-20 Groth16 deposit proof to the ALREADY-DEPLOYED app pool, confirming its
// verifier accepts a proof from the same zkey the browser prover uses.
//   POOL=0xcD79... USDG=0x7461... PK=$TESTNET_DEPLOYER_PK forge script script/SmokeAppPool.s.sol \
//     --rpc-url rh_testnet --broadcast --private-key $PK --gas-estimate-multiplier 300
import {Script, console} from "forge-std/Script.sol";
import {EsseyShieldedPool} from "../src/private/pool/EsseyShieldedPool.sol";

interface IERC20Approve {
  function approve(address, uint256) external returns (bool);
  function balanceOf(address) external view returns (uint256);
}

contract SmokeAppPool is Script {
  function run() external {
    EsseyShieldedPool pool = EsseyShieldedPool(vm.envAddress("POOL"));
    address usdg = vm.envAddress("USDG");
    vm.startBroadcast();
    IERC20Approve(usdg).approve(address(pool), 100);
    uint256 before = IERC20Approve(usdg).balanceOf(address(pool));
    pool.transact(_depositProof(), _depositExt());
    console.log("app pool USDG before:", before, "after:", IERC20Approve(usdg).balanceOf(address(pool)));
    require(IERC20Approve(usdg).balanceOf(address(pool)) == before + 100, "SMOKE FAILED: deposit not accepted");
    console.log("APP POOL ACCEPTS A REAL DEPTH-20 PROOF (browser prover verified end-to-end)");
    vm.stopBroadcast();
  }

  function _depositProof() internal pure returns (EsseyShieldedPool.Proof memory) {
    return EsseyShieldedPool.Proof({
      a: [
        uint256(0x0c43368251c33b14a5db87732ac855218caaab69c1c60056b471dd45d518f6e3),
        uint256(0x11c8fee16b3e590d289141ff55a0bfedf95c8e6b4c9777ab1c167cafb3389dd5)
      ],
      b: [
        [
          uint256(0x210f2f4d27a10d8fe25b9233afd93a5326e44969fd4f06e071d23759d984815d),
          uint256(0x0e1624953bf8ee0b04a5b18e9faa67331055fbb507102408103bba821f406ca7)
        ],
        [
          uint256(0x2ac0b6dcf2d42e230bfb162b5ad20013172ffad520ed90c95175afcafe1d2217),
          uint256(0x0f9d51f497e1d7531e24240ba9560e73fb9b4e62f874cbd36da2c3bbfebff698)
        ]
      ],
      c: [
        uint256(0x2cb75b90d47dc77a2ff6bb6e47894c30ffc0531f48a73b0d418aebad4ccd3447),
        uint256(0x21685f45230825e907a4efcb473f2fba95a645a54da4628a30aaaae58644fc19)
      ],
      root: bytes32(0x2b0f6fc0179fa65b6f73627c0e1e84c7374d2eaec44c9a48f2571393ea77bcbb),
      inputNullifiers: [
        bytes32(0x1af59f0d0263108a005a43acde48bd6d81b2b44cf0d865aa866790cba302a78e),
        bytes32(0x1a1275e3f9ad322b3b5e2876e1262fb467d5dc4d92154c33443e312d7ad54fbb)
      ],
      outputCommitments: [
        bytes32(0x157ea0e0c9d63a49044772668169d2770595846ed2cefb6563d83e46ad381667),
        bytes32(0x27a0892dac640ef501d486f45dcf524234252888ed5ed9617547e952d18a02b4)
      ],
      publicAmount: 100,
      extDataHash: bytes32(0x008d9ffbaff3e4c3a2254578b66e772a0218b55a0e7979e299180942c827607c)
    });
  }

  function _depositExt() internal pure returns (EsseyShieldedPool.ExtData memory) {
    return EsseyShieldedPool.ExtData(address(0), int256(100), address(0), 0, hex"", hex"");
  }
}
