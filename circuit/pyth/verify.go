package pyth

import (
	"bytes"
	"fmt"

	"github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
	"golang.org/x/crypto/sha3"
)

// keccak256 hashes the concatenation of parts (Ethereum/Wormhole keccak, not SHA3-256).
func keccak256(parts ...[]byte) []byte {
	h := sha3.NewLegacyKeccak256()
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

// ecrecover reproduces Wormhole's guardian check: recover the signer's public key from the
// signature over digest, then derive its 20-byte address = keccak256(pubkey)[12:].
func ecrecover(digest []byte, s GuardianSig) (Address, error) {
	var compact [65]byte
	if s.V >= 27 {
		compact[0] = s.V // already offset
	} else {
		compact[0] = 27 + s.V // decred RecoverCompact wants 27 + recoveryID for an uncompressed key
	}
	copy(compact[1:33], s.R[:])
	copy(compact[33:65], s.S[:])
	pub, _, err := ecdsa.RecoverCompact(compact[:], digest)
	if err != nil {
		return Address{}, err
	}
	un := pub.SerializeUncompressed() // 0x04 || X(32) || Y(32)
	addr := keccak256(un[1:])         // keccak over X||Y
	var a Address
	copy(a[:], addr[12:])
	return a, nil
}

// VerifyGuardianQuorum checks that a quorum of guardians in `set` signed the VAA body. Guardians
// sign keccak256(keccak256(body)); indices must be strictly increasing (Wormhole rule); each
// recovered address must equal the guardian at its index.
func VerifyGuardianQuorum(a *AccumulatorUpdate, set []Address) error {
	digest := keccak256(keccak256(a.VAA.Body))
	last := -1
	valid := 0
	for _, s := range a.VAA.Signatures {
		if int(s.Index) >= len(set) {
			return fmt.Errorf("guardian index %d out of range (set has %d)", s.Index, len(set))
		}
		if int(s.Index) <= last {
			return fmt.Errorf("guardian indices not strictly increasing at %d", s.Index)
		}
		last = int(s.Index)
		got, err := ecrecover(digest, s)
		if err != nil {
			return fmt.Errorf("sig for guardian %d: recover: %w", s.Index, err)
		}
		if got != set[s.Index] {
			return fmt.Errorf("sig for guardian %d: recovered %x != %x", s.Index, got, set[s.Index])
		}
		valid++
	}
	if valid < Quorum {
		return fmt.Errorf("only %d valid signatures, need quorum %d", valid, Quorum)
	}
	return nil
}

// VerifyMerkle checks the price is included under root. Pyth leaves are keccak256(0x00 || msg)[:20]
// and internal nodes keccak256(0x01 || min || max)[:20] (the pair is sorted, so proofs carry no
// left/right flags).
func VerifyMerkle(u PriceUpdate, root [20]byte) error {
	cur := keccak256(append([]byte{0x00}, u.Message...))[:20]
	for _, sib := range u.Proof {
		lo, hi := cur, sib[:]
		if bytes.Compare(lo, hi) > 0 {
			lo, hi = hi, lo
		}
		node := append([]byte{0x01}, lo...)
		node = append(node, hi...)
		cur = keccak256(node)[:20]
	}
	if !bytes.Equal(cur, root[:]) {
		return fmt.Errorf("merkle root mismatch: got %x want %x", cur, root[:])
	}
	return nil
}

// Verify runs the full native trust chain: guardian quorum + every price's Merkle inclusion. This
// is the ground truth the in-circuit verifier must reproduce.
func Verify(a *AccumulatorUpdate, set []Address) error {
	if err := VerifyGuardianQuorum(a, set); err != nil {
		return err
	}
	for i := range a.Updates {
		if err := VerifyMerkle(a.Updates[i], a.MerkleRoot); err != nil {
			return fmt.Errorf("update %d merkle: %w", i, err)
		}
	}
	return nil
}
