package tmpl

import (
	"errors"
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	MaxBodyBytes    = 2_000_000
	MaxSubjectBytes = 64_000
	MaxCaptureRunes = 512
	MaxEmptyGroups  = 32
)

var (
	ErrNoMatch      = errors.New("tmpl: the message does not match this template")
	ErrMissingField = errors.New("tmpl: a required field was not produced")
	ErrDefinition   = errors.New("tmpl: the definition cannot be executed")
	ErrTooLarge     = errors.New("tmpl: input exceeds the executor size bound")
)

type Extraction struct {
	AmountMinor int64
	Currency    string
	Direction   string
	PostedAt    time.Time
	Merchant    string
	Last4       string
	IsTransfer  bool
	EmptyGroups []string
	Matched     bool
}

func (e Extraction) Produced(field string) bool {
	switch field {
	case FieldAmount:
		return e.Currency != ""
	case FieldDate:
		return !e.PostedAt.IsZero()
	case FieldMerchant:
		return e.Merchant != ""
	case FieldLast4:
		return e.Last4 != ""
	case FieldDirection:
		return e.Direction != ""
	default:
		return false
	}
}

type Compiled struct {
	def     Definition
	entries []compiledEntry
}

type compiledEntry struct {
	x       Extract
	res     []*regexp.Regexp
	onMatch []string
}

func (c *Compiled) Definition() Definition { return c.def }

func Compile(d Definition) (*Compiled, error) {
	if !currencyRe.MatchString(d.DefaultCurrency) {
		return nil, fmt.Errorf("%w: default_currency %q is not three upper-case letters, so no amount could carry a currency",
			ErrDefinition, d.DefaultCurrency)
	}
	switch {
	case !d.channelKnown():
		return nil, fmt.Errorf("%w: channel %q is neither %q nor %q", ErrDefinition, d.Channel, ChannelMail, ChannelSMS)
	case d.IsSMS() && d.DateFrom != DateFromReceived:
		return nil, fmt.Errorf("%w: an sms template's date_from %q is not %q", ErrDefinition, d.DateFrom, DateFromReceived)
	case !d.IsSMS() && d.DateFrom != DateFromBody && d.DateFrom != DateFromEmail:
		return nil, fmt.Errorf("%w: date_from %q is neither %q nor %q", ErrDefinition, d.DateFrom, DateFromBody, DateFromEmail)
	case d.IsSMS() && len(d.Match.SMSSender) == 0:
		return nil, fmt.Errorf("%w: an sms template names no sms_sender", ErrDefinition)
	case d.IsSMS() && len(d.Match.SenderDomain) > 0:
		return nil, fmt.Errorf("%w: an sms template names a sender_domain, and a text has no signing domain", ErrDefinition)
	case d.IsSMS() && len(d.Match.SubjectContains) > 0:
		return nil, fmt.Errorf("%w: an sms template has subject_contains, and a text has no subject", ErrDefinition)
	case !d.IsSMS() && len(d.Match.SMSSender) > 0:
		return nil, fmt.Errorf("%w: a mail template names an sms_sender", ErrDefinition)
	case !d.transferRoleKnown():
		return nil, fmt.Errorf("%w: transfer_role %q is neither %q nor %q", ErrDefinition, d.TransferRole, TransferRoleNotice, TransferRoleAlert)
	case !d.IsSMS() && d.TransferRole != "":
		return nil, fmt.Errorf("%w: a mail template names a transfer_role", ErrDefinition)
	}
	for i, x := range d.Extract {
		if d.IsSMS() && x.Source == SourceSubject {
			return nil, fmt.Errorf("%w: extract[%d]: an sms template reads the body only, and a text has no subject", ErrDefinition, i)
		}
	}
	for _, f := range d.Required {
		if _, ok := fieldTypes[f]; !ok {
			return nil, fmt.Errorf("%w: required names %q, which is not a field", ErrDefinition, f)
		}
		if f == FieldIsTransfer {
			return nil, fmt.Errorf("%w: is_transfer cannot be required — a flag that is false is "+
				"indistinguishable from one that was never set, so the requirement could never be enforced", ErrDefinition)
		}
		if f == FieldDate && d.DateFrom == DateFromReceived {
			return nil, fmt.Errorf("%w: date cannot be required when date_from is %q", ErrDefinition, DateFromReceived)
		}
	}

	c := &Compiled{def: d, entries: make([]compiledEntry, 0, len(d.Extract))}
	dates := 0
	for i, x := range d.Extract {
		ce, err := compileEntry(i, x)
		if err != nil {
			return nil, err
		}
		if x.Field == FieldDate {
			dates++
		}
		c.entries = append(c.entries, ce)
	}
	switch {
	case d.DateFrom == DateFromBody && dates == 0:
		return nil, fmt.Errorf("%w: date_from is %q but no extract entry produces a date", ErrDefinition, DateFromBody)
	case d.DateFrom == DateFromEmail && dates > 0:
		return nil, fmt.Errorf("%w: date_from is %q but %d extract entries produce a date", ErrDefinition, DateFromEmail, dates)
	}
	return c, nil
}

func compileEntry(i int, x Extract) (compiledEntry, error) {
	fail := func(format string, args ...any) (compiledEntry, error) {
		return compiledEntry{}, fmt.Errorf("%w: extract[%d]: "+format, append([]any{ErrDefinition, i}, args...)...)
	}
	types, ok := fieldTypes[x.Field]
	if !ok {
		return fail("field %q is not a field name", x.Field)
	}
	spec, ok := groupNamesByType[x.Type]
	if !ok {
		return fail("type %q is not a type", x.Type)
	}
	if !slices.Contains(types, x.Type) {
		return fail("field %q cannot be extracted as type %q", x.Field, x.Type)
	}
	if x.Source != SourceBody && x.Source != SourceSubject {
		return fail("source %q is neither %q nor %q", x.Source, SourceBody, SourceSubject)
	}

	isConst := x.Type == TypeConst || x.Type == TypeFlag
	if isConst {
		if err := checkLiteral(x.Field, x.Value); err != nil {
			return fail("%s", err)
		}
	} else if len(x.Patterns) == 0 {
		return fail("a %s entry with no patterns can never produce a value", x.Type)
	}
	for f, v := range x.OnMatch {
		if err := checkLiteral(f, v); err != nil {
			return fail("on_match: %s", err)
		}
	}
	if x.Type == TypeDate {
		if len(x.Layouts) == 0 {
			return fail("a date entry with no layouts can never convert its capture")
		}
		for _, l := range x.Layouts {
			if _, ok := goDateLayouts[l]; !ok {
				return fail("layout %q is not one of the supported layouts", l)
			}
		}
	}

	ce := compiledEntry{x: x, res: make([]*regexp.Regexp, 0, len(x.Patterns)), onMatch: slices.Sorted(maps.Keys(x.OnMatch))}
	for j, p := range x.Patterns {
		re, err := CompileGo(p, x.Flags)
		if err != nil {
			return fail("patterns[%d] does not compile: %v", j, err)
		}
		names := re.SubexpNames()
		for _, want := range spec.required {
			if !slices.Contains(names, want) {
				return fail("patterns[%d] does not capture (?P<%s>...), so a %s entry could never read a value from it",
					j, want, x.Type)
			}
		}
		for _, n := range names {
			if n == "" {
				continue
			}
			if !reEmptyGroupLabel.MatchString(emptyGroupLabel(x.Field, n)) {
				return fail("patterns[%d] group %q would produce the diagnostics label %q, which is not a bounded identifier",
					j, n, emptyGroupLabel(x.Field, n))
			}
		}
		ce.res = append(ce.res, re)
	}
	return ce, nil
}

func checkLiteral(field, value string) error {
	switch field {
	case FieldDirection:
		if value != "debit" && value != "credit" {
			return fmt.Errorf("direction %q is neither debit nor credit", value)
		}
	case FieldIsTransfer:
		if value != "true" && value != "false" {
			return fmt.Errorf("is_transfer %q is neither true nor false", value)
		}
	case FieldMerchant, FieldLast4:
		if value == "" {
			return fmt.Errorf("%s cannot be set to the empty string: an unset field and a field set to \"\" are the same thing to every reader", field)
		}
		if utf8.RuneCountInString(value) > MaxCaptureRunes {
			return fmt.Errorf("%s literal is longer than %d runes", field, MaxCaptureRunes)
		}
	default:
		return fmt.Errorf("%s cannot be set from a literal value", field)
	}
	return nil
}

func Execute(d Definition, subject, normalizedBody string) (Extraction, error) {
	c, err := Compile(d)
	if err != nil {
		return Extraction{}, err
	}
	return c.Execute(subject, normalizedBody)
}

func (c *Compiled) Execute(subject, normalizedBody string) (Extraction, error) {
	if len(normalizedBody) > MaxBodyBytes {
		return Extraction{}, fmt.Errorf("%w: normalized body is %d bytes, limit %d",
			ErrTooLarge, len(normalizedBody), MaxBodyBytes)
	}
	if len(subject) > MaxSubjectBytes {
		return Extraction{}, fmt.Errorf("%w: subject is %d bytes, limit %d",
			ErrTooLarge, len(subject), MaxSubjectBytes)
	}
	if err := c.gate(subject, normalizedBody); err != nil {
		return Extraction{}, err
	}

	st := &execState{set: map[string]bool{}, empty: map[string]bool{}, refused: map[string]bool{}}
	for _, ce := range c.entries {
		if st.refused[ce.x.Field] || (st.set[ce.x.Field] && !ce.x.Override) {
			continue
		}
		src := normalizedBody
		if ce.x.Source == SourceSubject {
			src = subject
		}
		produced, err := c.runEntry(st, ce, src)
		if err != nil {
			return st.finish(), err
		}
		if !produced {
			continue
		}
		for _, f := range ce.onMatch {
			if st.set[f] {
				continue
			}
			if err := st.setLiteral(f, ce.x.OnMatch[f]); err != nil {
				return st.finish(), err
			}
		}
	}

	e := st.finish()
	if err := ValidateExtraction(e, c.def); err != nil {
		return e, err
	}
	e.Matched = true
	return e, nil
}

func (c *Compiled) gate(subject, body string) error {
	for _, s := range c.def.Match.SubjectContains {
		if !strings.Contains(subject, s) {
			return fmt.Errorf("%w: the subject does not contain %q", ErrNoMatch, s)
		}
	}
	for _, s := range c.def.Match.BodyContains {
		if !strings.Contains(body, s) {
			return fmt.Errorf("%w: the body does not contain %q", ErrNoMatch, s)
		}
	}
	for _, s := range c.def.Match.BodyNotContains {
		if strings.Contains(body, s) {
			return fmt.Errorf("%w: the body contains %q", ErrNoMatch, s)
		}
	}
	return nil
}

func (c *Compiled) runEntry(st *execState, ce compiledEntry, src string) (bool, error) {
	x := ce.x
	if len(ce.res) == 0 {
		return true, st.setLiteral(x.Field, x.Value)
	}
	for _, re := range ce.res {
		idx := re.FindStringSubmatchIndex(src)
		if idx == nil {
			continue
		}
		st.recordEmptyGroups(x.Field, re, idx)

		switch x.Type {
		case TypeConst, TypeFlag:
			return true, st.setLiteral(x.Field, x.Value)

		case TypeAmount:
			amt, ok := group(src, re, idx, "amt")
			if !ok {
				continue
			}
			ccy, _ := group(src, re, idx, "ccy")
			minor, currency, ok := convertAmount(amt, ccy, c.def.DefaultCurrency)
			if !ok {
				if currencyRefused(ccy, c.def.DefaultCurrency) {
					st.refused[x.Field] = true
					return false, nil
				}
				continue
			}
			st.out.AmountMinor, st.out.Currency = minor, currency
			st.mark(x.Field)
			return true, nil

		case TypeDate:
			text, ok := group(src, re, idx, "d")
			if !ok {
				continue
			}
			when, ok := convertDate(text, x.Layouts)
			if !ok {
				continue
			}
			st.out.PostedAt = when
			st.mark(x.Field)
			return true, nil

		case TypeText:
			text, ok := group(src, re, idx, "v")
			if !ok {
				continue
			}
			value, ok := convertText(text)
			if !ok {
				continue
			}
			return true, st.setLiteral(x.Field, value)

		case TypeLast4:
			text, ok := group(src, re, idx, "v")
			if !ok {
				continue
			}
			value, ok := convertLast4(text)
			if !ok {
				continue
			}
			return true, st.setLiteral(x.Field, value)

		default:
			return false, fmt.Errorf("%w: type %q has no conversion", ErrDefinition, x.Type)
		}
	}
	return false, nil
}

type execState struct {
	out     Extraction
	set     map[string]bool
	empty   map[string]bool
	refused map[string]bool
}

func (st *execState) mark(field string) { st.set[field] = true }

func (st *execState) setLiteral(field, value string) error {
	switch field {
	case FieldDirection:
		st.out.Direction = value
	case FieldMerchant:
		st.out.Merchant = value
	case FieldLast4:
		st.out.Last4 = value
	case FieldIsTransfer:
		st.out.IsTransfer = value == "true"
	default:
		return fmt.Errorf("%w: %s cannot be set from the literal %q", ErrDefinition, field, value)
	}
	st.mark(field)
	return nil
}

func (st *execState) recordEmptyGroups(field string, re *regexp.Regexp, idx []int) {
	for gi, name := range re.SubexpNames() {
		if gi == 0 || name == "" || 2*gi+1 >= len(idx) {
			continue
		}
		start, end := idx[2*gi], idx[2*gi+1]
		if start < 0 || start != end {
			continue
		}
		st.empty[emptyGroupLabel(field, name)] = true
	}
}

func (st *execState) finish() Extraction {
	out := st.out
	if len(st.empty) > 0 {
		labels := slices.Sorted(maps.Keys(st.empty))
		if len(labels) > MaxEmptyGroups {
			labels = labels[:MaxEmptyGroups]
		}
		out.EmptyGroups = labels
	}
	return out
}

func emptyGroupLabel(field, group string) string { return field + "_" + group }

var reEmptyGroupLabel = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,31}$`)

func group(src string, re *regexp.Regexp, idx []int, name string) (string, bool) {
	gi := re.SubexpIndex(name)
	if gi < 0 || 2*gi+1 >= len(idx) {
		return "", false
	}
	start, end := idx[2*gi], idx[2*gi+1]
	if start < 0 {
		return "", false
	}
	return src[start:end], true
}

const trimCutset = " \t\n\v\f\r"

func trimCapture(s string) string { return strings.Trim(s, trimCutset) }

var amountShapeRe = regexp.MustCompile(`^[0-9]+\.[0-9]{2}$`)

func convertAmount(amt, ccy, defaultCurrency string) (int64, string, bool) {
	amt = trimCapture(amt)
	if utf8.RuneCountInString(amt) > MaxCaptureRunes {
		return 0, "", false
	}
	digits := strings.ReplaceAll(amt, ",", "")
	if !amountShapeRe.MatchString(digits) {
		return 0, "", false
	}
	minor, err := strconv.ParseInt(strings.Replace(digits, ".", "", 1), 10, 64)
	if err != nil {
		return 0, "", false
	}
	currency, ok := resolveCurrency(ccy, defaultCurrency)
	if !ok {
		return 0, "", false
	}
	if _, ok := nonTwoDecimalCurrencies[currency]; ok {
		return 0, "", false
	}
	return minor, currency, true
}

func resolveCurrency(ccy, defaultCurrency string) (string, bool) {
	c := asciiUpper(trimCapture(ccy))
	if c == "" {
		return defaultCurrency, true
	}
	return c, currencyRe.MatchString(c)
}

func currencyRefused(ccy, defaultCurrency string) bool {
	currency, ok := resolveCurrency(ccy, defaultCurrency)
	if !ok {
		return false
	}
	_, ok = nonTwoDecimalCurrencies[currency]
	return ok
}

var nonTwoDecimalCurrencies = map[string]struct{}{
	"BHD": {}, "IQD": {}, "JOD": {}, "KWD": {}, "LYD": {}, "OMR": {}, "TND": {},
	"BIF": {}, "CLP": {}, "DJF": {}, "GNF": {}, "ISK": {}, "JPY": {}, "KMF": {}, "KRW": {},
	"PYG": {}, "RWF": {}, "UGX": {}, "UYI": {}, "VND": {}, "VUV": {}, "XAF": {}, "XOF": {}, "XPF": {},
}

func asciiUpper(s string) string {
	b := []byte(s)
	for i := range b {
		if b[i] >= 'a' && b[i] <= 'z' {
			b[i] -= 'a' - 'A'
		}
	}
	return string(b)
}

var goDateLayouts = map[string]string{
	LayoutDDMMYYYY:       "02-01-2006",
	LayoutDDMonYYYYHHMMA: "02/Jan/2006 03:04 PM",
	LayoutDDMonYYYY:      "02/Jan/2006",
	LayoutDDMMYYYYHHmm:   "02-01-2006 15:04",
}

func convertDate(text string, layouts []string) (time.Time, bool) {
	text = trimCapture(text)
	if utf8.RuneCountInString(text) > MaxCaptureRunes {
		return time.Time{}, false
	}
	for _, l := range layouts {
		layout, ok := goDateLayouts[l]
		if !ok {
			continue
		}
		if t, ok := parseLayout(text, layout); ok {
			return t, true
		}
	}
	return time.Time{}, false
}

func parseLayout(text, layout string) (time.Time, bool) {
	if !strings.Contains(text, "  ") {
		if t, err := time.Parse(layout, text); err == nil {
			return t, true
		}
	}
	if i := strings.IndexByte(text, ' '); i >= 0 {
		if t, err := time.Parse(layout, text[:i]); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

func convertText(s string) (string, bool) {
	s = trimCapture(s)
	if s == "" || utf8.RuneCountInString(s) > MaxCaptureRunes {
		return "", false
	}
	return s, true
}

func convertLast4(s string) (string, bool) {
	if utf8.RuneCountInString(s) > MaxCaptureRunes {
		return "", false
	}
	digits := make([]byte, 0, 4)
	for i := 0; i < len(s); i++ {
		if s[i] >= '0' && s[i] <= '9' {
			digits = append(digits, s[i])
			if len(digits) > 4 {
				digits = digits[1:]
			}
		}
	}
	if len(digits) == 0 {
		return "", false
	}
	return string(digits), true
}

func MatchesSenderDomain(d Definition, verified string) bool {
	if d.IsSMS() {
		return false
	}
	v := asciiLower(strings.TrimSuffix(strings.TrimSpace(verified), "."))
	if !domainRe.MatchString(v) {
		return false
	}
	for _, listed := range d.Match.SenderDomain {
		l := asciiLower(listed)
		if l == "" {
			continue
		}
		if v == l || strings.HasSuffix(v, "."+l) {
			return true
		}
	}
	return false
}

func MatchesSMSSender(d Definition, sender string) bool {
	if !d.IsSMS() {
		return false
	}
	s := asciiLower(trimCapture(sender))
	if s == "" {
		return false
	}
	for _, listed := range d.Match.SMSSender {
		if asciiLower(listed) == s {
			return true
		}
	}
	return false
}

func asciiLower(s string) string {
	b := []byte(s)
	for i := range b {
		if b[i] >= 'A' && b[i] <= 'Z' {
			b[i] += 'a' - 'A'
		}
	}
	return string(b)
}

var last4Re = regexp.MustCompile(`^[0-9]{1,4}$`)

func ValidateExtraction(e Extraction, d Definition) error {
	for _, f := range d.Required {
		if _, ok := fieldTypes[f]; !ok {
			return fmt.Errorf("%w: required names %q, which is not a field", ErrDefinition, f)
		}
		if f == FieldIsTransfer {
			return fmt.Errorf("%w: is_transfer cannot be required", ErrDefinition)
		}
		if !e.Produced(f) {
			return fmt.Errorf("%w: %s", ErrMissingField, f)
		}
	}
	switch {
	case e.AmountMinor < 0:
		return fmt.Errorf("%w: amount %d is negative; amounts are always positive and direction carries the sign",
			ErrDefinition, e.AmountMinor)
	case e.AmountMinor != 0 && e.Currency == "":
		return fmt.Errorf("%w: an amount was extracted with no currency", ErrDefinition)
	case e.Currency != "" && !currencyRe.MatchString(e.Currency):
		return fmt.Errorf("%w: currency %q is not three upper-case letters", ErrDefinition, e.Currency)
	case e.Direction != "" && e.Direction != "debit" && e.Direction != "credit":
		return fmt.Errorf("%w: direction %q is neither debit nor credit", ErrDefinition, e.Direction)
	case e.Last4 != "" && !last4Re.MatchString(e.Last4):
		return fmt.Errorf("%w: last4 %q is not one to four digits", ErrDefinition, e.Last4)
	case utf8.RuneCountInString(e.Merchant) > MaxCaptureRunes:
		return fmt.Errorf("%w: merchant is %d runes, limit %d",
			ErrDefinition, utf8.RuneCountInString(e.Merchant), MaxCaptureRunes)
	case d.DateFrom == DateFromEmail && !e.PostedAt.IsZero():
		return fmt.Errorf("%w: date_from is %q but a date was extracted from the message body",
			ErrDefinition, DateFromEmail)
	}
	return nil
}
