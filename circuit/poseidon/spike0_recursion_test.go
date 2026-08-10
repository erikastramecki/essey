package poseidon

// Spike 0 — the go/no-go for the provably-solvent rollup thesis.
//
// The crux: can we fold N proven state-transitions into ONE proof that stays
// cheaply verifiable on any EVM chain? Our whole stack is BN254 (that is what the
// EVM pairing precompile and our exported verifier use), so the load-bearing
// question is whether the BN254-in-BN254 *emulated* recursion path is economical.
// If it is, the aggregate proof is itself a standard BN254 Groth16 proof and lands
// on-chain at ~our current gas class with no BW6 wrap.
//
// 0a (TestSpike0_Constraints): compile-only. Reports constraints/proof for the
//    outer aggregation circuit at K=1,2,4,8. This is the decisive economics number
//    and is cheap (no setup/prove).
// 0b (TestSpike0_ProveVerify): full Groth16 setup+prove+verify of the aggregate at
//    K=1 then K=2. Confirms it actually proves and times it.
//
// Recursion overhead is ~independent of the inner circuit's size, so we use a small
// inner circuit here on purpose: it isolates the per-proof aggregation cost (the
// thing that decides viability) from the app-circuit cost we already measured.

import (
	"fmt"
	"runtime"
	"testing"
	"time"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/backend/witness"
	"github.com/consensys/gnark/constraint"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/algebra/emulated/sw_bn254"
	stdgroth16 "github.com/consensys/gnark/std/recursion/groth16"
)

// spikeInner stands in for one proven state-transition: x -> y = x^3 + x + 5.
type spikeInner struct {
	X frontend.Variable
	Y frontend.Variable `gnark:",public"`
}

func (c *spikeInner) Define(api frontend.API) error {
	x3 := api.Mul(c.X, c.X, c.X)
	api.AssertIsEqual(c.Y, api.Add(x3, c.X, 5))
	return nil
}

// computeSpikeInner produces one real BN254 Groth16 proof of spikeInner, prepared
// for recursive verification (GetNativeProverOptions binds the in-circuit hash).
func computeSpikeInner(t *testing.T) (constraint.ConstraintSystem, groth16.VerifyingKey, witness.Witness, groth16.Proof) {
	field := ecc.BN254.ScalarField()
	innerCcs, err := frontend.Compile(field, r1cs.NewBuilder, &spikeInner{})
	if err != nil {
		t.Fatalf("inner compile: %v", err)
	}
	innerPK, innerVK, err := groth16.Setup(innerCcs)
	if err != nil {
		t.Fatalf("inner setup: %v", err)
	}
	assignment := &spikeInner{X: 3, Y: 35} // 27 + 3 + 5
	fullWit, err := frontend.NewWitness(assignment, field)
	if err != nil {
		t.Fatalf("inner witness: %v", err)
	}
	proof, err := groth16.Prove(innerCcs, innerPK, fullWit,
		stdgroth16.GetNativeProverOptions(field, field))
	if err != nil {
		t.Fatalf("inner prove: %v", err)
	}
	pubWit, err := fullWit.Public()
	if err != nil {
		t.Fatalf("inner public witness: %v", err)
	}
	if err := groth16.Verify(proof, innerVK, pubWit,
		stdgroth16.GetNativeVerifierOptions(field, field)); err != nil {
		t.Fatalf("inner verify: %v", err)
	}
	return innerCcs, innerVK, pubWit, proof
}

// spikeAgg verifies K inner proofs against ONE shared verifying key — the realistic
// block-prover shape, where every transition uses the same transition circuit.
type spikeAgg struct {
	Proofs    []stdgroth16.Proof[sw_bn254.G1Affine, sw_bn254.G2Affine]
	Witnesses []stdgroth16.Witness[sw_bn254.ScalarField]
	VK        stdgroth16.VerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl]
}

func (c *spikeAgg) Define(api frontend.API) error {
	v, err := stdgroth16.NewVerifier[sw_bn254.ScalarField, sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](api)
	if err != nil {
		return fmt.Errorf("new verifier: %w", err)
	}
	for i := range c.Proofs {
		if err := v.AssertProof(c.VK, c.Proofs[i], c.Witnesses[i]); err != nil {
			return fmt.Errorf("assert proof %d: %w", i, err)
		}
	}
	return nil
}

// aggPlaceholder builds an outer circuit sized for K inner proofs (for Compile/Setup).
func aggPlaceholder(innerCcs constraint.ConstraintSystem, k int) *spikeAgg {
	c := &spikeAgg{
		Proofs:    make([]stdgroth16.Proof[sw_bn254.G1Affine, sw_bn254.G2Affine], k),
		Witnesses: make([]stdgroth16.Witness[sw_bn254.ScalarField], k),
		VK:        stdgroth16.PlaceholderVerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](innerCcs),
	}
	for i := 0; i < k; i++ {
		c.Proofs[i] = stdgroth16.PlaceholderProof[sw_bn254.G1Affine, sw_bn254.G2Affine](innerCcs)
		c.Witnesses[i] = stdgroth16.PlaceholderWitness[sw_bn254.ScalarField](innerCcs)
	}
	return c
}

// aggAssignment fills the outer circuit with K copies of one real inner proof.
func aggAssignment(t *testing.T, vk groth16.VerifyingKey, pubWit witness.Witness, proof groth16.Proof, k int) *spikeAgg {
	cvk, err := stdgroth16.ValueOfVerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](vk)
	if err != nil {
		t.Fatalf("ValueOfVerifyingKey: %v", err)
	}
	cproof, err := stdgroth16.ValueOfProof[sw_bn254.G1Affine, sw_bn254.G2Affine](proof)
	if err != nil {
		t.Fatalf("ValueOfProof: %v", err)
	}
	cwit, err := stdgroth16.ValueOfWitness[sw_bn254.ScalarField](pubWit)
	if err != nil {
		t.Fatalf("ValueOfWitness: %v", err)
	}
	c := &spikeAgg{
		Proofs:    make([]stdgroth16.Proof[sw_bn254.G1Affine, sw_bn254.G2Affine], k),
		Witnesses: make([]stdgroth16.Witness[sw_bn254.ScalarField], k),
		VK:        cvk,
	}
	for i := 0; i < k; i++ {
		c.Proofs[i] = cproof
		c.Witnesses[i] = cwit
	}
	return c
}

func mb(bytes uint64) string { return fmt.Sprintf("%d MB", bytes/1024/1024) }

// TestSpike0_Constraints — 0a: the decisive economics number, compile-only.
func TestSpike0_Constraints(t *testing.T) {
	innerCcs, _, _, _ := computeSpikeInner(t)
	t.Logf("inner circuit constraints: %d", innerCcs.GetNbConstraints())
	t.Logf("%-4s %-16s %-14s %-16s", "K", "outer-constraints", "per-proof", "compile")
	var base int
	for _, k := range []int{1, 2, 4, 8} {
		t0 := time.Now()
		ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, aggPlaceholder(innerCcs, k))
		if err != nil {
			t.Fatalf("K=%d compile: %v", k, err)
		}
		n := ccs.GetNbConstraints()
		if k == 1 {
			base = n
		}
		per := n / k
		t.Logf("%-4d %-16d %-14d %-16s", k, n, per, time.Since(t0).Round(time.Millisecond))
	}
	t.Logf("marginal cost of the FIRST recursion (fixed overhead) ~= %d constraints", base)
}

// TestSpike0_ProveVerify — 0b: prove the aggregate for real. Ramps K to avoid
// melting RAM; logs setup/prove time and heap. Skipped under -short.
func TestSpike0_ProveVerify(t *testing.T) {
	if testing.Short() {
		t.Skip("heavy: setup+prove of emulated recursion")
	}
	innerCcs, innerVK, innerPub, innerProof := computeSpikeInner(t)

	for _, k := range []int{1, 2} {
		t.Run(fmt.Sprintf("K=%d", k), func(t *testing.T) {
			t0 := time.Now()
			ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, aggPlaceholder(innerCcs, k))
			if err != nil {
				t.Fatalf("compile: %v", err)
			}
			t.Logf("K=%d outer constraints=%d compile=%s", k, ccs.GetNbConstraints(), time.Since(t0).Round(time.Millisecond))

			t1 := time.Now()
			pk, vk, err := groth16.Setup(ccs)
			if err != nil {
				t.Fatalf("setup: %v", err)
			}
			t.Logf("K=%d setup=%s", k, time.Since(t1).Round(time.Millisecond))

			asg := aggAssignment(t, innerVK, innerPub, innerProof, k)
			fullWit, err := frontend.NewWitness(asg, ecc.BN254.ScalarField())
			if err != nil {
				t.Fatalf("witness: %v", err)
			}
			pubWit, err := fullWit.Public()
			if err != nil {
				t.Fatalf("public witness: %v", err)
			}

			t2 := time.Now()
			outerProof, err := groth16.Prove(ccs, pk, fullWit)
			if err != nil {
				t.Fatalf("prove: %v", err)
			}
			proveDur := time.Since(t2)

			if err := groth16.Verify(outerProof, vk, pubWit); err != nil {
				t.Fatalf("verify: %v", err)
			}

			var m runtime.MemStats
			runtime.ReadMemStats(&m)
			t.Logf("K=%d PROVE=%s verify=OK heapInUse=%s totalAlloc=%s",
				k, proveDur.Round(time.Millisecond), mb(m.HeapInuse), mb(m.TotalAlloc))
			t.Logf("K=%d aggregate is a standard BN254 Groth16 proof (EVM-verifiable)", k)
		})
	}
}
