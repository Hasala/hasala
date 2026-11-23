package norm_test

import (
	"fmt"
	. "github.com/salehtl/hasala/server/internal/norm"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/oracle/corpus"
	v1 "github.com/salehtl/hasala/server/oracle/v1ref/parse"
)

const maxShown = 20

const recordedCorpusSize = 7057

func TestCorpusEquivalence(t *testing.T) {
	path := os.Getenv("HASALA_CORPUS_DB")
	if path == "" {
		t.Skip("HASALA_CORPUS_DB is unset; the equivalence gate needs a scratch .backup of the v1 corpus")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("HASALA_CORPUS_DB=%s is set but unusable: %v", path, err)
	}
	db, err := corpus.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	available, err := db.Count()
	if err != nil {
		t.Fatal(err)
	}
	if floor := recordedCorpusSize / 10 * 9; available < floor {
		t.Fatalf("corpus at %s holds %d messages; the last recorded gate pass saw %d "+
			"and ingest_log is append-only, so anything below %d is a truncated or "+
			"wrong snapshot rather than the corpus. Re-take it:\n"+
			"  sudo sqlite3 /var/lib/ledger/ledger.db \".backup '<scratch>/v2-corpus.db'\"",
			path, available, recordedCorpusSize, floor)
	}

	var (
		total        int
		d1TrimSet    int
		d2RawFall    int
		d2bPartial   int
		bothFailed   int
		textDiffs    int
		subjDiffs    int
		fromDiffs    int
		dateDiffs    int
		forwardsSeen int
		fwdDatesV1   int
		d1IDs        []int64
		d2IDs        []int64
		d2bIDs       []int64
		d1Findings   []finding
		others       []finding
		otherCount   int
	)

	err = db.Each(func(m corpus.Message) error {
		total++

		v1Text, berr := v1.BodyText(m.RawBody)
		got, nerr := Normalize(CurrentVersion, m.RawBody, m.ReceivedAt)

		switch {
		case berr != nil && nerr != nil:
			bothFailed++
			return nil
		case berr != nil && got.PartUsed == PartRaw:
			d2RawFall++
			d2IDs = append(d2IDs, m.ID)
			return nil
		case berr != nil:
			d2bPartial++
			d2bIDs = append(d2bIDs, m.ID)
			return nil
		case nerr != nil:
			otherCount++
			if len(others) < maxShown {
				others = append(others, finding{id: m.ID, kind: "normalize-error", detail: nerr.Error()})
			}
			return nil
		}

		v1From, v1Subject, v1FwdDate, v1Body := v1.Unwrap(m.FromAddr, m.Subject, v1Text)
		if v1FwdDate != "" {
			forwardsSeen++
		}

		var (
			shadow    shadowResult
			shadowRun bool
		)
		need := func() shadowResult {
			if !shadowRun {
				shadow, shadowRun = shadowV1Trim(m.RawBody, m.ReceivedAt), true
			}
			return shadow
		}
		record := func(f finding, isD1 bool) {
			if isD1 {
				d1TrimSet++
				d1IDs = append(d1IDs, m.ID)
				if len(d1Findings) < maxShown {
					d1Findings = append(d1Findings, f)
				}
				return
			}
			otherCount++
			if len(others) < maxShown {
				others = append(others, f)
			}
		}

		if got.Text != v1Body {
			textDiffs++
			s := need()
			record(finding{id: m.ID, kind: "text", v1: v1Body, v2: got.Text},
				s.ok && s.text == v1Body)
		}

		if got.Subject != v1Subject {
			subjDiffs++
			s := need()
			record(finding{id: m.ID, kind: "subject", v1: v1Subject, v2: got.Subject},
				s.ok && s.subject == v1Subject)
		}

		if got.From != v1From {
			fromDiffs++
			s := need()
			record(finding{id: m.ID, kind: "from", v1: v1From, v2: got.From},
				s.ok && s.from == v1From)
		}

		v1Date := dateOutcome(v1.ParseForwardDate(v1FwdDate))
		if v1Date.ok {
			fwdDatesV1++
		}
		v2Date := outcome{t: got.EmailDate, ok: got.DateSource == DateSourceForwardHeader}
		if !v1Date.equal(v2Date) {
			dateDiffs++
			s := need()
			record(finding{
				id: m.ID, kind: "date",
				detail: fmt.Sprintf("v1 %s vs v2 %s (%s)", v1Date, v2Date, got.DateSource),
				v1:     v1FwdDate, v2: got.EmailDate.Format(time.RFC3339),
			}, s.ok && v1Date.equal(s.date))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if total != available {
		t.Fatalf("scanned %d messages but ingest_log holds %d", total, available)
	}

	t.Logf("corpus: %d messages, D1_trim_set: %d, D2_raw_fallback: %d, other: %d",
		total, d1TrimSet, d2RawFall, otherCount)
	t.Logf("detail: %d text diffs, %d subject diffs, %d from diffs, %d date diffs; "+
		"%d both-failed, %d v2-salvaged-partial-walk; "+
		"%d messages carried a forwarded Date value, %d of those parsed",
		textDiffs, subjDiffs, fromDiffs, dateDiffs, bothFailed, d2bPartial, forwardsSeen, fwdDatesV1)
	t.Logf("D1 ids: %v", d1IDs)
	if len(d2IDs) > 0 {
		t.Logf("D2 ids: %v", d2IDs)
	}
	if len(d2bIDs) > 0 {
		t.Logf("v2-salvaged-partial-walk ids: %v", d2bIDs)
	}
	for _, f := range d1Findings {
		t.Logf("D1 id=%d kind=%s\n%s", f.id, f.kind, f.render())
	}

	if otherCount > 0 {
		var b strings.Builder
		for _, f := range others {
			fmt.Fprintf(&b, "\n--- id=%d kind=%s %s\n%s", f.id, f.kind, f.detail, f.render())
		}
		t.Fatalf("%d differences are neither D1_trim_set nor D2_raw_fallback "+
			"(showing first %d):%s", otherCount, len(others), b.String())
	}
}

type finding struct {
	id     int64
	kind   string
	detail string
	v1, v2 string
}

func (f finding) render() string {
	if f.kind == "text" {
		return lineDiff(f.v1, f.v2)
	}
	return fmt.Sprintf("- v1: %s\n+ v2: %s\n", escapeInvisible(f.v1), escapeInvisible(f.v2))
}

var v1Trim Trimmer = strings.TrimSpace

type shadowResult struct {
	from    string
	subject string
	text    string
	date    outcome
	ok      bool
}

func shadowV1Trim(raw []byte, receivedAt time.Time) shadowResult {
	res, err := NormalizeWithTrim(CurrentVersion, raw, receivedAt, v1Trim)
	if err != nil {
		return shadowResult{}
	}
	return shadowResult{
		from:    res.From,
		subject: res.Subject,
		text:    res.Text,
		date:    outcome{t: res.EmailDate, ok: res.DateSource == DateSourceForwardHeader},
		ok:      true,
	}
}

type outcome struct {
	t  time.Time
	ok bool
}

func dateOutcome(t time.Time, err error) outcome { return outcome{t: t, ok: err == nil} }

func (o outcome) equal(b outcome) bool {
	return o.ok == b.ok && (!o.ok || o.t.Equal(b.t))
}

func (o outcome) String() string {
	if !o.ok {
		return "no-forward-date"
	}
	return o.t.Format(time.RFC3339)
}

func escapeInvisible(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= 0x20 && r < 0x7f {
			b.WriteRune(r)
			continue
		}
		fmt.Fprintf(&b, "<U+%04X>", r)
	}
	return b.String()
}

func lineDiff(v1Text, v2Text string) string {
	a := strings.Split(v1Text, "\n")
	b := strings.Split(v2Text, "\n")
	p := 0
	for p < len(a) && p < len(b) && a[p] == b[p] {
		p++
	}
	ea, eb := len(a), len(b)
	for ea > p && eb > p && a[ea-1] == b[eb-1] {
		ea--
		eb--
	}
	var out strings.Builder
	fmt.Fprintf(&out, "@@ v1 lines %d-%d of %d / v2 lines %d-%d of %d @@\n",
		p+1, ea, len(a), p+1, eb, len(b))
	if p > 0 {
		fmt.Fprintf(&out, "  %s\n", escapeInvisible(a[p-1]))
	}
	for _, l := range a[p:ea] {
		fmt.Fprintf(&out, "- %s\n", escapeInvisible(l))
	}
	for _, l := range b[p:eb] {
		fmt.Fprintf(&out, "+ %s\n", escapeInvisible(l))
	}
	if ea < len(a) {
		fmt.Fprintf(&out, "  %s\n", escapeInvisible(a[ea]))
	}
	return out.String()
}
