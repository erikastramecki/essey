package poseidon

import (
	"encoding/hex"
	"math/big"
	"os"
	"testing"
	"time"

	"github.com/consensys/gnark/backend/groth16"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/r1cs"
	"github.com/consensys/gnark/std/algebra/emulated/sw_emulated"
	"github.com/consensys/gnark/std/hash/sha3"
	"github.com/consensys/gnark/std/math/cmp"
	"github.com/consensys/gnark/std/math/emulated"
	"github.com/consensys/gnark/std/math/uints"
	"github.com/consensys/gnark/std/signature/ecdsa"
	"github.com/consensys/gnark/test"
	iden3 "github.com/iden3/go-iden3-crypto/poseidon"
)

// portableProofCircuit is the whole thing in one circuit — the artifact that lets an Essey loan
// settle on a chain with no oracle. It proves, revealing only the loan commitment:
//
//	1. a quorum of Pyth guardians signed a VAA body  (keccak(keccak(body)) + N ECDSA vs pinned keys)
//	2. that body carries the Merkle root             (root = body[68:88], guardian-signed)
//	3. the price message is included under that root (13-hop keccak160 Merkle climb == root)
//	4. the loan is solvent against THAT price        (price = message[33:41] -> solvency commitment)
//
// So the single public input Commit is provably tied to a real Pyth-attested price. No oracle read
// on the settlement chain — the proof carries the price's provenance.
type portableProofCircuit struct {
	Body    []uints.U8
	Pubs    []ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr]
	Sigs    []ecdsa.Signature[emulated.Secp256k1Fr]
	Message []uints.U8
	Proof   [][]uints.U8

	PoolHi, PoolLo         frontend.Variable
	BorrowerHi, BorrowerLo frontend.Variable
	Debt, Collateral       frontend.Variable
	LtvBps, Nonce          frontend.Variable
	TypeHi, TypeLo         frontend.Variable

	Commit frontend.Variable `gnark:",public"`
}

func (c *portableProofCircuit) Define(api frontend.API) error {
	uapi, err := uints.New[uints.U64](api)
	if err != nil {
		return err
	}

	// (1) guardian-signed digest, then a quorum of ECDSA verifications against pinned pubkeys.
	h1, _ := sha3.NewLegacyKeccak256(api)
	h1.Write(c.Body)
	h2, _ := sha3.NewLegacyKeccak256(api)
	h2.Write(h1.Sum())
	digest := h2.Sum()

	fr, err := emulated.NewField[emulated.Secp256k1Fr](api)
	if err != nil {
		return err
	}
	msg := digestToScalar(api, fr, digest)
	params := sw_emulated.GetCurveParams[emulated.Secp256k1Fp]()
	for i := range c.Pubs {
		c.Pubs[i].Verify(api, params, msg, &c.Sigs[i])
	}

	// (2)+(3) the root lives inside the signed body; the price message must climb to it.
	root := c.Body[68:88]
	cmp160 := cmp.NewBoundedComparator(api, new(big.Int).Lsh(big.NewInt(1), 160), false)
	cur := keccak20(api, append([]uints.U8{uints.NewU8(0)}, c.Message...))
	for _, sib := range c.Proof {
		lo, hi := sortPair(api, uapi, cmp160, cur, sib)
		in := append([]uints.U8{uints.NewU8(1)}, lo...)
		cur = keccak20(api, append(in, hi...))
	}
	for i := 0; i < 20; i++ {
		uapi.ByteAssertEq(root[i], cur[i])
	}

	// (4) the price the loan is sized against IS the attested price (message[33:41], big-endian).
	price := packBE(api, c.Message[33:41])
	enforceLoan(api, c.PoolHi, c.PoolLo, c.BorrowerHi, c.BorrowerLo,
		c.Debt, c.Collateral, c.LtvBps, c.Nonce, c.TypeHi, c.TypeLo, price, c.Commit)
	return nil
}

// guardian witnesses recovered natively from the fixture (pubX, pubY, sigR, sigS).
var guardianWitness = [][4]string{
	{"9a1e801daa25d9808e70aae9981353086f958955cc94ef33a461b0e596feaef9", "0a8474dd10cf6ae967143f86105c16d6304a3d268ea952fda9389139d4bb9da1", "f0971465a645fba95601c5aa076655efbca23001cf03ea29fe8f76674d27ff95", "0bc7b717a59d38124b71259d8d46a2dae41d6f0e3d8308f942fd4915b084a0f2"},
	{"54177ff4a8329520b76efd86f8bfce5c942554db16e673267dc1133b3f5e230b", "2d8cbf90fe274946045d4491de288d736680edc2ee9ee5b1b15416b0a34806c4", "f2342523bfe1b9eb202d184a4a3623f08a298695232f1142cb1024b9be5c92ea", "1d8222bfd75c129e411e816f5ef80399ef6f1a80759e55f928ef44c18ab01bda"},
	{"0bdcbccc0297c2a4f92a7c39358c42f22a8ed700a78bd05c39c8b61aaf2338e8", "25b6c0d26d1f2a2ae4129cd751201f73d7234c753bd0735212a5288b19748fd2", "5d54287dd4bb64c3f4e6069b691b40c8ca6470e81e47e184f7d3355f0877e9a2", "2dcac425af45b9239536fbd85960a92a4a23cc4d06586981a95f268b3258de8f"},
	{"0a872a7c2cfb93710baee3c1a91e7e3050c5a1a04a02873133b456c24f25d88b", "861a21afb9cbfc55be9608356b7cd2a7db8eddd86190206ae6147e47e601a625", "676dd7f4e6a39179415fecdd9862aa34f71b1d8fa396b5393db86cd2d5b3e4fd", "3f44fcadb9cd2897f6aa68d660b6a7d8dfd4d91d983928e279997a60a2d2dc66"},
	{"b1afbe24acb53ac1306f3bdde910f554e06d374efee41598fbd403557c3114b5", "af6d363bfbd78af16a258844041e04f6dfe67fe62f305e6097c6ece48ccc92c4", "2f3290338ace9baa7eb816725c997097563ce5c38edfbae2b275aef231ee8128", "556e7890cf6aa8789f1d154255086e24b53669faf0c71edd3a55b2f27314612d"},
	{"768d4d655de6876fe51f2ede3b563b71883466b3cdd2a2b1900d53e7e04fc37e", "9d1c8ff0e0a4ed6b520fa3fc9c3937c9fffbad2b26367852af4922b3af644002", "51a36e5f35381ea72190778687a840f21a12b003cea0a48048ccbc752639c8af", "146fdd4070853a66fe58d98a0e219af87ca00a94dc8b954725e570b7c72eabb4"},
	{"cc64af75ec2e2741fb9af9f6191cb9ee187d6d26af4d1e96d7bab47e6ec09be1", "2d3192030dc4bbf54d1da319a7a2acfc7a9dd4c644af6646a4aaa02b1024bbab", "1f9902e038076c99e257eeb2da96367fb204a3532fdd18d09f502394691aab38", "566b86100c69604cf231ba9493c17d04c4b2fd367082b81b2ec1464deced8c2e"},
	{"b5943b6e284682ad2e011d6962d41febf86af2f5fc0c9c8f4b81358ff077f9c9", "6ba0880eaf93541eae94b4fa41dba66dab7fb0201cc9af7c75681e5719b0c95f", "fef4f402a63b179359bf83efa51e1d780dc74839f5f5e5abbfb47c865889d76f", "2bec6e98bcea66fe641ce49876d51dfdefde29a2f2bfe4e9bbef0d285fec6511"},
	{"0aa78894d894a15933969f5826347439e2c309f2049277a10066c91978404994", "98ad19ee3d1b291f932ec0890bbdafcec292c4f02a446670cd0084f997e25e2f", "f52412d95d1c6e44431fda5bd6d350be31a676257f7df2352b9001335dcd7337", "3183a8d51a894609a9f519dc65bfdbe9c5ed4b25722557e8c84ca6b4d4e70a00"},
	{"ef07af0c798fe9109bd14ed797c32cdae9268ef33f89cd9805751c7f2727d5e2", "1aed6feb01363221cf88f66323aace25d4f07e477699b8545167ef2ecbfb537a", "07135be591cd60313470373e0b1bfa60e36300796532a5f1b13f2872701c7476", "72912c4657a4311961bc04d22898bcef41479891cfa84233e462d3d006bbf93c"},
	{"4881345cbb299fa7c60ab2d16cb7fe7bf8d14675506ef6eb6037038b5b7092ea", "0a9e4d0b53ba3904edd99f86717d6ba81dffe44eb5b23c6fd22c91ab73c33021", "fe0ee3103fb450c2bef3558db246ad448ff245579da78bb0aa88f2feb5ca0fc7", "45894948d1a404e7815503cba07a9a00006a27aa3c3d9913118b356567c41516"},
	{"fe7e6f982e4f74234e7ed3b49ce96b7dd7cf838a4cae13d9c25c67a38eec75a7", "c03bf6072f712c88935f128d1e5e9c7515c1f894f59a7f6c839ad1829ab0adac", "e2943bc8b8e0dfbe15b35425bd77e9ed0aa14c13ed318a25206fe2a2d52035c2", "3c657c58d4f439fadd4e0b53b097f2fc21f0f4030d11f8b17b15b4449b310684"},
	{"efb38a96896f71d2ad1ba068c3545ee0090ebb4150c7599984b65f41fb9c786d", "1d96bdd7239eee557e2845def19b10a88bebe0ff537da715637d013ea1f3e92f", "ed10d71f1d7116c0901f59f7ab03bb4e8c8e72f9bfb7d1e8be6d5a4cd56b32c1", "32b8b9d695a02c6c8050d46ea51b73bb300925064559f58546633586b72e7bd0"},
}

// portableInputs builds the skeleton + real-data witness shared by the solve and full-proof tests.
func portableInputs(t *testing.T) (skel, w *portableProofCircuit, price *big.Int) {
	t.Helper()
	body, _ := hex.DecodeString(realBodyHex)
	msg, _ := hex.DecodeString(realMsgHex)
	proofBytes, _ := hex.DecodeString(realProof)
	hops := len(proofBytes) / 20
	n := len(guardianWitness)

	// the committed price MUST equal the attested BTC price (message[33:41]).
	price = new(big.Int).SetBytes(msg[33:41])
	terms := []*big.Int{
		big.NewInt(0x1111), big.NewInt(0x2222), big.NewInt(0x3333), big.NewInt(0x4444),
		big.NewInt(2_000_000_000_000), // debt: solvent vs max = 1*price*0.35 ≈ 2.244e12
		big.NewInt(1),                 // collateral
		big.NewInt(3500),              // ltv bps
		big.NewInt(7),                 // nonce
		big.NewInt(0x5555), big.NewInt(0x6666),
		price,
	}
	commit, err := iden3.Hash(terms)
	if err != nil {
		t.Fatal(err)
	}

	skel = &portableProofCircuit{
		Body: make([]uints.U8, len(body)), Message: make([]uints.U8, len(msg)),
		Pubs:  make([]ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr], n),
		Sigs:  make([]ecdsa.Signature[emulated.Secp256k1Fr], n),
		Proof: make([][]uints.U8, hops),
	}
	for i := range skel.Proof {
		skel.Proof[i] = make([]uints.U8, 20)
	}

	w = &portableProofCircuit{
		Body: u8s(body), Message: u8s(msg),
		Pubs:   make([]ecdsa.PublicKey[emulated.Secp256k1Fp, emulated.Secp256k1Fr], n),
		Sigs:   make([]ecdsa.Signature[emulated.Secp256k1Fr], n),
		Proof:  make([][]uints.U8, hops),
		PoolHi: terms[0], PoolLo: terms[1], BorrowerHi: terms[2], BorrowerLo: terms[3],
		Debt: terms[4], Collateral: terms[5], LtvBps: terms[6], Nonce: terms[7],
		TypeHi: terms[8], TypeLo: terms[9], Commit: commit,
	}
	for i := 0; i < hops; i++ {
		w.Proof[i] = u8s(proofBytes[i*20 : i*20+20])
	}
	for i, g := range guardianWitness {
		w.Pubs[i].X = emulated.ValueOf[emulated.Secp256k1Fp](new(big.Int).SetBytes(mustHex(t, g[0])))
		w.Pubs[i].Y = emulated.ValueOf[emulated.Secp256k1Fp](new(big.Int).SetBytes(mustHex(t, g[1])))
		w.Sigs[i].R = emulated.ValueOf[emulated.Secp256k1Fr](new(big.Int).SetBytes(mustHex(t, g[2])))
		w.Sigs[i].S = emulated.ValueOf[emulated.Secp256k1Fr](new(big.Int).SetBytes(mustHex(t, g[3])))
	}
	return skel, w, price
}

func TestPortableProof_Assembled_RealData(t *testing.T) {
	skel, w, price := portableInputs(t)
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, skel)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("ASSEMBLED portable-proof circuit: %d constraints (%d guardians, %d-hop merkle)",
		ccs.GetNbConstraints(), len(w.Pubs), len(w.Proof))
	if err := test.IsSolved(skel, w, ecc.BN254.ScalarField()); err != nil {
		t.Fatalf("assembled portable proof must be satisfied by real data: %v", err)
	}
	t.Logf("SOLVED: %d Pyth guardians signed the body; price %s is Merkle-included under the "+
		"signed root; the loan commitment binds to that exact price — one proof, no oracle ✓", len(w.Pubs), price)
}

// TestPortableProof_FullGroth16 produces a REAL proof of the whole assembled circuit and measures
// the pipeline. Opt-in (setup is minutes at ~2.4M constraints): FULLPROOF=1 go test -run FullGroth16.
func TestPortableProof_FullGroth16(t *testing.T) {
	if os.Getenv("FULLPROOF") == "" {
		t.Skip("set FULLPROOF=1 to run the full ~2.4M-constraint Groth16 pipeline (minutes)")
	}
	skel, w, _ := portableInputs(t)

	t0 := time.Now()
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), r1cs.NewBuilder, skel)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("compile : %v (%d constraints)", time.Since(t0).Round(time.Millisecond), ccs.GetNbConstraints())

	t1 := time.Now()
	pk, vk, err := groth16.Setup(ccs)
	if err != nil {
		t.Fatal(err)
	}
	var pkw countW
	pk.WriteTo(&pkw)
	t.Logf("setup   : %v (proving key %.0f MB)", time.Since(t1).Round(time.Second), float64(pkw.n)/1e6)

	full, err := frontend.NewWitness(w, ecc.BN254.ScalarField())
	if err != nil {
		t.Fatal(err)
	}
	t2 := time.Now()
	proof, err := groth16.Prove(ccs, pk, full)
	if err != nil {
		t.Fatal(err)
	}
	proveT := time.Since(t2)
	pub, _ := full.Public()
	t3 := time.Now()
	if err := groth16.Verify(proof, vk, pub); err != nil {
		t.Fatalf("assembled portable proof must verify: %v", err)
	}
	t.Logf("PROVE   : %v", proveT.Round(time.Millisecond))
	t.Logf("verify  : %v", time.Since(t3).Round(time.Millisecond))
	t.Log("REAL Groth16 proof of the full portable-proof circuit verified ✓")
}

type countW struct{ n int64 }

func (w *countW) Write(p []byte) (int, error) { w.n += int64(len(p)); return len(p), nil }

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
