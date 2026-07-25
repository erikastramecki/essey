package poseidon

import (
	"encoding/hex"
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/hash/sha3"
	"github.com/consensys/gnark/std/math/uints"
)

// Real guardian-signed material from the committed Pyth fixture (circuit/pyth). The guardians sign
// keccak256(keccak256(body)); this proves the circuit reproduces that digest from the real body.
const (
	realBodyHex   = "6a64d08800000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa71000000000d19d32a0141555756000000000012278dd2000027102029746a3b61f34f90c804bff3b951e8925db70a"
	realDigestHex = "ae69b7aa1c4bda1a2a9ffe44df3ac892e5a11c6d6eea779db60675292508a772"
)

// bodyDigestCircuit computes the double-keccak the guardian quorum signs, in-circuit, and checks it
// equals the public digest. This is the ECDSA "message" the signatures verify against — binding the
// proof to the ACTUAL VAA body rather than an arbitrary value.
type bodyDigestCircuit struct {
	Body   []uints.U8
	Digest []uints.U8 `gnark:",public"`
}

func (c *bodyDigestCircuit) Define(api frontend.API) error {
	uapi, err := uints.New[uints.U64](api)
	if err != nil {
		return err
	}
	h1, err := sha3.NewLegacyKeccak256(api)
	if err != nil {
		return err
	}
	h1.Write(c.Body)
	d1 := h1.Sum()

	h2, err := sha3.NewLegacyKeccak256(api)
	if err != nil {
		return err
	}
	h2.Write(d1)
	d2 := h2.Sum()

	for i := range c.Digest {
		uapi.ByteAssertEq(c.Digest[i], d2[i])
	}
	return nil
}

func TestVaaDigest_InCircuit_RealBody(t *testing.T) {
	body, _ := hex.DecodeString(realBodyHex)
	digest, _ := hex.DecodeString(realDigestHex)

	skeleton := &bodyDigestCircuit{Body: make([]uints.U8, len(body)), Digest: make([]uints.U8, 32)}
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, skeleton)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("double-keccak(body) circuit: %d constraints", ccs.GetNbConstraints())

	pk, vk, err := groth16.Setup(ccs)
	if err != nil {
		t.Fatal(err)
	}
	w := &bodyDigestCircuit{Body: uints.NewU8Array(body), Digest: uints.NewU8Array(digest)}
	full, err := frontend.NewWitness(w, ecc.BN254.ScalarField())
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
		t.Fatalf("in-circuit digest of the real body must verify: %v", err)
	}
	t.Log("in-circuit keccak256(keccak256(real VAA body)) == real guardian digest ✓")
}
