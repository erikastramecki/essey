package poseidon

import (
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/algebra/emulated/sw_emulated"
	"github.com/consensys/gnark/std/math/emulated"
	"github.com/consensys/gnark/std/signature/ecdsa"
)

// ecdsaOne verifies a single secp256k1 ECDSA signature — the primitive Pyth/Wormhole guardians use.
// secp256k1 is not BN254's field, so every operation is emulated ("wrong-field") arithmetic, which
// is where the cost explodes.
type ecdsaOne struct {
	Sig ecdsa.Signature[emulated.Secp256k1Fr]
	Msg emulated.Element[emulated.Secp256k1Fr]
	Pub ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr]
}

func (c *ecdsaOne) Define(api frontend.API) error {
	c.Pub.Verify(api, sw_emulated.GetCurveParams[emulated.Secp256k1Fp](), &c.Msg, &c.Sig)
	return nil
}

// TestEcdsa_ConstraintCount puts a hard floor under the "heavy B" estimate: it compiles ONE
// secp256k1 ECDSA verify and extrapolates to the Wormhole guardian quorum. Compile-only (no prove)
// because proving this many constraints is slow and memory-heavy — the count is the deliverable.
func TestEcdsa_ConstraintCount(t *testing.T) {
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &ecdsaOne{})
	if err != nil {
		t.Fatal(err)
	}
	one := ccs.GetNbConstraints()
	t.Logf("one secp256k1 ECDSA verify : %d constraints", one)
	t.Logf("Wormhole quorum ~13 of 19  : ~%d constraints (13x)", one*13)
	t.Logf("all 19 guardians           : ~%d constraints (19x)", one*19)
	t.Logf("for scale: bare solvency 2235 | EdDSA-attested 9238 | secp256k1 x13 ~%d", one*13)
}
