package keyproto

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"fmt"
	"math/big"
)

func ParseDAK(b []byte) (*ecdsa.PublicKey, error) {
	if len(b) != DAKKeySize || b[0] != 0x04 {
		return nil, fmt.Errorf("%w: DAK is not a 65-byte uncompressed point", ErrShape)
	}
	pub, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), b)
	if err != nil {
		return nil, fmt.Errorf("%w: DAK: %v", ErrShape, err)
	}
	return pub, nil
}

func VerifyDAK(pub *ecdsa.PublicKey, msg, sig []byte) bool {
	if pub == nil || len(sig) != DAKSigSize {
		return false
	}
	n := elliptic.P256().Params().N
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if r.Sign() == 0 || s.Sign() == 0 || r.Cmp(n) >= 0 || s.Cmp(n) >= 0 {
		return false
	}
	h := sha256.Sum256(msg)
	return ecdsa.Verify(pub, h[:], r, s)
}

func VerifyDAKBytes(dak, msg, sig []byte) bool {
	pub, err := ParseDAK(dak)
	if err != nil {
		return false
	}
	return VerifyDAK(pub, msg, sig)
}
