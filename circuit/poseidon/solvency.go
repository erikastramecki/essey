package poseidon

import "github.com/consensys/gnark/frontend"

// SolvencyCircuit proves, in zero knowledge, that a loan is solvent —
//
//	debt * BPS_DENOM  <=  collateral * price * ltvBps
//
// — and that its terms hash to the public commitment Commit under the SAME BN254 Poseidon
// used by sui::poseidon::poseidon_bn254 / dregg_lending::loan_commit_of. The proof reveals
// nothing but Commit; a verifier learns the loan is within its LTV without seeing the terms.
//
// The commitment preimage mirrors loan_commit_of<Collateral> field-for-field:
//
//	poseidon([pool_hi, pool_lo, borrower_hi, borrower_lo, debt, collateral, ltv_bps, nonce, type_hi, type_lo])
//
// PLUS a trailing `price`. loan_commit_of does NOT yet bind price (grep confirms: no price in
// lending.move), and you cannot prove `debt <= collateral*price*ltv` against a commitment that
// never mentions price. Adding `price` to loan_commit_of is the Phase 2 on-chain schema change;
// binding that committed price to a real oracle is the Phase 3 trust decision. Phase 1 (this file)
// establishes the circuit and a locally-verifying proof against the intended schema.
//
// The two-limb fields (PoolHi/Lo, BorrowerHi/Lo, TypeHi/Lo) match Move's split32: a 32-byte value
// cut into high/low 16-byte halves, each < 2^128 < the BN254 scalar field, so each is a valid
// Poseidon input.
type SolvencyCircuit struct {
	PoolHi, PoolLo         frontend.Variable // split32(pool_id)
	BorrowerHi, BorrowerLo frontend.Variable // split32(borrower address)
	Debt                   frontend.Variable // stablecoin owed
	Collateral             frontend.Variable // collateral units
	LtvBps                 frontend.Variable // loan-to-value, basis points
	Nonce                  frontend.Variable // per-loan nonce (single-use binding)
	TypeHi, TypeLo         frontend.Variable // split32(blake2b256(collateral type name))
	Price                  frontend.Variable // conservative price per unit (NEW vs loan_commit_of)

	Commit frontend.Variable `gnark:",public"` // == on-chain loan_commit_of(...) preimage hash
}

// bpsDenom is the basis-point denominator: ltvBps of 3500 means 35%.
const bpsDenom = 10000

func (c *SolvencyCircuit) Define(api frontend.API) error {
	// 1) Terms bind to the public commitment — same field order as loan_commit_of, then price.
	commit := PoseidonBn254(api, []frontend.Variable{
		c.PoolHi, c.PoolLo, c.BorrowerHi, c.BorrowerLo,
		c.Debt, c.Collateral, c.LtvBps, c.Nonce,
		c.TypeHi, c.TypeLo, c.Price,
	})
	api.AssertIsEqual(commit, c.Commit)

	// 2) Range-bound the arithmetic operands. This is not optional: without it a prover could
	//    supply field elements so large that collateral*price*ltvBps WRAPS the BN254 modulus and a
	//    genuinely-insolvent loan appears small enough to pass the comparison. Bounding each input
	//    keeps the product < 2^176 « the ~254-bit field, so no wrap is possible.
	api.ToBinary(c.Debt, 64)       // u64
	api.ToBinary(c.Collateral, 64) // u64
	api.ToBinary(c.Price, 96)      // room for decimal-scaled prices
	api.ToBinary(c.LtvBps, 16)     // <= 65535 bps

	// 3) Solvency: debt * 10000 <= collateral * price * ltvBps.
	lhs := api.Mul(c.Debt, bpsDenom)
	rhs := api.Mul(api.Mul(c.Collateral, c.Price), c.LtvBps)
	api.AssertIsLessOrEqual(lhs, rhs)
	return nil
}
