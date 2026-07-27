package poseidon

import (
	"fmt"
	"math/big"
	"testing"
	"time"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/groth16"
	"github.com/consensys/gnark/backend/witness"
	"github.com/consensys/gnark/constraint"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/algebra/emulated/sw_bn254"
	stdgroth16 "github.com/consensys/gnark/std/recursion/groth16"
	"github.com/consensys/gnark/test"
)

// TestDummy_ShapeMatchesFold confirms the dummy circuit's proof shape equals a fold proof's shape
// (nbPublic, nbCommitment, pubCommitted), so the genesis fold — sized to verify fold proofs — accepts
// the dummy in its recursive slot.
func TestDummy_ShapeMatchesFold(t *testing.T) {
	sig := func(name string, ccs constraint.ConstraintSystem) (int, int, string) {
		comms := ccs.GetCommitments().(constraint.Groth16Commitments)
		pacc := comms.GetPublicAndCommitmentCommitted(comms.CommitmentIndexes(), ccs.GetNbPublicVariables())
		s := fmt.Sprintf("%v", pacc)
		t.Logf("%-22s nbPub=%d nbCommit=%d pubCommitted=%s", name, ccs.GetNbPublicVariables(), len(comms), s)
		return ccs.GetNbPublicVariables(), len(comms), s
	}

	dummyCCS, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, &ivcDummyCircuit{})
	if err != nil {
		t.Fatalf("dummy compile: %v", err)
	}
	dp, dc, ds := sig("ivcDummyCircuit", dummyCCS)

	// IVCFold's own proof shape must equal the dummy's, so ONE verifying key verifies the dummy, the
	// genesis fold's output, and every subsequent step — self-reference across the whole chain.
	ivcCCS, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, ivcFoldPlaceholder(dummyCCS))
	if err != nil {
		t.Fatalf("IVCFold compile: %v", err)
	}
	ip, ic, is := sig("IVCFold", ivcCCS)
	if ip == dp && ic == dc && is == ds {
		t.Logf("=> SELF-REFERENTIAL: one VK verifies the dummy AND IVCFold's own proofs (%d constraints)", ivcCCS.GetNbConstraints())
	} else {
		t.Fatalf("IVCFold not self-referential: dummy (%d,%d,%s) != IVCFold (%d,%d,%s)", dp, dc, ds, ip, ic, is)
	}
}

func ivcFoldPlaceholder(innerCCS constraint.ConstraintSystem) *IVCFold {
	return &IVCFold{
		PrevProof:   stdgroth16.PlaceholderProof[sw_bn254.G1Affine, sw_bn254.G2Affine](innerCCS),
		PrevWitness: stdgroth16.PlaceholderWitness[sw_bn254.ScalarField](innerCCS),
		PrevVK:      stdgroth16.PlaceholderVerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](innerCCS),
	}
}

// makeDummyProof produces the constant genesis dummy proof (recursion-ready).
func makeDummyProof(t *testing.T) (constraint.ConstraintSystem, groth16.VerifyingKey, groth16.Proof, witness.Witness) {
	field := ecc.BN254.ScalarField()
	ccs, err := frontend.Compile(field, r1cs.NewBuilder, &ivcDummyCircuit{})
	if err != nil {
		t.Fatalf("dummy compile: %v", err)
	}
	pk, vk, err := groth16.Setup(ccs)
	if err != nil {
		t.Fatalf("dummy setup: %v", err)
	}
	// Non-zero public slots: the genesis fold gates their values out, but the recursion verifier's
	// (unsafe) MSM must not hit a zero-scalar degeneracy.
	full, err := frontend.NewWitness(&ivcDummyCircuit{Slot0: 1, Slot1: 2, Slot2: 3, X: 3}, field)
	if err != nil {
		t.Fatalf("dummy witness: %v", err)
	}
	proof, err := groth16.Prove(ccs, pk, full, stdgroth16.GetNativeProverOptions(field, field))
	if err != nil {
		t.Fatalf("dummy prove: %v", err)
	}
	pub, _ := full.Public()
	if err := groth16.Verify(proof, vk, pub, stdgroth16.GetNativeVerifierOptions(field, field)); err != nil {
		t.Fatalf("dummy verify: %v", err)
	}
	return ccs, vk, proof, pub
}

// baseAssignment builds a genesis (IsBase=1) fold: verify the dummy, borrow `amount` from genesis root0.
func baseAssignment(t *testing.T, dvk groth16.VerifyingKey, dproof groth16.Proof, dpub witness.Witness,
	amount int64, current *big.Int, pin *big.Int) *IVCFold {
	sib := emptySiblings(t, StateTreeDepth)
	idx := uint64(0b1011)
	pos0 := samplePosition(0)
	root0 := climb(t, positionLeaf(t, pos0), idx, sib)

	cvk, _ := stdgroth16.ValueOfVerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](dvk)
	cp, _ := stdgroth16.ValueOfProof[sw_bn254.G1Affine, sw_bn254.G2Affine](dproof)
	cw, _ := stdgroth16.ValueOfWitness[sw_bn254.ScalarField](dpub)

	c := &IVCFold{
		PrevProof: cp, PrevWitness: cw, PrevVK: cvk,
		IsBase: 1, Old: pos0, Amount: big.NewInt(amount), Price: big.NewInt(testPrice),
		GenesisRoot: root0, CurrentRoot: current, VKCommit: pin,
	}
	for i := 0; i < StateTreeDepth; i++ {
		c.PathBits[i] = big.NewInt(int64((idx >> uint(i)) & 1))
		c.Siblings[i] = sib[i]
	}
	return c
}

// TestIVC_BaseCase — the genesis fold: verify the constant dummy proof and make the FIRST transition
// (root0 -> root1) with the VK binding and carry checks gated off. Validated by solving the circuit.
func TestIVC_BaseCase(t *testing.T) {
	if testing.Short() {
		t.Skip("recursive verification of the dummy proof")
	}
	dCCS, dvk, dproof, dpub := makeDummyProof(t)
	sib := emptySiblings(t, StateTreeDepth)
	idx := uint64(0b1011)
	root1 := climb(t, positionLeaf(t, samplePosition(600)), idx, sib)

	ph := ivcFoldPlaceholder(dCCS)
	asg := baseAssignment(t, dvk, dproof, dpub, 600, root1, big.NewInt(0xBEEF))
	if err := test.IsSolved(ph, asg, ecc.BN254.ScalarField()); err != nil {
		t.Fatalf("genesis fold should solve: %v", err)
	}
	t.Logf("base case: genesis fold verified the dummy and made the first transition root0 -> root1")
}

// TestIVC_BaseCase_BadTransition — even at genesis the transition must be valid: a wrong current root
// (not the honest borrow result) must fail.
func TestIVC_BaseCase_BadTransition(t *testing.T) {
	if testing.Short() {
		t.Skip("recursive verification of the dummy proof")
	}
	dCCS, dvk, dproof, dpub := makeDummyProof(t)
	sib := emptySiblings(t, StateTreeDepth)
	idx := uint64(0b1011)
	wrong := climb(t, positionLeaf(t, samplePosition(9999)), idx, sib) // not the borrow-600 result

	ph := ivcFoldPlaceholder(dCCS)
	asg := baseAssignment(t, dvk, dproof, dpub, 600, wrong, big.NewInt(0xBEEF))
	if err := test.IsSolved(ph, asg, ecc.BN254.ScalarField()); err == nil {
		t.Fatal("a genesis fold with an inconsistent transition must fail")
	}
}

// TestIVC_BaseCase_StepRequiresBinding — flipping IsBase to 0 with the dummy in the recursive slot must
// fail, because a step demands hash(PrevVK) == VKCommit and the dummy's key does not match the pin.
func TestIVC_BaseCase_StepRequiresBinding(t *testing.T) {
	if testing.Short() {
		t.Skip("recursive verification of the dummy proof")
	}
	dCCS, dvk, dproof, dpub := makeDummyProof(t)
	sib := emptySiblings(t, StateTreeDepth)
	idx := uint64(0b1011)
	root1 := climb(t, positionLeaf(t, samplePosition(600)), idx, sib)

	ph := ivcFoldPlaceholder(dCCS)
	asg := baseAssignment(t, dvk, dproof, dpub, 600, root1, big.NewInt(0xBEEF))
	asg.IsBase = 0 // pretend it's a real step: binding + carry now enforced, dummy won't satisfy them
	if err := test.IsSolved(ph, asg, ecc.BN254.ScalarField()); err == nil {
		t.Fatal("IsBase=0 with an unbound dummy key must fail the binding/carry checks")
	}
}

// ivcStepAssignment builds a real step fold (IsBase=0): verify a prior IVCFold proof under vk, and
// extend prev_current -> current. VKCommit is hash(vk) (== the pinned accumulator key).
func ivcStepAssignment(t *testing.T, vk groth16.VerifyingKey, proof groth16.Proof, pub witness.Witness,
	old Position, amount int64, idx uint64, sib []*big.Int, genesis, current *big.Int) *IVCFold {
	cvk, _ := stdgroth16.ValueOfVerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](vk)
	cp, _ := stdgroth16.ValueOfProof[sw_bn254.G1Affine, sw_bn254.G2Affine](proof)
	cw, _ := stdgroth16.ValueOfWitness[sw_bn254.ScalarField](pub)
	vkCommit, err := hashVKNative(cvk)
	if err != nil {
		t.Fatalf("hashVKNative: %v", err)
	}
	c := &IVCFold{
		PrevProof: cp, PrevWitness: cw, PrevVK: cvk,
		IsBase: 0, Old: old, Amount: big.NewInt(amount), Price: big.NewInt(testPrice),
		GenesisRoot: genesis, CurrentRoot: current, VKCommit: vkCommit,
	}
	for i := 0; i < StateTreeDepth; i++ {
		c.PathBits[i] = big.NewInt(int64((idx >> uint(i)) & 1))
		c.Siblings[i] = sib[i]
	}
	return c
}

func proveIVC(t *testing.T, ccs constraint.ConstraintSystem, pk groth16.ProvingKey, vk groth16.VerifyingKey, asg *IVCFold) (groth16.Proof, witness.Witness) {
	field := ecc.BN254.ScalarField()
	full, err := frontend.NewWitness(asg, field)
	if err != nil {
		t.Fatalf("witness: %v", err)
	}
	proof, err := groth16.Prove(ccs, pk, full, stdgroth16.GetNativeProverOptions(field, field))
	if err != nil {
		t.Fatalf("prove: %v", err)
	}
	pub, _ := full.Public()
	if err := groth16.Verify(proof, vk, pub, stdgroth16.GetNativeVerifierOptions(field, field)); err != nil {
		t.Fatalf("verify: %v", err)
	}
	return proof, pub
}

// TestIVC_SingleVK_BaseCase — TRUE single-VK IVC: one circuit, one key. Genesis (IsBase=1) verifies the
// dummy; every step (IsBase=0) verifies the PRIOR IVCFold proof under the SAME vk. No adapter.
func TestIVC_SingleVK_BaseCase(t *testing.T) {
	if testing.Short() {
		t.Skip("one heavy setup (~2.84M) + a genesis fold + two self-referential steps")
	}
	field := ecc.BN254.ScalarField()
	sib := emptySiblings(t, StateTreeDepth)
	idx := uint64(0b1011)
	pos0, pos1, pos2 := samplePosition(0), samplePosition(600), samplePosition(1100)
	root0 := climb(t, positionLeaf(t, pos0), idx, sib)
	root1 := climb(t, positionLeaf(t, pos1), idx, sib)
	root2 := climb(t, positionLeaf(t, pos2), idx, sib)
	root3 := climb(t, positionLeaf(t, samplePosition(1500)), idx, sib)

	dCCS, dvk, dproof, dpub := makeDummyProof(t)

	// One and only setup: the IVCFold verifying key is THE accumulator key.
	ccs, err := frontend.Compile(field, r1cs.NewBuilder, ivcFoldPlaceholder(dCCS))
	if err != nil {
		t.Fatalf("IVCFold compile: %v", err)
	}
	t1 := time.Now()
	pk, vk, err := groth16.Setup(ccs)
	if err != nil {
		t.Fatalf("IVCFold setup: %v", err)
	}
	t.Logf("IVCFold (%d constraints) setup=%s", ccs.GetNbConstraints(), time.Since(t1).Round(time.Millisecond))

	pin, err := hashVKNative(mustVKVal(t, vk))
	if err != nil {
		t.Fatalf("pin: %v", err)
	}

	// Genesis: IsBase=1, verify dummy, borrow root0 -> root1, VKCommit pinned to hash(vk).
	gAsg := baseAssignment(t, dvk, dproof, dpub, 600, root1, pin)
	piG, pubG := proveIVC(t, ccs, pk, vk, gAsg)
	t.Logf("genesis proved (IsBase=1): dummy verified, root0 -> root1")

	// Step 1: IsBase=0, verify the genesis IVCFold proof under vk, root1 -> root2.
	s1 := ivcStepAssignment(t, vk, piG, pubG, pos1, 500, idx, sib, root0, root2)
	piS1, pubS1 := proveIVC(t, ccs, pk, vk, s1)
	t.Logf("step1 proved (IsBase=0): verified the genesis proof under vk, root1 -> root2")

	// Step 2: IsBase=0, verify step1's IVCFold proof under the SAME vk — self-reference, root2 -> root3.
	s2 := ivcStepAssignment(t, vk, piS1, pubS1, pos2, 400, idx, sib, root0, root3)
	piS2, pubS2 := proveIVC(t, ccs, pk, vk, s2)
	t.Logf("step2 proved (IsBase=0): verified step1 under the SAME vk (SELF-REFERENCE), root2 -> root3")

	if err := groth16.Verify(piS2, vk, pubS2, stdgroth16.GetNativeVerifierOptions(field, field)); err != nil {
		t.Fatalf("final verify under the single vk: %v", err)
	}
	t.Logf("TRUE SINGLE-VK IVC: one key, base case in-circuit, attests root0 -> root3 across 3 steps")
}

func mustVKVal(t *testing.T, vk groth16.VerifyingKey) stdgroth16.VerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl] {
	v, err := stdgroth16.ValueOfVerifyingKey[sw_bn254.G1Affine, sw_bn254.G2Affine, sw_bn254.GTEl](vk)
	if err != nil {
		t.Fatalf("ValueOfVerifyingKey: %v", err)
	}
	return v
}
