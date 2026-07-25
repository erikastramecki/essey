package pyth

import (
	"github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
)

// GuardianWitness is one recovered guardian signature ready to feed a circuit: the signer's public
// key (X,Y) and the signature (R,S) over the VAA digest.
type GuardianWitness struct {
	PubX, PubY [32]byte
	SigR, SigS [32]byte
}

// PriceWitness is one price's circuit witness: the leaf message and its Merkle path to the root.
type PriceWitness struct {
	Message []byte
	Proof   [][20]byte
	Price   int64
}

// Witness is everything a portable-proof circuit needs from one accumulator update.
type Witness struct {
	Body      []byte           // guardians sign keccak256(keccak256(Body))
	Digest    [32]byte         // the double-keccak the signatures verify against
	Root      [20]byte         // Merkle root, extracted from Body[68:88]
	Guardians []GuardianWitness
	Prices    []PriceWitness
}

// BuildWitness parses an update and recovers each guardian's public key from its signature, so a
// circuit (which pins pubkeys and verifies, rather than recovers) has ready witness data. It only
// returns successfully if the update passes native verification against `set`.
func BuildWitness(raw []byte, set []Address) (*Witness, error) {
	a, err := Parse(raw)
	if err != nil {
		return nil, err
	}
	if err := Verify(a, set); err != nil {
		return nil, err
	}
	digest := keccak256(keccak256(a.VAA.Body))
	w := &Witness{Body: a.VAA.Body}
	copy(w.Digest[:], digest)
	w.Root = a.MerkleRoot

	for _, s := range a.VAA.Signatures {
		var compact [65]byte
		if s.V >= 27 {
			compact[0] = s.V
		} else {
			compact[0] = 27 + s.V
		}
		copy(compact[1:33], s.R[:])
		copy(compact[33:65], s.S[:])
		pub, _, err := ecdsa.RecoverCompact(compact[:], digest)
		if err != nil {
			return nil, err
		}
		un := pub.SerializeUncompressed() // 0x04 || X || Y
		var g GuardianWitness
		copy(g.PubX[:], un[1:33])
		copy(g.PubY[:], un[33:65])
		g.SigR = s.R
		g.SigS = s.S
		w.Guardians = append(w.Guardians, g)
	}
	for _, u := range a.Updates {
		w.Prices = append(w.Prices, PriceWitness{Message: u.Message, Proof: u.Proof, Price: u.Price})
	}
	return w, nil
}
