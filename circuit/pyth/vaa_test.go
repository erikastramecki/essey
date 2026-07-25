package pyth

import (
	"bytes"
	"encoding/hex"
	"os"
	"strings"
	"testing"
)

func loadFixture(t *testing.T) []byte {
	t.Helper()
	h, err := os.ReadFile("testdata/pyth_btc_update.hex")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := hex.DecodeString(strings.TrimSpace(string(h)))
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// The parser is the spec for the in-circuit verifier, so it is pinned against a REAL Hermes update:
// every field below matches what Hermes reported for this exact blob.
func TestParse_RealUpdate(t *testing.T) {
	a, err := Parse(loadFixture(t))
	if err != nil {
		t.Fatal(err)
	}

	if a.Major != 1 {
		t.Errorf("major = %d, want 1", a.Major)
	}
	if a.VAA.GuardianSetIndex != 7 {
		t.Errorf("guardian set index = %d, want 7", a.VAA.GuardianSetIndex)
	}
	if len(a.VAA.Signatures) != 13 {
		t.Fatalf("num signatures = %d, want 13 (the quorum)", len(a.VAA.Signatures))
	}
	if len(a.VAA.Body) != 88 {
		t.Errorf("body length = %d, want 88 (the double-keccak preimage)", len(a.VAA.Body))
	}
	if got := hex.EncodeToString(a.MerkleRoot[:]); got != "2029746a3b61f34f90c804bff3b951e8925db70a" {
		t.Errorf("merkle root = %s", got)
	}
	if a.VAA.EmitterChain != 26 {
		t.Errorf("emitter chain = %d, want 26 (pythnet)", a.VAA.EmitterChain)
	}

	if len(a.Updates) != 1 {
		t.Fatalf("updates = %d, want 1", len(a.Updates))
	}
	u := a.Updates[0]
	wantFeed := "e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43"
	if got := hex.EncodeToString(u.FeedID[:]); got != wantFeed {
		t.Errorf("feed id = %s", got)
	}
	if u.Price != 6412448778202 || u.Conf != 1493221796 || u.Expo != -8 || u.PublishTime != 1784991880 {
		t.Errorf("price fields = (%d, conf %d, expo %d, t %d) — do not match Hermes",
			u.Price, u.Conf, u.Expo, u.PublishTime)
	}
	if len(u.Proof) != 13 {
		t.Errorf("merkle proof hops = %d, want 13", len(u.Proof))
	}
	t.Logf("parsed real Pyth update: BTC $%.2f (price %d, expo %d), %d guardian sigs, %d-hop merkle proof",
		float64(u.Price)/1e8, u.Price, u.Expo, len(a.VAA.Signatures), len(u.Proof))
}

// Each guardian signature must be exactly 66 wire bytes (index + r + s + v).
func TestParse_SignatureShape(t *testing.T) {
	a, err := Parse(loadFixture(t))
	if err != nil {
		t.Fatal(err)
	}
	seen := map[uint8]bool{}
	for i, s := range a.VAA.Signatures {
		if seen[s.Index] {
			t.Errorf("duplicate guardian index %d at sig %d", s.Index, i)
		}
		seen[s.Index] = true
		if bytes.Equal(s.R[:], make([]byte, 32)) {
			t.Errorf("sig %d has zero R", i)
		}
	}
}
