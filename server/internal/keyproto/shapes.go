package keyproto

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"regexp"

	"filippo.io/edwards25519"
)

const (
	WrapSize       = 127
	WrapHeaderSize = 46
	WrapVersion1   = 0x01
	PhraseBoxSize  = 45
	PhraseBoxV1    = 0x01

	KDFRecovery = 0x01
	KDFPRF      = 0x02

	MinCredentialID = 16
	MaxCredentialID = 1023
)

var ErrShape = errors.New("keyproto: malformed")

func CheckRecoveryWrap(w []byte) error { return checkWrap(w, KDFRecovery) }

func CheckPRFWrap(w []byte) error { return checkWrap(w, KDFPRF) }

func checkWrap(w []byte, kdf byte) error {
	if len(w) != WrapSize {
		return fmt.Errorf("%w: wrap is %d bytes, want %d", ErrShape, len(w), WrapSize)
	}
	if w[0] != WrapVersion1 {
		return fmt.Errorf("%w: wrap version 0x%02x", ErrShape, w[0])
	}
	if w[1] != kdf {
		return fmt.Errorf("%w: wrap kdf 0x%02x, want 0x%02x", ErrShape, w[1], kdf)
	}
	return nil
}

func CheckPhraseBox(b []byte) error {
	if len(b) != PhraseBoxSize {
		return fmt.Errorf("%w: phrase box is %d bytes, want %d", ErrShape, len(b), PhraseBoxSize)
	}
	if b[0] != PhraseBoxV1 {
		return fmt.Errorf("%w: phrase box version 0x%02x", ErrShape, b[0])
	}
	return nil
}

func CheckCredentialID(id []byte) error {
	if len(id) < MinCredentialID || len(id) > MaxCredentialID {
		return fmt.Errorf("%w: credential id is %d bytes", ErrShape, len(id))
	}
	return nil
}

var writerIDGrammar = regexp.MustCompile(`^ios-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func ValidWriterID(id string) bool { return writerIDGrammar.MatchString(id) }

func CheckEd25519PublicKey(pub []byte) error {
	if len(pub) != ed25519.PublicKeySize {
		return fmt.Errorf("%w: Ed25519 key is %d bytes", ErrShape, len(pub))
	}
	p, err := new(edwards25519.Point).SetBytes(pub)
	if err != nil {
		return fmt.Errorf("%w: Ed25519 key is not a curve point", ErrShape)
	}
	if new(edwards25519.Point).MultByCofactor(p).Equal(edwards25519.NewIdentityPoint()) == 1 {
		return fmt.Errorf("%w: Ed25519 key has small order", ErrShape)
	}
	return nil
}

func VerifyEd25519(pub, msg, sig []byte) bool {
	if CheckEd25519PublicKey(pub) != nil || len(sig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(pub), msg, sig)
}

func InviteLinkKeyMatches(linkKey, linkKeyHash []byte) bool {
	if len(linkKey) != 32 || len(linkKeyHash) != 32 {
		return false
	}
	h := sha256.Sum256(linkKey)
	return subtle.ConstantTimeCompare(h[:], linkKeyHash) == 1
}

func distinct(keys ...[]byte) bool {
	for i := range keys {
		for j := i + 1; j < len(keys); j++ {
			if bytes.Equal(keys[i], keys[j]) {
				return false
			}
		}
	}
	return true
}
