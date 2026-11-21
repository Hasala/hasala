package tmpl

import (
	"bytes"
	"encoding/json"
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

type Definition struct {
	ID                string    `json:"id"`
	Version           int       `json:"version"`
	Bank              string    `json:"bank"`
	NormalizerVersion int       `json:"normalizer_version"`
	Channel           string    `json:"channel,omitempty"`
	TransferRole      string    `json:"transfer_role,omitempty"`
	Match             Match     `json:"match"`
	DefaultCurrency   string    `json:"default_currency"`
	DateFrom          string    `json:"date_from"`
	Extract           []Extract `json:"extract"`
	Required          []string  `json:"required"`
}

type Match struct {
	SenderDomain    []string `json:"sender_domain"`
	SMSSender       []string `json:"sms_sender,omitempty"`
	SubjectContains []string `json:"subject_contains,omitempty"`
	BodyContains    []string `json:"body_contains,omitempty"`
	BodyNotContains []string `json:"body_not_contains,omitempty"`
}

type Extract struct {
	Field    string            `json:"field"`
	Type     string            `json:"type"`
	Source   string            `json:"source"`
	Patterns []string          `json:"patterns,omitempty"`
	Flags    []string          `json:"flags,omitempty"`
	Layouts  []string          `json:"layouts,omitempty"`
	Value    string            `json:"value,omitempty"`
	Override bool              `json:"override,omitempty"`
	Why      string            `json:"why,omitempty"`
	OnMatch  map[string]string `json:"on_match,omitempty"`
}

const (
	LayoutDDMMYYYY       = "DD-MM-YYYY"
	LayoutDDMonYYYYHHMMA = "DD/Mon/YYYY hh:mm A"
	LayoutDDMonYYYY      = "DD/Mon/YYYY"
	LayoutDDMMYYYYHHmm   = "DD-MM-YYYY HH:mm"
)

const (
	ChannelMail = "mail"
	ChannelSMS  = "sms"
)

const (
	TransferRoleNotice = "notice"
	TransferRoleAlert  = "alert"
)

func (d Definition) IsSMS() bool { return d.Channel == ChannelSMS }

func (d Definition) transferRoleKnown() bool {
	return d.TransferRole == "" || d.TransferRole == TransferRoleNotice || d.TransferRole == TransferRoleAlert
}

func (d Definition) alwaysDebit() bool {
	for _, e := range d.Extract {
		if v, ok := e.OnMatch[FieldDirection]; ok && v != "debit" {
			return false
		}
		if e.Field == FieldDirection && e.Value != "debit" {
			return false
		}
	}
	return true
}

func (d Definition) channelKnown() bool {
	return d.Channel == "" || d.Channel == ChannelMail || d.Channel == ChannelSMS
}

const (
	FieldAmount     = "amount"
	FieldDate       = "date"
	FieldMerchant   = "merchant"
	FieldLast4      = "last4"
	FieldDirection  = "direction"
	FieldIsTransfer = "is_transfer"

	TypeAmount = "amount"
	TypeDate   = "date"
	TypeText   = "text"
	TypeLast4  = "last4"
	TypeConst  = "const"
	TypeFlag   = "flag"

	SourceBody    = "body"
	SourceSubject = "subject"

	DateFromBody     = "body"
	DateFromEmail    = "email"
	DateFromReceived = "received"
)

var fieldTypes = map[string][]string{
	FieldAmount:     {TypeAmount},
	FieldDate:       {TypeDate},
	FieldMerchant:   {TypeText, TypeConst},
	FieldLast4:      {TypeLast4, TypeConst},
	FieldDirection:  {TypeConst},
	FieldIsTransfer: {TypeFlag},
}

var groupNamesByType = map[string]struct{ required, optional []string }{
	TypeAmount: {required: []string{"amt"}, optional: []string{"ccy"}},
	TypeDate:   {required: []string{"d"}},
	TypeText:   {required: []string{"v"}},
	TypeLast4:  {required: []string{"v"}},
	TypeConst:  {},
	TypeFlag:   {},
}

var (
	idRe        = regexp.MustCompile(`^[a-z0-9]+([._-][a-z0-9]+)*$`)
	currencyRe  = regexp.MustCompile(`^[A-Z]{3}$`)
	domainRe    = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`)
	smsSenderRe = regexp.MustCompile(`^[A-Za-z0-9+](?:[A-Za-z0-9._ -]{0,30}[A-Za-z0-9])?$`)
)

func ParseDefinition(b []byte) (Definition, error) {
	var d Definition
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&d); err != nil {
		return Definition{}, fmt.Errorf("template definition: %w", err)
	}
	if dec.More() {
		return Definition{}, fmt.Errorf("template definition: trailing data after the JSON object")
	}
	return d, nil
}

func (d Definition) Canonical() ([]byte, error) {
	if err := d.checkUTF8(); err != nil {
		return nil, err
	}
	extract := make([][]byte, 0, len(d.Extract))
	for _, e := range d.Extract {
		extract = append(extract, canonicalObject([]canonicalField{
			{"field", canonicalString(e.Field)},
			{"flags", canonicalStrings(e.Flags)},
			{"layouts", canonicalStrings(e.Layouts)},
			{"on_match", canonicalStringMap(e.OnMatch)},
			{"override", canonicalBool(e.Override)},
			{"patterns", canonicalStrings(e.Patterns)},
			{"source", canonicalString(e.Source)},
			{"type", canonicalString(e.Type)},
			{"value", canonicalString(e.Value)},
			{"why", canonicalString(e.Why)},
		}))
	}
	matchFields := []canonicalField{
		{"body_contains", canonicalStrings(d.Match.BodyContains)},
		{"body_not_contains", canonicalStrings(d.Match.BodyNotContains)},
		{"sender_domain", canonicalStrings(d.Match.SenderDomain)},
		{"subject_contains", canonicalStrings(d.Match.SubjectContains)},
	}
	if len(d.Match.SMSSender) > 0 {
		matchFields = append(matchFields, canonicalField{"sms_sender", canonicalStrings(d.Match.SMSSender)})
	}
	fields := []canonicalField{
		{"bank", canonicalString(d.Bank)},
		{"date_from", canonicalString(d.DateFrom)},
		{"default_currency", canonicalString(d.DefaultCurrency)},
		{"extract", canonicalArray(extract)},
		{"id", canonicalString(d.ID)},
		{"match", canonicalObject(matchFields)},
		{"normalizer_version", canonicalInt(d.NormalizerVersion)},
		{"required", canonicalStrings(d.Required)},
		{"version", canonicalInt(d.Version)},
	}
	if d.Channel != "" && d.Channel != ChannelMail {
		fields = append(fields, canonicalField{"channel", canonicalString(d.Channel)})
	}
	if d.TransferRole != "" {
		fields = append(fields, canonicalField{"transfer_role", canonicalString(d.TransferRole)})
	}
	return canonicalObject(fields), nil
}

func (d Definition) checkUTF8() error {
	bad := func(where, s string) error {
		return fmt.Errorf("template %s: %s is not valid UTF-8", d.ID, where)
	}
	type group struct {
		where  string
		values []string
	}
	groups := []group{
		{"id", []string{d.ID}},
		{"bank", []string{d.Bank}},
		{"default_currency", []string{d.DefaultCurrency}},
		{"date_from", []string{d.DateFrom}},
		{"channel", []string{d.Channel}},
		{"transfer_role", []string{d.TransferRole}},
		{"match.sender_domain", d.Match.SenderDomain},
		{"match.sms_sender", d.Match.SMSSender},
		{"match.subject_contains", d.Match.SubjectContains},
		{"match.body_contains", d.Match.BodyContains},
		{"match.body_not_contains", d.Match.BodyNotContains},
		{"required", d.Required},
	}
	for i, e := range d.Extract {
		onMatch := make([]string, 0, 2*len(e.OnMatch))
		for _, k := range slices.Sorted(maps.Keys(e.OnMatch)) {
			onMatch = append(onMatch, k, e.OnMatch[k])
		}
		groups = append(groups,
			group{fmt.Sprintf("extract[%d]", i), []string{e.Field, e.Type, e.Source, e.Value, e.Why}},
			group{fmt.Sprintf("extract[%d].patterns", i), e.Patterns},
			group{fmt.Sprintf("extract[%d].flags", i), e.Flags},
			group{fmt.Sprintf("extract[%d].layouts", i), e.Layouts},
			group{fmt.Sprintf("extract[%d].on_match", i), onMatch},
		)
	}
	for _, g := range groups {
		for _, s := range g.values {
			if !utf8.ValidString(s) {
				return bad(g.where, s)
			}
		}
	}
	return nil
}

type canonicalField struct {
	key string
	val []byte
}

func canonicalObject(fs []canonicalField) []byte {
	slices.SortFunc(fs, func(a, b canonicalField) int { return strings.Compare(a.key, b.key) })
	var b bytes.Buffer
	b.WriteByte('{')
	for i, f := range fs {
		if i > 0 {
			b.WriteByte(',')
		}
		b.Write(canonicalString(f.key))
		b.WriteByte(':')
		b.Write(f.val)
	}
	b.WriteByte('}')
	return b.Bytes()
}

func canonicalArray(vs [][]byte) []byte {
	var b bytes.Buffer
	b.WriteByte('[')
	for i, v := range vs {
		if i > 0 {
			b.WriteByte(',')
		}
		b.Write(v)
	}
	b.WriteByte(']')
	return b.Bytes()
}

func canonicalStrings(ss []string) []byte {
	vs := make([][]byte, 0, len(ss))
	for _, s := range ss {
		vs = append(vs, canonicalString(s))
	}
	return canonicalArray(vs)
}

func canonicalStringMap(m map[string]string) []byte {
	fs := make([]canonicalField, 0, len(m))
	for k, v := range m {
		fs = append(fs, canonicalField{k, canonicalString(v)})
	}
	return canonicalObject(fs)
}

func canonicalBool(v bool) []byte {
	if v {
		return []byte("true")
	}
	return []byte("false")
}

func canonicalInt(n int) []byte { return []byte(strconv.Itoa(n)) }

func canonicalString(s string) []byte {
	b := make([]byte, 0, len(s)+2)
	b = append(b, '"')
	for _, r := range s {
		switch r {
		case '"':
			b = append(b, '\\', '"')
		case '\\':
			b = append(b, '\\', '\\')
		case '\b':
			b = append(b, '\\', 'b')
		case '\f':
			b = append(b, '\\', 'f')
		case '\n':
			b = append(b, '\\', 'n')
		case '\r':
			b = append(b, '\\', 'r')
		case '\t':
			b = append(b, '\\', 't')
		default:
			if r < 0x20 {
				b = append(b, fmt.Sprintf(`\u%04x`, r)...)
			} else {
				b = utf8.AppendRune(b, r)
			}
		}
	}
	return append(b, '"')
}

func ValidateDefinition(d Definition) []error {
	var errs []error
	add := func(format string, args ...any) { errs = append(errs, fmt.Errorf(format, args...)) }

	if !idRe.MatchString(d.ID) {
		add("id %q must match %s", d.ID, idRe)
	}
	if d.Version < 1 {
		add("version must be >= 1, got %d", d.Version)
	}
	if d.Bank == "" {
		add("bank must not be empty")
	}
	if d.NormalizerVersion < 1 {
		add("normalizer_version must be >= 1, got %d", d.NormalizerVersion)
	}
	if !currencyRe.MatchString(d.DefaultCurrency) {
		add("default_currency %q must be three upper-case letters", d.DefaultCurrency)
	}
	switch {
	case !d.channelKnown():
		add("channel must be %q or %q, got %q", ChannelMail, ChannelSMS, d.Channel)
	case d.IsSMS():
		if d.DateFrom != DateFromReceived {
			add("an sms template's date_from must be %q, got %q", DateFromReceived, d.DateFrom)
		}
		if len(d.Match.SMSSender) == 0 {
			add("match.sms_sender must list at least one sender: it is what lets a hit file with no " +
				"review, and a text's content alone is attacker-authored")
		}
		for i, s := range d.Match.SMSSender {
			if !smsSenderRe.MatchString(s) {
				add("match.sms_sender[%d] %q must be a sender ID of letters, digits and . _ - or space", i, s)
			}
		}
		if len(d.Match.SenderDomain) > 0 {
			add("match.sender_domain must be empty on an sms template: a text has no signing domain")
		}
		if len(d.Match.SubjectContains) > 0 {
			add("match.subject_contains must be empty on an sms template: a text has no subject")
		}
		for i, e := range d.Extract {
			if e.Source == SourceSubject {
				add("extract[%d]: an sms template reads the body only; a text has no subject", i)
			}
		}
	default:
		if d.DateFrom != DateFromBody && d.DateFrom != DateFromEmail {
			add("date_from must be %q or %q, got %q", DateFromBody, DateFromEmail, d.DateFrom)
		}
		if len(d.Match.SenderDomain) == 0 {
			add("match.sender_domain must list at least one domain: without it the template would " +
				"match on message content alone, and content is attacker-authored")
		}
		if len(d.Match.SMSSender) > 0 {
			add("match.sms_sender is only meaningful on an sms template")
		}
	}
	for i, dom := range d.Match.SenderDomain {
		if !domainRe.MatchString(dom) {
			add("match.sender_domain[%d] %q must be a lower-case domain name", i, dom)
		}
	}
	if d.DateFrom == DateFromReceived && slices.Contains(d.Required, FieldDate) {
		add("required cannot include %q when date_from is %q: the receive time stands in for a missing date",
			FieldDate, DateFromReceived)
	}
	switch {
	case !d.transferRoleKnown():
		add("transfer_role must be %q or %q when it is set, got %q", TransferRoleNotice, TransferRoleAlert, d.TransferRole)
	case d.TransferRole != "" && !d.IsSMS():
		add("transfer_role is only meaningful on an sms template: the fold pairs DIB's transfer mail itself")
	case d.TransferRole != "" && !d.alwaysDebit():
		add("a template with a transfer_role must read every hit as a debit: every direction entry and " +
			"every on_match that sets direction must say \"debit\"")
	}

	if len(d.Extract) == 0 {
		add("extract must contain at least one entry")
	}

	produced := map[string]bool{}
	overrides := 0
	for i, e := range d.Extract {
		errs = append(errs, validateExtract(i, e)...)
		produced[e.Field] = true
		for f := range e.OnMatch {
			produced[f] = true
		}
		if e.Override {
			overrides++
		}
	}
	if overrides > 1 {
		add("override is set on %d entries; it exists for exactly one case (v1 dib.go:79-83 "+
			"re-deriving direction from the description suffix) and a second use means the "+
			"first-entry-wins rule is being worked around rather than expressed", overrides)
	}

	for _, f := range []string{FieldAmount, FieldDirection} {
		if !slices.Contains(d.Required, f) {
			add("required must include %q: a transaction without it is not a transaction", f)
		}
	}
	for i, f := range d.Required {
		if _, ok := fieldTypes[f]; !ok {
			add("required[%d] %q is not a field name", i, f)
			continue
		}
		if !produced[f] {
			add("required[%d] %q is not produced by any extract entry, so the template can never match", i, f)
		}
	}
	return errs
}

func validateExtract(i int, e Extract) []error {
	var errs []error
	add := func(format string, args ...any) {
		errs = append(errs, fmt.Errorf("extract[%d]: "+format, append([]any{i}, args...)...))
	}

	types, knownField := fieldTypes[e.Field]
	if !knownField {
		add("field %q is not one of %s", e.Field, strings.Join(slices.Sorted(maps.Keys(fieldTypes)), ", "))
	}
	spec, knownType := groupNamesByType[e.Type]
	if !knownType {
		add("type %q is not one of %s", e.Type, strings.Join(slices.Sorted(maps.Keys(groupNamesByType)), ", "))
	}
	if knownField && knownType && !slices.Contains(types, e.Type) {
		add("field %q cannot be extracted as type %q; legal types are %s",
			e.Field, e.Type, strings.Join(types, ", "))
	}
	if e.Source != SourceBody && e.Source != SourceSubject {
		add("source must be %q or %q, got %q", SourceBody, SourceSubject, e.Source)
	}

	isConst := e.Type == TypeConst || e.Type == TypeFlag
	switch {
	case isConst && e.Value == "":
		add("a %s entry must carry a value", e.Type)
	case !isConst && e.Value != "":
		add("value is only meaningful on const and flag entries")
	}
	if e.Type == TypeFlag && e.Value != "true" && e.Value != "false" {
		add("a flag value must be \"true\" or \"false\", got %q", e.Value)
	}
	if e.Field == FieldDirection && e.Value != "debit" && e.Value != "credit" {
		add("a direction value must be \"debit\" or \"credit\", got %q", e.Value)
	}

	if !isConst && len(e.Patterns) == 0 {
		add("a %s entry needs at least one pattern; with none it can never produce a value", e.Type)
	}
	if e.Type == TypeDate && len(e.Layouts) == 0 {
		add("a date entry needs at least one layout; with none the captured text can never convert")
	}
	if e.Type != TypeDate && len(e.Layouts) > 0 {
		add("layouts are only meaningful on a date entry")
	}
	for j, l := range e.Layouts {
		if _, ok := goDateLayouts[l]; !ok {
			add("layouts[%d] %q is not one of the supported layouts %q", j, l, slices.Sorted(maps.Keys(goDateLayouts)))
		}
	}

	if e.Override && strings.TrimSpace(e.Why) == "" {
		add(`override must carry a "why": it suspends the first-entry-wins rule, ` +
			`so the reason has to survive in the template rather than in a commit message`)
	}
	if !e.Override && e.Why != "" {
		add(`"why" is only meaningful together with override`)
	}

	for f := range e.OnMatch {
		if _, ok := fieldTypes[f]; !ok {
			add("on_match key %q is not a field name", f)
		}
	}

	for j, p := range e.Patterns {
		for _, err := range ValidatePattern(p, e.Flags) {
			errs = append(errs, fmt.Errorf("extract[%d].patterns[%d]: %w", i, j, err))
		}
		if knownType {
			errs = append(errs, validateGroupNames(i, j, e.Type, p, spec.required, spec.optional)...)
		}
	}
	return errs
}

func validateGroupNames(i, j int, typ, p string, required, optional []string) []error {
	names := GroupNames(p)
	if names == nil && !regexpCompiles(p) {
		return nil
	}
	var errs []error
	have := map[string]bool{}
	for _, n := range names {
		have[n] = true
	}
	for _, want := range required {
		if !have[want] {
			errs = append(errs, fmt.Errorf(
				"extract[%d].patterns[%d]: a %s pattern must capture (?P<%s>...); it captures %v",
				i, j, typ, want, names))
		}
	}
	for _, n := range names {
		if !slices.Contains(required, n) && !slices.Contains(optional, n) {
			errs = append(errs, fmt.Errorf(
				"extract[%d].patterns[%d]: a %s pattern has no use for the group %q; the executor reads only %v",
				i, j, typ, n, append(append([]string{}, required...), optional...)))
		}
	}
	return errs
}

func regexpCompiles(p string) bool {
	_, err := regexp.Compile(p)
	return err == nil
}
