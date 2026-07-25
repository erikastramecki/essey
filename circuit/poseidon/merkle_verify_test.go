package poseidon

import (
	"encoding/hex"
	"math/big"
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/hash/sha3"
	"github.com/consensys/gnark/std/math/cmp"
	"github.com/consensys/gnark/std/math/uints"
	"github.com/consensys/gnark/test"
)

// Real Merkle witness from the committed Pyth fixture: the 85-byte price message, its 13-hop proof,
// and the root that lives in the (guardian-signed) VAA body.
const (
	realMsgHex  = "00e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43000005d503bb47da000000005900c1a4fffffff8000000006a64d088000000006a64d087000005d434984500000000005b75fa5c"
	realRootHex = "2029746a3b61f34f90c804bff3b951e8925db70a"
	realProof   = "b18afbc1ace9de2f6f93a9144ed109fec3c3bea6" + "1f45f9017fa3cbc3bc18df2c1ab15e1e8278b900" +
		"ac32faffa55f346f9399477cc3c4fd0c807d6fe1" + "fe87b594ed7a8257c37d110bee8f0a5bf8583d64" +
		"08e34920738aed5a5a4381837e0d79b47be16227" + "1519ab9c64ccf6359c58d9635d7acb4fe0e6e3d5" +
		"5ba441edfaf05915c52c18d1d3e563306f9ed86f" + "72e89a5c01870d6e624c42d529a436502de61e6e" +
		"63686e0870bce39a3ab06bec55653a395f78d813" + "d052f2631a1edc320261febe9d61b395d1c13370" +
		"a8d6c1225551fa29311b92dec893eaafeeafcce3" + "ce514929145022a4cc4df01731b4defd5a0337cb" +
		"0bf9ea700137754441732b59591d7aef631aa185"
)

func keccak20(api frontend.API, in []uints.U8) []uints.U8 {
	h, _ := sha3.NewLegacyKeccak256(api)
	h.Write(in)
	return h.Sum()[:20] // Pyth truncates keccak256 to 160 bits
}

// packBE folds a 20-byte hash into one 160-bit field element for numeric (== lexicographic)
// comparison. 160 bits « the BN254 field, so no wrap.
func packBE(api frontend.API, h []uints.U8) frontend.Variable {
	acc := frontend.Variable(0)
	for _, b := range h {
		acc = api.Add(api.Mul(acc, 256), b.Val)
	}
	return acc
}

// sortPair returns (min, max) of two 20-byte hashes — Pyth hashes the SORTED pair, so proofs carry
// no left/right flags.
func sortPair(api frontend.API, uapi *uints.BinaryField[uints.U64], cmp160 *cmp.BoundedComparator, a, b []uints.U8) (lo, hi []uints.U8) {
	aLE := cmp160.IsLessEq(packBE(api, a), packBE(api, b)) // 1 iff a <= b
	lo = make([]uints.U8, len(a))
	hi = make([]uints.U8, len(a))
	for i := range a {
		lo[i] = uapi.ByteValueOf(api.Select(aLE, a[i].Val, b[i].Val))
		hi[i] = uapi.ByteValueOf(api.Select(aLE, b[i].Val, a[i].Val))
	}
	return lo, hi
}

// merkleCircuit proves the price message is included under Root via the Pyth keccak160 Merkle tree.
type merkleCircuit struct {
	Message []uints.U8
	Proof   [][]uints.U8
	Root    []uints.U8 `gnark:",public"`
}

func (c *merkleCircuit) Define(api frontend.API) error {
	uapi, err := uints.New[uints.U64](api)
	if err != nil {
		return err
	}
	cmp160 := cmp.NewBoundedComparator(api, new(big.Int).Lsh(big.NewInt(1), 160), false)

	// leaf = keccak256(0x00 || message)[:20]
	cur := keccak20(api, append([]uints.U8{uints.NewU8(0)}, c.Message...))
	for _, sib := range c.Proof {
		lo, hi := sortPair(api, uapi, cmp160, cur, sib)
		in := append([]uints.U8{uints.NewU8(1)}, lo...)
		in = append(in, hi...)
		cur = keccak20(api, in) // node = keccak256(0x01 || min || max)[:20]
	}
	for i := range c.Root {
		uapi.ByteAssertEq(c.Root[i], cur[i])
	}
	return nil
}

func u8s(b []byte) []uints.U8 { return uints.NewU8Array(b) }

func TestMerkle_InCircuit_RealProof(t *testing.T) {
	msg, _ := hex.DecodeString(realMsgHex)
	root, _ := hex.DecodeString(realRootHex)
	proofBytes, _ := hex.DecodeString(realProof)
	hops := len(proofBytes) / 20

	skeleton := &merkleCircuit{Message: make([]uints.U8, len(msg)), Root: make([]uints.U8, 20)}
	skeleton.Proof = make([][]uints.U8, hops)
	for i := range skeleton.Proof {
		skeleton.Proof[i] = make([]uints.U8, 20)
	}
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, skeleton)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("in-circuit merkle (%d hops): %d constraints", hops, ccs.GetNbConstraints())

	w := &merkleCircuit{Message: u8s(msg), Root: u8s(root), Proof: make([][]uints.U8, hops)}
	for i := 0; i < hops; i++ {
		w.Proof[i] = u8s(proofBytes[i*20 : i*20+20])
	}
	// test.IsSolved checks the witness satisfies every constraint (correctness) without the ~6-min
	// Groth16 setup this 2.7M-constraint circuit would need; full-proof timing follows the measured
	// linear extrapolation already characterised in BUILD-portable-proof.md.
	if err := test.IsSolved(&merkleCircuit{Message: make([]uints.U8, len(msg)), Root: make([]uints.U8, 20),
		Proof: skeleton.Proof}, w, ecc.BN254.ScalarField()); err != nil {
		t.Fatalf("real Merkle proof must satisfy the in-circuit climb: %v", err)
	}
	t.Log("in-circuit: real 13-hop Pyth Merkle proof climbs to the real root ✓")
}
