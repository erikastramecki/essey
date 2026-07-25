package pyth

import "strings"

// GuardianSet7 is the Wormhole mainnet guardian set at index 7 (the current active set;
// getCurrentGuardianSetIndex() == 7). Fetched from the Wormhole core contract on Ethereum
// (0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B, getGuardianSet(7)) — expirationTime 0 = active.
//
// A guardian is identified on-chain by its 20-byte address, which is keccak256(pubkey)[12:]. The
// VAA carries each signature with the guardian's INDEX into this set, so verification recovers the
// signer address from the signature and checks it equals GuardianSet7[index].
var GuardianSet7 = mustAddrs([]string{
	"0x5893B5A76c3f739645648885bDCcC06cd70a3Cd3",
	"0xfF6CB952589BDE862c25Ef4392132fb9D4A42157",
	"0x114De8460193bdf3A2fCf81f86a09765F4762fD1",
	"0x107A0086b32d7A0977926A205131d8731D39cbEB",
	"0x8C82B2fd82FaeD2711d59AF0F2499D16e726f6b2",
	"0x42579bFFbCF4276E290aB8E4C162bd4052b97970",
	"0x938f104AEb5581293216ce97d771e0CB721221B1",
	"0xF3ea0AD4FFB5a178AE4EBc21861651B25BdcbB91",
	"0x9D16870160e703324D057c3361c34C5beFBa2c34",
	"0x000aC0076727b35FBea2dAc28fEE5cCB0fEA768e",
	"0xAF45Ced136b9D9e24903464AE889F5C8a723FC14",
	"0xf93124b7c738843CBB89E864c862c38cddCccF95",
	"0xD2CC37A4dc036a8D232b48f62cDD4731412f4890",
	"0xDA798F6896A3331F64b48c12D1D57Fd9cbe70811",
	"0xaE565927Bb8dB25CD8Bf3e7BB663D70023e4Ea78",
	"0x3F851Ad586A47ceF8d04748f33ab0D71395f06b4",
	"0x178e21ad2E77AE06711549CFBB1f9c7a9d8096e8",
	"0x7899cEAB1DC961Dae9defDB7A4f521269a5448FC",
	"0x61D9800f9FCb4160FB0C6cf3A0902592bAC2B434",
})

// Quorum is the 2/3+1 threshold over 19 guardians = 13.
const Quorum = 13

type Address [20]byte

func mustAddrs(ss []string) []Address {
	out := make([]Address, len(ss))
	for i, s := range ss {
		s = strings.TrimPrefix(s, "0x")
		for j := 0; j < 20; j++ {
			out[i][j] = hexByte(s[2*j])<<4 | hexByte(s[2*j+1])
		}
	}
	return out
}

func hexByte(c byte) byte {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10
	}
	return 0
}
