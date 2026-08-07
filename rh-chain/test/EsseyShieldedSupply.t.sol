// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EsseyShieldedSupply, ILendingPool} from "../src/private/pool/EsseyShieldedSupply.sol";
import {IPoolVerifier, IEsseyPoolGate} from "../src/private/pool/EsseyShieldedPool.sol";
import {EsseyPoolGate} from "../src/private/pool/EsseyPoolGate.sol";
import {Groth16Verifier} from "../src/private/pool/PoolVerifier2.sol";

contract MockUSDG is ERC20 {
  constructor() ERC20("Mock USDG", "USDG") {}
  function mint(address to, uint256 amt) external {
    _mint(to, amt);
  }
}

/// A vanilla ERC-4626 vault over USDG (no decimals offset -> 1:1 on the first deposit), so the proven depth-20
/// value=100 proofs work as 100-SHARE proofs. Donating USDG to it raises the share price = yield.
contract MockVault is ERC4626 {
  constructor(IERC20 asset_) ERC20("Mock aUSDG", "aUSDG") ERC4626(asset_) {}
}

/// Proves the SHIELDED LENDING SUPPLY end to end: supply 100 USDG privately -> the vault earns yield -> withdraw
/// the shielded share-note and receive MORE than 100 USDG. The zk proofs are the same depth-20 proofs the base
/// pool uses (value = 100 = 100 shares at the 1:1 rate); the new code is the USDG<->share edges.
contract EsseyShieldedSupplyTest is Test {
  EsseyShieldedSupply pool;
  MockUSDG usdg;
  MockVault vault;
  address supplier = address(0xD3);
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
    EsseyPoolGate gate = new EsseyPoolGate(address(this), true);
    usdg = new MockUSDG();
    vault = new MockVault(IERC20(address(usdg)));
    pool = new EsseyShieldedSupply(
      IPoolVerifier(address(verifier)), 20, hasher, IERC20(address(usdg)), ILendingPool(address(vault)), IEsseyPoolGate(address(gate)), address(this), 0
    );
    usdg.mint(supplier, 100);
  }

  function test_SupplyEarnYieldWithdraw() public {
    // ---- SUPPLY 100 USDG privately (deposit proof; 100 USDG -> 100 shares at 1:1) ----
    EsseyShieldedSupply.Proof memory dp = _depositProof();
    EsseyShieldedSupply.ExtData memory de = EsseyShieldedSupply.ExtData(address(0), int256(100), address(0), 0, hex"", hex"");
    vm.prank(supplier);
    usdg.approve(address(pool), 100);
    vm.prank(supplier);
    pool.supply(100, dp, de);

    assertEq(vault.balanceOf(address(pool)), 100, "pool holds 100 aUSDG shares");
    assertEq(usdg.balanceOf(address(vault)), 100, "vault holds the supplied USDG");
    assertEq(usdg.balanceOf(supplier), 0, "supplier debited");

    // ---- YIELD: donate 50 USDG to the vault -> the 100 shares are now worth ~149 USDG ----
    usdg.mint(address(this), 50);
    usdg.transfer(address(vault), 50);
    assertGt(pool.sharesToUsdg(100), 100, "100 shares now worth more than 100 USDG (yield accrued)");

    // ---- WITHDRAW the shielded 100-share note -> recipient receives the yielded USDG ----
    EsseyShieldedSupply.Proof memory wp = _withdrawProof();
    EsseyShieldedSupply.ExtData memory we = EsseyShieldedSupply.ExtData(recipient, int256(-100), address(0), 0, hex"", hex"");
    pool.transact(wp, we);

    assertGt(usdg.balanceOf(recipient), 100, "recipient received MORE than 100 USDG - private yield");
    assertEq(vault.balanceOf(address(pool)), 0, "pool redeemed all shares");
    assertTrue(pool.isSpent(wp.inputNullifiers[0]), "note spent");
  }

  function _depositProof() internal pure returns (EsseyShieldedSupply.Proof memory) {
    return EsseyShieldedSupply.Proof({
      a: [uint256(0x0c43368251c33b14a5db87732ac855218caaab69c1c60056b471dd45d518f6e3), uint256(0x11c8fee16b3e590d289141ff55a0bfedf95c8e6b4c9777ab1c167cafb3389dd5)],
      b: [
        [uint256(0x210f2f4d27a10d8fe25b9233afd93a5326e44969fd4f06e071d23759d984815d), uint256(0x0e1624953bf8ee0b04a5b18e9faa67331055fbb507102408103bba821f406ca7)],
        [uint256(0x2ac0b6dcf2d42e230bfb162b5ad20013172ffad520ed90c95175afcafe1d2217), uint256(0x0f9d51f497e1d7531e24240ba9560e73fb9b4e62f874cbd36da2c3bbfebff698)]
      ],
      c: [uint256(0x2cb75b90d47dc77a2ff6bb6e47894c30ffc0531f48a73b0d418aebad4ccd3447), uint256(0x21685f45230825e907a4efcb473f2fba95a645a54da4628a30aaaae58644fc19)],
      root: bytes32(0x2b0f6fc0179fa65b6f73627c0e1e84c7374d2eaec44c9a48f2571393ea77bcbb),
      inputNullifiers: [bytes32(0x1af59f0d0263108a005a43acde48bd6d81b2b44cf0d865aa866790cba302a78e), bytes32(0x1a1275e3f9ad322b3b5e2876e1262fb467d5dc4d92154c33443e312d7ad54fbb)],
      outputCommitments: [bytes32(0x157ea0e0c9d63a49044772668169d2770595846ed2cefb6563d83e46ad381667), bytes32(0x27a0892dac640ef501d486f45dcf524234252888ed5ed9617547e952d18a02b4)],
      publicAmount: 100,
      extDataHash: bytes32(0x008d9ffbaff3e4c3a2254578b66e772a0218b55a0e7979e299180942c827607c)
    });
  }

  function _withdrawProof() internal pure returns (EsseyShieldedSupply.Proof memory) {
    return EsseyShieldedSupply.Proof({
      a: [uint256(0x030064510b8f9c08028fc2ceb24e8bfa7e817bacd27de4f51503d8650b75168e), uint256(0x2a1051eb87b7634f15ba5772f3eb6f17ef55e402ed2056a79b390dd4b1b5e0ed)],
      b: [
        [uint256(0x14ca9980a402aa4342998d6f8f7a6e4b7374c68f5bba96f285f247b919f7d3da), uint256(0x2a90ddec13cc78284755e352ecad9ef3a660c78606c38b075bb53638346efded)],
        [uint256(0x08c460cc1ca897a37cfcc6d732f4544fc6a2d4ea87ebc7bc4f0914ff14596ad0), uint256(0x130b7ab8eb7226ee63620aa5a9214126ebab0b32d95a46513eb6451d92408d60)]
      ],
      c: [uint256(0x107598a6238dd6f9076b72bfacf15327635b5e44dd08a5f55d3605e53dccb59c), uint256(0x2bac130568012e9022abfc6c13f34388aa70ca74a2d3859894d5e3c0b52e8a27)],
      root: bytes32(0x0633c0ec68749978a67b6990eee3cc3fcc513f7e1c5d096ec33091927f5dcc7c),
      inputNullifiers: [bytes32(0x0612a02aaa4c5a259665b1c9f537b222b05daceebad62d3d79bd86665246e593), bytes32(0x0c66da1e051fbc3cb6e3d2714395a1d21e35bd21e22cb4341a842ca6d5bceea8)],
      outputCommitments: [bytes32(0x07a3ee04205a099e175743f0f0013adaa3d7e926ab1b21372abfb1840b1594c4), bytes32(0x26d5a9ff1bc4de58bf839689c82e33d8c1f50df8d7c0c461fa43fc335055acae)],
      publicAmount: uint256(0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593efffff9d),
      extDataHash: bytes32(0x2912ee1a618a0fdd368451ddb12eec90197a8b0b1861d282619240756ea7b27c)
    });
  }

  function _trim(string memory s) internal pure returns (string memory) {
    bytes memory b = bytes(s);
    uint256 end = b.length;
    while (end > 0 && (b[end - 1] == 0x0a || b[end - 1] == 0x0d || b[end - 1] == 0x20)) end--;
    bytes memory out = new bytes(end);
    for (uint256 i = 0; i < end; i++) out[i] = b[i];
    return string(out);
  }
}
