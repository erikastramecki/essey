package poseidon

import (
	"math/big"
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/test"
	iden3 "github.com/iden3/go-iden3-crypto/poseidon"
)

// A representative loan, mirroring the fork example: 10 AAPL @ $333, 35% LTV.
// max borrow = 10*333*3500/10000 = 1165.5, so debt 1000 is solvent, 1200 is not.
func sampleTerms(debt int64) []*big.Int {
	return []*big.Int{
		big.NewInt(0x1111), big.NewInt(0x2222), // pool hi/lo
		big.NewInt(0x3333), big.NewInt(0x4444), // borrower hi/lo
		big.NewInt(debt),                       // debt
		big.NewInt(10),                         // collateral units
		big.NewInt(3500),                       // ltv bps (35%)
		big.NewInt(7),                          // nonce
		big.NewInt(0x5555), big.NewInt(0x6666), // type hi/lo
		big.NewInt(333),                        // price
	}
}

// commit computes the reference commitment the same way the circuit does — via the native iden3
// Poseidon the gadget is proven to match. In production this equals sui::poseidon::poseidon_bn254.
func commit(t *testing.T, terms []*big.Int) *big.Int {
	h, err := iden3.Hash(terms)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func assign(terms []*big.Int, c *big.Int) *SolvencyCircuit {
	return &SolvencyCircuit{
		PoolHi: terms[0], PoolLo: terms[1],
		BorrowerHi: terms[2], BorrowerLo: terms[3],
		Debt: terms[4], Collateral: terms[5], LtvBps: terms[6], Nonce: terms[7],
		TypeHi: terms[8], TypeLo: terms[9], Price: terms[10],
		Commit: c,
	}
}

// A solvent loan satisfies every constraint.
func TestSolvency_Solvent(t *testing.T) {
	terms := sampleTerms(1000)
	err := test.IsSolved(&SolvencyCircuit{}, assign(terms, commit(t, terms)), ecc.BN254.ScalarField())
	if err != nil {
		t.Fatalf("solvent loan should satisfy the circuit: %v", err)
	}
}

// An over-borrow (debt above the LTV limit) must NOT satisfy the circuit.
func TestSolvency_OverBorrowRejected(t *testing.T) {
	terms := sampleTerms(1200) // > 1165.5 max
	err := test.IsSolved(&SolvencyCircuit{}, assign(terms, commit(t, terms)), ecc.BN254.ScalarField())
	if err == nil {
		t.Fatal("over-borrow must fail the solvency constraint, but the circuit accepted it")
	}
	t.Logf("over-borrow correctly rejected: %v", err)
}

// Tampering with a term after committing must break the commitment binding: prove the terms are
// the ones the commitment fixes, not a swapped-in cheaper set.
func TestSolvency_CommitmentBinds(t *testing.T) {
	terms := sampleTerms(1000)
	c := commit(t, terms)
	tampered := sampleTerms(1000)
	tampered[5] = big.NewInt(1) // claim 1 unit of collateral against a commitment made for 10
	err := test.IsSolved(&SolvencyCircuit{}, assign(tampered, c), ecc.BN254.ScalarField())
	if err == nil {
		t.Fatal("changing a term without changing Commit must fail the binding")
	}
	t.Logf("commitment binding holds: %v", err)
}

// The Phase 1 deliverable: a real Groth16 proof that verifies locally.
func TestSolvency_Groth16ProveVerify(t *testing.T) {
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &SolvencyCircuit{})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("R1CS: %d constraints", ccs.GetNbConstraints())

	pk, vk, err := groth16.Setup(ccs)
	if err != nil {
		t.Fatal(err)
	}

	terms := sampleTerms(1000)
	full, err := frontend.NewWitness(assign(terms, commit(t, terms)), ecc.BN254.ScalarField())
	if err != nil {
		t.Fatal(err)
	}
	proof, err := groth16.Prove(ccs, pk, full)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := full.Public()
	if err != nil {
		t.Fatal(err)
	}
	if err := groth16.Verify(proof, vk, pub); err != nil {
		t.Fatalf("valid proof must verify: %v", err)
	}
	t.Log("groth16 proof verified locally ✓")
}
