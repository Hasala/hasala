package authkeys

import (
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync/atomic"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

const (
	KeySize          = 32
	PasswordSaltSize = 16
	VerifierSize     = 32
	ServerIterations = 100_000
	CodeDigits       = 6
)

var codePurposes = []string{
	"signup", "email_verify", "email_change_old", "email_change_new",
	"password_reset", "recovery", "waitlist",
}

func CodePurposes() []string { return append([]string(nil), codePurposes...) }

var ErrKeyFile = errors.New("authkeys: a key file holds exactly 64 hex characters")

func ParseKeyHex(s string) ([]byte, error) {
	s = strings.TrimSuffix(strings.TrimSuffix(s, "\n"), "\r")
	if len(s) != 2*KeySize {
		return nil, ErrKeyFile
	}
	k, err := hex.DecodeString(s)
	if err != nil {
		return nil, ErrKeyFile
	}
	return k, nil
}

type Keys struct {
	kSalt   []byte
	peppers map[int][]byte
	current int
	kCode   []byte
	kTag    []byte
	kInvite []byte

	SaltKeyID string
	AuthKeyID map[int]string

	hashes atomic.Int64
}

func (k *Keys) HashCount() int64 { return k.hashes.Load() }

func New(saltKey []byte, authKeys map[int][]byte, current int) (*Keys, error) {
	if len(saltKey) != KeySize {
		return nil, fmt.Errorf("authkeys: salt_key is %d bytes, want %d", len(saltKey), KeySize)
	}
	cur, ok := authKeys[current]
	if !ok {
		return nil, fmt.Errorf("authkeys: no auth_key for the current generation %d", current)
	}
	k := &Keys{
		peppers:   map[int][]byte{},
		current:   current,
		SaltKeyID: KeyID(saltKey),
		AuthKeyID: map[int]string{},
	}
	var err error
	if k.kSalt, err = subkey(saltKey, keyproto.DomainServerPasswordSalt); err != nil {
		return nil, err
	}
	for g, ak := range authKeys {
		if g < 1 {
			return nil, fmt.Errorf("authkeys: generation %d is not ≥ 1", g)
		}
		if len(ak) != KeySize {
			return nil, fmt.Errorf("authkeys: auth_key generation %d is %d bytes, want %d", g, len(ak), KeySize)
		}
		if k.peppers[g], err = subkey(ak, keyproto.DomainServerPasswordPeppr); err != nil {
			return nil, err
		}
		k.AuthKeyID[g] = KeyID(ak)
	}
	if k.kCode, err = subkey(cur, keyproto.DomainServerEmailCode); err != nil {
		return nil, err
	}
	if k.kTag, err = subkey(cur, keyproto.DomainServerEmailTag); err != nil {
		return nil, err
	}
	if k.kInvite, err = subkey(cur, keyproto.DomainServerInviteMint); err != nil {
		return nil, err
	}
	return k, nil
}

func (k *Keys) Current() int { return k.current }

func subkey(ikm []byte, info string) ([]byte, error) {
	return hkdf.Key(sha256.New, ikm, make([]byte, 32), info, KeySize)
}

func mac(key []byte, parts ...[]byte) []byte {
	h := hmac.New(sha256.New, key)
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

func KeyID(k []byte) string {
	return hex.EncodeToString(mac(k, []byte(keyproto.DomainServerAuthKeyID))[:8])
}

func (k *Keys) PasswordSalt(emailNorm string) []byte {
	return mac(k.kSalt, []byte(emailNorm))
}

func (k *Keys) EmailTag(emailNorm string) []byte {
	return mac(k.kTag, []byte(emailNorm))
}

func (k *Keys) InviteSecrets(inviteID uuid.UUID, mailID int64) (code, link []byte) {
	return inviteSecrets(k.kInvite, inviteID, mailID)
}

func inviteSecrets(key []byte, inviteID uuid.UUID, mailID int64) (code, link []byte) {
	id := binary.BigEndian.AppendUint64(nil, uint64(mailID))
	code = mac(key, []byte("code"), []byte{0}, inviteID[:], id)[:15]
	link = mac(key, []byte("link"), []byte{0}, inviteID[:], id)
	return code, link
}

func (k *Keys) CodeMAC(purpose string, codeID uuid.UUID, emailTag []byte, code string) ([]byte, error) {
	if !slices.Contains(codePurposes, purpose) {
		return nil, fmt.Errorf("authkeys: %q is not a code purpose", purpose)
	}
	if len(emailTag) != 32 {
		return nil, fmt.Errorf("authkeys: email_tag is %d bytes", len(emailTag))
	}
	if len(code) != CodeDigits {
		return nil, fmt.Errorf("authkeys: a code is %d digits", CodeDigits)
	}
	for i := 0; i < len(code); i++ {
		if code[i] < '0' || code[i] > '9' {
			return nil, fmt.Errorf("authkeys: a code is %d digits", CodeDigits)
		}
	}
	return mac(k.kCode, []byte(purpose), []byte{0}, codeID[:], emailTag, []byte(code)), nil
}

func (k *Keys) CodeMatches(stored []byte, purpose string, codeID uuid.UUID, emailTag []byte, code string) bool {
	m, err := k.CodeMAC(purpose, codeID, emailTag, code)
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare(m, stored) == 1
}

func (k *Keys) Pepper(s []byte, generation int) ([]byte, error) {
	kp, ok := k.peppers[generation]
	if !ok {
		return nil, fmt.Errorf("authkeys: no pepper for generation %d", generation)
	}
	if len(s) != VerifierSize {
		return nil, fmt.Errorf("authkeys: a verifier S is %d bytes", VerifierSize)
	}
	return mac(kp, s), nil
}

func (k *Keys) VerifierHash(s, pwSalt []byte, generation int) ([]byte, error) {
	if len(pwSalt) != PasswordSaltSize {
		return nil, fmt.Errorf("authkeys: pw_salt is %d bytes, want %d", len(pwSalt), PasswordSaltSize)
	}
	p, err := k.Pepper(s, generation)
	if err != nil {
		return nil, err
	}
	k.hashes.Add(1)
	return pbkdf2.Key(sha256.New, string(p), pwSalt, ServerIterations, VerifierSize)
}
