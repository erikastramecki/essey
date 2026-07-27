package poseidon

import "github.com/consensys/gnark/frontend"

// StateTreeDepth is the height of the position state tree (2^depth position slots).
const StateTreeDepth = 20

// Position is one lending position stored as a leaf in the state tree. Field order mirrors
// dregg_lending::loan_commit_of (minus price, which is the *current* oracle value applied at
// transition time, not stored state). Two-limb fields are Move split32 halves (< 2^128).
type Position struct {
	PoolHi, PoolLo         frontend.Variable
	BorrowerHi, BorrowerLo frontend.Variable
	Debt, Collateral       frontend.Variable
	LtvBps, Nonce          frontend.Variable
	TypeHi, TypeLo         frontend.Variable
}

// leaf hashes the position to its tree leaf with the Sui-compatible Poseidon (10 inputs).
func (p Position) leaf(api frontend.API) frontend.Variable {
	return PoseidonBn254(api, []frontend.Variable{
		p.PoolHi, p.PoolLo, p.BorrowerHi, p.BorrowerLo,
		p.Debt, p.Collateral, p.LtvBps, p.Nonce, p.TypeHi, p.TypeLo,
	})
}

// merkleRoot climbs from leaf to root using an authentication path. At level i, pathBits[i]==0
// means the running node is the LEFT child (sibling on the right); ==1 means it is the RIGHT
// child. Node hash is the 2-input Sui-compatible Poseidon, so the same tree verifies natively
// under sui::poseidon_bn254 at settlement. Callers must have already constrained pathBits boolean.
func merkleRoot(api frontend.API, leaf frontend.Variable, pathBits, siblings []frontend.Variable) frontend.Variable {
	cur := leaf
	for i := range siblings {
		l := api.Select(pathBits[i], siblings[i], cur)
		r := api.Select(pathBits[i], cur, siblings[i])
		cur = PoseidonBn254(api, []frontend.Variable{l, r})
	}
	return cur
}

// TransitionCircuit proves one valid, solvency-preserving state transition:
//
//	old_root --(borrow Amount against this position)--> new_root
//
// It proves: (1) the pre-image position is included in old_root; (2) applying the borrow yields a
// position that satisfies the dregg solvency invariant at the public price; (3) replacing only that
// leaf along the same authentication path produces new_root. Composed through the Spike-0 IVC fold,
// a chain of these is a constant-size proof that the protocol was solvent across all of history.
//
// Public: old_root, new_root, price. Everything about the position and the action is private.
type TransitionCircuit struct {
	Old      Position                      // position before the action
	Amount   frontend.Variable             // borrow amount added to debt (>= 0)
	PathBits [StateTreeDepth]frontend.Variable
	Siblings [StateTreeDepth]frontend.Variable

	OldRoot frontend.Variable `gnark:",public"`
	NewRoot frontend.Variable `gnark:",public"`
	Price   frontend.Variable `gnark:",public"`
}

func (c *TransitionCircuit) Define(api frontend.API) error {
	proveBorrow(api, c.Old, c.Amount, c.Price, c.PathBits[:], c.Siblings[:], c.OldRoot, c.NewRoot)
	return nil
}

// proveBorrow enforces one borrow transition against an authentication path: `old` is included under
// oldRoot, borrowing `amount` keeps the position solvent at `price`, and replacing only that leaf
// along the same path yields newRoot. Shared by TransitionCircuit and the IVC fold (IVCFold) so the
// transition rule lives in exactly one place.
func proveBorrow(api frontend.API, old Position, amount, price frontend.Variable,
	pathBits, siblings []frontend.Variable, oldRoot, newRoot frontend.Variable) {

	for i := range pathBits {
		api.AssertIsBoolean(pathBits[i])
	}

	// 1) The pre-image position is a member of oldRoot.
	api.AssertIsEqual(merkleRoot(api, old.leaf(api), pathBits, siblings), oldRoot)

	// 2) Apply the borrow: new_debt = old_debt + amount, amount range-bound to prevent field wrap.
	api.ToBinary(amount, 64)
	newPos := old
	newPos.Debt = api.Add(old.Debt, amount)

	// 3) The resulting position is solvent at the price (same rule as enforceLoan).
	enforceSolvent(api, newPos.Debt, newPos.Collateral, newPos.LtvBps, price)

	// 4) Replacing only this leaf along the same path yields newRoot.
	api.AssertIsEqual(merkleRoot(api, newPos.leaf(api), pathBits, siblings), newRoot)
}
