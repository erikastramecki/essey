package poseidon

import (
	"math/big"
	"testing"

	"essey/pyth"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/math/emulated"
	"github.com/consensys/gnark/std/math/uints"
	"github.com/consensys/gnark/std/signature/ecdsa"
	"github.com/consensys/gnark/test"
)

// The native tree helpers (phash / positionLeaf / climb / emptySiblings) live in transition_test.go —
// this file reuses them so the oracle-bound transition builds its tree exactly like TransitionCircuit.

// posForPrice is a position with collateral 1 at 35% LTV, so max debt at price P is P*3500/10000.
func posForPrice(debt *big.Int) Position {
	return Position{
		PoolHi: big.NewInt(0), PoolLo: big.NewInt(7),
		BorrowerHi: big.NewInt(0), BorrowerLo: big.NewInt(0xABCD),
		Debt: debt, Collateral: big.NewInt(1),
		LtvBps: big.NewInt(3500), Nonce: big.NewInt(1),
		TypeHi: big.NewInt(0), TypeLo: big.NewInt(42),
	}
}

// oracleInputs builds an OracleBoundTransition that borrows `amount` (from debt 0) against the price
// Pyth attests in pw.Prices[priceIdx], at tree index idx.
func oracleInputs(t *testing.T, pw *pyth.Witness, priceIdx int, amount *big.Int, idx uint64) (skel, w *OracleBoundTransition) {
	ng := len(pw.Guardians)
	p := pw.Prices[priceIdx]

	sib := emptySiblings(t, StateTreeDepth)
	oldPos := posForPrice(big.NewInt(0))
	newPos := posForPrice(new(big.Int).Set(amount))
	oldRoot := climb(t, positionLeaf(t, oldPos), idx, sib)
	newRoot := climb(t, positionLeaf(t, newPos), idx, sib)

	skel = &OracleBoundTransition{
		Body:    make([]uints.U8, len(pw.Body)),
		Pubs:    make([]ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr], ng),
		Sigs:    make([]ecdsa.Signature[emulated.Secp256k1Fr], ng),
		Message: make([]uints.U8, len(p.Message)),
		Proof:   make([][]uints.U8, len(p.Proof)),
	}
	for j := range skel.Proof {
		skel.Proof[j] = make([]uints.U8, 20)
	}

	w = &OracleBoundTransition{
		Body:    uints.NewU8Array(pw.Body),
		Pubs:    make([]ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr], ng),
		Sigs:    make([]ecdsa.Signature[emulated.Secp256k1Fr], ng),
		Message: uints.NewU8Array(p.Message),
		Proof:   make([][]uints.U8, len(p.Proof)),
		Old:     oldPos,
		Amount:  new(big.Int).Set(amount),
		OldRoot: oldRoot,
		NewRoot: newRoot,
	}
	for i, g := range pw.Guardians {
		w.Pubs[i].X = emulated.ValueOf[emulated.Secp256k1Fp](new(big.Int).SetBytes(g.PubX[:]))
		w.Pubs[i].Y = emulated.ValueOf[emulated.Secp256k1Fp](new(big.Int).SetBytes(g.PubY[:]))
		w.Sigs[i].R = emulated.ValueOf[emulated.Secp256k1Fr](new(big.Int).SetBytes(g.SigR[:]))
		w.Sigs[i].S = emulated.ValueOf[emulated.Secp256k1Fr](new(big.Int).SetBytes(g.SigS[:]))
	}
	for j, hsh := range p.Proof {
		w.Proof[j] = uints.NewU8Array(hsh[:])
	}
	for i := 0; i < StateTreeDepth; i++ {
		w.PathBits[i] = big.NewInt(int64((idx >> uint(i)) & 1))
		w.Siblings[i] = sib[i]
	}
	return skel, w
}

// attestedPrice reads the price exactly as the circuit does: big-endian message[33:41].
func attestedPrice(p pyth.PriceWitness) *big.Int {
	return new(big.Int).SetBytes(p.Message[33:41])
}

func maxDebtAt(price *big.Int) *big.Int {
	return new(big.Int).Div(new(big.Int).Mul(price, big.NewInt(3500)), big.NewInt(10000))
}

// TestOracle_Solvent — a borrow just under the max allowed by the REAL Pyth-attested price solves.
// The price is never supplied as a witness: it is derived from the guardian-signed, Merkle-included msg.
func TestOracle_Solvent(t *testing.T) {
	if testing.Short() {
		t.Skip("full Pyth guardian quorum in-circuit (~2.4M constraints)")
	}
	pw := loadMultiWitness(t)
	price := attestedPrice(pw.Prices[0])
	amount := new(big.Int).Sub(maxDebtAt(price), big.NewInt(1))
	t.Logf("attested price=%s, max debt=%s, borrowing=%s", price, maxDebtAt(price), amount)

	skel, w := oracleInputs(t, pw, 0, amount, 0b1011)
	if err := test.IsSolved(skel, w, ecc.BN254.ScalarField()); err != nil {
		t.Fatalf("solvent borrow against the attested price should solve: %v", err)
	}
}

// TestOracle_Insolvent — borrowing past what the attested price supports must fail the solvency check,
// even though the new root is the honest single-leaf update for that (too-large) debt.
func TestOracle_Insolvent(t *testing.T) {
	if testing.Short() {
		t.Skip("full Pyth guardian quorum in-circuit (~2.4M constraints)")
	}
	pw := loadMultiWitness(t)
	price := attestedPrice(pw.Prices[0])
	amount := new(big.Int).Add(maxDebtAt(price), big.NewInt(1_000_000)) // over the line

	skel, w := oracleInputs(t, pw, 0, amount, 0b1011)
	if err := test.IsSolved(skel, w, ecc.BN254.ScalarField()); err == nil {
		t.Fatal("borrowing beyond the attested price's max debt must fail")
	}
}

// TestOracle_TamperedPrice — flipping a byte in the price field of the message must fail: the message
// no longer hashes to the guardian-signed Merkle root, so no fake price can be smuggled in.
func TestOracle_TamperedPrice(t *testing.T) {
	if testing.Short() {
		t.Skip("full Pyth guardian quorum in-circuit (~2.4M constraints)")
	}
	pw := loadMultiWitness(t)
	price := attestedPrice(pw.Prices[0])
	amount := new(big.Int).Sub(maxDebtAt(price), big.NewInt(1))

	skel, w := oracleInputs(t, pw, 0, amount, 0b1011)
	// Tamper a price byte in the message (index 33 starts the price field) and rebuild the witness
	// message. The Merkle proof is untouched, so the tampered message no longer hashes to the root.
	tampered := make([]byte, len(pw.Prices[0].Message))
	copy(tampered, pw.Prices[0].Message)
	tampered[33] ^= 0x01
	w.Message = uints.NewU8Array(tampered)
	if err := test.IsSolved(skel, w, ecc.BN254.ScalarField()); err == nil {
		t.Fatal("a tampered price message must fail Merkle inclusion under the signed root")
	}
}

// TestOracle_Constraints reports the oracle-bound transition size (guardian quorum + Merkle + borrow).
func TestOracle_Constraints(t *testing.T) {
	if testing.Short() {
		t.Skip("compiles the full guardian quorum (~2.4M constraints)")
	}
	pw := loadMultiWitness(t)
	price := attestedPrice(pw.Prices[0])
	amount := new(big.Int).Sub(maxDebtAt(price), big.NewInt(1))
	skel, _ := oracleInputs(t, pw, 0, amount, 0b1011)
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, skel)
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	t.Logf("OracleBoundTransition: %d constraints (guardian quorum + Merkle inclusion + borrow)", ccs.GetNbConstraints())
}
