// Package pyth parses and (natively) verifies Pyth's "PNAU" accumulator updates: a Wormhole VAA
// attesting a Merkle root of prices, plus a Merkle proof per price. This native reference is the
// spec the in-circuit verifier must mirror, and the generator of its witness data. Every offset
// here is grounded against a real Hermes update (see testdata + vaa_test.go).
//
// The full trust chain a from-scratch verifier must reproduce:
//  1. N guardians sign keccak256(keccak256(body)); each guardian is a keccak-derived address.
//  2. The body payload carries a 20-byte keccak160 Merkle root.
//  3. Each price is a leaf keccak160(0x00 || message); the proof hops keccak160(0x01 || pair) to
//     the root.
package pyth

import (
	"encoding/binary"
	"errors"
	"fmt"
)

type GuardianSig struct {
	Index   uint8
	R, S    [32]byte
	V       uint8 // recovery id
	rawWire [66]byte
}

type PriceUpdate struct {
	Message     []byte     // PriceFeedMessage: the Merkle leaf preimage (with a 0x00 leaf prefix)
	Proof       [][20]byte // keccak160 Merkle path to the root
	FeedID      [32]byte
	Price       int64
	Conf        uint64
	Expo        int32
	PublishTime int64
}

type VAA struct {
	Version          uint8
	GuardianSetIndex uint32
	Signatures       []GuardianSig
	Body             []byte // EXACT bytes the guardians double-keccak and sign
	Timestamp        uint32
	EmitterChain     uint16
	EmitterAddress   [32]byte
	Sequence         uint64
	Payload          []byte
}

type AccumulatorUpdate struct {
	Major, Minor uint8
	VAA          VAA
	MerkleRoot   [20]byte
	Slot         uint64
	RingSize     uint32
	Updates      []PriceUpdate
}

// reader is a big-endian cursor with bounds checking.
type reader struct {
	b   []byte
	o   int
	err error
}

func (r *reader) need(n int) []byte {
	if r.err != nil {
		return nil
	}
	if r.o+n > len(r.b) {
		r.err = fmt.Errorf("pyth: short read at %d (+%d > %d)", r.o, n, len(r.b))
		return nil
	}
	v := r.b[r.o : r.o+n]
	r.o += n
	return v
}
func (r *reader) u8() uint8   { v := r.need(1); if v == nil { return 0 }; return v[0] }
func (r *reader) u16() uint16 { v := r.need(2); if v == nil { return 0 }; return binary.BigEndian.Uint16(v) }
func (r *reader) u32() uint32 { v := r.need(4); if v == nil { return 0 }; return binary.BigEndian.Uint32(v) }
func (r *reader) u64() uint64 { v := r.need(8); if v == nil { return 0 }; return binary.BigEndian.Uint64(v) }

const (
	accumulatorMagic = 0x504e4155 // "PNAU"
	wormholeMerkle   = 0          // update_type
	auwvMagic        = 0x41555756 // "AUWV" — wormhole-merkle payload magic
	priceFeedMsgType = 0          // message type in a leaf
)

// Parse walks a full PNAU accumulator update.
func Parse(raw []byte) (*AccumulatorUpdate, error) {
	r := &reader{b: raw}
	if r.u32() != accumulatorMagic {
		return nil, errors.New("pyth: bad accumulator magic (want PNAU)")
	}
	a := &AccumulatorUpdate{Major: r.u8(), Minor: r.u8()}
	trailing := r.u8()
	r.need(int(trailing)) // skip trailing header
	if ut := r.u8(); ut != wormholeMerkle {
		return nil, fmt.Errorf("pyth: unsupported update_type %d", ut)
	}

	vaaLen := int(r.u16())
	vaaStart := r.o
	if err := parseVAA(r, &a.VAA, vaaStart, vaaLen); err != nil {
		return nil, err
	}
	// payload = wormhole-merkle: magic(4) update_type(1) slot(8) ring_size(4) root(20)
	pr := &reader{b: a.VAA.Payload}
	if pr.u32() != auwvMagic {
		return nil, errors.New("pyth: bad payload magic (want AUWV)")
	}
	pr.u8() // payload update_type
	a.Slot = pr.u64()
	a.RingSize = pr.u32()
	copy(a.MerkleRoot[:], pr.need(20))
	if pr.err != nil {
		return nil, pr.err
	}

	r.o = vaaStart + vaaLen // updates follow the VAA
	n := int(r.u8())
	a.Updates = make([]PriceUpdate, n)
	for i := 0; i < n; i++ {
		if err := parseUpdate(r, &a.Updates[i]); err != nil {
			return nil, err
		}
	}
	if r.err != nil {
		return nil, r.err
	}
	return a, nil
}

func parseVAA(r *reader, v *VAA, vaaStart, vaaLen int) error {
	vaaEnd := vaaStart + vaaLen
	if vaaEnd > len(r.b) {
		return errors.New("pyth: VAA length exceeds buffer")
	}
	v.Version = r.u8()
	v.GuardianSetIndex = r.u32()
	nsig := int(r.u8())
	v.Signatures = make([]GuardianSig, nsig)
	for i := range v.Signatures {
		s := &v.Signatures[i]
		s.Index = r.u8()
		copy(s.R[:], r.need(32))
		copy(s.S[:], r.need(32))
		s.V = r.u8()
	}
	if r.err != nil {
		return r.err
	}
	bodyStart := r.o
	// The body is EXACTLY the bytes from here to the end of the VAA — this is what guardians sign.
	v.Body = r.b[bodyStart:vaaEnd]
	v.Timestamp = r.u32()
	r.u32() // nonce
	v.EmitterChain = r.u16()
	copy(v.EmitterAddress[:], r.need(32))
	v.Sequence = r.u64()
	r.u8() // consistency level
	if r.err != nil {
		return r.err
	}
	v.Payload = r.b[r.o:vaaEnd]
	r.o = vaaEnd
	return nil
}

func parseUpdate(r *reader, u *PriceUpdate) error {
	msgLen := int(r.u16())
	u.Message = append([]byte(nil), r.need(msgLen)...)
	if r.err != nil {
		return r.err
	}
	m := &reader{b: u.Message}
	if t := m.u8(); t != priceFeedMsgType {
		return fmt.Errorf("pyth: unsupported message type %d", t)
	}
	copy(u.FeedID[:], m.need(32))
	u.Price = int64(m.u64())
	u.Conf = m.u64()
	u.Expo = int32(m.u32())
	u.PublishTime = int64(m.u64())
	if m.err != nil {
		return m.err
	}
	nhash := int(r.u8())
	u.Proof = make([][20]byte, nhash)
	for i := range u.Proof {
		copy(u.Proof[i][:], r.need(20))
	}
	return r.err
}
