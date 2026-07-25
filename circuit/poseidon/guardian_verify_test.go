package poseidon

import (
	"encoding/hex"
	"math/big"
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/algebra/emulated/sw_emulated"
	"github.com/consensys/gnark/std/hash/sha3"
	"github.com/consensys/gnark/std/math/emulated"
	"github.com/consensys/gnark/std/math/uints"
	"github.com/consensys/gnark/std/signature/ecdsa"
)

// Real guardian-0 witness from the committed Pyth fixture (pubkey recovered natively).
const (
	realPubX = "9a1e801daa25d9808e70aae9981353086f958955cc94ef33a461b0e596feaef9"
	realPubY = "0a8474dd10cf6ae967143f86105c16d6304a3d268ea952fda9389139d4bb9da1"
	realSigR = "f0971465a645fba95601c5aa076655efbca23001cf03ea29fe8f76674d27ff95"
	realSigS = "0bc7b717a59d38124b71259d8d46a2dae41d6f0e3d8308f942fd4915b084a0f2"
)

// digestToScalar now lives in portableproof.go (library code, shared with the prover).

// singleGuardianCircuit: the seam closed. It computes the guardian-signed digest from the real body
// in-circuit, then verifies a real guardian ECDSA signature over it against the pinned pubkey. This
// is one guardian's slice of the portable-proof verifier, end to end, on real data.
type singleGuardianCircuit struct {
	Body []uints.U8
	Pub  ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr] `gnark:",public"`
	Sig  ecdsa.Signature[emulated.Secp256k1Fr]
}

func (c *singleGuardianCircuit) Define(api frontend.API) error {
	h1, err := sha3.NewLegacyKeccak256(api)
	if err != nil {
		return err
	}
	h1.Write(c.Body)
	h2, err := sha3.NewLegacyKeccak256(api)
	if err != nil {
		return err
	}
	h2.Write(h1.Sum())
	digest := h2.Sum()

	fr, err := emulated.NewField[emulated.Secp256k1Fr](api)
	if err != nil {
		return err
	}
	msg := digestToScalar(api, fr, digest)
	c.Pub.Verify(api, sw_emulated.GetCurveParams[emulated.Secp256k1Fp](), msg, &c.Sig)
	return nil
}

func hb(s string) *big.Int { b, _ := hex.DecodeString(s); return new(big.Int).SetBytes(b) }

func TestGuardianVerify_InCircuit_RealSig(t *testing.T) {
	body, _ := hex.DecodeString(realBodyHex)

	skeleton := &singleGuardianCircuit{Body: make([]uints.U8, len(body))}
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, skeleton)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("single-guardian verify circuit: %d constraints", ccs.GetNbConstraints())

	pk, vk, err := groth16.Setup(ccs)
	if err != nil {
		t.Fatal(err)
	}
	w := &singleGuardianCircuit{
		Body: uints.NewU8Array(body),
		Pub: ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr]{
			X: emulated.ValueOf[emulated.Secp256k1Fp](hb(realPubX)),
			Y: emulated.ValueOf[emulated.Secp256k1Fp](hb(realPubY)),
		},
		Sig: ecdsa.Signature[emulated.Secp256k1Fr]{
			R: emulated.ValueOf[emulated.Secp256k1Fr](hb(realSigR)),
			S: emulated.ValueOf[emulated.Secp256k1Fr](hb(realSigS)),
		},
	}
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
		t.Fatalf("real guardian signature over the in-circuit digest must verify: %v", err)
	}
	t.Log("in-circuit: real guardian ECDSA sig verified over keccak256(keccak256(real body)) ✓ — seam closed")
}
