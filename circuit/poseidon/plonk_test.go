package poseidon

import (
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/plonk"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/scs"
	"github.com/consensys/gnark/test/unsafekzg"
)

// TestPlonk_Migration proves the migration off Groth16: the SAME circuit definition compiles and
// proves under PLONK, whose KZG setup is UNIVERSAL.
//
// Why it matters: Groth16 needs a per-circuit trusted-setup ceremony — change the circuit (batch
// size, guardian-set rotation, a new asset) and you must run a fresh multi-party ceremony, each one
// a security-sensitive event. PLONK's canonical SRS is universal: one ceremony (in practice, an
// existing PUBLIC Powers-of-Tau SRS with thousands of contributors) serves every circuit up to a
// size bound, forever. The per-circuit Lagrange form is a deterministic transform, not a ceremony.
//
// The `unsafekzg` SRS below is a throwaway test one (known toxic waste — test only). In production
// it is swapped for the public Powers-of-Tau SRS; nothing else in this flow changes.
func TestPlonk_Migration(t *testing.T) {
	skel := &SolvencyCircuit{}
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), scs.NewBuilder, skel)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("PLONK constraint system (solvency): %d constraints", ccs.GetNbConstraints())

	// PROD: replace with a public Powers-of-Tau canonical SRS (reused across all circuits).
	srs, srsLagrange, err := unsafekzg.NewSRS(ccs)
	if err != nil {
		t.Fatal(err)
	}
	pk, vk, err := plonk.Setup(ccs, srs, srsLagrange)
	if err != nil {
		t.Fatal(err)
	}

	terms := sampleTerms(1000)
	full, err := frontend.NewWitness(assign(terms, commit(t, terms)), ecc.BN254.ScalarField())
	if err != nil {
		t.Fatal(err)
	}
	proof, err := plonk.Prove(ccs, pk, full)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := full.Public()
	if err != nil {
		t.Fatal(err)
	}
	if err := plonk.Verify(proof, vk, pub); err != nil {
		t.Fatalf("PLONK proof must verify: %v", err)
	}
	t.Log("PLONK proof verified — same circuit, universal setup, no per-circuit ceremony ✓")

	// Over-borrow must still be rejected under PLONK (soundness is a circuit property, not a
	// backend one): a bad witness fails to prove.
	bad := sampleTerms(1200) // over the LTV limit
	badW, err := frontend.NewWitness(assign(bad, commit(t, bad)), ecc.BN254.ScalarField())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := plonk.Prove(ccs, pk, badW); err == nil {
		t.Fatal("PLONK accepted an over-borrow witness — soundness lost in migration")
	}
	t.Log("PLONK rejects the over-borrow witness too — soundness preserved across backends ✓")
}
