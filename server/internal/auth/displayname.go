package auth

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

var (
	ErrBadName           = errors.New("auth: display name refused")
	ErrBadNameLength     = errors.New("display_name: length")
	ErrBadNameCharacters = errors.New("display_name: characters")
)

func DisplayName(in string) (string, error) {
	if !utf8.ValidString(in) || len(in) > 256 {
		return "", errors.Join(ErrBadName, ErrBadNameCharacters)
	}
	name := strings.Join(strings.FieldsFunc(in, unicode.IsSpace), " ")
	n := utf8.RuneCountInString(name)
	if n < 1 || n > 64 {
		return "", errors.Join(ErrBadName, ErrBadNameLength)
	}
	letters := 0
	rs := []rune(name)
	for i, r := range rs {
		switch {
		case unicode.IsLetter(r):
			letters++
		case unicode.IsMark(r), r == ' ', r == '\'', r == '’', r == '-':
		case r == '.':
			if i+1 < len(rs) && rs[i+1] != ' ' {
				return "", errors.Join(ErrBadName, ErrBadNameCharacters)
			}
		default:
			return "", errors.Join(ErrBadName, ErrBadNameCharacters)
		}
	}
	if letters == 0 || !keyproto.NameOK(name) {
		return "", errors.Join(ErrBadName, ErrBadNameCharacters)
	}
	return name, nil
}
