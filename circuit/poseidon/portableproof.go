package poseidon

import (
	"math/big"

	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/algebra/emulated/sw_emulated"
	"github.com/consensys/gnark/std/hash/sha3"
	"github.com/consensys/gnark/std/math/bits"
	"github.com/consensys/gnark/std/math/cmp"
	"github.com/consensys/gnark/std/math/emulated"
	"github.com/consensys/gnark/std/math/uints"
	"github.com/consensys/gnark/std/signature/ecdsa"
)

// This file is the PRODUCTION circuit — library code (not _test.go), so the prover service can
// compile and prove it. The trust chain it enforces is documented on BatchCircuit.

// keccak20 hashes with keccak256 and truncates to 160 bits — Pyth's Merkle node hash.
func keccak20(api frontend.API, in []uints.U8) []uints.U8 {
	h, _ := sha3.NewLegacyKeccak256(api)
	h.Write(in)
	return h.Sum()[:20]
}

// packBE folds big-endian bytes into one field element (numeric == lexicographic for fixed width).
func packBE(api frontend.API, h []uints.U8) frontend.Variable {
	acc := frontend.Variable(0)
	for _, b := range h {
		acc = api.Add(api.Mul(acc, 256), b.Val)
	}
	return acc
}

// sortPair returns (min, max) of two 20-byte hashes; Pyth hashes the SORTED pair.
func sortPair(api frontend.API, uapi *uints.BinaryField[uints.U64], cmp160 *cmp.BoundedComparator, a, b []uints.U8) (lo, hi []uints.U8) {
	aLE := cmp160.IsLessEq(packBE(api, a), packBE(api, b))
	lo = make([]uints.U8, len(a))
	hi = make([]uints.U8, len(a))
	for i := range a {
		lo[i] = uapi.ByteValueOf(api.Select(aLE, a[i].Val, b[i].Val))
		hi[i] = uapi.ByteValueOf(api.Select(aLE, b[i].Val, a[i].Val))
	}
	return lo, hi
}

// digestToScalar bridges a 32-byte big-endian keccak digest to the secp256k1 scalar the ECDSA
// gadget takes as its message (little-endian FromBits + reduce mod n).
func digestToScalar(api frontend.API, fr *emulated.Field[emulated.Secp256k1Fr], digest []uints.U8) *emulated.Element[emulated.Secp256k1Fr] {
	le := make([]frontend.Variable, 0, len(digest)*8)
	for i := len(digest) - 1; i >= 0; i-- {
		le = append(le, bits.ToBinary(api, digest[i].Val, bits.WithNbDigits(8))...)
	}
	return fr.ReduceStrict(fr.FromBits(le...))
}

// LoanSlot is one loan in a batch: its Pyth price message + Merkle proof (under the shared root) and
// its solvency terms, with a per-loan public commitment.
type LoanSlot struct {
	Message                []uints.U8
	Proof                  [][]uints.U8
	PoolHi, PoolLo         frontend.Variable
	BorrowerHi, BorrowerLo frontend.Variable
	Debt, Collateral       frontend.Variable
	LtvBps, Nonce          frontend.Variable
	TypeHi, TypeLo         frontend.Variable
	Commit                 frontend.Variable `gnark:",public"`
}

// BatchCircuit is the portable proof: it verifies a Pyth guardian quorum + Merkle root ONCE, then
// proves N loans solvent against prices included under that one signed root. The single public
// input per loan (its commitment) is provably tied to a real Pyth-attested price — so the loan can
// settle on any chain that can verify the proof, with no oracle deployed there.
//
//	double-keccak(body) -> N ECDSA verifies vs pinned guardian pubkeys (quorum)
//	-> Merkle root extracted from the signed body (body[68:88])
//	-> per loan: Merkle climb to that root + price extracted from message[33:41] -> solvency commitment
type BatchCircuit struct {
	Body  []uints.U8
	Pubs  []ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr]
	Sigs  []ecdsa.Signature[emulated.Secp256k1Fr]
	Loans []LoanSlot
}

func (c *BatchCircuit) Define(api frontend.API) error {
	uapi, err := uints.New[uints.U64](api)
	if err != nil {
		return err
	}
	h1, _ := sha3.NewLegacyKeccak256(api)
	h1.Write(c.Body)
	h2, _ := sha3.NewLegacyKeccak256(api)
	h2.Write(h1.Sum())
	fr, err := emulated.NewField[emulated.Secp256k1Fr](api)
	if err != nil {
		return err
	}
	msg := digestToScalar(api, fr, h2.Sum())
	params := sw_emulated.GetCurveParams[emulated.Secp256k1Fp]()
	for i := range c.Pubs {
		c.Pubs[i].Verify(api, params, msg, &c.Sigs[i])
	}
	root := c.Body[68:88]
	cmp160 := cmp.NewBoundedComparator(api, new(big.Int).Lsh(big.NewInt(1), 160), false)

	for li := range c.Loans {
		ln := &c.Loans[li]
		cur := keccak20(api, append([]uints.U8{uints.NewU8(0)}, ln.Message...))
		for _, sib := range ln.Proof {
			lo, hi := sortPair(api, uapi, cmp160, cur, sib)
			in := append([]uints.U8{uints.NewU8(1)}, lo...)
			cur = keccak20(api, append(in, hi...))
		}
		for i := 0; i < 20; i++ {
			uapi.ByteAssertEq(root[i], cur[i])
		}
		price := packBE(api, ln.Message[33:41])
		enforceLoan(api, ln.PoolHi, ln.PoolLo, ln.BorrowerHi, ln.BorrowerLo,
			ln.Debt, ln.Collateral, ln.LtvBps, ln.Nonce, ln.TypeHi, ln.TypeLo, price, ln.Commit)
	}
	return nil
}
