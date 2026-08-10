package poseidon

import (
	"fmt"

	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/algebra/emulated/sw_bn254"
	"github.com/consensys/gnark/std/math/emulated"
	stdgroth16 "github.com/consensys/gnark/std/recursion/groth16"
)

// Recursion type aliases for the BN254-in-BN254 emulated path — the one that keeps the aggregate
// cheaply EVM-verifiable (see docs/SCOPE-solvency-rollup.md, Spike 0).
type (
	innerProof   = stdgroth16.Proof[sw_bn254.G1Affine, sw_bn254.G2Affine]
	innerWitness = stdgroth16.Witness[sw_bn254.ScalarField]
	innerVK      = stdgroth16.VerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl]
)

// Accumulator proof public-input layout: Public = [GenesisRoot, CurrentRoot, VKCommit].
const (
	aiGenesis  = 0
	aiCurrent  = 1
	aiVKCommit = 2
)

// ivcDummyCircuit supplies the constant proof that the genesis fold feeds into its recursive slot.
// The genesis fold (IsBase=1) must still run the pairing check on *some* valid proof, but there is no
// prior accumulator proof at genesis. This circuit proves nothing about state — its only job is to
// match the fold's inner-proof shape exactly: 3 declared public inputs (the genesis/current/vkcommit
// slots, left unconstrained) plus one commitment over an internal wire, giving the same
// (nbPublic=4, nbCommitment=1, pubCommitted=[[]]) signature as a real fold proof. The genesis fold
// verifies it so the pairing check passes, then gates out its content via the IsBase selector.
type ivcDummyCircuit struct {
	Slot0 frontend.Variable `gnark:",public"`
	Slot1 frontend.Variable `gnark:",public"`
	Slot2 frontend.Variable `gnark:",public"`
	X     frontend.Variable // witnessed value behind the internal commitment
}

func (c *ivcDummyCircuit) Define(api frontend.API) error {
	committer, ok := api.(frontend.Committer)
	if !ok {
		return fmt.Errorf("frontend does not support commitments")
	}
	// Commit over an internal wire (derived from X), giving pubCommitted=[[]] to match the fold's
	// recursion-induced commitment structure.
	y := api.Mul(c.X, c.X)
	cmt, err := committer.Commit(y)
	if err != nil {
		return fmt.Errorf("dummy commit: %w", err)
	}
	api.AssertIsDifferent(cmt, 0)
	// The public slots are intentionally unconstrained — their values are irrelevant, the genesis fold
	// ignores them. They exist only so this circuit's proof shape matches a real fold proof.
	_ = c.Slot0
	_ = c.Slot1
	_ = c.Slot2
	return nil
}

// IVCFold is the unified single-VK IVC step with an in-circuit base case (replacing the earlier
// two-circuit base+step scaffolding): one circuit, one verifying key, no bootstrap adapter. Every
// proof does exactly one borrow transition
// prev_current -> current; what differs is where prev_current comes from:
//
//   - IsBase = 1 (genesis): the recursive slot holds a constant dummy proof (verified so the pairing
//     check passes, content ignored). prev_current is forced to GenesisRoot, and the VK binding,
//     genesis-carry, and VKCommit propagation checks are made vacuous. This can only start a fresh
//     one-transition-from-genesis history, so it cannot launder a deep bad state.
//   - IsBase = 0 (step): the recursive slot holds a real prior IVCFold proof. It is verified, its VK is
//     bound to VKCommit (hash(PrevVK) == VKCommit), the genesis is carried forward, VKCommit propagates
//     unchanged, and prev_current is bridged from the incoming proof.
//
// Because a real fold proof and the dummy share the exact same shape (see TestDummy_ShapeMatchesFold),
// a single VK verifies both — the fold folds against itself for unbounded history.
type IVCFold struct {
	PrevProof   innerProof
	PrevWitness innerWitness
	PrevVK      innerVK

	IsBase   frontend.Variable // 1 for the genesis fold (dummy in the recursive slot), else 0
	Old      Position
	Amount   frontend.Variable
	Price    frontend.Variable
	PathBits [StateTreeDepth]frontend.Variable
	Siblings [StateTreeDepth]frontend.Variable

	GenesisRoot frontend.Variable `gnark:",public"`
	CurrentRoot frontend.Variable `gnark:",public"`
	VKCommit    frontend.Variable `gnark:",public"`
}

func (c *IVCFold) Define(api frontend.API) error {
	api.AssertIsBoolean(c.IsBase)
	verifier, err := stdgroth16.NewVerifier[sw_bn254.ScalarField, sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](api)
	if err != nil {
		return fmt.Errorf("new verifier: %w", err)
	}
	field, err := emulated.NewField[sw_bn254.ScalarField](api)
	if err != nil {
		return fmt.Errorf("new field: %w", err)
	}

	// The recursive slot is always verified (a real prior fold in a step; the dummy at genesis).
	// Complete arithmetic is required: the genesis dummy proof can drive the verifier's MSM into
	// edge cases (coincident points) that the faster unsafe path cannot handle.
	if err := verifier.AssertProof(c.PrevVK, c.PrevProof, c.PrevWitness,
		stdgroth16.WithCompleteArithmetic()); err != nil {
		return fmt.Errorf("verify prev: %w", err)
	}

	// VK-hash binding, gated: a step binds hash(PrevVK) to the pinned VKCommit; genesis is exempt (its
	// recursive slot is a dummy under a different key).
	hv := hashVKInCircuit(api, c.PrevVK)
	api.AssertIsEqual(api.Select(c.IsBase, c.VKCommit, hv), c.VKCommit)

	// Bridge the incoming proof's emulated public inputs to native.
	prevGenesis := api.FromBinary(field.ToBitsCanonical(&c.PrevWitness.Public[aiGenesis])...)
	prevCurrent := api.FromBinary(field.ToBitsCanonical(&c.PrevWitness.Public[aiCurrent])...)
	prevVKCommit := api.FromBinary(field.ToBitsCanonical(&c.PrevWitness.Public[aiVKCommit])...)

	// Genesis carried forward (gated) and VKCommit propagated unchanged (gated).
	api.AssertIsEqual(api.Select(c.IsBase, c.GenesisRoot, prevGenesis), c.GenesisRoot)
	api.AssertIsEqual(api.Select(c.IsBase, c.VKCommit, prevVKCommit), c.VKCommit)

	// Extend history by one transition. Genesis starts from GenesisRoot; a step from the incoming root.
	oldRoot := api.Select(c.IsBase, c.GenesisRoot, prevCurrent)
	proveBorrow(api, c.Old, c.Amount, c.Price, c.PathBits[:], c.Siblings[:], oldRoot, c.CurrentRoot)
	return nil
}

