package tmpl

import (
	"slices"
	"testing"
)

const arabicGate = "إشعار مشتريات"

func TestAnASCIIOnlyGateLiteralIsNotAWitness(t *testing.T) {
	for _, s := range []string{
		"Purchase alert",
		"Transaction Alert",
		"AED",
		"",
		"~!@#$%^&*()_+-=[]{}|;':\",./<>?",
	} {
		d := Definition{Match: Match{BodyContains: []string{s}}}
		if got := d.DecodeWitnesses(); len(got) != 0 {
			t.Errorf("DecodeWitnesses() = %q for the ASCII literal %q, want none", got, s)
		}
	}
}

func TestANonASCIIGateLiteralIsAWitness(t *testing.T) {
	for _, s := range []string{
		arabicGate,
		"إشعار إيداع",
		"é",
		"Amount\u00a0x",
	} {
		d := Definition{Match: Match{BodyContains: []string{s}}}
		if got := d.DecodeWitnesses(); !slices.Equal(got, []string{s}) {
			t.Errorf("DecodeWitnesses() = %q for %q, want [%q]", got, s, s)
		}
	}
}

func TestDecodeWitnessesFiltersRatherThanAllOrNothing(t *testing.T) {
	d := Definition{Match: Match{BodyContains: []string{
		"Purchase alert", arabicGate, "Card", "إشعار إيداع",
	}}}
	want := []string{arabicGate, "إشعار إيداع"}
	if got := d.DecodeWitnesses(); !slices.Equal(got, want) {
		t.Errorf("DecodeWitnesses() = %q, want %q", got, want)
	}
}

func TestOnlyBodyContainsCanWitness(t *testing.T) {
	subject := Definition{Match: Match{SubjectContains: []string{arabicGate}}}
	if got := subject.DecodeWitnesses(); len(got) != 0 {
		t.Errorf("a subject_contains literal witnessed the body decode: %q", got)
	}
	exclusion := Definition{Match: Match{BodyNotContains: []string{arabicGate}}}
	if got := exclusion.DecodeWitnesses(); len(got) != 0 {
		t.Errorf("a body_not_contains literal witnessed the decode: %q", got)
	}
	both := Definition{Match: Match{
		SubjectContains: []string{arabicGate},
		BodyNotContains: []string{"إشعار إيداع"},
		BodyContains:    []string{"Purchase alert"},
	}}
	if got := both.DecodeWitnesses(); len(got) != 0 {
		t.Errorf("DecodeWitnesses() = %q; the only body_contains entry is ASCII", got)
	}
}

func TestDecodeWitnessesReturnsTheLiteralsVerbatim(t *testing.T) {
	d := Definition{Match: Match{BodyContains: []string{arabicGate}}}
	got := d.DecodeWitnesses()
	if len(got) != 1 || got[0] != d.Match.BodyContains[0] {
		t.Fatalf("DecodeWitnesses() = %q, want the definition's own literal", got)
	}
}
