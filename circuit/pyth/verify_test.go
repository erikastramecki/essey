package pyth

import "testing"

// The whole point of phase 2: the REAL guardian quorum and REAL Merkle proof verify natively.
// If this passes, the trust chain a chain-with-no-oracle would rely on is proven correct off-circuit.
func TestVerify_RealUpdate_EndToEnd(t *testing.T) {
	a, err := Parse(loadFixture(t))
	if err != nil {
		t.Fatal(err)
	}
	if err := Verify(a, GuardianSet7); err != nil {
		t.Fatalf("real Pyth update failed native verification: %v", err)
	}
	t.Logf("VERIFIED: %d guardian signatures recovered to set-7 addresses; %d-hop Merkle proof "+
		"climbs to root %x — price is trustlessly attested", len(a.VAA.Signatures), len(a.Updates[0].Proof), a.MerkleRoot)
}

// Guardian check must FAIL if the signed body is tampered (flip one byte -> different digest ->
// recovered addresses no longer match the set).
func TestVerify_TamperedBodyRejected(t *testing.T) {
	a, err := Parse(loadFixture(t))
	if err != nil {
		t.Fatal(err)
	}
	a.VAA.Body[10] ^= 0x01
	if err := VerifyGuardianQuorum(a, GuardianSet7); err == nil {
		t.Fatal("tampered body must fail the guardian quorum")
	}
}

// Merkle check must FAIL if the price message is tampered (leaf no longer under the root).
func TestVerify_TamperedPriceRejected(t *testing.T) {
	a, err := Parse(loadFixture(t))
	if err != nil {
		t.Fatal(err)
	}
	a.Updates[0].Message[40] ^= 0x01 // somewhere in the price bytes
	if err := VerifyMerkle(a.Updates[0], a.MerkleRoot); err == nil {
		t.Fatal("tampered price must fail Merkle inclusion")
	}
}
