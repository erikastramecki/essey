package poseidon

import (
	"math/big"

	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/math/cmp"
	"github.com/consensys/gnark/std/math/emulated"
	"github.com/consensys/gnark/std/math/uints"
	"github.com/consensys/gnark/std/signature/ecdsa"
)

// OracleBoundTransition is a state transition whose price is NOT a free witness: it is the price
// extracted from a Pyth price message that is Merkle-included under a root the guardian quorum signed.
// So the solvency check is proven against a real, guardian-attested price, closing the gap where a
// prover could otherwise borrow against a price of their choosing.
//
//	guardian quorum verifies body -> Merkle root -> price message climbs to root -> attested price
//	-> proveBorrow(old_root -> new_root) solvent at THAT price
//
// It reuses the portable-proof primitives (verifyPythQuorum, attestPythPrice) and the rung-1 borrow
// rule (proveBorrow), so the guardian trust chain and the transition rule each live in one place.
type OracleBoundTransition struct {
	// Pyth attestation of the price.
	Body    []uints.U8
	Pubs    []ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr]
	Sigs    []ecdsa.Signature[emulated.Secp256k1Fr]
	Message []uints.U8
	Proof   [][]uints.U8

	// State transition (the borrow applied against the attested price).
	Old      Position
	Amount   frontend.Variable
	PathBits [StateTreeDepth]frontend.Variable
	Siblings [StateTreeDepth]frontend.Variable

	OldRoot frontend.Variable `gnark:",public"`
	NewRoot frontend.Variable `gnark:",public"`
	// No public Price input: the price is the attested value derived in-circuit, not supplied.
}

func (c *OracleBoundTransition) Define(api frontend.API) error {
	uapi, err := uints.New[uints.U64](api)
	if err != nil {
		return err
	}
	root, err := verifyPythQuorum(api, c.Body, c.Pubs, c.Sigs)
	if err != nil {
		return err
	}
	cmp160 := cmp.NewBoundedComparator(api, new(big.Int).Lsh(big.NewInt(1), 160), false)
	price := attestPythPrice(api, uapi, cmp160, root, c.Message, c.Proof)

	proveBorrow(api, c.Old, c.Amount, price, c.PathBits[:], c.Siblings[:], c.OldRoot, c.NewRoot)
	return nil
}
