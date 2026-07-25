package poseidon

import (
	"os"
	"strconv"
	"testing"
	"time"

	"crypto/rand"

	"github.com/consensys/gnark-crypto/ecc"
	secpecdsa "github.com/consensys/gnark-crypto/ecc/secp256k1/ecdsa"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/algebra/emulated/sw_emulated"
	"github.com/consensys/gnark/std/math/emulated"
	"github.com/consensys/gnark/std/signature/ecdsa"
)

// quorumCircuit verifies COUNT independent secp256k1 ECDSA signatures — a stand-in for the
// Wormhole guardian quorum that attests a Pyth price. Slice lengths are fixed per compile.
type quorumCircuit struct {
	Sigs []ecdsa.Signature[emulated.Secp256k1Fr]
	Msgs []emulated.Element[emulated.Secp256k1Fr]
	Pubs []ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr]
}

func (c *quorumCircuit) Define(api frontend.API) error {
	params := sw_emulated.GetCurveParams[emulated.Secp256k1Fp]()
	for i := range c.Sigs {
		c.Pubs[i].Verify(api, params, &c.Msgs[i], &c.Sigs[i])
	}
	return nil
}

type countWriter struct{ n int64 }

func (w *countWriter) Write(p []byte) (int, error) { w.n += int64(len(p)); return len(p), nil }

// TestQuorum_FullPipeline measures the whole Groth16 cost of "heavy B" — compile, trusted setup,
// proving-key size, prove, verify — for COUNT ECDSA verifications. Set COUNT=13 for the Wormhole
// quorum. Run peak memory via `/usr/bin/time -l`.
func TestQuorum_FullPipeline(t *testing.T) {
	// Heavy (setup is minutes at high COUNT) — opt-in so the normal suite stays fast.
	v := os.Getenv("COUNT")
	if v == "" {
		t.Skip("set COUNT=<n> to run the ECDSA-quorum benchmark (e.g. COUNT=13)")
	}
	n, _ := strconv.Atoi(v)
	t.Logf("=== %d secp256k1 ECDSA verifications ===", n)

	skeleton := &quorumCircuit{
		Sigs: make([]ecdsa.Signature[emulated.Secp256k1Fr], n),
		Msgs: make([]emulated.Element[emulated.Secp256k1Fr], n),
		Pubs: make([]ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr], n),
	}

	t0 := time.Now()
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, skeleton)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("compile   : %v  (%d constraints)", time.Since(t0).Round(time.Millisecond), ccs.GetNbConstraints())

	t1 := time.Now()
	pk, vk, err := groth16.Setup(ccs)
	if err != nil {
		t.Fatal(err)
	}
	var pkw, vkw countWriter
	pk.WriteTo(&pkw)
	vk.WriteTo(&vkw)
	t.Logf("setup     : %v  (proving key %.1f MB, verifying key %d B)",
		time.Since(t1).Round(time.Millisecond), float64(pkw.n)/1e6, vkw.n)

	// witness: COUNT real signatures
	w := &quorumCircuit{
		Sigs: make([]ecdsa.Signature[emulated.Secp256k1Fr], n),
		Msgs: make([]emulated.Element[emulated.Secp256k1Fr], n),
		Pubs: make([]ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr], n),
	}
	for i := 0; i < n; i++ {
		priv, err := secpecdsa.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		msg := []byte("pyth-price-attestation-" + strconv.Itoa(i))
		sigBin, err := priv.Sign(msg, nil)
		if err != nil {
			t.Fatal(err)
		}
		var sig secpecdsa.Signature
		sig.SetBytes(sigBin)
		w.Sigs[i].R = emulated.ValueOf[emulated.Secp256k1Fr](sig.R[:32])
		w.Sigs[i].S = emulated.ValueOf[emulated.Secp256k1Fr](sig.S[:32])
		w.Msgs[i] = emulated.ValueOf[emulated.Secp256k1Fr](secpecdsa.HashToInt(msg))
		w.Pubs[i].X = emulated.ValueOf[emulated.Secp256k1Fp](priv.PublicKey.A.X)
		w.Pubs[i].Y = emulated.ValueOf[emulated.Secp256k1Fp](priv.PublicKey.A.Y)
	}
	full, err := frontend.NewWitness(w, ecc.BN254.ScalarField())
	if err != nil {
		t.Fatal(err)
	}

	t2 := time.Now()
	proof, err := groth16.Prove(ccs, pk, full)
	if err != nil {
		t.Fatal(err)
	}
	proveT := time.Since(t2)

	pub, err := full.Public()
	if err != nil {
		t.Fatal(err)
	}
	t3 := time.Now()
	if err := groth16.Verify(proof, vk, pub); err != nil {
		t.Fatalf("proof must verify: %v", err)
	}
	t.Logf("PROVE     : %v", proveT.Round(time.Millisecond))
	t.Logf("verify    : %v", time.Since(t3).Round(time.Millisecond))
}
