package keyproto

import (
	"crypto/sha256"
	"encoding/base32"
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

var ErrBadEmail = errors.New("keyproto: not an address this beta accepts")

func EmailNorm(x string) (string, error) {
	for i := 0; i < len(x); i++ {
		c := x[i]
		if c != 0x09 && (c < 0x20 || c > 0x7e) {
			return "", ErrBadEmail
		}
	}
	s := strings.Trim(x, " \t")
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	s = string(b)
	if len(s) < 3 || len(s) > 254 || strings.Count(s, "@") != 1 {
		return "", ErrBadEmail
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x21 {
			return "", ErrBadEmail
		}
	}
	at := strings.IndexByte(s, '@')
	local, domain := s[:at], s[at+1:]
	if len(local) < 1 || len(local) > 64 || len(domain) < 1 || len(domain) > 253 {
		return "", ErrBadEmail
	}
	if domain[0] == '.' || domain[len(domain)-1] == '.' || !strings.Contains(domain, ".") {
		return "", ErrBadEmail
	}
	return s, nil
}

func EmailHash(emailNorm string) [32]byte { return sha256.Sum256([]byte(emailNorm)) }

func NameOK(x string) bool {
	if !utf8.ValidString(x) {
		return false
	}
	n := utf8.RuneCountInString(x)
	if n < 1 || n > 64 {
		return false
	}
	if x[0] == ' ' || x[len(x)-1] == ' ' || strings.Contains(x, "  ") {
		return false
	}
	for _, r := range x {
		if r == ' ' {
			continue
		}
		if !unicode.IsGraphic(r) || unicode.Is(unicode.Zs, r) {
			return false
		}
	}
	return true
}

func ResetCode(ekPub []byte) (code80 []byte, code string, err error) {
	if err := need("ek_pub", ekPub, Ed25519KeySize); err != nil {
		return nil, "", err
	}
	m := prefix(DomainResetCode, len(DomainResetCode)+1+32)
	m = append(m, ekPub...)
	h := sha256.Sum256(m)
	code80 = append([]byte(nil), h[:10]...)
	return code80, base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(code80), nil
}
