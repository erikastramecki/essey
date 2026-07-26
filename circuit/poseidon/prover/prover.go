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
	"encoding/binary"
	"fmt"
	"io"
	"math/big"
	"os"
	"path/filepath"

	"essey/pyth"
	poseidon "dregg/poseidon-gadget"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/backend/solidity"
	groth16bn254 "github.com/consensys/gnark/backend/groth16/bn254"
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
	Calldata     []byte     // proof.MarshalSolidity() — the bytes the on-chain verifyProof takes
	Commitments  []*big.Int // loan commitments = the public inputs, one per loan
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

func shapeOf(pw *pyth.Witness, nLoans int) shape {
	return shape{
		nGuard:  len(pw.Guardians),
		nLoans:  nLoans,
		bodyLen: len(pw.Body),
		msgLen:  len(pw.Prices[0].Message),
		hops:    len(pw.Prices[0].Proof),
	}
}

// New compiles the portable-proof circuit for the given shape and runs the (one-time) setup.
func New(pw *pyth.Witness, nLoans int) (*Prover, error) {
	s := shapeOf(pw, nLoans)
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, skeleton(s))
	if err != nil {
		return nil, fmt.Errorf("compile: %w", err)
	}
	pk, vk, err := groth16.Setup(ccs)
	if err != nil {
		return nil, fmt.Errorf("setup: %w", err)
	}
	return &Prover{ccs: ccs, pk: pk, vk: vk, shape: s}, nil
}

// NewCached loads ccs/pk/vk for this shape from dir, or runs setup once and persists them. The heavy
// setup happens on the first call; every later demo run is just prove + verify.
func NewCached(pw *pyth.Witness, nLoans int, dir string) (*Prover, bool, error) {
	s := shapeOf(pw, nLoans)
	tag := fmt.Sprintf("%dg-%dl-%db-%dm-%dh", s.nGuard, s.nLoans, s.bodyLen, s.msgLen, s.hops)
	pcs := filepath.Join(dir, tag+".ccs")
	ppk := filepath.Join(dir, tag+".pk")
	pvk := filepath.Join(dir, tag+".vk")

	if fileExists(pcs) && fileExists(ppk) && fileExists(pvk) {
		ccs := groth16.NewCS(ecc.BN254)
		pk := groth16.NewProvingKey(ecc.BN254)
		vk := groth16.NewVerifyingKey(ecc.BN254)
		if err := readFrom(pcs, ccs); err != nil {
			return nil, false, err
		}
		if err := readFrom(ppk, pk); err != nil {
			return nil, false, err
		}
		if err := readFrom(pvk, vk); err != nil {
			return nil, false, err
		}
		return &Prover{ccs: ccs, pk: pk, vk: vk, shape: s}, true, nil
	}

	p, err := New(pw, nLoans)
	if err != nil {
		return nil, false, err
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, false, err
	}
	if err := writeTo(pcs, p.ccs); err != nil {
		return nil, false, err
	}
	if err := writeTo(ppk, p.pk); err != nil {
		return nil, false, err
	}
	if err := writeTo(pvk, p.vk); err != nil {
		return nil, false, err
	}
	return p, false, nil
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }
func writeTo(path string, x io.WriterTo) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = x.WriteTo(f)
	return err
}
func readFrom(path string, x io.ReaderFrom) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	// Keys we generated ourselves: skip subgroup checks on load (seconds vs minutes for a 684MB pk).
	if u, ok := x.(interface {
		UnsafeReadFrom(io.Reader) (int64, error)
	}); ok {
		_, err = u.UnsafeReadFrom(f)
		return err
	}
	_, err = x.ReadFrom(f)
	return err
}

// ExportSolidity writes the Groth16 verifier contract for this circuit's vk.
func (p *Prover) ExportSolidity(w io.Writer) error {
	return p.vk.(*groth16bn254.VerifyingKey).ExportSolidity(w)
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
	// sha256 hash-to-field for the lookup-argument commitment — MUST match the exported Solidity
	// verifier (which hardcodes sha256), or the on-chain check rejects a valid proof.
	proof, err := groth16.Prove(p.ccs, p.pk, full, solidity.WithProverTargetSolidityVerifier(backend.GROTH16))
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
	calldata := solidityProofArgs(proof.(*groth16bn254.Proof).MarshalSolidity())
	return &Bundle{Proof: pb.Bytes(), PublicInputs: pubb.Bytes(), VK: vkb.Bytes(), Calldata: calldata, Commitments: commits}, nil
}

// solidityProofArgs turns MarshalSolidity() into clean 32-byte-aligned verifyProof args. For a proof
// with Pedersen commitments, WriteRawTo encodes Commitments as a SLICE — a 4-byte length prefix
// sits between Krs and the commitment points, which misaligns naive word-splitting. Strip it so the
// result is exactly proof[8] ++ commitments[2*nc] ++ commitmentPok[2].
func solidityProofArgs(raw []byte) []byte {
	const proofBytes = 8 * 32
	if len(raw) == proofBytes {
		return raw // no commitments
	}
	proof8 := raw[:proofBytes]
	nc := int(binary.BigEndian.Uint32(raw[proofBytes : proofBytes+4]))
	body := raw[proofBytes+4:]
	comms := body[:nc*2*32]
	pok := body[nc*2*32 : nc*2*32+2*32]
	out := make([]byte, 0, proofBytes+len(comms)+len(pok))
	out = append(out, proof8...)
	out = append(out, comms...)
	out = append(out, pok...)
	return out
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
	return groth16.Verify(proof, vk, pub, solidity.WithVerifierTargetSolidityVerifier(backend.GROTH16))
}
