package tmpl

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func mustLoad(t *testing.T, path string) Definition {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	d, err := ParseDefinition(b)
	if err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	return d
}

func mustDef(t *testing.T, src string) Definition {
	t.Helper()
	d, err := ParseDefinition([]byte(src))
	if err != nil {
		t.Fatalf("parse definition: %v\n%s", err, src)
	}
	if errs := ValidateDefinition(d); len(errs) != 0 {
		t.Fatalf("inline definition does not validate: %v", errs)
	}
	return d
}

const dibCardBody = "إشعار مشتريات\nالمبلغ\nAED 250.00\nبتاريخ 05-06-2026\n" +
	"الدفع الى\nCARREFOUR DUBAI\nرقم البطاقة\nXXXX1234"

const dibAccountBody = "إشعار إيداع\nالمبلغ\nAED 1,250.75\nبتاريخ 05-06-2026\n" +
	"المعاملة\nSALARY TRNSFER DEBIT\nمن حساب\n0123456789"

func TestTheTestdataTemplatesAreValidDefinitions(t *testing.T) {
	for _, f := range []string{"dib.card.v1", "dib.account.v1", "enbd.alert.v1"} {
		d := mustLoad(t, "testdata/"+f+".json")
		if errs := ValidateDefinition(d); len(errs) != 0 {
			t.Errorf("%s: %v", f, errs)
		}
		if err := ValidateForPublish(d); err != nil {
			t.Errorf("%s: not publishable: %v", f, err)
		}
	}
}

func TestExecuteDIBCardPurchase(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	e, err := Execute(d, "", dibCardBody)
	if err != nil {
		t.Fatal(err)
	}
	if e.AmountMinor != 25000 || e.Currency != "AED" || e.Direction != "debit" ||
		e.Merchant != "CARREFOUR DUBAI" || e.Last4 != "1234" {
		t.Fatalf("%+v", e)
	}
	if !e.Matched {
		t.Fatal("Matched must be true")
	}
	want := time.Date(2026, 6, 5, 0, 0, 0, 0, time.UTC)
	if !e.PostedAt.Equal(want) {
		t.Fatalf("PostedAt = %s, want %s", e.PostedAt, want)
	}
	if len(e.EmptyGroups) != 0 {
		t.Fatalf("EmptyGroups = %v, want none", e.EmptyGroups)
	}
}

func TestBodyNotContainsSeparatesTheTwoDIBLayouts(t *testing.T) {
	account := mustLoad(t, "testdata/dib.account.v1.json")
	e, err := Execute(account, "", dibCardBody)
	if !errors.Is(err, ErrNoMatch) {
		t.Fatalf("err = %v, want ErrNoMatch", err)
	}
	if e.Matched {
		t.Fatal("a gated-out message must not report Matched")
	}
	if _, err := Execute(account, "", dibAccountBody); err != nil {
		t.Fatalf("account body: %v", err)
	}
}

func TestOverrideReplacesAnAlreadySetDirection(t *testing.T) {
	d := mustLoad(t, "testdata/dib.account.v1.json")
	e, err := Execute(d, "", dibAccountBody)
	if err != nil {
		t.Fatal(err)
	}
	if e.Direction != "debit" {
		t.Fatalf("Direction = %q, want debit (the override entry must win)", e.Direction)
	}
	if !e.IsTransfer {
		t.Fatal("IsTransfer must be true: the description contains TRNSFER")
	}
	if e.AmountMinor != 125075 || e.Last4 != "6789" || e.Merchant != "SALARY TRNSFER DEBIT" {
		t.Fatalf("%+v", e)
	}

	stripped := d
	stripped.Extract = nil
	for _, x := range d.Extract {
		if x.Override {
			continue
		}
		stripped.Extract = append(stripped.Extract, x)
	}
	e2, err := Execute(stripped, "", dibAccountBody)
	if err != nil {
		t.Fatal(err)
	}
	if e2.Direction != "credit" {
		t.Fatalf("without override Direction = %q, want credit", e2.Direction)
	}
}

func TestSubjectSourceUsesTheEffectiveSubject(t *testing.T) {
	d := mustLoad(t, "testdata/enbd.alert.v1.json")
	const subject = "Transaction advice for your account ending with 8642"
	const body = "AED 12,750.00 has been withdrawn from your account 012XXX34XXX56."
	e, err := Execute(d, subject, body)
	if err != nil {
		t.Fatal(err)
	}
	if e.Last4 != "8642" {
		t.Fatalf("Last4 = %q, want 8642 (read from the subject, not the body)", e.Last4)
	}
	if e.AmountMinor != 1275000 || e.Direction != "debit" || e.Currency != "AED" {
		t.Fatalf("%+v", e)
	}
	if !e.PostedAt.IsZero() {
		t.Fatalf("PostedAt = %s, want zero for date_from=email", e.PostedAt)
	}

	e2, err := Execute(d, "", body)
	if err != nil {
		t.Fatal(err)
	}
	if e2.Last4 != "" {
		t.Fatalf("Last4 = %q with no subject", e2.Last4)
	}
}

func TestOnMatchSetsDirectionOnlyWhenUnset(t *testing.T) {
	d := mustLoad(t, "testdata/enbd.alert.v1.json")
	const body = "AED 400.00 has been credited to your account 012XXX34XXX56."
	e, err := Execute(d, "", body)
	if err != nil {
		t.Fatal(err)
	}
	if e.Direction != "credit" || e.AmountMinor != 40000 {
		t.Fatalf("%+v", e)
	}

	def := mustDef(t, `{
	  "id":"onmatch","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"direction","type":"const","source":"body","value":"credit"},
	    {"field":"amount","type":"amount","source":"body",
	     "patterns":["Amt: (?P<amt>[^\\n]+)"],"on_match":{"direction":"debit"}}
	  ],
	  "required":["amount","direction"]}`)
	e2, err := Execute(def, "", "Amt: 10.00")
	if err != nil {
		t.Fatal(err)
	}
	if e2.Direction != "credit" {
		t.Fatalf("Direction = %q; on_match must not overwrite an already-set field", e2.Direction)
	}
}

func dateDef(t *testing.T, layouts, required string) Definition {
	t.Helper()
	return mustDef(t, fmt.Sprintf(`{
	  "id":"dates","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"body",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","patterns":["Amt: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"date","type":"date","source":"body","layouts":[%s],
	     "patterns":["Date: (?P<d>[^\\n]+)"]}
	  ],
	  "required":[%s]}`, layouts, required))
}

func TestDateLayoutsAreTriedInOrderAndFallBackToTheFirstToken(t *testing.T) {
	d := dateDef(t, `"DD/Mon/YYYY hh:mm A","DD/Mon/YYYY"`, `"amount","direction","date"`)
	for _, tc := range []struct {
		text string
		want time.Time
		why  string
	}{
		{"07/Jan/2026 03:14 PM", time.Date(2026, 1, 7, 15, 14, 0, 0, time.UTC), "layout 1, whole string"},
		{"07/Jan/2026", time.Date(2026, 1, 7, 0, 0, 0, 0, time.UTC), "layout 2, whole string"},
		{"07/Jan/2026 garbage", time.Date(2026, 1, 7, 0, 0, 0, 0, time.UTC), "layout 2 via the first-token attempt"},
		{"  07/Jan/2026  ", time.Date(2026, 1, 7, 0, 0, 0, 0, time.UTC), "trimmed before parsing"},
	} {
		e, err := Execute(d, "", "Amt: 1.00\nDate: "+tc.text)
		if err != nil {
			t.Fatalf("%q (%s): %v", tc.text, tc.why, err)
		}
		if !e.PostedAt.Equal(tc.want) {
			t.Errorf("%q (%s): PostedAt = %s, want %s", tc.text, tc.why, e.PostedAt, tc.want)
		}
	}
}

func TestDateParsingSemanticsTheTypeScriptMirrorMustReproduce(t *testing.T) {
	d := dateDef(t, `"DD-MM-YYYY","DD/Mon/YYYY hh:mm A","DD/Mon/YYYY"`, `"amount","direction"`)
	for _, tc := range []struct {
		text string
		want string
		why  string
	}{
		{"05/jun/2026", "2026-06-05T00:00:00Z", "month NAMES fold case"},
		{"05/JUN/2026", "2026-06-05T00:00:00Z", "month names fold case, upper too"},
		{"07/Jan/2026 03:14 pm", "2026-01-07T00:00:00Z", "the AM/PM marker does NOT fold case; the date-only layout catches it via the first-token attempt"},
		{"07/Jan/2026 03:14 PM", "2026-01-07T15:14:00Z", "12-hour + PM"},
		{"5-6-2026", "", "numeric fields need exactly two digits"},
		{"31-02-2026", "", "calendar ranges are checked; this is not 2 March"},
		{"07/Jan/2026 13:14 PM", "2026-01-07T00:00:00Z", "hour out of range for a 12-hour layout; the date-only layout still parses the first token"},
		{"05-06-26", "", "a two-digit year is not a year"},
		{"05-06-2026extra", "", "trailing text is an error, which is why the first-token attempt exists"},
	} {
		e, err := Execute(d, "", "Amt: 1.00\nDate: "+tc.text)
		if err != nil {
			t.Fatalf("%q: %v", tc.text, err)
		}
		got := ""
		if !e.PostedAt.IsZero() {
			got = e.PostedAt.Format(time.RFC3339)
		}
		if got != tc.want {
			t.Errorf("%q (%s): got %q, want %q", tc.text, tc.why, got, tc.want)
		}
	}
}

func TestExecuteBoundsExceedTheLargestStorableMail(t *testing.T) {
	const maxRawMail = 1_000_000
	if MaxBodyBytes < 2*maxRawMail {
		t.Fatalf("MaxBodyBytes = %d, want at least 2x the raw mail cap (%d)", MaxBodyBytes, maxRawMail)
	}
	if MaxEmptyGroups > 32 {
		t.Fatalf("MaxEmptyGroups = %d exceeds diag's own cap; the diagnostics row would be refused whole", MaxEmptyGroups)
	}
}

func TestAConversionFailureFallsThroughRatherThanZeroing(t *testing.T) {
	d := dateDef(t, `"DD-MM-YYYY"`, `"amount","direction"`)
	e, err := Execute(d, "", "Amt: 1.00\nDate: not a date")
	if err != nil {
		t.Fatal(err)
	}
	if !e.PostedAt.IsZero() {
		t.Fatalf("PostedAt = %s, want the zero time", e.PostedAt)
	}
	if !e.Matched {
		t.Fatal("the template must still match: date is not required")
	}

	req := dateDef(t, `"DD-MM-YYYY"`, `"amount","direction","date"`)
	e2, err := Execute(req, "", "Amt: 1.00\nDate: not a date")
	if !errors.Is(err, ErrMissingField) {
		t.Fatalf("err = %v, want ErrMissingField", err)
	}
	if e2.Matched {
		t.Fatal("Matched must be false")
	}
	if !strings.Contains(err.Error(), "date") {
		t.Fatalf("the error must name the missing field: %v", err)
	}
}

func TestAFailingPatternFallsThroughToTheNextPatternInTheSameEntry(t *testing.T) {
	d := mustDef(t, `{
	  "id":"fallthrough","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body",
	     "patterns":["Total: (?P<amt>[^\\n]+)","Amount: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"}
	  ],
	  "required":["amount","direction"]}`)

	e, err := Execute(d, "", "Total: three hundred\nAmount: 12.50")
	if err != nil {
		t.Fatal(err)
	}
	if e.AmountMinor != 1250 {
		t.Fatalf("AmountMinor = %d, want 1250", e.AmountMinor)
	}
}

func TestAnEntryThatProducesNothingFallsThroughToTheNextEntryForTheSameField(t *testing.T) {
	d := mustDef(t, `{
	  "id":"entryfallthrough","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"body",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","patterns":["Bad: (?P<amt>[^\\n]+)"]},
	    {"field":"amount","type":"amount","source":"body","patterns":["Good: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"date","type":"date","source":"body","layouts":["DD-MM-YYYY"],
	     "patterns":["BadDate: (?P<d>[^\\n]+)"]},
	    {"field":"date","type":"date","source":"body","layouts":["DD-MM-YYYY"],
	     "patterns":["GoodDate: (?P<d>[^\\n]+)"]}
	  ],
	  "required":["amount","direction","date"]}`)
	e, err := Execute(d, "", "Bad: not money\nGood: 42.00\nBadDate: nope\nGoodDate: 05-06-2026")
	if err != nil {
		t.Fatal(err)
	}
	if e.AmountMinor != 4200 {
		t.Errorf("AmountMinor = %d, want 4200 from the second entry", e.AmountMinor)
	}
	want := time.Date(2026, 6, 5, 0, 0, 0, 0, time.UTC)
	if !e.PostedAt.Equal(want) {
		t.Errorf("PostedAt = %s, want %s from the second entry", e.PostedAt, want)
	}
}

func TestFirstEntryWinsAndLaterEntriesForTheSameFieldAreSkipped(t *testing.T) {
	d := mustDef(t, `{
	  "id":"firstwins","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","patterns":["A: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"merchant","type":"text","source":"body","patterns":["M1: (?P<v>[^\\n]+)"]},
	    {"field":"merchant","type":"text","source":"body","patterns":["M2: (?P<v>[^\\n]+)"]}
	  ],
	  "required":["amount","direction"]}`)
	e, err := Execute(d, "", "A: 1.00\nM1: first\nM2: second")
	if err != nil {
		t.Fatal(err)
	}
	if e.Merchant != "first" {
		t.Fatalf("Merchant = %q, want first", e.Merchant)
	}
}

func TestAnUnconditionalConstEntryIsTheConditionalDefault(t *testing.T) {
	d := mustLoad(t, "testdata/dib.account.v1.json")
	body := "إشعار تحويل\nالمبلغ\nAED 10.00\nبتاريخ 05-06-2026\nالمعاملة\nSOMETHING\nمن حساب\n0000001111"
	e, err := Execute(d, "", body)
	if err != nil {
		t.Fatal(err)
	}
	if e.Direction != "credit" {
		t.Fatalf("Direction = %q, want credit", e.Direction)
	}

	body2 := strings.Replace(body, "المعاملة\nSOMETHING", "من الحساب\nالمعاملة\nSOMETHING", 1)
	e2, err := Execute(d, "", body2)
	if err != nil {
		t.Fatal(err)
	}
	if e2.Direction != "debit" {
		t.Fatalf("Direction = %q, want debit", e2.Direction)
	}
}

func amountDef(t *testing.T) Definition {
	t.Helper()
	return mustDef(t, `{
	  "id":"amounts","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","flags":["i"],
	     "patterns":["Amt: (?P<ccy>[A-Z]{3} )?(?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"}
	  ],
	  "required":["amount","direction"]}`)
}

func TestAmountConversion(t *testing.T) {
	d := amountDef(t)
	for _, tc := range []struct {
		in       string
		want     int64
		currency string
		ok       bool
	}{
		{"250.00", 25000, "AED", true},
		{"1,250.75", 125075, "AED", true},
		{"0.00", 0, "AED", true},
		{"12,750.00", 1275000, "AED", true},
		{"USD 12.34", 1234, "USD", true},
		{"usd 12.34", 1234, "USD", true},
		{"250", 0, "", false},
		{"250.5", 0, "", false},
		{"250.005", 0, "", false},
		{"-250.00", 0, "", false},
		{"+250.00", 0, "", false},
		{"99999999999999999999.00", 0, "", false},
		{".50", 0, "", false},
		{"", 0, "", false},
	} {
		e, err := Execute(d, "", "Amt: "+tc.in)
		if !tc.ok {
			if err == nil {
				t.Errorf("%q: converted to %d, want a conversion failure", tc.in, e.AmountMinor)
			}
			if e.AmountMinor != 0 || e.Currency != "" {
				t.Errorf("%q: a failed conversion left %+v behind", tc.in, e)
			}
			continue
		}
		if err != nil {
			t.Errorf("%q: %v", tc.in, err)
			continue
		}
		if e.AmountMinor != tc.want || e.Currency != tc.currency {
			t.Errorf("%q: got %d %s, want %d %s", tc.in, e.AmountMinor, e.Currency, tc.want, tc.currency)
		}
	}
}

func TestLast4KeepsTheLastFourASCIIDigits(t *testing.T) {
	d := mustDef(t, `{
	  "id":"last4","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","patterns":["A: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"last4","type":"last4","source":"body","patterns":["C: (?P<v>[^\\n]+)"]}
	  ],
	  "required":["amount","direction"]}`)
	for _, tc := range []struct{ in, want string }{
		{"XXXX1234", "1234"},
		{"4321-8765-****-1234", "1234"},
		{"12", "12"},
		{"card ٤٣٢١", ""},
		{"no digits", ""},
		{"٠١٢٣ 9", "9"},
	} {
		e, err := Execute(d, "", "A: 1.00\nC: "+tc.in)
		if err != nil {
			t.Fatalf("%q: %v", tc.in, err)
		}
		if e.Last4 != tc.want {
			t.Errorf("%q: Last4 = %q, want %q", tc.in, e.Last4, tc.want)
		}
	}
}

func TestExecuteRecordsEmptyCaptureGroups(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	body := strings.Replace(dibCardBody, "الدفع الى\nCARREFOUR DUBAI", "الدفع الى\n", 1)
	e, err := Execute(d, "", body)
	if err != nil {
		t.Fatal(err)
	}
	if e.Merchant != "" {
		t.Fatalf("Merchant = %q, want empty", e.Merchant)
	}
	if got := strings.Join(e.EmptyGroups, ","); got != "merchant_v" {
		t.Fatalf("EmptyGroups = %v, want [merchant_v]", e.EmptyGroups)
	}
}

func TestAGroupThatDidNotParticipateIsNotAnEmptyGroup(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	body := strings.Replace(dibCardBody, "AED 250.00", "250.00", 1)
	e, err := Execute(d, "", body)
	if err != nil {
		t.Fatal(err)
	}
	if e.Currency != "AED" {
		t.Fatalf("Currency = %q, want the default AED", e.Currency)
	}
	for _, g := range e.EmptyGroups {
		if strings.HasSuffix(g, "_ccy") {
			t.Fatalf("EmptyGroups = %v: a non-participating group must not be reported", e.EmptyGroups)
		}
	}
}

func TestEmptyGroupsSurviveAFailedMatch(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	body := strings.Replace(dibCardBody, "بتاريخ 05-06-2026", "بتاريخ", 1)
	body = strings.Replace(body, "الدفع الى\nCARREFOUR DUBAI", "الدفع الى\n", 1)
	e, err := Execute(d, "", body)
	if !errors.Is(err, ErrMissingField) {
		t.Fatalf("err = %v, want ErrMissingField", err)
	}
	if e.Matched {
		t.Fatal("Matched must be false")
	}
	if len(e.EmptyGroups) == 0 {
		t.Fatal("a failed match must still carry its empty groups, or the diagnostic is useless")
	}
}

func TestEmptyGroupsAreSortedAndDeduplicated(t *testing.T) {
	d := mustDef(t, `{
	  "id":"empties","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","patterns":["A: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"merchant","type":"text","source":"body",
	     "patterns":["M: (?P<v>[^\\n]*)","M: (?P<v>[^\\n]*)"]},
	    {"field":"last4","type":"last4","source":"body","patterns":["C: (?P<v>[^\\n]*)"]}
	  ],
	  "required":["amount","direction"]}`)
	e, err := Execute(d, "", "A: 1.00\nC: \nM: ")
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(e.EmptyGroups, ","); got != "last4_v,merchant_v" {
		t.Fatalf("EmptyGroups = %v, want [last4_v merchant_v]", e.EmptyGroups)
	}
}

func TestExecuteFailsClosedOnMissingRequiredField(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	body := strings.Replace(dibCardBody, "المبلغ\nAED 250.00", "المبلغ\n", 1)
	e, err := Execute(d, "", body)
	if !errors.Is(err, ErrMissingField) {
		t.Fatalf("err = %v, want ErrMissingField", err)
	}
	if e.Matched {
		t.Fatal("Matched must be false when a required field was not produced")
	}
	if !strings.Contains(err.Error(), "amount") {
		t.Fatalf("the error must name the field: %v", err)
	}
}

func TestMatchesSenderDomainIsASuffixMatchOnLabelBoundaries(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	for _, tc := range []struct {
		domain string
		want   bool
	}{
		{"dib.ae", true},
		{"notifications.dib.ae", true},
		{"DIB.AE", true},
		{"dib.ae.", true},
		{"evildib.ae", false},
		{"dib.ae.evil.com", false},
		{"ae", false},
		{"", false},
		{".dib.ae", false},
	} {
		if got := MatchesSenderDomain(d, tc.domain); got != tc.want {
			t.Errorf("MatchesSenderDomain(%q) = %v, want %v", tc.domain, got, tc.want)
		}
	}
}

func TestValidateExtractionRefusesIncoherentResults(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	ok := Extraction{AmountMinor: 1, Currency: "AED", Direction: "debit",
		PostedAt: time.Date(2026, 6, 5, 0, 0, 0, 0, time.UTC)}
	if err := ValidateExtraction(ok, d); err != nil {
		t.Fatalf("a coherent extraction was rejected: %v", err)
	}
	for name, mutate := range map[string]func(Extraction) Extraction{
		"negative amount":    func(e Extraction) Extraction { e.AmountMinor = -1; return e },
		"amount no currency": func(e Extraction) Extraction { e.Currency = ""; return e },
		"bad currency":       func(e Extraction) Extraction { e.Currency = "aed"; return e },
		"bad direction":      func(e Extraction) Extraction { e.Direction = "outbound"; return e },
		"bad last4":          func(e Extraction) Extraction { e.Last4 = "12x4"; return e },
		"missing date":       func(e Extraction) Extraction { e.PostedAt = time.Time{}; return e },
	} {
		if err := ValidateExtraction(mutate(ok), d); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}

	bare := Definition{DateFrom: DateFromEmail}
	for name, e := range map[string]Extraction{
		"amount with no currency":           {AmountMinor: 500},
		"negative amount":                   {AmountMinor: -1, Currency: "AED"},
		"lower-case currency":               {AmountMinor: 1, Currency: "aed"},
		"direction that is not a direction": {Direction: "inbound"},
		"last4 that is not digits":          {Last4: "12x4"},
		"merchant beyond the capture bound": {Merchant: strings.Repeat("m", MaxCaptureRunes+1)},
	} {
		if err := ValidateExtraction(e, bare); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}

	alert := mustLoad(t, "testdata/enbd.alert.v1.json")
	bad := Extraction{AmountMinor: 1, Currency: "AED", Direction: "debit", PostedAt: time.Now()}
	if err := ValidateExtraction(bad, alert); err == nil {
		t.Error("a body date under date_from=email was accepted")
	}
}

func TestIsTransferCannotBeRequired(t *testing.T) {
	src := `{
	  "id":"flagreq","version":1,"bank":"t","normalizer_version":1,
	  "match":{"sender_domain":["example.com"]},
	  "default_currency":"AED","date_from":"email",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","patterns":["A: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"is_transfer","type":"flag","source":"body","value":"true","patterns":["X"]}
	  ],
	  "required":["amount","direction","is_transfer"]}`
	d, err := ParseDefinition([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateForPublish(d); err == nil {
		t.Fatal("the publish gate accepted is_transfer in required")
	}
	if _, err := Execute(d, "", "A: 1.00\nX"); err == nil {
		t.Fatal("execution accepted is_transfer in required")
	}
}

func TestCompileRejectsADefinitionTheExecutorCannotRun(t *testing.T) {
	for name, src := range map[string]string{
		"uncompilable pattern": `{"id":"x","version":1,"bank":"t","normalizer_version":1,
		  "match":{"sender_domain":["example.com"]},"default_currency":"AED","date_from":"email",
		  "extract":[{"field":"amount","type":"amount","source":"body","patterns":["(?P<amt>["]}],
		  "required":["amount","direction"]}`,
		"amount pattern with no amt group": `{"id":"x","version":1,"bank":"t","normalizer_version":1,
		  "match":{"sender_domain":["example.com"]},"default_currency":"AED","date_from":"email",
		  "extract":[{"field":"amount","type":"amount","source":"body","patterns":["[0-9]+"]}],
		  "required":["amount","direction"]}`,
		"unknown layout": `{"id":"x","version":1,"bank":"t","normalizer_version":1,
		  "match":{"sender_domain":["example.com"]},"default_currency":"AED","date_from":"body",
		  "extract":[{"field":"date","type":"date","source":"body","layouts":["RFC3339"],
		    "patterns":["(?P<d>[^\\n]+)"]}],"required":["amount","direction"]}`,
		"no default currency": `{"id":"x","version":1,"bank":"t","normalizer_version":1,
		  "match":{"sender_domain":["example.com"]},"default_currency":"","date_from":"email",
		  "extract":[{"field":"amount","type":"amount","source":"body","patterns":["(?P<amt>[0-9.]+)"]}],
		  "required":["amount","direction"]}`,
		"on_match names an unconstructible field": `{"id":"x","version":1,"bank":"t","normalizer_version":1,
		  "match":{"sender_domain":["example.com"]},"default_currency":"AED","date_from":"email",
		  "extract":[{"field":"amount","type":"amount","source":"body","patterns":["(?P<amt>[0-9.]+)"],
		    "on_match":{"date":"today"}}],"required":["amount","direction"]}`,
		"on_match direction is not a direction": `{"id":"x","version":1,"bank":"t","normalizer_version":1,
		  "match":{"sender_domain":["example.com"]},"default_currency":"AED","date_from":"email",
		  "extract":[{"field":"amount","type":"amount","source":"body","patterns":["(?P<amt>[0-9.]+)"],
		    "on_match":{"direction":"sideways"}}],"required":["amount","direction"]}`,
		"date_from body with no date entry": `{"id":"x","version":1,"bank":"t","normalizer_version":1,
		  "match":{"sender_domain":["example.com"]},"default_currency":"AED","date_from":"body",
		  "extract":[{"field":"amount","type":"amount","source":"body","patterns":["(?P<amt>[0-9.]+)"]}],
		  "required":["amount","direction"]}`,
		"date_from email with a date entry": `{"id":"x","version":1,"bank":"t","normalizer_version":1,
		  "match":{"sender_domain":["example.com"]},"default_currency":"AED","date_from":"email",
		  "extract":[{"field":"date","type":"date","source":"body","layouts":["DD-MM-YYYY"],
		    "patterns":["(?P<d>[^\\n]+)"]}],"required":["amount","direction"]}`,
	} {
		d, err := ParseDefinition([]byte(src))
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if _, err := Compile(d); err == nil {
			t.Errorf("%s: Compile accepted it", name)
		}
	}
}

func TestExecuteRefusesAnInputBeyondItsSizeBound(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	big := strings.Repeat("x", MaxBodyBytes+1)
	if _, err := Execute(d, "", big); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("err = %v, want ErrTooLarge", err)
	}
	if _, err := Execute(d, strings.Repeat("s", MaxSubjectBytes+1), dibCardBody); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("subject: err = %v, want ErrTooLarge", err)
	}
	if _, err := Execute(d, "", dibCardBody+strings.Repeat("x", MaxBodyBytes)); !errors.Is(err, ErrTooLarge) {
		t.Fatal("an oversize body that happens to start with a matching one must still be refused")
	}
}

func TestAnEnormousCaptureIsAConversionFailureRatherThanAMerchant(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	huge := strings.Repeat("A", 400_000)
	body := strings.Replace(dibCardBody, "CARREFOUR DUBAI", huge, 1)
	e, err := Execute(d, "", body)
	if err != nil {
		t.Fatal(err)
	}
	if e.Merchant != "" {
		t.Fatalf("Merchant is %d runes; an over-long capture must not become a value", len(e.Merchant))
	}
	if e.AmountMinor != 25000 {
		t.Fatalf("the rest of the extraction must survive: %+v", e)
	}
}

func TestExecuteIsLinearOnInputsThatWouldReDoSABacktrackingEngine(t *testing.T) {
	for _, p := range []string{
		`(?P<v>[0-9]+)[0-9]+z`,
		`(?P<v>[0-9]+)[0-9]+[0-9]+z`,
		`(?P<v>[0-9]+)[0-9]+[0-9]+[0-9]+z`,
		`(?P<v>[^\n]+)[^\n]+[^\n]+[^\n]+X`,
		`(?P<v>[0-9a-z]*[0-9]*[0-9a-z]*[0-9]*)!`,
	} {
		if !hasCode(ValidatePattern(p, nil), ReasonMultipleUnboundedQuantifiers) {
			t.Errorf("%q is the polynomial shape and the dialect must refuse it: %v",
				p, codesOf(ValidatePattern(p, nil)))
		}
		d, err := ParseDefinition([]byte(fmt.Sprintf(`{
		  "id":"redos","version":1,"bank":"t","normalizer_version":1,
		  "match":{"sender_domain":["example.com"]},
		  "default_currency":"AED","date_from":"email",
		  "extract":[
		    {"field":"amount","type":"amount","source":"body","patterns":["A: (?P<amt>[^\\n]+)"]},
		    {"field":"direction","type":"const","source":"body","value":"debit"},
		    {"field":"merchant","type":"text","source":"body","patterns":[%q]}
		  ],
		  "required":["amount","direction"]}`, p)))
		if err != nil {
			t.Fatalf("%q: %v", p, err)
		}
		body := "A: 1.00\n" + strings.Repeat("1", 50_000)
		start := time.Now()
		if _, err := Execute(d, "", body); err != nil {
			t.Fatalf("%q: %v", p, err)
		}
		if el := time.Since(start); el > 5*time.Second {
			t.Fatalf("%q took %s on a 50 KB body: the executor is not linear", p, el)
		}
	}
}

func TestKNOWNASingleUnboundedQuantifierIsStillQuadraticInJavaScript(t *testing.T) {
	for _, p := range []string{`[0-9]+z`, `[^\n]+X`, `DEBIT$`} {
		if errs := ValidatePattern(p, nil); len(errs) != 0 {
			t.Fatalf("the dialect now rejects %q (%v) — rewrite this note", p, errs)
		}
	}
}

func TestExecuteSurvivesHostileBodies(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	bodies := map[string]string{
		"empty":                  "",
		"nul bytes":              "\x00\x00\x00",
		"invalid utf-8":          "\xff\xfe\xfd" + dibCardBody,
		"lone newlines":          strings.Repeat("\n", 200_000),
		"one enormous line":      strings.Repeat("A", 500_000),
		"line separators":        strings.Repeat("  ", 50_000),
		"bidi overrides":         strings.Repeat("\u202e\u202d", 50_000),
		"anchors then nothing":   "المبلغ\nبتاريخ\nالدفع الى\nرقم البطاقة\n",
		"repeated anchors":       strings.Repeat("المبلغ\nAED 1.00\n", 20_000),
		"amount then 100k zeros": "إشعار مشتريات\nالمبلغ\nAED " + strings.Repeat("0", 100_000) + ".00\n",
	}
	for name, body := range bodies {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Errorf("%s: panic: %v", name, r)
				}
			}()
			_, _ = Execute(d, "", body)
			_, _ = Execute(d, "", "إشعار مشتريات\n"+body)
		}()
	}
}

func TestCompiledIsSafeForConcurrentUse(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	c, err := Compile(d)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				e, err := c.Execute("", dibCardBody)
				if err != nil || e.AmountMinor != 25000 || e.Merchant != "CARREFOUR DUBAI" {
					t.Errorf("concurrent execute: %+v %v", e, err)
					return
				}
			}
		}()
	}
	wg.Wait()
}

func TestExecuteMatchesExactlyWhenItReturnsNoError(t *testing.T) {
	d := mustLoad(t, "testdata/dib.card.v1.json")
	for _, body := range []string{
		dibCardBody,
		"",
		"إشعار مشتريات\n",
		strings.Replace(dibCardBody, "AED 250.00", "AED 250", 1),
		strings.Repeat("\n", 100),
	} {
		e, err := Execute(d, "", body)
		if e.Matched != (err == nil) {
			t.Fatalf("body %q: Matched = %v, err = %v", body, e.Matched, err)
		}
	}
}

func smsDef(t *testing.T, layouts string) Definition {
	t.Helper()
	return mustDef(t, fmt.Sprintf(`{
	  "id":"sms","version":1,"bank":"t","channel":"sms","normalizer_version":1,
	  "match":{"sms_sender":["BANK-SMS","AD-Bank"]},
	  "default_currency":"AED","date_from":"received",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","patterns":["Amt: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"date","type":"date","source":"body","layouts":[%s],
	     "patterns":["Date: (?P<d>[^\\n]+)"]}
	  ],
	  "required":["amount","direction"]}`, layouts))
}

func TestTheTimedNumericLayoutReadsAsGoReadsIt(t *testing.T) {
	d := smsDef(t, `"DD-MM-YYYY HH:mm"`)
	for _, tc := range []struct {
		text string
		want string
		why  string
	}{
		{"05-06-2026 14:30", "2026-06-05T14:30:00Z", "24-hour clock"},
		{"05-06-2026 00:00", "2026-06-05T00:00:00Z", "midnight"},
		{"05-06-2026 23:59", "2026-06-05T23:59:00Z", "the last minute"},
		{"05-06-2026 8:05", "2026-06-05T08:05:00Z", "Go's 15 accepts a one-digit hour"},
		{"05-06-2026 24:00", "", "hour 24 is out of range"},
		{"05-06-2026 12:60", "", "minute 60 is out of range"},
		{"05-06-2026 12:5", "", "the minute needs two digits"},
		{"05-06-2026 123:45", "", "three hour digits leave trailing text"},
		{"05-06-2026", "", "the timed layout needs the time"},
		{"05-06-2026 14:30 extra", "", "trailing text, and the first token has no time"},
		{"05-06-2026  14:30", "", "two spaces: no whole-string attempt, and the first token has no time"},
		{"05-06-2026T14:30", "", "the separator is one U+0020"},
		{"31-02-2026 10:00", "", "calendar ranges are checked"},
	} {
		e, err := Execute(d, "", "Amt: 1.00\nDate: "+tc.text)
		if err != nil {
			t.Fatalf("%q: %v", tc.text, err)
		}
		got := ""
		if !e.PostedAt.IsZero() {
			got = e.PostedAt.Format(time.RFC3339)
		}
		if got != tc.want {
			t.Errorf("%q (%s): got %q, want %q", tc.text, tc.why, got, tc.want)
		}
	}
	both := smsDef(t, `"DD-MM-YYYY HH:mm","DD-MM-YYYY"`)
	e, err := Execute(both, "", "Amt: 1.00\nDate: 05-06-2026 garbage")
	if err != nil || e.PostedAt.Format(time.RFC3339) != "2026-06-05T00:00:00Z" {
		t.Fatalf("the date-only layout after the timed one reads the first token: %v %v", e.PostedAt, err)
	}
}

func TestDateFromReceivedLeavesTheDateToTheCallerOnlyWhenTheTextHasNone(t *testing.T) {
	d := smsDef(t, `"DD-MM-YYYY HH:mm"`)
	e, err := Execute(d, "", "Amt: 12.34\nDate: 05-06-2026 14:30")
	if err != nil || !e.Matched {
		t.Fatalf("a dated text must match: %v", err)
	}
	if e.PostedAt.Format(time.RFC3339) != "2026-06-05T14:30:00Z" {
		t.Fatalf("the text's own date wins: %v", e.PostedAt)
	}
	e, err = Execute(d, "", "Amt: 12.34")
	if err != nil || !e.Matched {
		t.Fatalf("an undated text still matches under date_from received: %v", err)
	}
	if !e.PostedAt.IsZero() {
		t.Fatalf("no date in the text leaves PostedAt zero for the receive time: %v", e.PostedAt)
	}
	noDateEntry := mustDef(t, `{
	  "id":"sms","version":1,"bank":"t","channel":"sms","normalizer_version":1,
	  "match":{"sms_sender":["BANK-SMS"]},"default_currency":"AED","date_from":"received",
	  "extract":[{"field":"amount","type":"amount","source":"body","patterns":["Amt: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"credit"}],
	  "required":["amount","direction"]}`)
	if e, err := Execute(noDateEntry, "", "Amt: 1.00"); err != nil || !e.Matched || !e.PostedAt.IsZero() {
		t.Fatalf("date_from received needs no date entry: %+v %v", e, err)
	}
}

func TestCompileHoldsTheChannelRules(t *testing.T) {
	for name, src := range map[string]string{
		"an unknown channel": `{"id":"x","version":1,"bank":"t","channel":"fax","normalizer_version":1,
		  "match":{"sms_sender":["B"]},"default_currency":"AED","date_from":"received",
		  "extract":[{"field":"direction","type":"const","source":"body","value":"debit"}],"required":["direction"]}`,
		"sms with date_from body": `{"id":"x","version":1,"bank":"t","channel":"sms","normalizer_version":1,
		  "match":{"sms_sender":["B"]},"default_currency":"AED","date_from":"body",
		  "extract":[{"field":"date","type":"date","source":"body","layouts":["DD-MM-YYYY"],
		    "patterns":["(?P<d>[^\\n]+)"]}],"required":["direction"]}`,
		"sms with date_from email": `{"id":"x","version":1,"bank":"t","channel":"sms","normalizer_version":1,
		  "match":{"sms_sender":["B"]},"default_currency":"AED","date_from":"email",
		  "extract":[{"field":"direction","type":"const","source":"body","value":"debit"}],"required":["direction"]}`,
		"mail with date_from received": `{"id":"x","version":1,"bank":"t","normalizer_version":1,
		  "match":{"sender_domain":["example.com"]},"default_currency":"AED","date_from":"received",
		  "extract":[{"field":"direction","type":"const","source":"body","value":"debit"}],"required":["direction"]}`,
		"received with a required date": `{"id":"x","version":1,"bank":"t","channel":"sms","normalizer_version":1,
		  "match":{"sms_sender":["B"]},"default_currency":"AED","date_from":"received",
		  "extract":[{"field":"date","type":"date","source":"body","layouts":["DD-MM-YYYY"],
		    "patterns":["(?P<d>[^\\n]+)"]}],"required":["direction","date"]}`,
		"sms with no sms_sender": `{"id":"x","version":1,"bank":"t","channel":"sms","normalizer_version":1,
		  "match":{"sms_sender":[]},"default_currency":"AED","date_from":"received",
		  "extract":[{"field":"direction","type":"const","source":"body","value":"debit"}],"required":["direction"]}`,
		"sms with an absent match": `{"id":"x","version":1,"bank":"t","channel":"sms","normalizer_version":1,
		  "match":{},"default_currency":"AED","date_from":"received",
		  "extract":[{"field":"direction","type":"const","source":"body","value":"debit"}],"required":["direction"]}`,
		"sms with a sender_domain": `{"id":"x","version":1,"bank":"t","channel":"sms","normalizer_version":1,
		  "match":{"sms_sender":["B"],"sender_domain":["dib.ae"]},"default_currency":"AED","date_from":"received",
		  "extract":[{"field":"direction","type":"const","source":"body","value":"debit"}],"required":["direction"]}`,
		"sms with subject_contains": `{"id":"x","version":1,"bank":"t","channel":"sms","normalizer_version":1,
		  "match":{"sms_sender":["B"],"subject_contains":["Alert"]},"default_currency":"AED","date_from":"received",
		  "extract":[{"field":"direction","type":"const","source":"body","value":"debit"}],"required":["direction"]}`,
		"sms reading the subject": `{"id":"x","version":1,"bank":"t","channel":"sms","normalizer_version":1,
		  "match":{"sms_sender":["B"]},"default_currency":"AED","date_from":"received",
		  "extract":[{"field":"direction","type":"const","source":"body","value":"debit"},
		    {"field":"merchant","type":"text","source":"subject","patterns":["(?P<v>[^\\n]+)"]}],"required":["direction"]}`,
		"mail with an sms_sender": `{"id":"x","version":1,"bank":"t","normalizer_version":1,
		  "match":{"sender_domain":["example.com"],"sms_sender":["B"]},"default_currency":"AED","date_from":"email",
		  "extract":[{"field":"direction","type":"const","source":"body","value":"debit"}],"required":["direction"]}`,
		"sms with an unknown transfer role": `{"id":"x","version":1,"bank":"t","channel":"sms","transfer_role":"both","normalizer_version":1,
		  "match":{"sms_sender":["B"]},"default_currency":"AED","date_from":"received",
		  "extract":[{"field":"direction","type":"const","source":"body","value":"debit"}],"required":["direction"]}`,
		"mail with a transfer role": `{"id":"x","version":1,"bank":"t","transfer_role":"alert","normalizer_version":1,
		  "match":{"sender_domain":["example.com"]},"default_currency":"AED","date_from":"email",
		  "extract":[{"field":"direction","type":"const","source":"body","value":"debit"}],"required":["direction"]}`,
	} {
		d, err := ParseDefinition([]byte(src))
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if _, err := Compile(d); !errors.Is(err, ErrDefinition) {
			t.Errorf("%s: Compile returned %v, want ErrDefinition", name, err)
		}
	}
}

func TestCompileTakesATransferRoleOnlyOnAText(t *testing.T) {
	for _, role := range []string{"", TransferRoleNotice, TransferRoleAlert} {
		d := smsDef(t, `"DD-MM-YYYY"`)
		d.TransferRole = role
		c, err := Compile(d)
		if err != nil {
			t.Fatalf("role %q: %v", role, err)
		}
		if c.Definition().TransferRole != role {
			t.Fatalf("role %q not kept: %q", role, c.Definition().TransferRole)
		}
	}
	mail := mustLoad(t, "testdata/dib.transfer.v1.json")
	if _, err := Compile(mail); err != nil {
		t.Fatal(err)
	}
	mail.TransferRole = TransferRoleNotice
	if _, err := Compile(mail); !errors.Is(err, ErrDefinition) {
		t.Fatalf("a mail template with a transfer role must not compile: %v", err)
	}
}

func TestMatchesSMSSenderIsExactAndIgnoresASCIICase(t *testing.T) {
	d := smsDef(t, `"DD-MM-YYYY"`)
	for _, tc := range []struct {
		sender string
		want   bool
	}{
		{"BANK-SMS", true},
		{"bank-sms", true},
		{"Bank-Sms", true},
		{" BANK-SMS\n", true},
		{"AD-BANK", true},
		{"BANK-SMS2", false},
		{"BANK", false},
		{"XBANK-SMS", false},
		{"BANK SMS", false},
		{"", false},
		{"   ", false},
		{"BANK-SMS\u00a0", false},
		{" \t\v\f\r\nBANK-SMS\v", true},
		{"\u0085BANK-SMS", false},
	} {
		if got := MatchesSMSSender(d, tc.sender); got != tc.want {
			t.Errorf("MatchesSMSSender(%q) = %v, want %v", tc.sender, got, tc.want)
		}
	}
	mail := mustLoad(t, "testdata/dib.card.v1.json")
	mail.Match.SMSSender = []string{"BANK-SMS"}
	if MatchesSMSSender(mail, "BANK-SMS") {
		t.Fatal("a mail template never matches a text sender")
	}
	d.Match.SenderDomain = []string{"example.com"}
	if _, err := Compile(d); !errors.Is(err, ErrDefinition) {
		t.Fatalf("an sms template that names a mail domain must not compile: %v", err)
	}
	if MatchesSenderDomain(d, "example.com") || MatchesSenderDomain(d, "alerts.example.com") {
		t.Fatal("an sms template never matches a mail domain, even one it names")
	}
}

func TestAnSMSTemplateWitnessesNoDecode(t *testing.T) {
	d := smsDef(t, `"DD-MM-YYYY"`)
	d.Match.BodyContains = []string{"مشتريات"}
	if w := d.DecodeWitnesses(); w != nil {
		t.Fatalf("a text is not decoded from bytes, so nothing witnesses a decode: %q", w)
	}
}
