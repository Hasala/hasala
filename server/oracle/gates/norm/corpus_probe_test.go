package norm_test

import (
	. "github.com/salehtl/hasala/server/internal/norm"
	"os"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/oracle/corpus"
	v1 "github.com/salehtl/hasala/server/oracle/v1ref/parse"
)

func TestCorpusDivergenceFromV1IsOnlyTheTrimSet(t *testing.T) {
	path := os.Getenv("HASALA_CORPUS_DB")
	if path == "" {
		t.Skip("HASALA_CORPUS_DB is unset; this probe needs a scratch .backup of the v1 corpus")
	}
	db, err := corpus.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	var total, v1Failed, textDiff, subjDiff int
	var diffIDs, unexplained []int64

	err = db.Each(func(m corpus.Message) error {
		total++

		v1Text, berr := v1.BodyText(m.RawBody)
		if berr != nil {
			v1Failed++
			return nil
		}
		_, v1Subject, _, v1Body := v1.Unwrap(m.FromAddr, m.Subject, v1Text)

		got, nerr := Normalize(CurrentVersion, m.RawBody, m.ReceivedAt)
		if nerr != nil {
			unexplained = append(unexplained, m.ID)
			return nil
		}
		if got.Subject != v1Subject {
			subjDiff++
			unexplained = append(unexplained, m.ID)
		}
		if got.Text != v1Body {
			textDiff++
			diffIDs = append(diffIDs, m.ID)
			if canonicalLines(got.Text) != canonicalLines(v1Body) {
				unexplained = append(unexplained, m.ID)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	t.Logf("corpus %d messages: %d v1 parse failures, %d text differences %v, "+
		"%d subject differences, %d NOT explained by the trim set",
		total, v1Failed, textDiff, diffIDs, subjDiff, len(unexplained))

	if len(unexplained) > 0 {
		show := unexplained
		if len(show) > 20 {
			show = show[:20]
		}
		t.Fatalf("%d messages diverge from v1 for a reason that is not the trim set: %v",
			len(unexplained), show)
	}
}

func canonicalLines(s string) string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if t := TrimExplicit(strings.TrimSpace(l)); t != "" {
			out = append(out, t)
		}
	}
	return strings.Join(out, "\n")
}
