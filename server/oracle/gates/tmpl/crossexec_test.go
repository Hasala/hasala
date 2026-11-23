package tmpl_test

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	. "github.com/salehtl/hasala/server/internal/tmpl"
	"os"
	"testing"

	"github.com/salehtl/hasala/server/internal/norm"
	"github.com/salehtl/hasala/server/oracle/corpus"
)

type crossExecTemplateRow struct {
	Template   string `json:"template"`
	Definition string `json:"definition_base64"`
	ID         int64  `json:"id"`
	Subject    string `json:"subject_base64"`
	Body       string `json:"normalized_body_base64"`

	Expect TemplateExpect `json:"expect"`
}

func TestWriteCrossExecutorTemplates(t *testing.T) {
	out := os.Getenv("HASALA_CROSSEXEC_OUT")
	if out == "" {
		t.Skip("HASALA_CROSSEXEC_OUT is unset; this exports the corpus for the TypeScript differ")
	}
	path := os.Getenv("HASALA_CORPUS_DB")
	if path == "" {
		t.Fatal("HASALA_CROSSEXEC_OUT is set but HASALA_CORPUS_DB is not; a typo must not silently skip the check")
	}
	db, err := corpus.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	defs, raws, err := LoadMailSeedTemplates(seedDir)
	if err != nil {
		t.Fatal(err)
	}
	compiled := make([]*Compiled, len(defs))
	for i, d := range defs {
		c, err := Compile(d)
		if err != nil {
			t.Fatal(err)
		}
		compiled[i] = c
	}

	f, err := os.Create(out)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	w := bufio.NewWriterSize(f, 1<<20)
	enc := json.NewEncoder(w)

	var rows, matched, normFailed int
	err = db.Each(func(m corpus.Message) error {
		dom := senderDomain(m.FromAddr)
		r, err := norm.Normalize(norm.CurrentVersion, m.RawBody, m.ReceivedAt)
		if err != nil {
			normFailed++
			return nil
		}
		subject := base64.StdEncoding.EncodeToString([]byte(r.Subject))
		body := base64.StdEncoding.EncodeToString([]byte(r.Text))
		for i, d := range defs {
			if !MatchesSenderDomain(d, dom) {
				continue
			}
			e, execErr := compiled[i].Execute(r.Subject, r.Text)
			if e.Matched {
				matched++
			}
			rows++
			if err := enc.Encode(crossExecTemplateRow{
				Template:   d.ID,
				Definition: base64.StdEncoding.EncodeToString(raws[i]),
				ID:         m.ID,
				Subject:    subject,
				Body:       body,
				Expect:     ExpectOf(e, execErr),
			}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	t.Logf("wrote %s: %d rows, %d matched, %d messages the normalizer refused", out, rows, matched, normFailed)
	if rows == 0 {
		t.Fatal("no rows written; the corpus snapshot holds no mail from any seed template's sender")
	}
}
