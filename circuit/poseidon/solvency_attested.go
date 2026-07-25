package poseidon

import (
	tedwards "github.com/consensys/gnark-crypto/ecc/twistededwards"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/algebra/native/twistededwards"
	"github.com/consensys/gnark/std/hash/mimc"
	"github.com/consensys/gnark/std/signature/eddsa"
)

// SolvencyAttestedCircuit is SolvencyCircuit plus an in-circuit EdDSA check that Price was signed by
// a pinned price attester (Option B). The proof itself carries the price's provenance, so a verifier
// on a chain with no oracle can still trust the price the loan was sized against.
//
// The attester here signs with EdDSA over BN254's embedded (Baby-Jubjub-class) twisted-edwards
// curve — "native," hence cheap. Trust reduces to the attester key, the same trust the operator's
// ed25519 attestation carries today, but now inside the proof and portable. Swapping in a REAL
// oracle (secp256k1 ECDSA / Wormhole) is the far heavier B2 variant and slots in at Verify.
type SolvencyAttestedCircuit struct {
	PoolHi, PoolLo         frontend.Variable
	BorrowerHi, BorrowerLo frontend.Variable
	Debt                   frontend.Variable
	Collateral             frontend.Variable
	LtvBps                 frontend.Variable
	Nonce                  frontend.Variable
	TypeHi, TypeLo         frontend.Variable
	Price                  frontend.Variable

	Commit         frontend.Variable `gnark:",public"` // == on-chain loan_commit_of(...)
	AttesterPubKey eddsa.PublicKey    `gnark:",public"` // pinned in the pool
	PriceSig       eddsa.Signature    // witness: attester's signature over Price
}

func (c *SolvencyAttestedCircuit) Define(api frontend.API) error {
	enforceLoan(api, c.PoolHi, c.PoolLo, c.BorrowerHi, c.BorrowerLo,
		c.Debt, c.Collateral, c.LtvBps, c.Nonce, c.TypeHi, c.TypeLo, c.Price, c.Commit)

	curve, err := twistededwards.NewEdCurve(api, tedwards.BN254)
	if err != nil {
		return err
	}
	h, err := mimc.NewMiMC(api)
	if err != nil {
		return err
	}
	// The attester signs the price; the circuit proves that signature is valid under the pinned
	// key. Binding asset-id/timestamp into the signed message (to stop cross-asset or stale reuse)
	// is one extra in-circuit hash on top of this — measured cost below is the minimal core.
	return eddsa.Verify(curve, c.PriceSig, c.Price, c.AttesterPubKey, &h)
}
