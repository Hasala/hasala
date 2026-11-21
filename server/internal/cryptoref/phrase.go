package cryptoref

import (
	"crypto/pbkdf2"
	"crypto/sha256"
	"fmt"
	"strings"

	"golang.org/x/text/unicode/norm"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

var wordlist = strings.Fields(wordlistText)

var wordIndex = func() map[string]int {
	m := make(map[string]int, len(wordlist))
	for i, w := range wordlist {
		m[w] = i
	}
	return m
}()

func Wordlist() []string { return append([]string(nil), wordlist...) }

func Words(e []byte) []string {
	if len(e) != EntropySize {
		panic("cryptoref: phrase entropy is 16 bytes")
	}
	cs := sha256.Sum256(e)
	bits := append(append([]byte(nil), e...), cs[0]&0xf0)
	out := make([]string, 12)
	for i := 0; i < 12; i++ {
		v := 0
		for j := 0; j < 11; j++ {
			bit := i*11 + j
			v = v<<1 | int(bits[bit/8]>>(7-bit%8))&1
		}
		out[i] = wordlist[v]
	}
	return out
}

type PhraseError struct {
	Kind  string
	Count int
	Index int
	Word  string
}

func (e *PhraseError) Error() string {
	switch e.Kind {
	case "length":
		return fmt.Sprintf("length(%d)", e.Count)
	case "unknownWord":
		return fmt.Sprintf("unknownWord(%d, %q)", e.Index, e.Word)
	}
	return e.Kind
}

func isW(r rune) bool {
	switch {
	case r >= 0x09 && r <= 0x0d, r == 0x20, r == 0xa0, r == 0x1680,
		r >= 0x2000 && r <= 0x200a, r == 0x2028, r == 0x2029, r == 0x202f,
		r == 0x205f, r == 0x3000, r == 0xfeff:
		return true
	}
	return false
}

func NormalizePhrase(input string) []string {
	s := strings.ToLower(norm.NFKD.String(input))
	var b strings.Builder
	inRun := false
	for _, r := range s {
		if isW(r) {
			if !inRun {
				b.WriteByte(' ')
			}
			inRun = true
			continue
		}
		inRun = false
		b.WriteRune(r)
	}
	t := strings.Trim(b.String(), " ")
	if t == "" {
		return nil
	}
	return strings.Split(t, " ")
}

func ParsePhrase(input string) ([]byte, error) {
	words := NormalizePhrase(input)
	if len(words) != 12 {
		return nil, &PhraseError{Kind: "length", Count: len(words)}
	}
	idx := make([]int, 12)
	for i, w := range words {
		v, ok := wordIndex[w]
		if !ok {
			return nil, &PhraseError{Kind: "unknownWord", Index: i, Word: w}
		}
		idx[i] = v
	}
	bits := make([]byte, 17)
	for i, v := range idx {
		for j := 0; j < 11; j++ {
			if v>>(10-j)&1 == 1 {
				bit := i*11 + j
				bits[bit/8] |= 1 << (7 - bit%8)
			}
		}
	}
	e := bits[:16]
	cs := sha256.Sum256(e)
	if bits[16]&0xf0 != cs[0]&0xf0 {
		return nil, &PhraseError{Kind: "checksum"}
	}
	return append([]byte(nil), e...), nil
}

const StretchIterations = 600_000

func PasswordSaltC(sSrv []byte, emailNorm string) []byte {
	return cat(dom(keyproto.DomainPassword), sSrv, []byte(emailNorm))
}

func NFC(s string) string { return norm.NFC.String(s) }

func Stretch(password string, sSrv []byte, emailNorm string) []byte {
	pw := norm.NFC.String(password)
	k, err := pbkdf2.Key(sha256.New, pw, PasswordSaltC(sSrv, emailNorm), StretchIterations, 32)
	if err != nil {
		panic(err)
	}
	return k
}
