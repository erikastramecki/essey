package poseidon

import (
	"math/big"
	"testing"
	"time"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/test"
	iden3 "github.com/iden3/go-iden3-crypto/poseidon"
)

// hash is the native (off-circuit) twin of PoseidonBn254 — same iden3 params, so trees built
// here reproduce exactly what the circuit recomputes.
func phash(t *testing.T, ins ...*big.Int) *big.Int {
	h, err := iden3.Hash(ins)
	if err != nil {
		t.Fatalf("poseidon: %v", err)
	}
	return h
}

// emptySiblings returns the authentication path for a leaf in an otherwise-empty sparse tree:
// sib[0] is the empty leaf (0); sib[i] is the empty-subtree root at level i.
func emptySiblings(t *testing.T, depth int) []*big.Int {
	sib := make([]*big.Int, depth)
	sib[0] = big.NewInt(0)
	for i := 1; i < depth; i++ {
		sib[i] = phash(t, sib[i-1], sib[i-1])
	}
	return sib
}

// climb reproduces merkleRoot off-circuit: fold leaf up with siblings, ordering by index bit.
func climb(t *testing.T, leaf *big.Int, idx uint64, sib []*big.Int) *big.Int {
	cur := leaf
	for i := 0; i < len(sib); i++ {
		if (idx>>uint(i))&1 == 0 {
			cur = phash(t, cur, sib[i])
		} else {
			cur = phash(t, sib[i], cur)
		}
	}
	return cur
}

// samplePosition mirrors the fork example: 10 AAPL @ $333, 50% LTV. With price 333 and coll 10,
// max debt = 10*333*5000/10000 = 1665. debt 0 -> borrow up to 1665 stays solvent.
func samplePosition(debt int64) Position {
	return Position{
		PoolHi: big.NewInt(0), PoolLo: big.NewInt(1),
		BorrowerHi: big.NewInt(0), BorrowerLo: big.NewInt(0xABCD),
		Debt: big.NewInt(debt), Collateral: big.NewInt(10),
		LtvBps: big.NewInt(5000), Nonce: big.NewInt(7),
		TypeHi: big.NewInt(0), TypeLo: big.NewInt(42),
	}
}

func positionLeaf(t *testing.T, p Position) *big.Int {
	return phash(t,
		p.PoolHi.(*big.Int), p.PoolLo.(*big.Int), p.BorrowerHi.(*big.Int), p.BorrowerLo.(*big.Int),
		p.Debt.(*big.Int), p.Collateral.(*big.Int), p.LtvBps.(*big.Int), p.Nonce.(*big.Int),
		p.TypeHi.(*big.Int), p.TypeLo.(*big.Int))
}

const testPrice = 333

// buildTransition assembles a valid (or, if the caller picks an over-large amount, an invalid)
// borrow transition witness for one position in an otherwise-empty tree at index idx.
func buildTransition(t *testing.T, oldDebt, amount int64, idx uint64) *TransitionCircuit {
	depth := StateTreeDepth
	sib := emptySiblings(t, depth)

	oldPos := samplePosition(oldDebt)
	newPos := samplePosition(oldDebt + amount)
	oldRoot := climb(t, positionLeaf(t, oldPos), idx, sib)
	newRoot := climb(t, positionLeaf(t, newPos), idx, sib)

	c := &TransitionCircuit{
		Old:     oldPos,
		Amount:  big.NewInt(amount),
		OldRoot: oldRoot,
		NewRoot: newRoot,
		Price:   big.NewInt(testPrice),
	}
	for i := 0; i < depth; i++ {
		c.PathBits[i] = big.NewInt(int64((idx >> uint(i)) & 1))
		c.Siblings[i] = sib[i]
	}
	return c
}

// TestTransition_Valid — a solvent borrow (debt 0 -> 1600, max 1665) transitions old_root -> new_root.
func TestTransition_Valid(t *testing.T) {
	w := buildTransition(t, 0, 1600, 0b1011)
	if err := test.IsSolved(&TransitionCircuit{}, w, ecc.BN254.ScalarField()); err != nil {
		t.Fatalf("valid transition should solve: %v", err)
	}
}

// TestTransition_Insolvent — borrowing past the solvency bound (1700 > 1665) must be unprovable,
// even though the prover supplies a correctly-formed new_root for that debt.
func TestTransition_Insolvent(t *testing.T) {
	w := buildTransition(t, 0, 1700, 0b1011)
	if err := test.IsSolved(&TransitionCircuit{}, w, ecc.BN254.ScalarField()); err == nil {
		t.Fatal("insolvent borrow must fail the solvency constraint")
	}
}

// TestTransition_WrongNewRoot — a new_root that is not the honest single-leaf update must fail,
// so the prover cannot smuggle changes to other positions.
func TestTransition_WrongNewRoot(t *testing.T) {
	w := buildTransition(t, 0, 1600, 0b1011)
	w.NewRoot = new(big.Int).Add(w.NewRoot.(*big.Int), big.NewInt(1))
	if err := test.IsSolved(&TransitionCircuit{}, w, ecc.BN254.ScalarField()); err == nil {
		t.Fatal("tampered new_root must fail the Merkle update")
	}
}

// TestTransition_Constraints reports the circuit size — the cost of one proven state transition.
func TestTransition_Constraints(t *testing.T) {
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &TransitionCircuit{})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	t.Logf("TransitionCircuit (depth %d): %d constraints", StateTreeDepth, ccs.GetNbConstraints())
}

// TestTransition_ProveVerify runs the full Groth16 pipeline once — proving a real transition is
// cheap (Poseidon tree, no keccak/ECDSA), and confirms the verifier accepts it.
func TestTransition_ProveVerify(t *testing.T) {
	if testing.Short() {
		t.Skip("full groth16 setup+prove")
	}
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &TransitionCircuit{})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	pk, vk, err := groth16.Setup(ccs)
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	w := buildTransition(t, 0, 1600, 0b1011)
	fullWit, err := frontend.NewWitness(w, ecc.BN254.ScalarField())
	if err != nil {
		t.Fatalf("witness: %v", err)
	}
	pubWit, err := fullWit.Public()
	if err != nil {
		t.Fatalf("public witness: %v", err)
	}
	t0 := time.Now()
	proof, err := groth16.Prove(ccs, pk, fullWit)
	if err != nil {
		t.Fatalf("prove: %v", err)
	}
	proveDur := time.Since(t0)
	if err := groth16.Verify(proof, vk, pubWit); err != nil {
		t.Fatalf("verify: %v", err)
	}
	t.Logf("transition PROVE=%s verify=OK (3 public inputs: old_root, new_root, price)", proveDur.Round(time.Millisecond))
}
