package poseidon

import (
	"encoding/hex"
	"math/big"
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/std/math/uints"
	"github.com/consensys/gnark/test"
)

// Soundness is the property an audit ultimately checks: the circuit accepts ONLY valid witnesses.
// Each case below takes the real, valid portable-proof witness and breaks exactly one thing, then
// asserts the circuit REJECTS it. A completeness proof (it accepts the real one) is the assembled
// test; these are the negative half.
//
// The attacks map 1:1 to the trust chain: forge the guardian-signed body, forge a price's Merkle
// inclusion, lie about the loan terms, over-borrow, or claim a price the message doesn't contain.

func mustReject(t *testing.T, name string, mutate func(*portableProofCircuit)) {
	t.Helper()
	skel, w, _ := portableInputs(t)
	mutate(w)
	if err := test.IsSolved(skel, w, ecc.BN254.ScalarField()); err == nil {
		t.Fatalf("%s: circuit accepted an INVALID witness — soundness hole", name)
	} else {
		t.Logf("%s: rejected ✓", name)
	}
}

// 1. Forge the guardian-signed body: flip one byte → double-keccak digest changes → the 13 ECDSA
//    signatures no longer verify against the pinned pubkeys.
func TestSoundness_TamperedBodyRejected(t *testing.T) {
	body, _ := hex.DecodeString(realBodyHex)
	mustReject(t, "tampered body", func(w *portableProofCircuit) {
		w.Body[10] = uints.NewU8(body[10] ^ 0x01)
	})
}

// 2. Forge a price's inclusion: flip one byte of a Merkle sibling → the climb no longer reaches the
//    guardian-signed root.
func TestSoundness_TamperedMerkleRejected(t *testing.T) {
	proof, _ := hex.DecodeString(realProof)
	mustReject(t, "tampered merkle proof", func(w *portableProofCircuit) {
		w.Proof[0][0] = uints.NewU8(proof[0] ^ 0x01)
	})
}

// 3. Lie about the loan terms: change a committed term without changing the public commitment →
//    the Poseidon commitment binding fails.
func TestSoundness_TermsNotMatchingCommitRejected(t *testing.T) {
	mustReject(t, "collateral != commitment", func(w *portableProofCircuit) {
		w.Collateral = 999 // commit was computed for collateral = 1
	})
}

// 4. Over-borrow: raise debt above the LTV limit → the solvency inequality fails. (Commit must still
//    match, so recompute it for the inflated debt; only the inequality should catch this.)
func TestSoundness_OverBorrowRejected(t *testing.T) {
	skel, w, price := portableInputs(t)
	// max debt at collateral 1, 35% LTV; go 10x over it.
	over := new(big.Int).Mul(price, big.NewInt(3500))
	over.Div(over, big.NewInt(10000))
	over.Mul(over, big.NewInt(10))
	// recompute the commitment so ONLY the solvency check can reject this.
	commit := commitFor(t, w, over)
	w.Debt = over
	w.Commit = commit
	if err := test.IsSolved(skel, w, ecc.BN254.ScalarField()); err == nil {
		t.Fatal("over-borrow accepted — solvency guard is unsound")
	}
	t.Log("over-borrow (commitment consistent): rejected by the solvency inequality ✓")
}

// 5. Claim a price the message does not contain: change the message price bytes → the extracted
//    price no longer matches the committed price, so the commitment binding fails. This is the crux
//    of the whole scheme — you cannot substitute a favourable price for the attested one.
func TestSoundness_PriceSubstitutionRejected(t *testing.T) {
	msg, _ := hex.DecodeString(realMsgHex)
	mustReject(t, "price substitution", func(w *portableProofCircuit) {
		w.Message[33] = uints.NewU8(msg[33] ^ 0x40) // perturb the high price byte
	})
}

// commitFor recomputes the loan commitment from a witness's current terms with a given debt.
func commitFor(t *testing.T, w *portableProofCircuit, debt *big.Int) *big.Int {
	t.Helper()
	msg, _ := hex.DecodeString(realMsgHex)
	price := new(big.Int).SetBytes(msg[33:41])
	terms := []*big.Int{
		asBig(w.PoolHi), asBig(w.PoolLo), asBig(w.BorrowerHi), asBig(w.BorrowerLo),
		debt, asBig(w.Collateral), asBig(w.LtvBps), asBig(w.Nonce),
		asBig(w.TypeHi), asBig(w.TypeLo), price,
	}
	return commit(t, terms)
}

func asBig(v interface{}) *big.Int {
	switch x := v.(type) {
	case *big.Int:
		return x
	case int:
		return big.NewInt(int64(x))
	case int64:
		return big.NewInt(x)
	}
	return big.NewInt(0)
}
