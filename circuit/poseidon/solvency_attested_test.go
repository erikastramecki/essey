package poseidon

import (
	"crypto/rand"
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	tedwards "github.com/consensys/gnark-crypto/ecc/twistededwards"
	"github.com/consensys/gnark-crypto/hash"
	nativeeddsa "github.com/consensys/gnark-crypto/signature/eddsa"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
)

// TestAttested_ConstraintCount is the whole point: the MEASURED cost of Option B on our circuit,
// not an estimate. It compiles the bare and attested circuits and reports the delta, then does a
// full Groth16 Setup/Prove/Verify with a real attester signature over the price.
func TestAttested_ConstraintCount(t *testing.T) {
	bare, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &SolvencyCircuit{})
	if err != nil {
		t.Fatal(err)
	}
	att, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &SolvencyAttestedCircuit{})
	if err != nil {
		t.Fatal(err)
	}
	nb, na := bare.GetNbConstraints(), att.GetNbConstraints()
	t.Logf("bare solvency circuit      : %d constraints", nb)
	t.Logf("attested (EdDSA in-circuit): %d constraints", na)
	t.Logf("EdDSA signature-verify cost: +%d constraints (%.1fx total)", na-nb, float64(na)/float64(nb))

	// --- real signature over the price, then a real proof ---
	terms := sampleTerms(1000) // solvent; price is terms[10] = 333
	c := commit(t, terms)

	privKey, err := nativeeddsa.New(tedwards.BN254, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	// sign the price as a field element, left-padded to the field byte length
	field := ecc.BN254.ScalarField()
	msgData := make([]byte, len(field.Bytes()))
	pb := terms[10].Bytes()
	copy(msgData[len(msgData)-len(pb):], pb)
	sig, err := privKey.Sign(msgData, hash.MIMC_BN254.New())
	if err != nil {
		t.Fatal(err)
	}

	w := &SolvencyAttestedCircuit{
		PoolHi: terms[0], PoolLo: terms[1], BorrowerHi: terms[2], BorrowerLo: terms[3],
		Debt: terms[4], Collateral: terms[5], LtvBps: terms[6], Nonce: terms[7],
		TypeHi: terms[8], TypeLo: terms[9], Price: terms[10], Commit: c,
	}
	w.AttesterPubKey.Assign(tedwards.BN254, privKey.Public().Bytes())
	w.PriceSig.Assign(tedwards.BN254, sig)

	pk, vk, err := groth16.Setup(att)
	if err != nil {
		t.Fatal(err)
	}
	full, err := frontend.NewWitness(w, ecc.BN254.ScalarField())
	if err != nil {
		t.Fatal(err)
	}
	proof, err := groth16.Prove(att, pk, full)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := full.Public()
	if err != nil {
		t.Fatal(err)
	}
	if err := groth16.Verify(proof, vk, pub); err != nil {
		t.Fatalf("attested proof must verify: %v", err)
	}
	t.Log("attested proof (price signed by attester) verified locally ✓")
}
