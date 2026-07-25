package poseidon

import (
	"encoding/hex"
	"math/big"
	"os"
	"strings"
	"testing"

	"essey/pyth"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/algebra/emulated/sw_emulated"
	"github.com/consensys/gnark/std/hash/sha3"
	"github.com/consensys/gnark/std/math/cmp"
	"github.com/consensys/gnark/std/math/emulated"
	"github.com/consensys/gnark/std/math/uints"
	"github.com/consensys/gnark/std/signature/ecdsa"
	"github.com/consensys/gnark/test"
	iden3 "github.com/iden3/go-iden3-crypto/poseidon"
)

// loanSlot is one loan in a batch: its price message + Merkle proof (under the shared root) and its
// solvency terms, with a per-loan public commitment.
type loanSlot struct {
	Message                []uints.U8
	Proof                  [][]uints.U8
	PoolHi, PoolLo         frontend.Variable
	BorrowerHi, BorrowerLo frontend.Variable
	Debt, Collateral       frontend.Variable
	LtvBps, Nonce          frontend.Variable
	TypeHi, TypeLo         frontend.Variable
	Commit                 frontend.Variable `gnark:",public"`
}

// batchCircuit verifies the guardian quorum + root ONCE, then proves N loans under that one signed
// root. The expensive guardian ECDSA is shared across the whole batch; per-loan cost is one Merkle
// climb + solvency.
type batchCircuit struct {
	Body  []uints.U8
	Pubs  []ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr]
	Sigs  []ecdsa.Signature[emulated.Secp256k1Fr]
	Loans []loanSlot
}

func (c *batchCircuit) Define(api frontend.API) error {
	uapi, err := uints.New[uints.U64](api)
	if err != nil {
		return err
	}
	// --- shared: guardian quorum over the body digest ---
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

	// --- per loan: Merkle inclusion under the shared root + solvency ---
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

func loadMultiWitness(t *testing.T) *pyth.Witness {
	t.Helper()
	h, err := os.ReadFile("../pyth/testdata/pyth_multi_update.hex")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := hex.DecodeString(strings.TrimSpace(string(h)))
	if err != nil {
		t.Fatal(err)
	}
	w, err := pyth.BuildWitness(raw, pyth.GuardianSet7)
	if err != nil {
		t.Fatalf("multi-feed update must verify natively: %v", err)
	}
	return w
}

// build a batch circuit skeleton + witness for the first n loans of the update.
func batchInputs(t *testing.T, pw *pyth.Witness, n int) (skel, w *batchCircuit) {
	ng := len(pw.Guardians)

	skel = &batchCircuit{
		Body: make([]uints.U8, len(pw.Body)),
		Pubs: make([]ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr], ng),
		Sigs: make([]ecdsa.Signature[emulated.Secp256k1Fr], ng),
		Loans: make([]loanSlot, n),
	}
	w = &batchCircuit{
		Body: uints.NewU8Array(pw.Body),
		Pubs: make([]ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr], ng),
		Sigs: make([]ecdsa.Signature[emulated.Secp256k1Fr], ng),
		Loans: make([]loanSlot, n),
	}
	for i, g := range pw.Guardians {
		w.Pubs[i].X = emulated.ValueOf[emulated.Secp256k1Fp](new(big.Int).SetBytes(g.PubX[:]))
		w.Pubs[i].Y = emulated.ValueOf[emulated.Secp256k1Fp](new(big.Int).SetBytes(g.PubY[:]))
		w.Sigs[i].R = emulated.ValueOf[emulated.Secp256k1Fr](new(big.Int).SetBytes(g.SigR[:]))
		w.Sigs[i].S = emulated.ValueOf[emulated.Secp256k1Fr](new(big.Int).SetBytes(g.SigS[:]))
	}
	for li := 0; li < n; li++ {
		p := pw.Prices[li%len(pw.Prices)]
		skel.Loans[li].Message = make([]uints.U8, len(p.Message))
		skel.Loans[li].Proof = make([][]uints.U8, len(p.Proof))
		for j := range skel.Loans[li].Proof {
			skel.Loans[li].Proof[j] = make([]uints.U8, 20)
		}
		// solvent loan sized to THIS price: collateral 1, 35% LTV, debt just under max.
		price := big.NewInt(p.Price)
		maxDebt := new(big.Int).Div(new(big.Int).Mul(price, big.NewInt(3500)), big.NewInt(10000))
		debt := new(big.Int).Sub(maxDebt, big.NewInt(1))
		terms := []*big.Int{
			big.NewInt(int64(0x1000 + li)), big.NewInt(0x2222), big.NewInt(0x3333), big.NewInt(0x4444),
			debt, big.NewInt(1), big.NewInt(3500), big.NewInt(int64(li)),
			big.NewInt(0x5555), big.NewInt(0x6666), price,
		}
		commit, err := iden3.Hash(terms)
		if err != nil {
			t.Fatal(err)
		}
		ls := &w.Loans[li]
		ls.Message = uints.NewU8Array(p.Message)
		ls.Proof = make([][]uints.U8, len(p.Proof))
		for j, hsh := range p.Proof {
			ls.Proof[j] = uints.NewU8Array(hsh[:])
		}
		ls.PoolHi, ls.PoolLo, ls.BorrowerHi, ls.BorrowerLo = terms[0], terms[1], terms[2], terms[3]
		ls.Debt, ls.Collateral, ls.LtvBps, ls.Nonce = terms[4], terms[5], terms[6], terms[7]
		ls.TypeHi, ls.TypeLo, ls.Commit = terms[8], terms[9], commit
	}
	return skel, w
}

// TestBatch_PerLoanMarginal measures how the circuit grows as loans are added — the batching value:
// the guardian ECDSA is paid once, so each extra loan costs only its Merkle climb + solvency.
func TestBatch_PerLoanMarginal(t *testing.T) {
	pw := loadMultiWitness(t)
	t.Logf("multi-feed update: %d guardians, %d prices under one signed root", len(pw.Guardians), len(pw.Prices))

	var prev int
	for _, n := range []int{1, 2, 3} {
		skel, _ := batchInputs(t, pw, n)
		ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, skel)
		if err != nil {
			t.Fatal(err)
		}
		c := ccs.GetNbConstraints()
		if prev == 0 {
			t.Logf("batch n=%d: %d constraints", n, c)
		} else {
			t.Logf("batch n=%d: %d constraints (+%d for this loan)", n, c, c-prev)
		}
		prev = c
	}
}

// TestBatch_Solves confirms a real multi-price batch satisfies every constraint.
func TestBatch_Solves(t *testing.T) {
	pw := loadMultiWitness(t)
	n := len(pw.Prices)
	skel, w := batchInputs(t, pw, n)
	if err := test.IsSolved(skel, w, ecc.BN254.ScalarField()); err != nil {
		t.Fatalf("real %d-loan batch must satisfy the circuit: %v", n, err)
	}
	t.Logf("SOLVED: %d loans against %d distinct Pyth prices, all under ONE guardian-signed root, "+
		"one shared quorum verification ✓", n, n)
}
