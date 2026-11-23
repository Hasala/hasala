package dict

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode"
)

const K = 3

const (
	MatchContains = "contains"
	MatchExact    = "exact"
)

const (
	maxPatternRunes  = 64
	minPatternRunes  = 2
	minContainsRunes = 4
	maxCategoryRunes = 32
)

var (
	ErrInvalidEntry = errors.New("dict: invalid entry")
)

type Entry struct {
	Pattern  string `json:"pattern"`
	Match    string `json:"match"`
	Category string `json:"category"`
}

func Canonicalize(e Entry) (Entry, error) {
	if hasLineBreak(e.Pattern) || hasLineBreak(e.Category) {
		return Entry{}, fmt.Errorf("%w: a pattern and a category are each a single line", ErrInvalidEntry)
	}
	out := Entry{
		Pattern:  collapse(e.Pattern),
		Match:    strings.ToLower(strings.TrimSpace(e.Match)),
		Category: collapse(e.Category),
	}
	if out.Match == "" {
		out.Match = MatchContains
	}
	if !slices.Contains([]string{MatchContains, MatchExact}, out.Match) {
		return Entry{}, fmt.Errorf("%w: match must be one of %v (a regex published to every "+
			"client is a fleet-wide execution surface)", ErrInvalidEntry,
			[]string{MatchContains, MatchExact})
	}
	minRunes := minPatternRunes
	if out.Match == MatchContains {
		minRunes = minContainsRunes
	}
	if n := len([]rune(out.Pattern)); n < minRunes || n > maxPatternRunes {
		return Entry{}, fmt.Errorf("%w: a %q pattern must be %d..%d characters, got %d",
			ErrInvalidEntry, out.Match, minRunes, maxPatternRunes, n)
	}
	if !hasAlnum(out.Pattern) {
		return Entry{}, fmt.Errorf("%w: pattern must contain a letter or a digit; a pattern of "+
			"pure punctuation matches merchants it has nothing to do with", ErrInvalidEntry)
	}
	if hasUnprintable(out.Pattern) {
		return Entry{}, fmt.Errorf("%w: pattern must be a single line of printable text", ErrInvalidEntry)
	}
	if n := len([]rune(out.Category)); n < 2 || n > maxCategoryRunes {
		return Entry{}, fmt.Errorf("%w: category must be 2..%d characters, got %d",
			ErrInvalidEntry, maxCategoryRunes, n)
	}
	if !isCategoryLabel(out.Category) {
		return Entry{}, fmt.Errorf("%w: category must be a short label of letters, digits, "+
			"spaces and -_/&, not free text", ErrInvalidEntry)
	}
	return out, nil
}

func collapse(s string) string {
	return strings.ToLower(strings.Join(strings.Fields(s), " "))
}

func hasLineBreak(s string) bool {
	return strings.ContainsAny(s, "\n\r\v\f  ")
}

func hasAlnum(s string) bool {
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return true
		}
	}
	return false
}

func hasUnprintable(s string) bool {
	for _, r := range s {
		if r == ' ' {
			continue
		}
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) || unicode.Is(unicode.Co, r) ||
			unicode.Is(unicode.Cs, r) || !unicode.IsPrint(r) {
			return true
		}
	}
	return false
}

func isCategoryLabel(s string) bool {
	if s == "" {
		return false
	}
	for i, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
		case i > 0 && (r == ' ' || r == '_' || r == '/' || r == '&' || r == '-'):
		default:
			return false
		}
	}
	return true
}
