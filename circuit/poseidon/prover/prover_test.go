package prover

import (
	"encoding/hex"
	"os"
	"strings"
	"testing"

	"essey/pyth"
)

func loadWitness(t *testing.T) *pyth.Witness {
	t.Helper()
	h, err := os.ReadFile("../../pyth/testdata/pyth_multi_update.hex")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := hex.DecodeString(strings.TrimSpace(string(h)))
	if err != nil {
		t.Fatal(err)
	}
	w, err := pyth.BuildWitness(raw, pyth.GuardianSet7)
	if err != nil {
		t.Fatalf("update must verify natively: %v", err)
	}
	return w
}

// TestProver_EndToEnd is the proof-generating service, exercised on real data: a real Pyth update in,
// a real portable-proof bundle out, verified as a settlement chain would. Opt-in (full setup is
// minutes): PROVER=1 go test -run EndToEnd ./prover.
func TestProver_EndToEnd(t *testing.T) {
	if os.Getenv("PROVER") == "" {
		t.Skip("set PROVER=1 to run the full prover (compile + setup is minutes)")
	}
	pw := loadWitness(t)

	// two loans against two different real prices under one signed root.
	price0, price1 := pw.Prices[0].Price, pw.Prices[1].Price
	loans := []LoanTerms{
		{FeedIndex: 0, CollateralType: "BTC", Collateral: 1, LtvBps: 3500, Nonce: 1,
			Debt: uint64(price0)*3500/10000 - 1, Pool: [32]byte{1}, Borrower: [32]byte{2}},
		{FeedIndex: 1, CollateralType: "ETH", Collateral: 1, LtvBps: 3500, Nonce: 2,
			Debt: uint64(price1)*3500/10000 - 1, Pool: [32]byte{3}, Borrower: [32]byte{4}},
	}

	p, err := New(pw, len(loans)) // compile + one-time setup
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("prover ready: %d guardians, %d loans", p.shape.nGuard, p.shape.nLoans)

	bundle, err := p.Prove(pw, loans)
	if err != nil {
		t.Fatalf("prove: %v", err)
	}
	t.Logf("bundle: proof %d B, public inputs %d B, vk %d B; commitments %d",
		len(bundle.Proof), len(bundle.PublicInputs), len(bundle.VK), len(bundle.Commitments))

	// what a settlement chain does — verify the bundle with no oracle, no witness, no trust.
	if err := Verify(bundle); err != nil {
		t.Fatalf("settlement-side verify must pass: %v", err)
	}
	t.Log("portable-proof bundle verified as a no-oracle chain would ✓ — the service works end to end")
}
