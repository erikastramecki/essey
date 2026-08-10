package poseidon

import (
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/algebra/emulated/sw_emulated"
	"github.com/consensys/gnark/std/hash/sha3"
	"github.com/consensys/gnark/std/math/cmp"
	"github.com/consensys/gnark/std/math/emulated"
	"github.com/consensys/gnark/std/math/uints"
	"github.com/consensys/gnark/std/signature/ecdsa"
)

// Shared Pyth-attestation gadgets extracted so the oracle-bound transition (oracle_transition.go) can
// bind its price to the SAME guardian trust chain the batch portable proof (BatchCircuit) uses. Both the
// quorum check and the Merkle-inclusion price extraction live here, over the helpers in portableproof.go
// (keccak20, sortPair, packBE, digestToScalar).

// verifyPythQuorum enforces that the pinned guardians signed `body` (the accumulator update the guardians
// double-keccak and sign) and returns the Merkle root committed at body[68:88].
func verifyPythQuorum(api frontend.API, body []uints.U8,
	pubs []ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr],
	sigs []ecdsa.Signature[emulated.Secp256k1Fr]) ([]uints.U8, error) {
	h1, _ := sha3.NewLegacyKeccak256(api)
	h1.Write(body)
	h2, _ := sha3.NewLegacyKeccak256(api)
	h2.Write(h1.Sum())
	fr, err := emulated.NewField[emulated.Secp256k1Fr](api)
	if err != nil {
		return nil, err
	}
	msg := digestToScalar(api, fr, h2.Sum())
	params := sw_emulated.GetCurveParams[emulated.Secp256k1Fp]()
	for i := range pubs {
		pubs[i].Verify(api, params, msg, &sigs[i])
	}
	return body[68:88], nil
}

// attestPythPrice climbs `message` via `proof` to `root` (Pyth's keccak160 sorted-pair Merkle tree),
// asserts it lands on the signed root, and returns the price extracted from message[33:41] — a real
// Pyth-attested price, usable in a solvency check instead of a free-witness price.
func attestPythPrice(api frontend.API, uapi *uints.BinaryField[uints.U64], cmp160 *cmp.BoundedComparator,
	root, message []uints.U8, proof [][]uints.U8) frontend.Variable {
	cur := keccak20(api, append([]uints.U8{uints.NewU8(0)}, message...))
	for _, sib := range proof {
		lo, hi := sortPair(api, uapi, cmp160, cur, sib)
		in := append([]uints.U8{uints.NewU8(1)}, lo...)
		cur = keccak20(api, append(in, hi...))
	}
	for i := 0; i < 20; i++ {
		uapi.ByteAssertEq(root[i], cur[i])
	}
	return packBE(api, message[33:41])
}
