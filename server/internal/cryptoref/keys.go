package cryptoref

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

const (
	EntropySize = 16
	KeySize     = 32
	NonceSize   = 12
	TagSize     = 16
	BodySize    = 65
	BodyV1      = 0x01
)

var (
	ErrUnwrapFailed          = errors.New("unwrapFailed")
	ErrNotThisAccountsPhrase = errors.New("notThisAccountsPhrase")
	ErrAccountKeysMismatch   = errors.New("integrityAlarm(accountKeysMismatch)")
	ErrPhraseBoxMismatch     = errors.New("integrityAlarm(phraseBoxMismatch)")
)

var zeroSalt = make([]byte, 32)

func HKDF(ikm, salt, info []byte) []byte {
	k, err := hkdf.Key(sha256.New, ikm, salt, string(info), KeySize)
	if err != nil {
		panic(err)
	}
	return k
}

func HMAC(key []byte, parts ...[]byte) []byte {
	h := hmac.New(sha256.New, key)
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

func cat(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func dom(d string) []byte { return append([]byte(d), 0x00) }

func PRFSalt() [32]byte { return sha256.Sum256([]byte(keyproto.DomainPRFSaltUnlock)) }

func RKSeed(e []byte) []byte { return HKDF(e, zeroSalt, []byte(keyproto.DomainRecoveryKey)) }

func RK(e []byte) ed25519.PrivateKey { return ed25519.NewKeyFromSeed(RKSeed(e)) }

func RKPub(e []byte) []byte { return RK(e).Public().(ed25519.PublicKey) }

func RWK(e, salt []byte) []byte { return HKDF(e, salt, []byte(keyproto.DomainWrapRecovery)) }

func PWK(p, salt []byte) []byte { return HKDF(p, salt, []byte(keyproto.DomainWrapPRF)) }

func AMKCommit(amk []byte, user uuid.UUID) []byte {
	return HMAC(amk, dom(keyproto.DomainAMKCommitment), user[:])
}

func EpochKey1(amk []byte, user uuid.UUID) []byte {
	return HKDF(amk, user[:], binary.BigEndian.AppendUint32(dom(keyproto.DomainEpochKey), 1))
}

func KPV(amk []byte, user uuid.UUID) []byte {
	return HKDF(amk, user[:], []byte(keyproto.DomainPhraseBoxKey))
}

func Body(amk, aakSeed []byte) []byte { return cat([]byte{BodyV1}, amk, aakSeed) }

func AAKPub(seed []byte) []byte {
	return ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
}

func gcm(key []byte) cipher.AEAD {
	if len(key) != KeySize {
		panic(fmt.Sprintf("cryptoref: key is %d bytes", len(key)))
	}
	b, err := aes.NewCipher(key)
	if err != nil {
		panic(err)
	}
	g, err := cipher.NewGCM(b)
	if err != nil {
		panic(err)
	}
	return g
}

func Seal(key, nonce, pt, ad []byte) []byte {
	if len(nonce) != NonceSize {
		panic("cryptoref: nonce is not 12 bytes")
	}
	return gcm(key).Seal(nil, nonce, pt, ad)
}

func Open(key, nonce, ctTag, ad []byte) ([]byte, error) {
	if len(key) != KeySize || len(nonce) != NonceSize {
		return nil, ErrUnwrapFailed
	}
	pt, err := gcm(key).Open(nil, nonce, ctTag, ad)
	if err != nil {
		return nil, ErrUnwrapFailed
	}
	return pt, nil
}

func wrapAD(header []byte, user uuid.UUID, credentialID []byte) []byte {
	return cat(dom(keyproto.DomainWrap), header, user[:], credentialID)
}

func sealWrap(kdf byte, key, salt, nonce, body []byte, user uuid.UUID, credentialID []byte) []byte {
	if len(salt) != 32 || len(nonce) != NonceSize || len(body) != BodySize {
		panic("cryptoref: wrap input has the wrong length")
	}
	header := cat([]byte{keyproto.WrapVersion1, kdf}, salt, nonce)
	return cat(header, Seal(key, nonce, body, wrapAD(header, user, credentialID)))
}

func SealRecoveryWrap(e, salt, nonce, body []byte, user uuid.UUID) []byte {
	return sealWrap(keyproto.KDFRecovery, RWK(e, salt), salt, nonce, body, user, nil)
}

func SealPRFWrap(p, salt, nonce, body []byte, user uuid.UUID, credentialID []byte) []byte {
	return sealWrap(keyproto.KDFPRF, PWK(p, salt), salt, nonce, body, user, credentialID)
}

type Unwrapped struct {
	AMK, AAKSeed []byte
}

type AccountKeys struct {
	User            uuid.UUID
	AMKCommitment   []byte
	AuthorityPubkey []byte
	RecoveryPubkey  []byte
}

func openWrap(kdf byte, keyFor func(salt []byte) []byte, wrap []byte, acct AccountKeys, credentialID []byte) (Unwrapped, error) {
	if len(wrap) != keyproto.WrapSize || wrap[0] != keyproto.WrapVersion1 || wrap[1] != kdf {
		return Unwrapped{}, ErrUnwrapFailed
	}
	header := wrap[:keyproto.WrapHeaderSize]
	salt, nonce := wrap[2:34], wrap[34:46]
	body, err := Open(keyFor(salt), nonce, wrap[keyproto.WrapHeaderSize:], wrapAD(header, acct.User, credentialID))
	if err != nil {
		return Unwrapped{}, ErrUnwrapFailed
	}
	if len(body) != BodySize || body[0] != BodyV1 {
		return Unwrapped{}, ErrUnwrapFailed
	}
	amk, aak := body[1:33], body[33:65]
	if subtle.ConstantTimeCompare(AMKCommit(amk, acct.User), acct.AMKCommitment) != 1 ||
		subtle.ConstantTimeCompare(AAKPub(aak), acct.AuthorityPubkey) != 1 {
		return Unwrapped{}, ErrAccountKeysMismatch
	}
	return Unwrapped{AMK: append([]byte(nil), amk...), AAKSeed: append([]byte(nil), aak...)}, nil
}

func OpenRecoveryWrap(e, wrap []byte, acct AccountKeys) (Unwrapped, error) {
	if subtle.ConstantTimeCompare(RKPub(e), acct.RecoveryPubkey) != 1 {
		return Unwrapped{}, ErrNotThisAccountsPhrase
	}
	return openWrap(keyproto.KDFRecovery, func(salt []byte) []byte { return RWK(e, salt) }, wrap, acct, nil)
}

func OpenPRFWrap(p, wrap []byte, acct AccountKeys, credentialID []byte) (Unwrapped, error) {
	return openWrap(keyproto.KDFPRF, func(salt []byte) []byte { return PWK(p, salt) }, wrap, acct, credentialID)
}

func boxAD(user uuid.UUID, recoveryPub []byte, version byte) []byte {
	return cat(dom(keyproto.DomainPhraseBox), user[:], recoveryPub, []byte{version})
}

func SealPhraseBox(amk []byte, user uuid.UUID, recoveryPub, nonce, e []byte) []byte {
	if len(e) != EntropySize || len(recoveryPub) != 32 {
		panic("cryptoref: phrase box input has the wrong length")
	}
	return cat([]byte{keyproto.PhraseBoxV1}, nonce, Seal(KPV(amk, user), nonce, e, boxAD(user, recoveryPub, keyproto.PhraseBoxV1)))
}

func OpenPhraseBox(amk []byte, user uuid.UUID, recoveryPub, box []byte) ([]byte, error) {
	if len(box) != keyproto.PhraseBoxSize || box[0] != keyproto.PhraseBoxV1 {
		return nil, ErrUnwrapFailed
	}
	e, err := Open(KPV(amk, user), box[1:13], box[13:], boxAD(user, recoveryPub, box[0]))
	if err != nil || len(e) != EntropySize {
		return nil, ErrUnwrapFailed
	}
	if subtle.ConstantTimeCompare(RKPub(e), recoveryPub) != 1 {
		return nil, ErrPhraseBoxMismatch
	}
	return e, nil
}
