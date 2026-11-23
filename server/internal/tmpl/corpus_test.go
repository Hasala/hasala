package tmpl

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"testing"

	"github.com/salehtl/hasala/server/internal/privatefixtures"
)

type (
	templateFixture = TemplateFixture
	templateCase    = TemplateCase
	templateExpect  = TemplateExpect
)

var (
	expectOf              = ExpectOf
	encodeTemplateFixture = EncodeTemplateFixture
)

const (
	templateConformanceDir = "../../../conformance/templates"
	corpusTemplateDir      = CorpusTemplateDir
	smsFixtureSubdir       = "sms"
)

func TestTemplateFixturesAreWhatThisBuildProduces(t *testing.T) {
	files := readTemplateFixtures(t)
	total, matched := 0, 0
	for _, f := range files {
		n, m, err := replayTemplateFixture(f)
		if err != nil {
			t.Fatal(err)
		}
		total += n
		matched += m
	}
	if matched < 100 {
		t.Fatalf("only %d of %d cases matched; the fixture set is not exercising extraction", matched, total)
	}
	t.Logf("%d cases across %d templates, %d matched", total, len(files), matched)
}

func TestTemplateFixturesCoverEveryFieldAndEveryFailureMode(t *testing.T) {
	files := readTemplateFixtures(t)
	var (
		amounts, dates, merchants, last4s, credits, debits, transfers int
		emptyGroups, noMatch, missingField                            int
	)
	for _, f := range files {
		for _, c := range f.Cases {
			x := c.Expect
			if x.Currency != "" {
				amounts++
			}
			if x.PostedAt != "" {
				dates++
			}
			if x.Merchant != "" {
				merchants++
			}
			if x.Last4 != "" {
				last4s++
			}
			switch x.Direction {
			case "credit":
				credits++
			case "debit":
				debits++
			}
			if x.IsTransfer {
				transfers++
			}
			if len(x.EmptyGroups) > 0 {
				emptyGroups++
			}
			switch x.Error {
			case "no_match":
				noMatch++
			case "missing_field":
				missingField++
			}
		}
	}
	for _, c := range []struct {
		name string
		n    int
	}{
		{"amounts", amounts}, {"body dates", dates}, {"merchants", merchants},
		{"last4s", last4s}, {"credits", credits}, {"debits", debits},
		{"is_transfer", transfers}, {"empty capture groups", emptyGroups},
		{"gated-out (no_match)", noMatch}, {"required-field failures", missingField},
	} {
		if c.n == 0 {
			t.Errorf("no committed case exercises %s; the two executors cannot be compared on it", c.name)
		}
	}
	t.Logf("amounts=%d dates=%d merchants=%d last4=%d credit=%d debit=%d transfer=%d empty_groups=%d no_match=%d missing_field=%d",
		amounts, dates, merchants, last4s, credits, debits, transfers, emptyGroups, noMatch, missingField)
}

func readTemplateFixtures(t *testing.T) []templateFixture {
	t.Helper()
	privatefixtures.Path(t, path.Join(corpusTemplateDir, smsFixtureSubdir))
	out, err := collectTemplateFixtures(templateConformanceDir, privatefixtures.Path(t, corpusTemplateDir))
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func collectTemplateFixtures(publicDir, privateDir string) ([]templateFixture, error) {
	type fixtureFile struct{ dir, path string }
	var names []fixtureFile
	for _, dir := range []string{"", smsFixtureSubdir} {
		if public, _ := filepath.Glob(filepath.Join(publicDir, dir, "corpus-*.json")); len(public) > 0 {
			return nil, fmt.Errorf("%v: corpus fixtures are real bank mail or texts and belong in %s, not in this repository", public, privatefixtures.Repo)
		}
		globs := []string{filepath.Join(publicDir, dir, "synthetic-*.json")}
		if privateDir != "" {
			globs = append(globs, filepath.Join(privateDir, dir, "corpus-*.json"))
		}
		for _, glob := range globs {
			found, err := filepath.Glob(glob)
			if err != nil {
				return nil, err
			}
			for _, n := range found {
				names = append(names, fixtureFile{dir, n})
			}
		}
	}
	sort.SliceStable(names, func(i, j int) bool {
		return path.Join(names[i].dir, filepath.Base(names[i].path)) < path.Join(names[j].dir, filepath.Base(names[j].path))
	})
	out := make([]templateFixture, 0, len(names))
	for _, n := range names {
		b, err := os.ReadFile(n.path)
		if err != nil {
			return nil, err
		}
		var f templateFixture
		if err := json.Unmarshal(b, &f); err != nil {
			return nil, fmt.Errorf("%s: %w", n.path, err)
		}
		if len(f.Cases) == 0 {
			return nil, fmt.Errorf("%s has no cases", n.path)
		}
		d, err := ParseDefinition(f.Definition)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", n.path, err)
		}
		if want := corpusDirFor(d); path.Join(corpusTemplateDir, n.dir) != want {
			return nil, fmt.Errorf("%s holds %s, whose cases belong in %s", n.path, d.ID, want)
		}
		out = append(out, f)
	}
	return out, nil
}

func replayTemplateFixture(f templateFixture) (cases, matched int, err error) {
	d, err := ParseDefinition(f.Definition)
	if err != nil {
		return 0, 0, fmt.Errorf("%s: %w", f.Template, err)
	}
	if d.ID != f.Template {
		return 0, 0, fmt.Errorf("%s: definition id is %q", f.Template, d.ID)
	}
	c, err := Compile(d)
	if err != nil {
		return 0, 0, fmt.Errorf("%s: %w", f.Template, err)
	}
	for _, tc := range f.Cases {
		subject, err := base64.StdEncoding.DecodeString(tc.SubjectBase64)
		if err != nil {
			return 0, 0, fmt.Errorf("%s %s: %w", f.Template, tc.Name, err)
		}
		body, err := base64.StdEncoding.DecodeString(tc.NormalizedBodyBase64)
		if err != nil {
			return 0, 0, fmt.Errorf("%s %s: %w", f.Template, tc.Name, err)
		}
		e, execErr := c.Execute(string(subject), string(body))
		if got := expectOf(e, execErr); !sameExpect(got, tc.Expect) {
			regenerate := "./gates/tmpl/ -run TestWriteTemplateFixtures in server/oracle, with the corpus database"
			if d.IsSMS() {
				regenerate = "./internal/tmpl/seed/ -run TestWriteDIBSMSCorpus in server/, with " + privatefixtures.EnvVar
			}
			return 0, 0, fmt.Errorf("%w: %s %s\n got %+v\nwant %+v\nregenerate with\n  %s=1 go test %s",
				errStaleFixture, f.Template, tc.Name, got, tc.Expect, writeFixturesEnv, regenerate)
		}
		cases++
		if tc.Expect.Matched {
			matched++
		}
	}
	return cases, matched, nil
}

var errStaleFixture = errors.New("stale template fixture")

func corpusDirFor(d Definition) string {
	if d.IsSMS() {
		return path.Join(corpusTemplateDir, smsFixtureSubdir)
	}
	return corpusTemplateDir
}

func sameExpect(a, b templateExpect) bool {
	if a.Matched != b.Matched || a.Error != b.Error || a.AmountMinor != b.AmountMinor ||
		a.Currency != b.Currency || a.Direction != b.Direction || a.PostedAt != b.PostedAt ||
		a.Merchant != b.Merchant || a.Last4 != b.Last4 || a.IsTransfer != b.IsTransfer ||
		len(a.EmptyGroups) != len(b.EmptyGroups) {
		return false
	}
	for i := range a.EmptyGroups {
		if a.EmptyGroups[i] != b.EmptyGroups[i] {
			return false
		}
	}
	return true
}
