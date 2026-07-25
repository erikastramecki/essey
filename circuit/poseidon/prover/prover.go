// Package prover is the proof-generating service: given a real Pyth update and a set of loans, it
// produces a portable proof bundle (proof + public inputs + verifying key) that any chain can check
// with no oracle of its own. The operator calls this; it never holds a private key.
//
// Backend: production uses PLONK (universal setup — no per-circuit ceremony; see
// circuit/poseidon/plonk_test.go). Groth16 is available for a fast local end-to-end because
// generating a fresh multi-million-power PLONK SRS in a loop is impractical; the code path is
// identical either way.
package prover

import (
	"bytes"
	"fmt"
	"math/big"

	"essey/pyth"
	poseidon "dregg/poseidon-gadget"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/backend/witness"
	"github.com/consensys/gnark/constraint"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/math/emulated"
	"github.com/consensys/gnark/std/math/uints"
	"github.com/consensys/gnark/std/signature/ecdsa"
	iden3 "github.com/iden3/go-iden3-crypto/poseidon"
	"golang.org/x/crypto/blake2b"
)

// LoanTerms are one loan's borrower-supplied inputs. FeedIndex selects which price in the update the
// loan is sized against.
type LoanTerms struct {
	FeedIndex      int
	Pool           [32]byte
	Borrower       [32]byte
	CollateralType string
	Debt           uint64
	Collateral     uint64
	LtvBps         uint64
	Nonce          uint64
}

// Bundle is what the operator returns and a settlement chain verifies: a proof, its public inputs
// (the loan commitments), and the verifying key.
type Bundle struct {
	Proof        []byte
	PublicInputs []byte
	VK           []byte
	Commitments  []*big.Int // one per loan, for reference/inspection
}

// Prover holds a compiled circuit + keys for one circuit shape (guardian count, loan count, byte
// sizes). Build it once; Prove many times.
type Prover struct {
	ccs   constraint.ConstraintSystem
	pk    groth16.ProvingKey
	vk    groth16.VerifyingKey
	shape shape
}

type shape struct{ nGuard, nLoans, bodyLen, msgLen, hops int }

// New compiles the portable-proof circuit for the given shape and runs the (one-time) setup.
func New(pw *pyth.Witness, nLoans int) (*Prover, error) {
	s := shape{
		nGuard:  len(pw.Guardians),
		nLoans:  nLoans,
		bodyLen: len(pw.Body),
		msgLen:  len(pw.Prices[0].Message),
		hops:    len(pw.Prices[0].Proof),
	}
	skel := skeleton(s)
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, skel)
	if err != nil {
		return nil, fmt.Errorf("compile: %w", err)
	}
	pk, vk, err := groth16.Setup(ccs)
	if err != nil {
		return nil, fmt.Errorf("setup: %w", err)
	}
	return &Prover{ccs: ccs, pk: pk, vk: vk, shape: s}, nil
}

func skeleton(s shape) *poseidon.BatchCircuit {
	c := &poseidon.BatchCircuit{
		Body:  make([]uints.U8, s.bodyLen),
		Pubs:  make([]ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr], s.nGuard),
		Sigs:  make([]ecdsa.Signature[emulated.Secp256k1Fr], s.nGuard),
		Loans: make([]poseidon.LoanSlot, s.nLoans),
	}
	for i := range c.Loans {
		c.Loans[i].Message = make([]uints.U8, s.msgLen)
		c.Loans[i].Proof = make([][]uints.U8, s.hops)
		for j := range c.Loans[i].Proof {
			c.Loans[i].Proof[j] = make([]uints.U8, 20)
		}
	}
	return c
}

// split32 cuts a 32-byte value into (high 16, low 16) as field elements — matches Move's split32.
func split32(b []byte) (hi, lo *big.Int) {
	var p [32]byte
	copy(p[32-len(b):], b)
	return new(big.Int).SetBytes(p[:16]), new(big.Int).SetBytes(p[16:])
}

// commit computes the loan commitment the circuit will check: poseidon over the 11 fields, with the
// collateral type blake2b-hashed and split (matching dregg_lending::loan_commit_of).
func commit(l LoanTerms, price int64) (poolHi, poolLo, bHi, bLo, tHi, tLo, c *big.Int, err error) {
	poolHi, poolLo = split32(l.Pool[:])
	bHi, bLo = split32(l.Borrower[:])
	th := blake2b.Sum256([]byte(l.CollateralType))
	tHi, tLo = split32(th[:])
	terms := []*big.Int{
		poolHi, poolLo, bHi, bLo,
		new(big.Int).SetUint64(l.Debt), new(big.Int).SetUint64(l.Collateral),
		new(big.Int).SetUint64(l.LtvBps), new(big.Int).SetUint64(l.Nonce),
		tHi, tLo, big.NewInt(price),
	}
	c, err = iden3.Hash(terms)
	return
}

// Prove builds the witness from a verified Pyth update + loan terms and generates the proof bundle.
func (p *Prover) Prove(pw *pyth.Witness, loans []LoanTerms) (*Bundle, error) {
	if len(loans) != p.shape.nLoans {
		return nil, fmt.Errorf("prover built for %d loans, got %d", p.shape.nLoans, len(loans))
	}
	w := skeleton(p.shape)
	w.Body = uints.NewU8Array(pw.Body)
	for i, g := range pw.Guardians {
		w.Pubs[i].X = emulated.ValueOf[emulated.Secp256k1Fp](new(big.Int).SetBytes(g.PubX[:]))
		w.Pubs[i].Y = emulated.ValueOf[emulated.Secp256k1Fp](new(big.Int).SetBytes(g.PubY[:]))
		w.Sigs[i].R = emulated.ValueOf[emulated.Secp256k1Fr](new(big.Int).SetBytes(g.SigR[:]))
		w.Sigs[i].S = emulated.ValueOf[emulated.Secp256k1Fr](new(big.Int).SetBytes(g.SigS[:]))
	}
	commits := make([]*big.Int, len(loans))
	for li, l := range loans {
		if l.FeedIndex >= len(pw.Prices) {
			return nil, fmt.Errorf("loan %d: feed index %d out of range", li, l.FeedIndex)
		}
		price := pw.Prices[l.FeedIndex]
		poolHi, poolLo, bHi, bLo, tHi, tLo, c, err := commit(l, price.Price)
		if err != nil {
			return nil, err
		}
		commits[li] = c
		s := &w.Loans[li]
		s.Message = uints.NewU8Array(price.Message)
		s.Proof = make([][]uints.U8, len(price.Proof))
		for j, h := range price.Proof {
			s.Proof[j] = uints.NewU8Array(h[:])
		}
		s.PoolHi, s.PoolLo, s.BorrowerHi, s.BorrowerLo = poolHi, poolLo, bHi, bLo
		s.Debt, s.Collateral = new(big.Int).SetUint64(l.Debt), new(big.Int).SetUint64(l.Collateral)
		s.LtvBps, s.Nonce = new(big.Int).SetUint64(l.LtvBps), new(big.Int).SetUint64(l.Nonce)
		s.TypeHi, s.TypeLo, s.Commit = tHi, tLo, c
	}

	full, err := frontend.NewWitness(w, ecc.BN254.ScalarField())
	if err != nil {
		return nil, err
	}
	proof, err := groth16.Prove(p.ccs, p.pk, full)
	if err != nil {
		return nil, fmt.Errorf("prove: %w", err)
	}
	pub, err := full.Public()
	if err != nil {
		return nil, err
	}

	var pb, pubb, vkb bytes.Buffer
	if _, err := proof.WriteTo(&pb); err != nil {
		return nil, err
	}
	if _, err := pub.WriteTo(&pubb); err != nil {
		return nil, err
	}
	if _, err := p.vk.WriteTo(&vkb); err != nil {
		return nil, err
	}
	return &Bundle{Proof: pb.Bytes(), PublicInputs: pubb.Bytes(), VK: vkb.Bytes(), Commitments: commits}, nil
}

// Verify is what a settlement chain (or anyone) runs to check a bundle — deserialize and verify.
// On-chain this is a single Groth16/PLONK verifier call; here it is the off-chain equivalent.
func Verify(b *Bundle) error {
	proof := groth16.NewProof(ecc.BN254)
	if _, err := proof.ReadFrom(bytes.NewReader(b.Proof)); err != nil {
		return err
	}
	vk := groth16.NewVerifyingKey(ecc.BN254)
	if _, err := vk.ReadFrom(bytes.NewReader(b.VK)); err != nil {
		return err
	}
	pub, err := witness.New(ecc.BN254.ScalarField())
	if err != nil {
		return err
	}
	if _, err := pub.ReadFrom(bytes.NewReader(b.PublicInputs)); err != nil {
		return err
	}
	return groth16.Verify(proof, vk, pub)
}
