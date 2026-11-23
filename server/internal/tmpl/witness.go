package tmpl

import "unicode/utf8"

func (d Definition) DecodeWitnesses() []string {
	if d.IsSMS() {
		return nil
	}
	var out []string
	for _, s := range d.Match.BodyContains {
		if hasNonASCII(s) {
			out = append(out, s)
		}
	}
	return out
}

func hasNonASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= utf8.RuneSelf {
			return true
		}
	}
	return false
}
