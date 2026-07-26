// Command demo runs the whole Essey portable-proof pipeline on one real Pyth update and prints a
// narrated walkthrough: verify the guardian quorum, prove in zero knowledge, and emit an on-chain
// verifier + the exact calldata so a settlement chain can check it. The companion demo.sh fetches a
// LIVE price, runs this, and does the on-chain verification against a local EVM.
//
//	go run ./cmd/demo <update.hex> <cacheDir> <outDir>
package main

import (
	"encoding/hex"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"

	"essey/pyth"
	"dregg/poseidon-gadget/prover"

	"golang.org/x/crypto/sha3"
)

func die(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "demo: "+err.Error())
		os.Exit(1)
	}
}

func step(n int, s string) { fmt.Printf("\n\033[1m[%d] %s\033[0m\n", n, s) }

func main() {
	if len(os.Args) < 4 {
		die(fmt.Errorf("usage: demo <update.hex> <cacheDir> <outDir>"))
	}
	updatePath, cacheDir, outDir := os.Args[1], os.Args[2], os.Args[3]
	die(os.MkdirAll(outDir, 0755))

	raw, err := os.ReadFile(updatePath)
	die(err)
	upd, err := hex.DecodeString(strings.TrimSpace(string(raw)))
	die(err)

	step(1, "Verify the price came from Pyth's guardians (native)")
	pw, err := pyth.BuildWitness(upd, pyth.GuardianSet7)
	die(err)
	price := pw.Prices[0]
	fmt.Printf("    %d guardian signatures recovered to the real set-7 addresses\n", len(pw.Guardians))
	fmt.Printf("    price included under the guardian-signed Merkle root: %d (expo from the feed)\n", price.Price)
	fmt.Printf("    -> the price is genuinely Pyth-attested. No trust in us required.\n")

	step(2, "Load / build the proving keys")
	t0 := time.Now()
	p, cached, err := prover.NewCached(pw, 1, cacheDir)
	die(err)
	if cached {
		fmt.Printf("    keys loaded from cache in %s (setup already done once)\n", time.Since(t0).Round(time.Millisecond))
	} else {
		fmt.Printf("    one-time trusted setup done in %s and cached — future runs skip this\n", time.Since(t0).Round(time.Second))
	}

	step(3, "Prove, in zero knowledge, that a real loan is solvent against that price")
	// a solvent loan sized to the attested price: 1 unit collateral, 35% LTV, debt just under max.
	maxDebt := new(big.Int).Div(new(big.Int).Mul(big.NewInt(price.Price), big.NewInt(3500)), big.NewInt(10000))
	loans := []prover.LoanTerms{{
		FeedIndex: 0, CollateralType: "BTC", Collateral: 1, LtvBps: 3500, Nonce: 1,
		Debt: maxDebt.Uint64() - 1, Pool: [32]byte{1}, Borrower: [32]byte{2},
	}}
	t1 := time.Now()
	b, err := p.Prove(pw, loans)
	die(err)
	fmt.Printf("    proof generated in %s — %d bytes\n", time.Since(t1).Round(time.Millisecond), len(b.Proof))
	fmt.Printf("    it reveals only the loan commitment: %s\n", b.Commitments[0].String()[:24]+"…")

	step(4, "Verify the proof off-chain (sanity)")
	die(prover.Verify(b))
	fmt.Printf("    valid ✓\n")

	step(5, "Emit the on-chain verifier + calldata (for any chain, no oracle)")
	vf, err := os.Create(filepath.Join(outDir, "Verifier.sol"))
	die(err)
	die(p.ExportSolidity(vf))
	vf.Close()

	sig, calldata := onchainCalldata(b)
	die(os.WriteFile(filepath.Join(outDir, "calldata.txt"), []byte("0x"+hex.EncodeToString(calldata)), 0644))
	die(os.WriteFile(filepath.Join(outDir, "sig.txt"), []byte(sig), 0644))
	fmt.Printf("    Verifier.sol + calldata written to %s\n", outDir)
	fmt.Printf("    verifier entrypoint: %s\n", sig)
	fmt.Printf("    -> deploy this once on any EVM chain; every proof verifies for ~340k gas.\n")
}

// onchainCalldata builds the raw verifyProof calldata: selector ++ MarshalSolidity(proof [+ lookup
// commitments]) ++ public inputs. All args are static arrays, so ABI encoding is plain concatenation.
func onchainCalldata(b *prover.Bundle) (sig string, calldata []byte) {
	nWords := len(b.Calldata) / 32
	nInput := len(b.Commitments)
	var sb strings.Builder
	sb.WriteString("verifyProof(uint256[8],")
	if nWords > 8 {
		nc := (nWords - 8 - 2) / 2 // proof(8) + commitments(2*nc) + pok(2)
		fmt.Fprintf(&sb, "uint256[%d],uint256[2],", 2*nc)
	}
	fmt.Fprintf(&sb, "uint256[%d])", nInput)
	sig = sb.String()

	h := sha3.NewLegacyKeccak256()
	h.Write([]byte(sig))
	selector := h.Sum(nil)[:4]

	calldata = append(calldata, selector...)
	calldata = append(calldata, b.Calldata...) // proof + commitments + pok
	for _, c := range b.Commitments {
		var w [32]byte
		c.FillBytes(w[:])
		calldata = append(calldata, w[:]...)
	}
	return sig, calldata
}
