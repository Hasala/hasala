package tmpl

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

const CorpusTemplateDir = "conformance/templates"

var MailSeedTemplateFiles = []string{
	"dib.card.v1.json",
	"dib.account.v1.json",
	"dib.transfer.v1.json",
	"dib.money-transfer.v1.json",
	"dib.card-refund.v1.json",
	"dib.card-reversal.v1.json",
	"enbd.alert.v1.json",
	"enbd.transfer.v1.json",
	"adib.alert.v1.json",
	"adib.account.v1.json",
}

type TemplateFixture struct {
	Note              string          `json:"note"`
	Spec              string          `json:"spec"`
	SchemaVersion     int             `json:"schema_version"`
	Template          string          `json:"template"`
	Kind              string          `json:"kind"`
	NormalizerVersion int             `json:"normalizer_version"`
	Definition        json.RawMessage `json:"definition"`
	Cases             []TemplateCase  `json:"cases"`
}

type TemplateCase struct {
	Name                 string         `json:"name"`
	Source               string         `json:"source"`
	SubjectBase64        string         `json:"subject_base64"`
	NormalizedBodyBase64 string         `json:"normalized_body_base64"`
	Expect               TemplateExpect `json:"expect"`
}

type TemplateExpect struct {
	Matched     bool     `json:"matched"`
	Error       string   `json:"error"`
	AmountMinor string   `json:"amount_minor"`
	Currency    string   `json:"currency"`
	Direction   string   `json:"direction"`
	PostedAt    string   `json:"posted_at"`
	Merchant    string   `json:"merchant"`
	Last4       string   `json:"last4"`
	IsTransfer  bool     `json:"is_transfer"`
	EmptyGroups []string `json:"empty_groups"`
}

func ErrorKind(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, ErrNoMatch):
		return "no_match"
	case errors.Is(err, ErrMissingField):
		return "missing_field"
	case errors.Is(err, ErrTooLarge):
		return "too_large"
	case errors.Is(err, ErrDefinition):
		return "definition"
	default:
		return "other"
	}
}

func ExpectOf(e Extraction, err error) TemplateExpect {
	posted := ""
	if !e.PostedAt.IsZero() {
		posted = e.PostedAt.UTC().Format(time.RFC3339)
	}
	groups := e.EmptyGroups
	if groups == nil {
		groups = []string{}
	}
	return TemplateExpect{
		Matched:     e.Matched,
		Error:       ErrorKind(err),
		AmountMinor: strconv.FormatInt(e.AmountMinor, 10),
		Currency:    e.Currency,
		Direction:   e.Direction,
		PostedAt:    posted,
		Merchant:    e.Merchant,
		Last4:       e.Last4,
		IsTransfer:  e.IsTransfer,
		EmptyGroups: groups,
	}
}

func LoadMailSeedTemplates(dir string) ([]Definition, []json.RawMessage, error) {
	defs := make([]Definition, 0, len(MailSeedTemplateFiles))
	raws := make([]json.RawMessage, 0, len(MailSeedTemplateFiles))
	for _, name := range MailSeedTemplateFiles {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, nil, err
		}
		d, err := ParseDefinition(b)
		if err != nil {
			return nil, nil, fmt.Errorf("%s: %w", name, err)
		}
		if err := ValidateForPublish(d); err != nil {
			return nil, nil, fmt.Errorf("%s: a fixture may only be written from a PUBLISHABLE template: %w", name, err)
		}
		var compact bytes.Buffer
		if err := json.Compact(&compact, b); err != nil {
			return nil, nil, err
		}
		defs = append(defs, d)
		raws = append(raws, json.RawMessage(compact.Bytes()))
	}
	return defs, raws, nil
}

func EncodeTemplateFixture(f TemplateFixture) ([]byte, error) {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	e.SetIndent("", "  ")
	if err := e.Encode(f); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}
