// Command prover is the operator-facing proof service: POST a Pyth update + loans, get back a
// portable-proof bundle the borrower's settlement chain can verify with no oracle. It never holds a
// key. The heavy one-time setup runs lazily per circuit shape (guardian count × loan count × Merkle
// depth) and is cached, so the first request of a shape is slow (minutes) and the rest are fast.
//
//	PORT=8790 go run ./cmd/prover
//	curl -s localhost:8790/prove -d '{"updateHex":"504e4155...","loans":[{"feedIndex":0,"collateralType":"BTC","collateral":1,"ltvBps":3500,"nonce":1,"debt":2000000000000}]}'
package main

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"

	"essey/pyth"
	"dregg/poseidon-gadget/prover"
)

type loanReq struct {
	FeedIndex      int    `json:"feedIndex"`
	Pool           string `json:"pool"`     // hex, optional
	Borrower       string `json:"borrower"` // hex, optional
	CollateralType string `json:"collateralType"`
	Debt           uint64 `json:"debt"`
	Collateral     uint64 `json:"collateral"`
	LtvBps         uint64 `json:"ltvBps"`
	Nonce          uint64 `json:"nonce"`
}

type proveReq struct {
	UpdateHex string    `json:"updateHex"`
	Loans     []loanReq `json:"loans"`
}

type proveResp struct {
	Proof        string     `json:"proof"`        // base64
	PublicInputs string     `json:"publicInputs"` // base64
	VK           string     `json:"vk"`           // base64
	Commitments  []string   `json:"commitments"`  // decimal
}

var (
	mu      sync.Mutex
	provers = map[string]*prover.Prover{} // keyed by circuit shape
)

func hexTo32(s string) (out [32]byte) {
	b, _ := hex.DecodeString(trim0x(s))
	copy(out[32-min(len(b), 32):], b)
	return
}
func trim0x(s string) string {
	if len(s) >= 2 && s[:2] == "0x" {
		return s[2:]
	}
	return s
}
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func handleProve(w http.ResponseWriter, r *http.Request) {
	var req proveReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	raw, err := hex.DecodeString(trim0x(req.UpdateHex))
	if err != nil {
		http.Error(w, "bad updateHex: "+err.Error(), 400)
		return
	}
	// Native verification is the gate: only build a proof for an update that really is guardian-signed.
	pw, err := pyth.BuildWitness(raw, pyth.GuardianSet7)
	if err != nil {
		http.Error(w, "update failed native verification: "+err.Error(), 422)
		return
	}

	loans := make([]prover.LoanTerms, len(req.Loans))
	for i, l := range req.Loans {
		loans[i] = prover.LoanTerms{
			FeedIndex: l.FeedIndex, CollateralType: l.CollateralType,
			Debt: l.Debt, Collateral: l.Collateral, LtvBps: l.LtvBps, Nonce: l.Nonce,
			Pool: hexTo32(l.Pool), Borrower: hexTo32(l.Borrower),
		}
	}

	shapeKey := fmt.Sprintf("%dg-%dl-%dh", len(pw.Guardians), len(loans), len(pw.Prices[0].Proof))
	mu.Lock()
	p := provers[shapeKey]
	if p == nil {
		log.Printf("compiling+setup for shape %s (one-time, minutes)…", shapeKey)
		p, err = prover.New(pw, len(loans))
		if err != nil {
			mu.Unlock()
			http.Error(w, "setup: "+err.Error(), 500)
			return
		}
		provers[shapeKey] = p
		log.Printf("shape %s ready", shapeKey)
	}
	mu.Unlock()

	b, err := p.Prove(pw, loans)
	if err != nil {
		http.Error(w, "prove: "+err.Error(), 500)
		return
	}
	resp := proveResp{
		Proof:        base64.StdEncoding.EncodeToString(b.Proof),
		PublicInputs: base64.StdEncoding.EncodeToString(b.PublicInputs),
		VK:           base64.StdEncoding.EncodeToString(b.VK),
	}
	for _, c := range b.Commitments {
		resp.Commitments = append(resp.Commitments, c.String())
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8790"
	}
	http.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"ok": true, "shapesReady": len(provers)})
	})
	http.HandleFunc("/prove", handleProve)
	log.Printf("essey portable-proof prover on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
