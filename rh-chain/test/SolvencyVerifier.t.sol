// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {SolvencyVerifier} from "../src/verifier/SolvencyVerifier.sol";

/// Proves the load-bearing "verify on ANY EVM chain" property on-chain, in Foundry — not just a localnet
/// script. A REAL Groth16 proof of the dregg solvency statement (debt·10000 <= collateral·price·ltvBps),
/// exported from the gnark `SolvencyCircuit` via `OUT=... go test -run TestExportOnchainVerifier` in
/// circuit/poseidon, verifies against the deployed verifier here — and any tamper is rejected. The
/// verifier is stateless and self-contained (only the bn254 precompiles at 0x06/0x07/0x08, which every
/// EVM chain provides), so this exact contract deploys and verifies identically on any EVM chain.
/// `verifyProof` is a `view` that REVERTS on an invalid proof.
contract SolvencyVerifierTest is Test {
    SolvencyVerifier verifier;

    uint256[8] proof;
    uint256[1] input;

    function setUp() public {
        verifier = new SolvencyVerifier();
        proof = [
            uint256(0x15e755cbe2ce8cb41480c37d4785bc0af9e4b3d9d0c44e9ca96cded89b53c39f),
            0x2c5c95699f55bdc24eceb182941078d8516ac02a962fcdef92903630bb2f39aa,
            0x1a162a34d8014c2463221ee53e575c22756b006e66a287ad71c30add64b74cfe,
            0x296040fd2c4f521074add36dc2ae28decc7c3fef789082304749a54e986539d0,
            0x23f77ffd5f1f9616710d495271b552cf192202b2f70e25b623a423a7ea7be8cc,
            0x2ad5ca95ef2d960342554192e96b54baf79a22560aa269f4f13cb45c26d7e7c2,
            0x145cca1f7fb6e0c6215383d26057248859a446fa23253d158972d6f786eedb30,
            0x07ef3f727c7219a44c78af762551f2e40380553c0a2c51071d49a2c210859801
        ];
        // The single public input: the on-chain loan commitment the proof is bound to.
        input = [uint256(411147357000657739348223304947322702071440617372774715751427018448806772785)];
    }

    /// The real proof verifies on-chain. A successful (non-reverting) call IS the verification.
    function test_verifiesRealSolvencyProofOnChain() public view {
        verifier.verifyProof(proof, input);
    }

    /// Report the on-chain gas — this is the per-settlement-chain cost of proving solvency, and it is
    /// dominated by the fixed pairing + public-input count, independent of the circuit's size.
    function test_reportOnChainVerifyGas() public view {
        uint256 g = gasleft();
        verifier.verifyProof(proof, input);
        console.log("solvency proof on-chain verify gas:", g - gasleft());
    }

    /// A tampered proof is rejected — the pairing check fails and the view reverts.
    function test_rejectsTamperedProof() public {
        uint256[8] memory bad = proof;
        bad[0] ^= 1;
        vm.expectRevert();
        verifier.verifyProof(bad, input);
    }

    /// A proof cannot be reused for a DIFFERENT public input (a different loan commitment) — the
    /// public-input MSM changes, so verification reverts. This is what binds a proof to its statement.
    function test_rejectsTamperedPublicInput() public {
        uint256[1] memory bad = [input[0] + 1];
        vm.expectRevert();
        verifier.verifyProof(proof, bad);
    }
}
