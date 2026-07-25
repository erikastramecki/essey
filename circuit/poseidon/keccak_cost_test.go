package poseidon

import (
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/hash/sha3"
	"github.com/consensys/gnark/std/math/uints"
)

// keccakN measures keccak256 over an n-byte input (n <= 136 = one permutation block, which covers
// every hash the Pyth/Wormhole verifier needs: body 88, digest 32, pubkey 64, leaf 86, node 41).
type keccakN struct {
	In  []uints.U8
	Out [32]uints.U8 `gnark:",public"`
}

func (c *keccakN) Define(api frontend.API) error {
	h, err := sha3.NewLegacyKeccak256(api)
	if err != nil {
		return err
	}
	uapi, err := uints.New[uints.U64](api)
	if err != nil {
		return err
	}
	h.Write(c.In)
	res := h.Sum()
	for i := range c.Out {
		uapi.ByteAssertEq(c.Out[i], res[i])
	}
	return nil
}

// TestKeccak_ConstraintCount replaces the ~4M keccak ESTIMATE with a measured per-hash number, then
// projects the full Pyth/Wormhole verifier: ~29 single-block keccaks + the measured 1.27M ECDSA
// quorum + the ~2k solvency core.
func TestKeccak_ConstraintCount(t *testing.T) {
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder,
		&keccakN{In: make([]uints.U8, 88)})
	if err != nil {
		t.Fatal(err)
	}
	one := ccs.GetNbConstraints()
	t.Logf("one keccak256 (1 block)    : %d constraints", one)

	const nHashes = 29 // 2 body double-hash + 13 pubkey->address + 14 merkle (leaf + 13 hops)
	const ecdsaQuorum = 1266437
	const solvency = 2235
	keccakTotal := one * nHashes
	full := keccakTotal + ecdsaQuorum + solvency
	t.Logf("~%d keccaks (body+addr+merkle): ~%d constraints", nHashes, keccakTotal)
	t.Logf("+ ECDSA quorum (measured)   : %d", ecdsaQuorum)
	t.Logf("+ solvency core             : %d", solvency)
	t.Logf("=> FULL portable-proof circuit: ~%d constraints (~%.1fM)", full, float64(full)/1e6)
}
