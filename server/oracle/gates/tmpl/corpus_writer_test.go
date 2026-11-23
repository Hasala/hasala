package tmpl_test

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/norm"
	"github.com/salehtl/hasala/server/internal/privatefixtures"
	. "github.com/salehtl/hasala/server/internal/tmpl"
	"github.com/salehtl/hasala/server/oracle/corpus"
)

const writeFixturesEnv = "HASALA_WRITE_CONFORMANCE"

const seedDir = "../../../internal/tmpl/testdata"

const templateFixtureCap = 500

const templateFilterEnv = "HASALA_TEMPLATE_FIXTURE_ONLY"

func templateFilter(id string) bool {
	only := os.Getenv(templateFilterEnv)
	if only == "" {
		return true
	}
	for _, want := range strings.Split(only, ",") {
		if strings.TrimSpace(want) == id {
			return true
		}
	}
	return false
}

func senderDomain(fromAddr string) string {
	at := strings.LastIndex(fromAddr, "@")
	if at < 0 {
		return ""
	}
	d := strings.TrimSpace(fromAddr[at+1:])
	d = strings.TrimSuffix(strings.Trim(d, "<>"), ".")
	return ASCIILower(d)
}

func sampleEvenly(ids []int64, limit int) []int64 {
	if len(ids) <= limit || limit <= 0 {
		return ids
	}
	out := make([]int64, 0, limit)
	for i := 0; i < limit; i++ {
		j := int(int64(i) * int64(len(ids)-1) / int64(limit-1))
		out = append(out, ids[j])
	}
	return out
}

func TestWriteTemplateFixtures(t *testing.T) {
	if os.Getenv(writeFixturesEnv) == "" {
		t.Skipf("%s is unset; fixtures are committed and regenerated deliberately", writeFixturesEnv)
	}
	path := os.Getenv("HASALA_CORPUS_DB")
	if path == "" {
		t.Skip("HASALA_CORPUS_DB is unset; see server/oracle/corpus for how to make the .backup copy")
	}
	root := privatefixtures.Root()
	if root == "" {
		t.Fatalf("%s is unset: corpus fixtures are real mail and are written only into a checkout of %s, "+
			"never into this repository", privatefixtures.EnvVar, privatefixtures.Repo)
	}
	outDir := filepath.Join(root, filepath.FromSlash(CorpusTemplateDir))
	db, err := corpus.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	defs, raws, err := LoadMailSeedTemplates(seedDir)
	if err != nil {
		t.Fatal(err)
	}
	fromEML, err := emlTemplateIDs(root)
	if err != nil {
		t.Fatal(err)
	}

	eligible := make([][]int64, len(defs))
	if err := db.Each(func(m corpus.Message) error {
		dom := senderDomain(m.FromAddr)
		for i, d := range defs {
			if MatchesSenderDomain(d, dom) {
				eligible[i] = append(eligible[i], m.ID)
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	wanted := map[int64]bool{}
	picked := make([][]int64, len(defs))
	for i := range defs {
		if !templateFilter(defs[i].ID) || fromEML[defs[i].ID] {
			continue
		}
		picked[i] = sampleEvenly(eligible[i], templateFixtureCap)
		for _, id := range picked[i] {
			wanted[id] = true
		}
	}

	type msg struct {
		subject string
		body    string
		normErr error
	}
	byID := map[int64]msg{}
	if err := db.Each(func(m corpus.Message) error {
		if !wanted[m.ID] {
			return nil
		}
		r, err := norm.Normalize(norm.CurrentVersion, m.RawBody, m.ReceivedAt)
		byID[m.ID] = msg{subject: r.Subject, body: r.Text, normErr: err}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for i, d := range defs {
		if !templateFilter(d.ID) {
			t.Logf("%s: skipped, %s does not name it", d.ID, templateFilterEnv)
			continue
		}
		if fromEML[d.ID] {
			t.Logf("%s: skipped, its fixture is written from %s by TestWriteEMLTemplateFixtures", d.ID, EMLTemplateDir)
			continue
		}
		f := TemplateFixture{
			Note: "Written by server/oracle/gates/tmpl TestWriteTemplateFixtures over the operator's v1 mail corpus. " +
				"Regenerate with HASALA_WRITE_CONFORMANCE=1 HASALA_CORPUS_DB=... go test ./gates/tmpl/ " +
				"-run TestWriteTemplateFixtures (in server/oracle); do not hand-edit. `expect` is LITERAL Go executor output, never " +
				"recomputed by the reader: a conformance harness that derives its own expectation cannot see a " +
				"defect in the thing it is checking. Subject and body are the NORMALIZED forms (norm.Result.Subject " +
				"and norm.Result.Text), base64 because they carry CR, U+FEFF, bidi controls and Arabic.",
			Spec:              "server/internal/tmpl/v2-template-format.md",
			SchemaVersion:     1,
			Template:          d.ID,
			Kind:              "corpus",
			NormalizerVersion: norm.CurrentVersion,
			Definition:        raws[i],
			Cases:             []TemplateCase{},
		}
		skipped := 0
		for _, id := range picked[i] {
			m := byID[id]
			if m.normErr != nil {
				skipped++
				continue
			}
			e, execErr := Execute(d, m.subject, m.body)
			f.Cases = append(f.Cases, TemplateCase{
				Name:                 fmt.Sprintf("%s/%06d", d.ID, id),
				Source:               fmt.Sprintf("v1 corpus ingest_log id %d, normalized with norm v%d", id, norm.CurrentVersion),
				SubjectBase64:        base64.StdEncoding.EncodeToString([]byte(m.subject)),
				NormalizedBodyBase64: base64.StdEncoding.EncodeToString([]byte(m.body)),
				Expect:               ExpectOf(e, execErr),
			})
		}
		out := filepath.Join(outDir, "corpus-"+d.ID+".json")
		b, err := EncodeTemplateFixture(f)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(out, b, 0o644); err != nil {
			t.Fatal(err)
		}
		matched := 0
		for _, c := range f.Cases {
			if c.Expect.Matched {
				matched++
			}
		}
		t.Logf("%s: %d eligible, %d sampled, %d written (%d matched, %d unreadable by the normalizer), %d bytes",
			d.ID, len(eligible[i]), len(picked[i]), len(f.Cases), matched, skipped, len(b))
	}
}
