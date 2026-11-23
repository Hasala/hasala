package norm_test

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	. "github.com/salehtl/hasala/server/internal/norm"
	"os"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/oracle/corpus"
)

type crossExecRow struct {
	ID         int64  `json:"id"`
	ReceivedAt string `json:"received_at"`
	RawBase64  string `json:"raw_base64"`

	Error      string `json:"error"`
	Text       string `json:"text_base64"`
	Part       string `json:"part"`
	Charset    string `json:"charset"`
	Subject    string `json:"subject_base64"`
	From       string `json:"from_base64"`
	Forwarded  bool   `json:"forwarded"`
	EmailDate  string `json:"email_date"`
	DateSource string `json:"date_source"`
}

func TestWriteCrossExecutorCorpus(t *testing.T) {
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

	f, err := os.Create(out)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	w := bufio.NewWriterSize(f, 1<<20)
	enc := json.NewEncoder(w)

	var n, failed int
	err = db.Each(func(m corpus.Message) error {
		row := crossExecRow{
			ID:         m.ID,
			ReceivedAt: m.ReceivedAt.UTC().Format(time.RFC3339),
			RawBase64:  base64.StdEncoding.EncodeToString(m.RawBody),
		}
		res, nerr := Normalize(CurrentVersion, m.RawBody, m.ReceivedAt.UTC())
		switch {
		case nerr == ErrNoTextPart:
			row.Error = "no_text_part"
			failed++
		case nerr != nil:
			row.Error = nerr.Error()
			failed++
		default:
			row.Text = base64.StdEncoding.EncodeToString([]byte(res.Text))
			row.Part = res.PartUsed
			row.Charset = res.Charset
			row.Subject = base64.StdEncoding.EncodeToString([]byte(res.Subject))
			row.From = base64.StdEncoding.EncodeToString([]byte(res.From))
			row.Forwarded = res.Forwarded
			row.EmailDate = res.EmailDate.UTC().Format(time.RFC3339)
			row.DateSource = res.DateSource
		}
		n++
		return enc.Encode(&row)
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	t.Logf("wrote %d rows (%d normalizer errors) to %s", n, failed, out)
}
