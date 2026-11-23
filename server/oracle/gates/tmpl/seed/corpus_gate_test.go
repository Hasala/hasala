package seed_test

import (
	"context"
	"fmt"
	. "github.com/salehtl/hasala/server/internal/tmpl/seed"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/norm"
	"github.com/salehtl/hasala/server/internal/tmpl"
	"github.com/salehtl/hasala/server/oracle/corpus"
	v1 "github.com/salehtl/hasala/server/oracle/v1ref/parse"
)

const recordedCorpusSize = 7057

const recordedV1TemplateHits = 5751

const maxShown = 20

type v1Result struct {
	hit bool
	txn v1.ParsedTxn
}

type v2Result struct {
	id string
	e  tmpl.Extraction
}

func TestSeedTemplatesReproduceV1OverTheFullCorpus(t *testing.T) {
	path := os.Getenv("HASALA_CORPUS_DB")
	if path == "" {
		t.Skip("HASALA_CORPUS_DB is unset; the seed gate needs a scratch .backup of the v1 corpus")
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
			"  sudo sqlite3 \"file:/var/lib/ledger/ledger.db?mode=ro\" \".backup '<scratch>/corpus.db'\"",
			path, available, recordedCorpusSize, floor)
	}

	g, err := runGate(db, Seed())
	if err != nil {
		t.Fatal(err)
	}
	if g.total != available {
		t.Fatalf("scanned %d messages but ingest_log holds %d", g.total, available)
	}

	t.Logf("corpus: %d messages, v1 template hits: %d, mismatches: %d, v2 misses: %d, new matches: %d",
		g.total, g.v1Hits, g.mismatch, g.misses, g.newMatches)
	t.Logf("detail: v2 hits %d, ambiguous %d, agreed-no-transaction %d, v2 normalizer failures %d",
		g.v2Hits, g.ambiguous, g.agreedNone, g.normErrs)
	t.Logf("per template: %s", counts(g.perTemplate))
	t.Logf("v1 template hits per sender: %s", counts(g.v1PerBank))
	for _, f := range g.findings {
		t.Logf("FINDING %s", f)
	}
	for _, n := range g.newList {
		t.Logf("NEW MATCH %s", n)
	}

	if floor := recordedV1TemplateHits / 10 * 9; g.v1Hits < floor {
		t.Fatalf("v1's template tier extracted only %d transactions; the recorded pass saw %d, "+
			"so below %d the gate is comparing non-results to non-results rather than measuring anything",
			g.v1Hits, recordedV1TemplateHits, floor)
	}
	if g.mismatch != 0 || g.misses != 0 || g.ambiguous != 0 {
		t.Fatalf("SEED VALIDATION FAILED: %d mismatches, %d misses, %d ambiguous", g.mismatch, g.misses, g.ambiguous)
	}
}

type gateCounts struct {
	total, v1Hits, v2Hits            int
	mismatch, misses, ambiguous      int
	newMatches, agreedNone, normErrs int
	perTemplate, v1PerBank           map[string]int
	findings, newList                []string
}

func runGate(db *corpus.DB, defs []tmpl.Definition) (gateCounts, error) {
	cascade := &v1.Cascade{
		Parsers:   []v1.BankParser{v1.DIBParser{}, v1.ENBDParser{}, v1.ENBDAlertParser{}},
		Heuristic: v1.HeuristicParser{},
		AI:        nil,
	}
	compiled := make([]*tmpl.Compiled, len(defs))
	for i, d := range defs {
		c, err := tmpl.Compile(d)
		if err != nil {
			return gateCounts{}, fmt.Errorf("%s: %w", d.ID, err)
		}
		compiled[i] = c
	}

	g := gateCounts{perTemplate: map[string]int{}, v1PerBank: map[string]int{}}
	ctx := context.Background()

	err := db.Each(func(m corpus.Message) error {
		g.total++

		got1 := runV1(ctx, cascade, m)
		if got1.hit {
			g.v1Hits++
			g.v1PerBank[bankOf(m.FromAddr)]++
		}

		r, nerr := norm.Normalize(norm.CurrentVersion, m.RawBody, m.ReceivedAt)
		if nerr != nil {
			g.normErrs++
			if got1.hit {
				g.mismatch++
				if len(g.findings) < maxShown {
					g.findings = append(g.findings, fmt.Sprintf(
						"id %d: v1's template tier extracted a transaction but the normalizer refused the message: %v",
						m.ID, nerr))
				}
			}
			return nil
		}
		hits := runV2(defs, compiled, r.From, r.Subject, r.Text, r.EmailDate)
		if len(hits) > 0 {
			g.v2Hits++
			g.perTemplate[hits[0].id]++
		}

		switch {
		case len(hits) > 1:
			g.ambiguous++
			if len(g.findings) < maxShown {
				ids := make([]string, 0, len(hits))
				for _, h := range hits {
					ids = append(ids, h.id)
				}
				g.findings = append(g.findings, fmt.Sprintf(
					"id %d: %d seed templates claimed the same message (%s); v1 stops at its first matching parser, "+
						"so the Match blocks are not the partition they look like", m.ID, len(hits), strings.Join(ids, ", ")))
			}
		case got1.hit && len(hits) == 0:
			g.misses++
			if len(g.findings) < maxShown {
				g.findings = append(g.findings, fmt.Sprintf("id %d: V2 MISS\n%s\n%s",
					m.ID, describeV1(got1.txn), anchorSnippet(r.Text)))
			}
		case got1.hit:
			if diff := diffFields(got1.txn, hits[0].e); diff != "" {
				g.mismatch++
				if len(g.findings) < maxShown {
					g.findings = append(g.findings, fmt.Sprintf("id %d: MISMATCH (template %s)\n%s\n%s",
						m.ID, hits[0].id, diff, anchorSnippet(r.Text)))
				}
			}
		case len(hits) == 1:
			g.newMatches++
			if len(g.newList) < maxShown {
				g.newList = append(g.newList, fmt.Sprintf("id %d via %s: %s | v1 said: %s",
					m.ID, hits[0].id, describeV2(hits[0].e), v1Excuse(ctx, cascade, m)))
			}
		default:
			g.agreedNone++
		}
		return nil
	})
	return g, err
}

func runV1(ctx context.Context, cascade *v1.Cascade, m corpus.Message) v1Result {
	text, berr := v1.BodyText(m.RawBody)
	if berr != nil {
		return v1Result{}
	}
	from, subject, fwdDate, text := v1.Unwrap(m.FromAddr, m.Subject, text)
	fallback := m.ReceivedAt
	if fd, err := v1.ParseForwardDate(fwdDate); err == nil {
		fallback = fd
	}
	return runV1Text(ctx, cascade, from, subject, text, fallback)
}

func runV1Text(ctx context.Context, cascade *v1.Cascade, from, subject, text string, fallback time.Time) v1Result {
	res := cascade.Run(ctx, from, subject, text, fallback)
	if res.Status != v1.StatusParsed || res.Tier != v1.TierTemplate {
		return v1Result{}
	}
	return v1Result{hit: true, txn: res.Txn}
}

func runV2(defs []tmpl.Definition, compiled []*tmpl.Compiled, from, subject, text string, emailDate time.Time) []v2Result {
	dom := senderDomain(from)
	var hits []v2Result
	for i, c := range compiled {
		if !tmpl.MatchesSenderDomain(defs[i], dom) {
			continue
		}
		e, execErr := c.Execute(subject, text)
		if execErr != nil {
			continue
		}
		if defs[i].DateFrom == tmpl.DateFromEmail {
			e.PostedAt = emailDate
		}
		hits = append(hits, v2Result{id: defs[i].ID, e: e})
	}
	return hits
}

func v1Excuse(ctx context.Context, cascade *v1.Cascade, m corpus.Message) string {
	text, berr := v1.BodyText(m.RawBody)
	if berr != nil {
		return "body decode failed: " + berr.Error()
	}
	from, subject, fwdDate, text := v1.Unwrap(m.FromAddr, m.Subject, text)
	fallback := m.ReceivedAt
	if fd, err := v1.ParseForwardDate(fwdDate); err == nil {
		fallback = fd
	}
	res := cascade.Run(ctx, from, subject, text, fallback)
	if res.Err != "" {
		return fmt.Sprintf("status=%s tier=%s err=%s", res.Status, res.Tier, res.Err)
	}
	return fmt.Sprintf("status=%s tier=%s", res.Status, res.Tier)
}

func diffFields(a v1.ParsedTxn, b tmpl.Extraction) string {
	var out []string
	add := func(field string, v1v, v2v any) {
		out = append(out, fmt.Sprintf("  %-11s v1=%v  v2=%v", field, v1v, v2v))
	}
	if a.AmountFils != b.AmountMinor {
		add("amount", a.AmountFils, b.AmountMinor)
	}
	if a.Currency != b.Currency {
		add("currency", q(a.Currency), q(b.Currency))
	}
	if a.Direction != b.Direction {
		add("direction", q(a.Direction), q(b.Direction))
	}
	if !samePostedAt(a.PostedAt, b.PostedAt) {
		add("posted_at", a.PostedAt.UTC().Format(time.RFC3339), b.PostedAt.UTC().Format(time.RFC3339))
	}
	if a.MerchantRaw != b.Merchant {
		add("merchant", q(a.MerchantRaw), q(b.Merchant))
	}
	if a.Last4 != b.Last4 {
		add("last4", q(a.Last4), q(b.Last4))
	}
	if a.IsTransfer != b.IsTransfer {
		add("is_transfer", a.IsTransfer, b.IsTransfer)
	}
	return strings.Join(out, "\n")
}

func samePostedAt(a, b time.Time) bool { return a.Equal(b) }

func q(s string) string { return fmt.Sprintf("%q", s) }

func describeV1(p v1.ParsedTxn) string {
	return fmt.Sprintf("  v1: amount=%d %s %s posted=%s merchant=%q last4=%q transfer=%v",
		p.AmountFils, p.Currency, p.Direction, p.PostedAt.UTC().Format(time.RFC3339),
		p.MerchantRaw, p.Last4, p.IsTransfer)
}

func describeV2(e tmpl.Extraction) string {
	return fmt.Sprintf("amount=%d %s %s posted=%s merchant=%q last4=%q transfer=%v",
		e.AmountMinor, e.Currency, e.Direction, e.PostedAt.UTC().Format(time.RFC3339),
		e.Merchant, e.Last4, e.IsTransfer)
}

var anchorLines = regexp.MustCompile(
	`(?m)^.*(المبلغ|بتاريخ|الدفع الى|المعاملة|رقم البطاقة|من حساب|من الحساب|إشعار|Debit Amount|Transaction Date|Beneficiary Name|has been).*$`)

func anchorSnippet(text string) string {
	lines := strings.Split(text, "\n")
	keep := map[int]bool{}
	for i, l := range lines {
		if anchorLines.MatchString(l) {
			keep[i] = true
			if i+1 < len(lines) {
				keep[i+1] = true
			}
		}
	}
	idx := make([]int, 0, len(keep))
	for i := range keep {
		idx = append(idx, i)
	}
	sort.Ints(idx)
	var b strings.Builder
	b.WriteString("  --- anchors ---")
	shown := 0
	for _, i := range idx {
		if shown >= 24 {
			b.WriteString("\n  ...")
			break
		}
		fmt.Fprintf(&b, "\n  %3d| %q", i, lines[i])
		shown++
	}
	return b.String()
}

func senderDomain(fromAddr string) string {
	at := strings.LastIndex(fromAddr, "@")
	if at < 0 {
		return ""
	}
	d := strings.TrimSpace(fromAddr[at+1:])
	d = strings.TrimSuffix(strings.Trim(d, "<>"), ".")
	return strings.ToLower(d)
}

func bankOf(fromAddr string) string {
	f := strings.ToLower(fromAddr)
	switch {
	case strings.Contains(f, "dib.notification@dib.ae"):
		return "dib.notification@dib.ae"
	case strings.Contains(f, "onlinebanking@emiratesnbd.com"):
		return "onlinebanking@emiratesnbd.com"
	case strings.Contains(f, "alert@emiratesnbd.com"):
		return "alert@emiratesnbd.com"
	default:
		return "other"
	}
}

func counts(m map[string]int) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", k, m[k]))
	}
	if len(parts) == 0 {
		return "(none)"
	}
	return strings.Join(parts, " ")
}

func TestSeedDefinitionsArePublishable(t *testing.T) {
	defs := Seed()
	if len(defs) != len(IDs) {
		t.Fatalf("Seed returned %d definitions, IDs names %d", len(defs), len(IDs))
	}
	for i, d := range defs {
		if d.ID != IDs[i] {
			t.Errorf("Seed()[%d] is %q, want %q", i, d.ID, IDs[i])
		}
		if err := tmpl.ValidateForPublish(d); err != nil {
			t.Errorf("%s: %v", d.ID, err)
		}
		if d.NormalizerVersion != norm.CurrentVersion {
			t.Errorf("%s targets normalizer v%d; this build's normalizer is v%d, and a template "+
				"matching against text a different algorithm produced is not the template that was validated",
				d.ID, d.NormalizerVersion, norm.CurrentVersion)
		}
	}
	if len(Raw()) != len(IDs) {
		t.Errorf("Raw returned %d entries, want %d", len(Raw()), len(IDs))
	}
}

func TestSeedAnchorsAreByteIdenticalToV1(t *testing.T) {
	a := readV1Anchors(t)
	raw := Raw()
	card, account := string(raw["dib.card.v1"]), string(raw["dib.account.v1"])

	for _, tc := range []struct {
		name   string
		anchor string
		in     []string
	}{
		{"amount", a.amount, []string{card, account}},
		{"date", a.date, []string{card, account}},
		{"payee", a.payee, []string{card}},
		{"txn", a.txn, []string{account}},
		{"card", a.card, []string{card}},
		{"acct", a.acct, []string{account}},
		{"card layout", a.cardLayout, []string{card, account}},
		{"deposit notice", a.deposit, []string{account}},
		{"debit notice", a.debitNotice, []string{account}},
		{"withdrawal notice", a.withdrawal, []string{account}},
		{"from account", a.fromAccount, []string{account}},
	} {
		if tc.anchor == "" {
			t.Fatalf("%s: located an EMPTY anchor, which every seed trivially contains", tc.name)
		}
		for i, doc := range tc.in {
			if !strings.Contains(doc, tc.anchor) {
				t.Errorf("%s: seed %d does not contain v1's anchor %q (% x)", tc.name, i, tc.anchor, tc.anchor)
			}
		}
	}

	const withHamza = "الدفع إلى"
	if withHamza == a.payee {
		t.Fatal("v1's payee anchor now IS the hamza spelling; this guard is asserting the opposite of what dib.go says")
	}
	for id, b := range raw {
		if strings.Contains(string(b), withHamza) {
			t.Errorf("%s contains the hamza spelling of the payee anchor; DIB writes it without", id)
		}
	}
}

type v1Anchors struct {
	amount, date, payee, txn, card, acct          string
	cardLayout                                    string
	deposit, debitNotice, withdrawal, fromAccount string
}

func readV1Anchors(t *testing.T) v1Anchors {
	t.Helper()
	b, err := os.ReadFile("../../../v1ref/parse/dib.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	get := func(name, before, after string) string {
		s, ok := between(src, before, after)
		if !ok || s == "" {
			t.Fatalf("%s: could not locate the anchor in dib.go between %q and %q; "+
				"v1's source changed shape and this guard is no longer reading it", name, before, after)
		}
		return s
	}
	return v1Anchors{
		amount:      get("amount", "dibAmountRe = regexp.MustCompile(`", `\s*\n`),
		date:        get("date", "dibDateRe   = regexp.MustCompile(`", `\s*(`),
		payee:       get("payee", "dibPayeeRe  = regexp.MustCompile(`", `\s*\n`),
		txn:         get("txn", "dibTxnRe    = regexp.MustCompile(`", `\s*\n`),
		card:        get("card", "dibCardRe   = regexp.MustCompile(`", `\s*\n`),
		acct:        get("acct", "dibAcctRe   = regexp.MustCompile(`", `\s*\n`),
		cardLayout:  get("card layout", `isCard := strings.Contains(textBody, "`, `")`),
		deposit:     get("deposit notice", `case strings.Contains(textBody, "`, `"):`),
		debitNotice: get("debit notice", "DirectionCredit\n\tcase strings.Contains(textBody, \"", `"), strings.Contains`),
		withdrawal:  get("withdrawal notice", `"), strings.Contains(textBody, "`, `"):`),
		fromAccount: get("from account", `if strings.Contains(textBody, "`, `") {`),
	}
}

func between(s, before, after string) (string, bool) {
	i := strings.Index(s, before)
	if i < 0 {
		return "", false
	}
	rest := s[i+len(before):]
	j := strings.Index(rest, after)
	if j < 0 {
		return "", false
	}
	return rest[:j], true
}

func TestDIBSeedsPartitionEveryDIBMessage(t *testing.T) {
	var dib []tmpl.Definition
	var card, account tmpl.Definition
	for _, d := range Seed() {
		if d.Bank != "dib" || d.IsSMS() {
			continue
		}
		dib = append(dib, d)
		switch d.ID {
		case "dib.card.v1":
			card = d
		case "dib.account.v1":
			account = d
		}
	}
	if len(dib) != 6 {
		t.Fatalf("%d DIB seeds; this test names the card, account, two transfer-notice and two card-refund templates", len(dib))
	}
	if len(card.Match.BodyContains) != 1 || len(card.Match.BodyNotContains) != 0 || len(account.Match.BodyContains) != 0 {
		t.Fatalf("the DIB pair is no longer one body_contains against body_not_contains: %+v / %+v",
			card.Match, account.Match)
	}
	excludes := func(a, b tmpl.Definition) bool {
		for _, want := range a.Match.BodyContains {
			for _, not := range b.Match.BodyNotContains {
				if want == not {
					return true
				}
			}
		}
		return false
	}
	if !excludes(card, account) {
		t.Errorf("the DIB pair no longer partitions: card requires %q, account excludes %q",
			card.Match.BodyContains, account.Match.BodyNotContains)
	}
	for i := range dib {
		for j := i + 1; j < len(dib); j++ {
			if !excludes(dib[i], dib[j]) && !excludes(dib[j], dib[i]) {
				t.Errorf("%s and %s can claim the same message: neither requires a literal the other excludes",
					dib[i].ID, dib[j].ID)
			}
		}
	}
}

func TestSeedDirectionCascadeNeedsNoOverride(t *testing.T) {
	var account tmpl.Definition
	for _, d := range Seed() {
		if d.ID == "dib.account.v1" {
			account = d
		}
	}
	order := make([]string, 0, len(account.Extract))
	for _, x := range account.Extract {
		if x.Override {
			t.Errorf("dib.account.v1 still carries an override on %s; the suffix rules are "+
				"expressed by ORDER instead, and one override could only ever reproduce half of "+
				"v1's two-sided suffix re-derivation", x.Field)
		}
		if x.Field == tmpl.FieldDirection {
			order = append(order, x.Value+":"+strings.Join(x.Patterns, "|"))
		}
	}
	if len(order) != 6 {
		t.Fatalf("dib.account.v1 has %d direction entries, want 6: %v", len(order), order)
	}
	if !strings.HasPrefix(order[0], "debit:") || !strings.Contains(order[0], "DEBIT") {
		t.Errorf("direction entry 0 is %q, want the DEBIT suffix rule", order[0])
	}
	if !strings.HasPrefix(order[1], "credit:") || !strings.Contains(order[1], "CREDIT") {
		t.Errorf("direction entry 1 is %q, want the CREDIT suffix rule", order[1])
	}
	if last := account.Extract[len(account.Extract)-2]; last.Field != tmpl.FieldDirection ||
		len(last.Patterns) != 0 || last.Value != "credit" {
		t.Errorf("the last direction entry is %+v, want v1's unconditional credit default", last)
	}
}

func TestSeedReproducesV1OnTheBranchesTheCorpusNeverExercises(t *testing.T) {
	defs := Seed()
	compiled := make([]*tmpl.Compiled, len(defs))
	for i, d := range defs {
		c, err := tmpl.Compile(d)
		if err != nil {
			t.Fatal(err)
		}
		compiled[i] = c
	}
	for _, tc := range syntheticCases(readV1Anchors(t)) {
		t.Run(tc.name, func(t *testing.T) {
			if bad := compareSynthetic(defs, compiled, tc); bad != "" {
				t.Fatalf("%s\n%s", tc.why, bad)
			}
		})
	}
}

func TestTheNormalizerRemovesTheWhitespaceVariationTheENBDAnchorsCannotExpress(t *testing.T) {
	defs := Seed()
	compiled := make([]*tmpl.Compiled, len(defs))
	for i, d := range defs {
		c, err := tmpl.Compile(d)
		if err != nil {
			t.Fatal(err)
		}
		compiled[i] = c
	}

	for _, tc := range []struct {
		name    string
		from    string
		subject string
		body    string
	}{
		{
			"transfer advice",
			"onlinebanking@emiratesnbd.com", "Local Bank Transfer",
			"Transaction Date:   \r\n\r\n   15/Mar/2026 09:15 PM\r\n" +
				"From Account:\r\n012***34***56\r\n" +
				"Debit Amount:\t\r\n\r\n\t AED 23,456.00  \r\n" +
				"Beneficiary Name:  \r\n\r\n   SOME BENEFICIARY   \r\n",
		},
		{
			"account alert",
			"alert@emiratesnbd.com", "Emirates NBD Transaction advice for account ending with 8642",
			"AED  12,750.00 \t has been  \t withdrawn \t from your account 012XXX34XXX56.\r\n",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw := "From: " + tc.from + "\r\nSubject: " + tc.subject +
				"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" + tc.body
			r, err := norm.Normalize(norm.CurrentVersion, []byte(raw), syntheticEmailDate)
			if err != nil {
				t.Fatalf("normalize: %v", err)
			}
			if r.Text == "" {
				t.Fatal("the normalizer produced no text, so every assertion below is vacuous")
			}
			for i, line := range strings.Split(r.Text, "\n") {
				switch {
				case line == "":
					t.Errorf("line %d is empty; `Label:\\n(?P<v>...)` assumes blank lines are dropped", i)
				case strings.ContainsAny(line, "\t\v\f\u00a0\ufeff"):
					t.Errorf("line %d %q still carries a whitespace character the collapse removes", i, line)
				case strings.Contains(line, "  "):
					t.Errorf("line %d %q still carries a RUN of spaces; `[ \\t\\n\\f\\r]` matches exactly one", i, line)
				case line != strings.TrimSpace(line):
					t.Errorf("line %d %q is not trimmed; `Debit Amount:\\n` assumes the value starts at column 0", i, line)
				}
			}
			if bad := compareSynthetic(defs, compiled, syntheticCase{
				name: tc.name, why: "", from: tc.from, subject: tc.subject, text: r.Text,
			}); bad != "" {
				t.Fatalf("after normalization the two implementations disagree:\n%s", bad)
			}
			hits := runV2(defs, compiled, tc.from, tc.subject, r.Text, syntheticEmailDate)
			if len(hits) != 1 {
				t.Fatalf("%d seeds matched the normalized text; want exactly 1", len(hits))
			}
			if hits[0].e.Currency != "AED" || hits[0].e.AmountMinor == 0 {
				t.Fatalf("extracted %s, which is not the amount the hostile body carries", describeV2(hits[0].e))
			}
		})
	}
}

type syntheticCase struct {
	name    string
	why     string
	from    string
	subject string
	text    string
}

var syntheticEmailDate = time.Date(2026, 2, 14, 15, 4, 5, 0, time.UTC)

func compareSynthetic(defs []tmpl.Definition, compiled []*tmpl.Compiled, tc syntheticCase) string {
	cascade := &v1.Cascade{
		Parsers:   []v1.BankParser{v1.DIBParser{}, v1.ENBDParser{}, v1.ENBDAlertParser{}},
		Heuristic: v1.HeuristicParser{},
		AI:        nil,
	}
	got1 := runV1Text(context.Background(), cascade, tc.from, tc.subject, tc.text, syntheticEmailDate)
	hits := runV2(defs, compiled, tc.from, tc.subject, tc.text, syntheticEmailDate)
	switch {
	case len(hits) > 1:
		ids := make([]string, 0, len(hits))
		for _, h := range hits {
			ids = append(ids, h.id)
		}
		return fmt.Sprintf("%d seed templates claimed the message: %s", len(hits), strings.Join(ids, ", "))
	case got1.hit && len(hits) == 0:
		return fmt.Sprintf("v1 extracted a transaction and no seed matched:\n%s\ntext:\n%s",
			describeV1(got1.txn), tc.text)
	case !got1.hit && len(hits) == 1:
		return fmt.Sprintf("v1's template tier extracted nothing and %s extracted %s\ntext:\n%s",
			hits[0].id, describeV2(hits[0].e), tc.text)
	case got1.hit:
		if diff := diffFields(got1.txn, hits[0].e); diff != "" {
			return fmt.Sprintf("%s produced a different transaction:\n%s\ntext:\n%s",
				hits[0].id, diff, tc.text)
		}
	}
	return ""
}

func syntheticCases(a v1Anchors) []syntheticCase {
	const (
		dibFrom      = "dib.notification@dib.ae"
		enbdFrom     = "onlinebanking@emiratesnbd.com"
		alertFrom    = "alert@emiratesnbd.com"
		alertSubject = "Emirates NBD Transaction advice for account ending with 8642"
	)
	dibBody := func(notice, amount, desc, acct string) string {
		var b strings.Builder
		b.WriteString(notice + " " + a.date + " 14-02-2026 09:41\n")
		if amount != "" {
			b.WriteString(a.amount + "\n" + amount + "\n")
		}
		if desc != "" {
			b.WriteString(a.txn + "\n" + desc + "\n")
		}
		if acct != "" {
			b.WriteString(a.acct + "\n" + acct + "\n")
		}
		return b.String()
	}

	return []syntheticCase{
		{"deposit notice with a DEBIT suffix",
			"v1's cascade says credit and its suffix re-derivation then says debit. This is the case " +
				"the whole override question is about: the suffix must WIN.",
			dibFrom, "", dibBody(a.deposit, "AED 500.00", "SOME PAYMENT DEBIT", "0311000123456")},
		{"debit notice with a CREDIT suffix",
			"the mirror image, and the half a single `override` entry cannot express",
			dibFrom, "", dibBody(a.debitNotice, "AED 500.00", "SALARY MAY CREDIT", "0311000123456")},
		{"withdrawal notice with a CREDIT suffix",
			"the second debit anchor against the credit suffix",
			dibFrom, "", dibBody(a.withdrawal, "AED 500.00", "REVERSAL CREDIT", "0311000123456")},
		{"suffix in the middle of the description, not at the end",
			"v1 uses HasSuffix, so a description CONTAINING debit must NOT flip the direction",
			dibFrom, "", dibBody(a.deposit, "AED 500.00", "DEBIT CARD REFUND", "0311000123456")},
		{"lower-case debit suffix",
			"v1 upper-cases the description before testing it; the template carries flags [\"i\"]",
			dibFrom, "", dibBody(a.deposit, "AED 500.00", "some payment debit", "0311000123456")},
		{"suffix on the LAST line of the body",
			"the (?:\\n|$) alternative: v1's (.+) ends at the end of the text just as it does at a newline",
			dibFrom, "", a.deposit + " " + a.date + " 14-02-2026\n" + a.amount + "\nAED 500.00\n" + a.txn + "\nSOME PAYMENT DEBIT"},

		{"deposit notice, no suffix",
			"the first cascade arm on its own",
			dibFrom, "", dibBody(a.deposit, "AED 500.00", "SALARY MAY", "0311000123456")},
		{"debit notice, no suffix",
			"the second arm",
			dibFrom, "", dibBody(a.debitNotice, "AED 500.00", "ATM WITHDRAWAL", "0311000123456")},
		{"withdrawal notice, no suffix",
			"the second arm's other anchor",
			dibFrom, "", dibBody(a.withdrawal, "AED 500.00", "ATM WITHDRAWAL", "0311000123456")},
		{"deposit notice AND the preposition together",
			"the two cascade arms that disagree: v1's switch reaches the deposit arm first and " +
				"never evaluates the preposition. Without a case where they differ, deleting the " +
				"deposit arm is an equivalent mutant — the unconditional default is credit too",
			dibFrom, "", dibBody(a.deposit+" "+a.fromAccount, "AED 500.00", "SALARY MAY", "0311000123456")},
		{"no notice, من الحساب present",
			"the conditional default's debit half — never decisive on the corpus",
			dibFrom, "", dibBody("TRANSFER "+a.fromAccount, "AED 500.00", "OWN ACCOUNT MOVE", "0311000123456")},
		{"no notice, no preposition",
			"the unconditional default: v1 falls through to credit",
			dibFrom, "", dibBody("SOMETHING ELSE", "AED 500.00", "MYSTERY MOVEMENT", "0311000123456")},
		{"no notice, no description at all",
			"the default fires with no description block to re-derive from",
			dibFrom, "", dibBody("SOMETHING ELSE", "AED 500.00", "", "0311000123456")},

		{"transfer, spelled correctly",
			"one half of v1's TRNSFER||TRANSFER test",
			dibFrom, "", dibBody(a.debitNotice, "AED 500.00", "OUTWARD TRANSFER", "0311000123456")},
		{"transfer, DIB's misspelling",
			"the other half; the misspelling is DIB's",
			dibFrom, "", dibBody(a.debitNotice, "AED 500.00", "OUTWARD TRNSFER", "0311000123456")},
		{"transfer, lower case",
			"v1 tests the upper-cased description",
			dibFrom, "", dibBody(a.debitNotice, "AED 500.00", "outward transfer", "0311000123456")},

		{"account line with a trailing token",
			"v1 captures (\\S+), NOT the rest of the line; a whole-line capture would take " +
				"its last four digits from the wrong token",
			dibFrom, "", dibBody(a.debitNotice, "AED 500.00", "SOME PAYMENT", "0311****1234 (Savings 5)")},
		{"card line with a trailing token that carries its own digits",
			"the same, on the card layout. The trailing token has DIGITS on purpose: with a bare " +
				"\"VISA\" both spellings still yield 7777, and the case proves nothing",
			dibFrom, "", a.cardLayout + " " + a.date + " 14-02-2026 09:41\n" + a.card +
				"\n400000XXXXXX7777 (Visa 5)\n" + a.amount + "\nAED 87.50\n" + a.payee +
				"\nEXAMPLE CAFE\nDIB CUSTOMER CARE 0097146092222\n"},
		{"card merchant followed by another line",
			"v1's (.+) stops at the newline; a capture that ran to the end of the text would " +
				"swallow the footer. The corpus catches this 4,997 times over, but only because " +
				"real DIB mail always has a footer",
			dibFrom, "", a.cardLayout + " " + a.date + " 14-02-2026 09:41\n" + a.card +
				"\n400000XXXXXX7777\n" + a.amount + "\nAED 87.50\n" + a.payee +
				"\nEXAMPLE CAFE\nDIB CUSTOMER CARE\n"},

		{"amount with no currency prefix",
			"default_currency applies, as v1's ParseAEDToFils defaults to AED",
			dibFrom, "", dibBody(a.debitNotice, "500.00", "SOME PAYMENT", "0311000123456")},
		{"foreign currency",
			"the ccy group wins over default_currency",
			dibFrom, "", dibBody(a.debitNotice, "USD 99.99", "SOME PAYMENT", "0311000123456")},
		{"thousands separators",
			"commas are stripped before conversion in both",
			dibFrom, "", dibBody(a.debitNotice, "AED 1,234,567.89", "SOME PAYMENT", "0311000123456")},

		{"enbd transfer, foreign currency with a space",
			"the ordinary foreign-currency shape: the ccy group wins over default_currency on both sides",
			enbdFrom, "Telegraphic Transfer",
			"Transaction Date:\n15/Mar/2026 09:15 PM\nDebit Amount:\nUSD 1,200.00\nBeneficiary Name:\nSOME BENEFICIARY\n"},
		{"enbd transfer, foreign currency with NO space",
			"v1 reads the whole line and its amountRe separates the code with `\\s*` — ZERO or more — so " +
				"`USD1,200.00` is USD to v1. The seed demanded exactly one U+0020, so its ccy group did not " +
				"participate, RE2 re-matched at the digit and default_currency made it AED: a silently WRONG " +
				"AMOUNT IN A DIFFERENT CURRENCY, which is the worst class of defect this app has. Template " +
				"version 2 spells the separator `[A-Z]{3} ?`",
			enbdFrom, "Telegraphic Transfer",
			"Transaction Date:\n15/Mar/2026 09:15 PM\nDebit Amount:\nUSD1,200.00\nBeneficiary Name:\nSOME BENEFICIARY\n"},
		{"enbd transfer, timed date",
			"the shape all 62 corpus messages have",
			enbdFrom, "Local Bank Transfer",
			"Transaction Date:\n15/Mar/2026 09:15 PM\nFrom Account:\n012***34***56\nDebit Amount:\nAED 23,456.00\nBeneficiary Name:\nSOME BENEFICIARY\n"},
		{"enbd transfer, date only",
			"v1's strings.Fields(s)[0] fallback in ParseENBDDate — never taken on the corpus",
			enbdFrom, "Telegraphic Transfer",
			"Transaction Date:\n15/Mar/2026\nFrom Account:\n012***34***56\nDebit Amount:\nAED 23,456.00\nBeneficiary Name:\nSOME BENEFICIARY\n"},
		{"enbd transfer, date with unparseable trailing text",
			"the fallback again, this time because the whole string does not parse",
			enbdFrom, "Local Bank Transfer",
			"Transaction Date:\n15/Mar/2026 25:99 XX\nFrom Account:\n012***34***56\nDebit Amount:\nAED 23,456.00\nBeneficiary Name:\nSOME BENEFICIARY\n"},
		{"enbd transfer, no beneficiary",
			"merchant is not required; the transaction still extracts",
			enbdFrom, "Local Bank Transfer",
			"Transaction Date:\n15/Mar/2026 09:15 PM\nDebit Amount:\nAED 23,456.00\n"},

		{"enbd alert, withdrawn",
			"the shape of the forwarded alert the corpus has always held",
			alertFrom, alertSubject,
			"AED 12,750.00 has been withdrawn from your account 012XXX34XXX56.\n"},
		{"enbd alert, debited",
			"the second debit verb",
			alertFrom, alertSubject,
			"AED 12.34 has been debited from your account 012XXX34XXX56.\n"},
		{"enbd alert, deducted",
			"the THIRD debit verb, and the one the port lost: v1's enbd_alert.go gained `deducted` " +
				"— ENBD's wording for bank-initiated debits, transfer issuance and fees — after the seed " +
				"was cut from it, and the seed never followed. A message this test could not see falls " +
				"past the template tier to the heuristic, which reads this shape as a CREDIT",
			alertFrom, alertSubject,
			"AED 2,340.00 has been deducted from your account 012XXX34XXX56.\n"},
		{"enbd alert, credited",
			"the credit branch, which no corpus message takes",
			alertFrom, alertSubject,
			"AED 400.00 has been credited to your account 012XXX34XXX56.\n"},
		{"enbd alert, deposited into",
			"the (?:in)?to alternative",
			alertFrom, alertSubject,
			"AED 400.00 has been deposited into your account 012XXX34XXX56.\n"},
		{"enbd alert, subject without a last4",
			"last4 is read from the subject and is not required",
			alertFrom, "Emirates NBD Transaction advice",
			"AED 400.00 has been credited to your account 012XXX34XXX56.\n"},
		{"enbd alert, foreign currency with NO space, debit",
			"the alert half of the same defect, and the reason enbd.alert.v1 version 3 carries TWO patterns " +
				"per amount entry rather than one with `[A-Z]{3} ?`: the single-pattern spelling doubles the " +
				"anchor's backtracking width from 200 to 400, and TestTheShippingSeedsHaveHeadroomUnderTheWidthBound " +
				"pins the widest shipping seed at exactly 200. The currency-adjacent pattern is listed FIRST, " +
				"because rule 3 stops at the first pattern that produces a VALUE and the spaced pattern happily " +
				"produces an AED one here",
			alertFrom, alertSubject,
			"USD99.99 has been withdrawn from your account 012XXX34XXX56.\n"},
		{"enbd alert, foreign currency with NO space, credit",
			"the credit entry carries the same pair",
			alertFrom, alertSubject,
			"USD400.00 has been credited to your account 012XXX34XXX56.\n"},
		{"enbd alert, foreign currency with a space",
			"and the spaced form still reaches the second pattern rather than being captured by the first",
			alertFrom, alertSubject,
			"USD 99.99 has been withdrawn from your account 012XXX34XXX56.\n"},
		{"enbd alert, tab-separated",
			"v1 separates the tokens with `\\s+`, which is [\\t\\n\\f\\r ]. The port wrote `[ \\n]`, so a TAB " +
				"parsed in v1 and missed in v2. norm.Normalize collapses tabs to U+0020 before a template ever " +
				"runs — see TestTheNormalizerRemovesTheWhitespaceVariationTheENBDAnchorsCannotExpress — so this " +
				"was unreachable in production, but the class costs nothing to state exactly and `+` is not " +
				"available: three separators would be three unbounded quantifiers in one branch, which the " +
				"dialect refuses as the polynomial-backtracking shape",
			alertFrom, alertSubject,
			"AED 250.00\thas been\twithdrawn\tfrom your account 012XXX34XXX56.\n"},
		{"enbd alert, form-feed separated",
			"the other member of Go's \\s that [ \\n] did not cover",
			alertFrom, alertSubject,
			"AED 250.00\fhas been\fwithdrawn\ffrom your account 012XXX34XXX56.\n"},
		{"enbd alert, subject whose last4 is two spaces away",
			"the ONE anchor whose input the normalizer does NOT collapse: last4 reads the SUBJECT, and a " +
				"subject is RFC 2047-decoded and trimmed, never whitespace-collapsed. v1's `account ending " +
				"with\\s+` took it; the seed demanded exactly one space and lost the last4 outright",
			alertFrom, "Emirates NBD Transaction advice for account ending with  8642",
			"AED 250.00 has been withdrawn from your account 012XXX34XXX56.\n"},
		{"enbd alert, neither verb",
			"no amount entry produces a value; both sides extract nothing",
			alertFrom, alertSubject,
			"AED 250.00 has been reserved on your account 012XXX34XXX56.\n"},

		{"dib card layout with no amount",
			"v1's parser errors; v2's required-field gate fires",
			dibFrom, "", a.cardLayout + " " + a.date + " 14-02-2026\n" + a.payee + "\nEXAMPLE CAFE\n"},
		{"dib account layout with no date",
			"same, for the other required field",
			dibFrom, "", a.deposit + "\n" + a.amount + "\nAED 500.00\n" + a.txn + "\nSALARY\n"},
		{"dib amount with one decimal place",
			"a conversion failure in both, never a rounded number",
			dibFrom, "", dibBody(a.debitNotice, "AED 500.0", "SOME PAYMENT", "0311000123456")},
		{"dib date that is not a real day",
			"31 February: Go's time.Parse range-checks, and so must the template",
			dibFrom, "", a.deposit + " " + a.date + " 31-02-2026\n" + a.amount + "\nAED 500.00\n" + a.txn + "\nSALARY\n"},
	}
}
