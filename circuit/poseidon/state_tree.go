package poseidon

import "github.com/consensys/gnark/frontend"

// StateTreeDepth is the depth of the Poseidon Merkle tree of loan Positions. A borrow is a single-leaf
// update: the same path/siblings witness both the old and the new leaf.
const StateTreeDepth = 20

// Position is one loan's state in the tree. Its fields are EXACTLY the ten that
// dregg_lending::loan_commit_of hashes on-chain (two-limb split32 of the 32-byte values), so a leaf in
// this tree equals the on-chain loan commitment field-for-field. Price is deliberately NOT part of a
// Position: it is the oracle input to a transition, never stored state.
type Position struct {
	PoolHi, PoolLo         frontend.Variable // split32(pool_id)
	BorrowerHi, BorrowerLo frontend.Variable // split32(borrower address)
	Debt                   frontend.Variable // stablecoin owed
	Collateral             frontend.Variable // collateral units
	LtvBps                 frontend.Variable // loan-to-value, basis points
	Nonce                  frontend.Variable // per-loan nonce
	TypeHi, TypeLo         frontend.Variable // split32(collateral type hash)
}

// positionLeaf hashes a Position to its Merkle leaf — Poseidon over the ten fields in loan_commit_of
// order, matching the native positionLeaf() the tests build the tree with.
func positionLeafCircuit(api frontend.API, p Position) frontend.Variable {
	return PoseidonBn254(api, []frontend.Variable{
		p.PoolHi, p.PoolLo, p.BorrowerHi, p.BorrowerLo,
		p.Debt, p.Collateral, p.LtvBps, p.Nonce, p.TypeHi, p.TypeLo,
	})
}

// merkleRoot climbs from `leaf` to the root. pathBits[i] is 0 when the current node is the LEFT child at
// level i (sibling on the right) and 1 when it is the RIGHT child. Each parent is Poseidon(left, right),
// matching the native climb() in the tests and the on-chain Poseidon tree.
func merkleRoot(api frontend.API, leaf frontend.Variable, pathBits, siblings []frontend.Variable) frontend.Variable {
	cur := leaf
	for i := range pathBits {
		b := pathBits[i]
		left := api.Select(b, siblings[i], cur)  // b==1 -> sibling is left
		right := api.Select(b, cur, siblings[i]) // b==1 -> cur is right
		cur = PoseidonBn254(api, []frontend.Variable{left, right})
	}
	return cur
}

// proveBorrow proves one borrow transition against an attested price, with no free price witness:
//   - the OLD position is Merkle-included under oldRoot,
//   - the NEW position (same terms, debt increased by `amount`, same path) is included under newRoot,
//   - the resulting debt is solvent at `price` (the guardian-attested value passed in by the caller).
//
// pathBits/siblings are the shared inclusion path for both leaves (a single-leaf update).
func proveBorrow(api frontend.API, old Position, amount, price frontend.Variable, pathBits, siblings []frontend.Variable, oldRoot, newRoot frontend.Variable) {
	// The old state is what the tree currently commits to.
	api.AssertIsEqual(merkleRoot(api, positionLeafCircuit(api, old), pathBits, siblings), oldRoot)

	// Apply the borrow: only Debt changes; everything else (collateral, ltv, identity) is carried over.
	nw := old
	nw.Debt = api.Add(old.Debt, amount)
	api.AssertIsEqual(merkleRoot(api, positionLeafCircuit(api, nw), pathBits, siblings), newRoot)

	// The post-borrow debt must be covered at the attested price — the same rung-1 rule as the bare
	// solvency circuit, but here the price is oracle-attested rather than a free witness.
	enforceSolvent(api, nw.Debt, old.Collateral, price, old.LtvBps)
}
