package poseidon

import "github.com/consensys/gnark/frontend"

// bpsDenom is the basis-point denominator: ltvBps of 3500 means 35%.
const bpsDenom = 10000

// enforceLoan applies the commitment binding + range checks + solvency inequality. Shared by the
// bare circuit and the attested circuit so the core rule lives in exactly one place.
//
// The commitment preimage mirrors dregg_lending::loan_commit_of<Collateral> field-for-field, PLUS
// price (loan_commit_of does not yet bind price — adding it is the Phase 2 on-chain schema change).
// The two-limb fields match Move's split32: a 32-byte value cut into high/low 16-byte halves, each
// < 2^128 < the BN254 scalar field.
func enforceLoan(api frontend.API,
	poolHi, poolLo, bHi, bLo, debt, coll, ltvBps, nonce, tHi, tLo, price, commit frontend.Variable) {

	// 1) Terms bind to the public commitment — same field order as loan_commit_of, then price.
	c := PoseidonBn254(api, []frontend.Variable{poolHi, poolLo, bHi, bLo, debt, coll, ltvBps, nonce, tHi, tLo, price})
	api.AssertIsEqual(c, commit)

	// 2) Range-bound the operands so no product can wrap the BN254 field and hide an overflow.
	api.ToBinary(debt, 64)
	api.ToBinary(coll, 64)
	api.ToBinary(price, 96)
	api.ToBinary(ltvBps, 16)

	// 3) Solvency: debt * 10000 <= collateral * price * ltvBps.
	lhs := api.Mul(debt, bpsDenom)
	rhs := api.Mul(api.Mul(coll, price), ltvBps)
	api.AssertIsLessOrEqual(lhs, rhs)
}

// SolvencyCircuit proves, in zero knowledge, that a loan is solvent and that its terms hash to the
// public commitment Commit — with no oracle binding (Option A: price is checked on-chain). The
// single public input is Commit; every loan term is private.
type SolvencyCircuit struct {
	PoolHi, PoolLo         frontend.Variable // split32(pool_id)
	BorrowerHi, BorrowerLo frontend.Variable // split32(borrower address)
	Debt                   frontend.Variable // stablecoin owed
	Collateral             frontend.Variable // collateral units
	LtvBps                 frontend.Variable // loan-to-value, basis points
	Nonce                  frontend.Variable // per-loan nonce (single-use binding)
	TypeHi, TypeLo         frontend.Variable // split32(blake2b256(collateral type name))
	Price                  frontend.Variable // conservative price per unit

	Commit frontend.Variable `gnark:",public"` // == on-chain loan_commit_of(...) preimage hash
}

func (c *SolvencyCircuit) Define(api frontend.API) error {
	enforceLoan(api, c.PoolHi, c.PoolLo, c.BorrowerHi, c.BorrowerLo,
		c.Debt, c.Collateral, c.LtvBps, c.Nonce, c.TypeHi, c.TypeLo, c.Price, c.Commit)
	return nil
}
