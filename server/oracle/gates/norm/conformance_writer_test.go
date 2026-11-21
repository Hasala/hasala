package norm_test

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	. "github.com/salehtl/hasala/server/internal/norm"
	"github.com/salehtl/hasala/server/internal/privatefixtures"
	"github.com/salehtl/hasala/server/oracle/corpus"
)

const writeFixturesEnv = "HASALA_WRITE_CONFORMANCE"

func TestWriteNormalizerFixtures(t *testing.T) {
	if os.Getenv(writeFixturesEnv) == "" {
		t.Skipf("%s is unset; fixtures are committed and regenerated deliberately", writeFixturesEnv)
	}
	path := os.Getenv("HASALA_CORPUS_DB")
	if path == "" {
		t.Skip("HASALA_CORPUS_DB is unset; see server/oracle/corpus for how to make the .backup copy")
	}
	root := privatefixtures.Root()
	if root == "" {
		t.Fatalf("%s is unset: these fixtures are real mail and are written only into a checkout of %s, "+
			"never into this repository", privatefixtures.EnvVar, privatefixtures.Repo)
	}
	outDir := filepath.Join(root, filepath.FromSlash(RealCasesDir))
	db, err := corpus.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	wanted := map[int64]bool{}
	for _, f := range CorpusFixtures {
		wanted[f.ID] = true
	}
	rawByID := map[int64][]byte{}
	recvByID := map[int64]time.Time{}
	if err := db.Each(func(m corpus.Message) error {
		if !wanted[m.ID] {
			return nil
		}
		rawByID[m.ID] = append([]byte(nil), m.RawBody...)
		recvByID[m.ID] = m.ReceivedAt
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	for id := range wanted {
		if _, ok := rawByID[id]; !ok {
			t.Fatalf("corpus id %d is not in %s; the fixture list names explicit ids so a "+
				"regeneration cannot silently re-point at different mail", id, path)
		}
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		t.Fatal(err)
	}

	type manifestEntry struct {
		File    string `json:"file"`
		Name    string `json:"name"`
		Source  string `json:"source"`
		Note    string `json:"note,omitempty"`
		Part    string `json:"expect_part"`
		Charset string `json:"expect_charset"`
		Fwd     bool   `json:"expect_forwarded"`
		DateSrc string `json:"expect_date_source"`
	}
	var entries []manifestEntry

	for _, f := range CorpusFixtures {
		raw := rawByID[f.ID]
		source := fmt.Sprintf("v1 corpus ingest_log id %d, verbatim", f.ID)
		if f.Derive != nil {
			raw = f.Derive(raw)
			source = fmt.Sprintf("v1 corpus ingest_log id %d, DERIVED", f.ID)
		}
		recv := recvByID[f.ID]
		if recv.IsZero() {
			recv = time.Date(2026, 6, 5, 9, 0, 0, 0, time.UTC)
		}
		recv = recv.UTC()

		got, err := Normalize(CurrentVersion, raw, recv)
		if err != nil {
			t.Fatalf("%s: Normalize: %v", f.Name, err)
		}
		c := ConformanceCase{
			Name:                f.Name,
			Note:                f.Note,
			Source:              source,
			NormalizerVersion:   CurrentVersion,
			ReceivedAt:          recv.Format(time.RFC3339),
			RawBase64:           base64.StdEncoding.EncodeToString(raw),
			ExpectTextBase64:    base64.StdEncoding.EncodeToString([]byte(got.Text)),
			ExpectPart:          got.PartUsed,
			ExpectCharset:       got.Charset,
			ExpectSubjectBase64: base64.StdEncoding.EncodeToString([]byte(got.Subject)),
			ExpectFromBase64:    base64.StdEncoding.EncodeToString([]byte(got.From)),
			ExpectForwarded:     got.Forwarded,
			ExpectEmailDate:     got.EmailDate.UTC().Format(time.RFC3339),
			ExpectDateSource:    got.DateSource,
		}
		b, err := json.MarshalIndent(c, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(outDir, f.Name+".json"), append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		entries = append(entries, manifestEntry{
			File: f.Name + ".json", Name: f.Name, Source: source, Note: f.Note,
			Part: got.PartUsed, Charset: got.Charset, Fwd: got.Forwarded, DateSrc: got.DateSource,
		})
	}

	manifest := struct {
		Note              string          `json:"note"`
		Spec              string          `json:"spec"`
		NormalizerVersion int             `json:"normalizer_version"`
		Encoding          string          `json:"encoding"`
		Cases             []manifestEntry `json:"cases"`
	}{
		Note: "Written by server/oracle/gates/norm TestWriteNormalizerFixtures. Regenerate with " +
			"HASALA_WRITE_CONFORMANCE=1 HASALA_CORPUS_DB=/scratch/corpus.db; do not hand-edit. " +
			"Every case is real mail from the operator's own v1 corpus; the four cases marked DERIVED " +
			"are real messages mutated in one named way, because the corpus contains no natural sample " +
			"of the shape. Nothing is redacted: this is a private repository.",
		Spec:              "v2-normalizer-v1 (ledgerd design archive)",
		NormalizerVersion: CurrentVersion,
		Encoding: "expect_text, expect_subject and expect_from are base64 of the exact UTF-8 bytes. " +
			"A JSON string cannot round-trip the raw fallback's output, so the fixture holds bytes, not text.",
		Cases: entries,
	}
	b, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outDir, "manifest.json"), append(b, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("wrote %d fixtures + manifest to %s", len(entries), outDir)
}

func TestCorpusHeaderExtractionMatchesV1(t *testing.T) {
	path := os.Getenv("HASALA_CORPUS_DB")
	if path == "" {
		t.Skip("HASALA_CORPUS_DB is unset")
	}
	db, err := corpus.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	var checked, subjBad, fromBad int
	err = db.Each(func(m corpus.Message) error {
		subject, from, ok := HeadersOf(m.RawBody)
		if !ok {
			return nil
		}
		checked++
		if subject != m.Subject {
			if subjBad < 5 {
				t.Errorf("id %d subject: got %q, v1 envelope %q", m.ID, subject, m.Subject)
			}
			subjBad++
		}
		if !strings.EqualFold(from, m.FromAddr) {
			if fromBad < 5 {
				t.Errorf("id %d from: got %q, v1 envelope %q", m.ID, from, m.FromAddr)
			}
			fromBad++
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("checked %d messages: %d subject mismatches, %d from mismatches", checked, subjBad, fromBad)
}
