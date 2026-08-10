package poseidon

import (
	"math/big"
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/algebra/emulated/sw_bn254"
	stdgroth16 "github.com/consensys/gnark/std/recursion/groth16"
	"github.com/consensys/gnark/test"
)

// vkHashTestCircuit hashes a verifying key in-circuit and checks it against a pinned public value.
type vkHashTestCircuit struct {
	VK       innerVK
	Expected frontend.Variable `gnark:",public"`
}

func (c *vkHashTestCircuit) Define(api frontend.API) error {
	api.AssertIsEqual(hashVKInCircuit(api, c.VK), c.Expected)
	return nil
}

// TestVKHash_Matches validates that the in-circuit VK hash equals the off-circuit one (same walk, same
// sponge) and that it actually distinguishes verifying keys.
func TestVKHash_Matches(t *testing.T) {
	// A small inner circuit so the VK is small and the test is fast.
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &spikeInner{})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	_, vk, err := groth16.Setup(ccs)
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	vkVal, err := stdgroth16.ValueOfVerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](vk)
	if err != nil {
		t.Fatalf("ValueOfVerifyingKey: %v", err)
	}

	limbs := collectVKLimbs(vkVal)
	t.Logf("collected %d VK limbs", len(limbs))
	if len(limbs) == 0 {
		t.Fatal("no VK limbs collected — reflection walk found nothing")
	}

	expected, err := hashVKNative(vkVal)
	if err != nil {
		t.Fatalf("hashVKNative: %v", err)
	}
	t.Logf("native VK hash = %s", expected.String())

	circuit := &vkHashTestCircuit{VK: stdgroth16.PlaceholderVerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](ccs)}
	good := &vkHashTestCircuit{VK: vkVal, Expected: expected}
	if err := test.IsSolved(circuit, good, ecc.BN254.ScalarField()); err != nil {
		t.Fatalf("in-circuit hash should equal native hash: %v", err)
	}

	// Negative: a wrong pin must fail.
	bad := &vkHashTestCircuit{VK: vkVal, Expected: new(big.Int).Add(expected, big.NewInt(1))}
	if err := test.IsSolved(circuit, bad, ecc.BN254.ScalarField()); err == nil {
		t.Fatal("a mismatched VK commitment must fail")
	}
}

// TestVKHash_DistinguishesKeys confirms two different verifying keys hash to different values — the
// property that makes the binding meaningful.
func TestVKHash_DistinguishesKeys(t *testing.T) {
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &spikeInner{})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	_, vk1, err := groth16.Setup(ccs)
	if err != nil {
		t.Fatalf("setup1: %v", err)
	}
	_, vk2, err := groth16.Setup(ccs) // independent toxic waste => different vk
	if err != nil {
		t.Fatalf("setup2: %v", err)
	}
	v1, _ := stdgroth16.ValueOfVerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](vk1)
	v2, _ := stdgroth16.ValueOfVerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](vk2)
	h1, err := hashVKNative(v1)
	if err != nil {
		t.Fatalf("hash1: %v", err)
	}
	h2, err := hashVKNative(v2)
	if err != nil {
		t.Fatalf("hash2: %v", err)
	}
	if h1.Cmp(h2) == 0 {
		t.Fatal("distinct verifying keys hashed to the same value")
	}
	t.Logf("distinct VKs => distinct hashes (%s… vs %s…)", h1.String()[:12], h2.String()[:12])
}
