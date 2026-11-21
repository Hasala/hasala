package opref

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"
)

const SchemaVersion = 3

const (
	KindOps     = "ops"
	KindRawBody = "raw_body"
)

var ErrUnknownNewerVersion = errors.New("op schema version newer than supported")

type OpType string

const (
	OpTxnIngested             OpType = "txn_ingested"
	OpTxnSuperseded           OpType = "txn_superseded"
	OpTxnCategorized          OpType = "txn_categorized"
	OpTxnSplit                OpType = "txn_split"
	OpTxnEdited               OpType = "txn_edited"
	OpTxnDuplicateDisposition OpType = "txn_duplicate_disposition"
	OpRuleAdded               OpType = "rule_added"
	OpRateSet                 OpType = "rate_set"
	OpRateUnset               OpType = "rate_unset"
	OpHomeCurrencySet         OpType = "home_currency_set"
	OpBankDeclared            OpType = "bank_declared"
	OpBudgetSplitSet          OpType = "budget_split_set"
	OpCategoryDefined         OpType = "category_defined"
	OpWriterCheckpoint        OpType = "writer_checkpoint"
)

var Types = []OpType{
	OpTxnIngested, OpTxnSuperseded, OpTxnCategorized, OpTxnSplit, OpTxnEdited, OpTxnDuplicateDisposition,
	OpRuleAdded, OpRateSet, OpRateUnset, OpHomeCurrencySet,
	OpBankDeclared, OpBudgetSplitSet, OpCategoryDefined,
	OpWriterCheckpoint,
}

func (t OpType) Valid() bool { return slices.Contains(Types, t) }

func (t OpType) MinVersion() int {
	switch t {
	case OpTxnDuplicateDisposition:
		return 2
	case OpBankDeclared, OpBudgetSplitSet, OpCategoryDefined:
		return 3
	default:
		return 1
	}
}

func (t OpType) ParentFree() bool {
	switch t {
	case OpRateSet, OpRateUnset, OpHomeCurrencySet, OpWriterCheckpoint,
		OpBankDeclared, OpBudgetSplitSet, OpCategoryDefined:
		return true
	default:
		return false
	}
}

type EntityRef struct {
	Kind string `json:"kind"`
	ID   string `json:"id"`
}

type Op struct {
	V             int             `json:"v"`
	Type          OpType          `json:"type"`
	OpID          string          `json:"op_id"`
	AuthoredAt    time.Time       `json:"authored_at"`
	Entity        *EntityRef      `json:"entity,omitempty"`
	ParentVersion *int64          `json:"parent_version"`
	IngestID      string          `json:"ingest_id,omitempty"`
	Payload       json.RawMessage `json:"payload"`
}

func (o *Op) UnmarshalJSON(b []byte) error {
	b, err := exactFields(b, "v", "type", "op_id", "authored_at", "entity", "parent_version", "ingest_id", "payload")
	if err != nil {
		return err
	}
	if isNullField(b, "ingest_id") {
		return errors.New("ingest_id is null")
	}
	type alias Op
	var raw struct {
		*alias
		AuthoredAt string `json:"authored_at"`
	}
	raw.alias = (*alias)(o)
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	t, err := parseWireTime(raw.AuthoredAt)
	if err != nil {
		return fmt.Errorf("authored_at: %w", err)
	}
	o.AuthoredAt = t
	return nil
}

func (e *EntityRef) UnmarshalJSON(b []byte) error {
	b, err := exactFields(b, "kind", "id")
	if err != nil {
		return err
	}
	type alias EntityRef
	return json.Unmarshal(b, (*alias)(e))
}

func exactFields(b []byte, names ...string) ([]byte, error) {
	var m map[string]json.RawMessage
	if json.Unmarshal(b, &m) != nil || m == nil {
		return b, nil
	}
	kept := make(map[string]json.RawMessage, len(names))
	for _, n := range names {
		if v, ok := m[n]; ok {
			kept[n] = v
		}
	}
	return json.Marshal(kept)
}

func isNullField(b []byte, name string) bool {
	var m map[string]json.RawMessage
	if json.Unmarshal(b, &m) != nil {
		return false
	}
	v, ok := m[name]
	return ok && string(v) == "null"
}

func hasLoneSurrogateEscape(b []byte) bool {
	in := false
	for i := 0; i < len(b); i++ {
		if !in {
			in = b[i] == '"'
			continue
		}
		switch b[i] {
		case '"':
			in = false
		case '\\':
			if i+1 < len(b) && b[i+1] != 'u' {
				i++
				continue
			}
			r, ok := hex4(b, i+2)
			if !ok {
				return false
			}
			i += 5
			switch {
			case r >= 0xd800 && r < 0xdc00:
				if i+6 < len(b) && b[i+1] == '\\' && b[i+2] == 'u' {
					if r2, ok := hex4(b, i+3); ok && r2 >= 0xdc00 && r2 < 0xe000 {
						i += 6
						continue
					}
				}
				return true
			case r >= 0xdc00 && r < 0xe000:
				return true
			}
		}
	}
	return false
}

func hex4(b []byte, at int) (rune, bool) {
	if at+4 > len(b) {
		return 0, false
	}
	var r rune
	for _, c := range b[at : at+4] {
		switch {
		case c >= '0' && c <= '9':
			r = r<<4 | rune(c-'0')
		case c >= 'a' && c <= 'f':
			r = r<<4 | rune(c-'a'+10)
		case c >= 'A' && c <= 'F':
			r = r<<4 | rune(c-'A'+10)
		default:
			return 0, false
		}
	}
	return r, true
}

func decodeBody(b []byte, v any, names ...string) error {
	if hasLoneSurrogateEscape(b) {
		return errors.New("body carries a lone surrogate escape")
	}
	b, err := exactFields(b, names...)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func (o Op) Validate() error {
	if o.V > SchemaVersion {
		return fmt.Errorf("%w: op %s is v%d", ErrUnknownNewerVersion, o.OpID, o.V)
	}
	if o.V < 1 {
		return fmt.Errorf("op %s: version %d is not valid", o.OpID, o.V)
	}
	if o.Type == "" {
		return fmt.Errorf("op %s: type is empty", o.OpID)
	}
	if !o.Type.Valid() {
		return fmt.Errorf("op %s: unknown type %q", o.OpID, o.Type)
	}
	if o.V < o.Type.MinVersion() {
		return fmt.Errorf("op %s: type %q requires schema v%d", o.OpID, o.Type, o.Type.MinVersion())
	}
	if o.OpID == "" {
		return fmt.Errorf("op of type %s: op_id is empty", o.Type)
	}
	if o.AuthoredAt.IsZero() {
		return fmt.Errorf("op %s: authored_at is zero", o.OpID)
	}
	if _, err := canonicalTime(o.AuthoredAt); err != nil {
		return fmt.Errorf("op %s: authored_at %w", o.OpID, err)
	}

	if o.Type.ParentFree() {
		if o.Entity != nil {
			return fmt.Errorf("op %s: %s is parent-free and must not name an entity", o.OpID, o.Type)
		}
		if o.ParentVersion != nil {
			return fmt.Errorf("op %s: %s is parent-free and must not carry a parent_version", o.OpID, o.Type)
		}
	} else {
		if o.Entity == nil {
			return fmt.Errorf("op %s: %s must name an entity", o.OpID, o.Type)
		}
		if o.Entity.Kind == "" || o.Entity.ID == "" {
			return fmt.Errorf("op %s: entity needs both a kind and an id", o.OpID)
		}
		if o.ParentVersion != nil && *o.ParentVersion < 0 {
			return fmt.Errorf("op %s: parent_version %d is negative", o.OpID, *o.ParentVersion)
		}
	}

	switch o.Type {
	case OpTxnIngested, OpTxnSuperseded:
		if !isSHA256Hex(o.IngestID) {
			return fmt.Errorf("op %s: %s needs a 64-hex-char ingest_id, got %q", o.OpID, o.Type, o.IngestID)
		}
	default:
		if o.IngestID != "" {
			return fmt.Errorf("op %s: %s must not carry an ingest_id, got %q", o.OpID, o.Type, o.IngestID)
		}
	}

	if len(o.Payload) == 0 {
		return fmt.Errorf("op %s: payload is empty", o.OpID)
	}
	if !json.Valid(o.Payload) {
		return fmt.Errorf("op %s: payload is not valid JSON", o.OpID)
	}
	if o.Type == OpTxnDuplicateDisposition {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(o.Payload, &fields); err != nil {
			return fmt.Errorf("op %s: duplicate disposition payload: %w", o.OpID, err)
		}
		if _, ok := fields["disposition"]; !ok {
			return fmt.Errorf("op %s: duplicate disposition needs disposition", o.OpID)
		}
		var p struct {
			OtherTxnID  string  `json:"other_txn_id"`
			Disposition *string `json:"disposition"`
		}
		if err := json.Unmarshal(o.Payload, &p); err != nil {
			return fmt.Errorf("op %s: duplicate disposition payload: %w", o.OpID, err)
		}
		if p.OtherTxnID == "" {
			return fmt.Errorf("op %s: duplicate disposition needs other_txn_id", o.OpID)
		}
		if p.Disposition != nil && *p.Disposition != "same" && *p.Disposition != "different" {
			return fmt.Errorf("op %s: duplicate disposition must be same, different, or null", o.OpID)
		}
	}
	return nil
}

func canonicalTime(t time.Time) (time.Time, error) {
	c := t.UTC().Truncate(time.Millisecond)
	if s := c.Format(time.RFC3339Nano); !rfc3339Shape.MatchString(s) {
		return time.Time{}, fmt.Errorf("canonicalises to %q, which is outside the four-digit-year range this wire format carries", s)
	}
	return c, nil
}

func CanonicalWireTime(t time.Time) (string, error) {
	c, err := canonicalTime(t)
	if err != nil {
		return "", fmt.Errorf("oplog: timestamp %s: %w", t.UTC().Format(time.RFC3339Nano), err)
	}
	return c.Format(time.RFC3339Nano), nil
}

var rfc3339Shape = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$`)

func parseWireTime(s string) (time.Time, error) {
	if !rfc3339Shape.MatchString(s) {
		return time.Time{}, fmt.Errorf("timestamp %q is not RFC3339", s)
	}
	if zone := s[len(s)-6:]; zone[0] == '+' || zone[0] == '-' {
		hh, mm := (zone[1]-'0')*10+(zone[2]-'0'), (zone[4]-'0')*10+(zone[5]-'0')
		if hh > 23 || mm > 59 {
			return time.Time{}, fmt.Errorf("timestamp %q has an out-of-range UTC offset", s)
		}
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, fmt.Errorf("timestamp %q: %w", s, err)
	}
	if _, cerr := canonicalTime(t); cerr != nil {
		return time.Time{}, fmt.Errorf("timestamp %q %w", s, cerr)
	}
	return t, nil
}

func isSHA256Hex(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		switch {
		case c >= '0' && c <= '9', c >= 'a' && c <= 'f':
		default:
			return false
		}
	}
	return true
}

type opBlob struct {
	V    int    `json:"v"`
	Kind string `json:"kind"`
	Ops  []Op   `json:"ops"`
}

type blobHeader struct {
	V    int    `json:"v"`
	Kind string `json:"kind"`
}

func EncodeBlob(ops []Op) ([]byte, error) {
	version := 1
	out := make([]Op, len(ops))
	for i, o := range ops {
		if err := o.Validate(); err != nil {
			return nil, fmt.Errorf("oplog: op %d: %w", i, err)
		}
		ct, err := canonicalTime(o.AuthoredAt)
		if err != nil {
			return nil, fmt.Errorf("oplog: op %d: authored_at %w", i, err)
		}
		o.AuthoredAt = ct
		out[i] = o
		if o.V > version {
			version = o.V
		}
	}
	return json.Marshal(opBlob{V: version, Kind: KindOps, Ops: out})
}

func DecodeBlob(b []byte) ([]Op, error) {
	var h blobHeader
	if err := decodeBody(b, &h, "v", "kind"); err != nil {
		return nil, fmt.Errorf("oplog: decode blob: %w", err)
	}
	if h.V > SchemaVersion {
		return nil, fmt.Errorf("%w: blob is v%d, this build supports v%d", ErrUnknownNewerVersion, h.V, SchemaVersion)
	}
	if h.V < 1 {
		return nil, fmt.Errorf("oplog: blob version %d is not valid", h.V)
	}
	if h.Kind != KindOps {
		return nil, fmt.Errorf("oplog: blob kind is %q, not %q", h.Kind, KindOps)
	}

	var blob opBlob
	if err := decodeBody(b, &blob, "v", "kind", "ops"); err != nil {
		return nil, fmt.Errorf("oplog: decode blob: %w", err)
	}
	for i, o := range blob.Ops {
		if err := o.Validate(); err != nil {
			return nil, fmt.Errorf("oplog: op %d: %w", i, err)
		}
		ct, cerr := canonicalTime(o.AuthoredAt)
		if cerr != nil {
			return nil, fmt.Errorf("oplog: op %d: authored_at %w", i, cerr)
		}
		blob.Ops[i].AuthoredAt = ct
	}
	return blob.Ops, nil
}

type RawBody struct {
	V          int       `json:"v"`
	Kind       string    `json:"kind"`
	IngestID   string    `json:"ingest_id"`
	ReceivedAt time.Time `json:"received_at"`
	RawBase64  string    `json:"raw_base64"`
}

func (r *RawBody) UnmarshalJSON(b []byte) error {
	b, err := exactFields(b, "v", "kind", "ingest_id", "received_at", "raw_base64")
	if err != nil {
		return err
	}
	type alias RawBody
	var raw struct {
		*alias
		ReceivedAt string `json:"received_at"`
	}
	raw.alias = (*alias)(r)
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	t, err := parseWireTime(raw.ReceivedAt)
	if err != nil {
		return fmt.Errorf("received_at: %w", err)
	}
	r.ReceivedAt = t
	return nil
}

func EncodeRawBody(r RawBody) ([]byte, error) {
	if r.V == 0 {
		r.V = 1
	}
	if r.V > SchemaVersion || r.V < 1 {
		return nil, fmt.Errorf("oplog: raw body version %d is not valid", r.V)
	}
	if r.Kind == "" {
		r.Kind = KindRawBody
	}
	if r.Kind != KindRawBody {
		return nil, fmt.Errorf("oplog: raw body kind is %q, not %q", r.Kind, KindRawBody)
	}
	if !isSHA256Hex(r.IngestID) {
		return nil, fmt.Errorf("oplog: raw body needs a 64-hex-char ingest_id, got %q", r.IngestID)
	}
	if r.ReceivedAt.IsZero() {
		return nil, errors.New("oplog: raw body received_at is zero")
	}
	ct, err := canonicalTime(r.ReceivedAt)
	if err != nil {
		return nil, fmt.Errorf("oplog: raw body received_at %w", err)
	}
	r.ReceivedAt = ct
	return json.Marshal(r)
}

func DecodeRawBody(b []byte) (RawBody, error) {
	var h blobHeader
	if err := decodeBody(b, &h, "v", "kind"); err != nil {
		return RawBody{}, fmt.Errorf("oplog: decode raw body: %w", err)
	}
	if h.V > SchemaVersion {
		return RawBody{}, fmt.Errorf("%w: raw body is v%d, this build supports v%d", ErrUnknownNewerVersion, h.V, SchemaVersion)
	}
	if h.V < 1 {
		return RawBody{}, fmt.Errorf("oplog: raw body version %d is not valid", h.V)
	}
	if h.Kind != KindRawBody {
		return RawBody{}, fmt.Errorf("oplog: blob kind is %q, not %q", h.Kind, KindRawBody)
	}
	var r RawBody
	if err := decodeBody(b, &r, "v", "kind", "ingest_id", "received_at", "raw_base64"); err != nil {
		return RawBody{}, fmt.Errorf("oplog: decode raw body: %w", err)
	}
	if !isSHA256Hex(r.IngestID) {
		return RawBody{}, fmt.Errorf("oplog: raw body has no usable ingest_id: %q", r.IngestID)
	}
	if r.ReceivedAt.IsZero() {
		return RawBody{}, errors.New("oplog: raw body received_at is zero")
	}
	if _, err := base64.StdEncoding.DecodeString(r.RawBase64); err != nil {
		return RawBody{}, fmt.Errorf("oplog: raw body payload is not standard base64: %w", err)
	}
	return r, nil
}

func KindOf(b []byte) (string, error) {
	var h blobHeader
	if err := decodeBody(b, &h, "v", "kind"); err != nil {
		return "", fmt.Errorf("oplog: read blob kind: %w", err)
	}
	if h.Kind == "" {
		return "", errors.New("oplog: blob has no kind")
	}
	return h.Kind, nil
}

type CheckpointHead struct {
	WriterID string `json:"writer_id"`
	Stream   string `json:"stream"`
	Counter  string `json:"counter"`
	Hash     string `json:"hash"`
}

func (h *CheckpointHead) UnmarshalJSON(b []byte) error {
	b, err := exactFields(b, "writer_id", "stream", "counter", "hash")
	if err != nil {
		return err
	}
	type alias CheckpointHead
	return json.Unmarshal(b, (*alias)(h))
}

type checkpointPayload struct {
	Heads []CheckpointHead `json:"heads"`
}

func EncodeCheckpointPayload(heads []CheckpointHead) (json.RawMessage, error) {
	out := slices.Clone(heads)
	for _, h := range out {
		if err := h.validate(); err != nil {
			return nil, err
		}
	}
	slices.SortFunc(out, compareHeads)
	for i := 1; i < len(out); i++ {
		if compareHeads(out[i-1], out[i]) == 0 {
			return nil, fmt.Errorf("oplog: duplicate checkpoint head for (%s, %s)", out[i].WriterID, out[i].Stream)
		}
	}
	return json.Marshal(checkpointPayload{Heads: out})
}

func DecodeCheckpointPayload(p json.RawMessage) ([]CheckpointHead, error) {
	var cp checkpointPayload
	if err := decodeBody(p, &cp, "heads"); err != nil {
		return nil, fmt.Errorf("oplog: decode checkpoint: %w", err)
	}
	for _, h := range cp.Heads {
		if err := h.validate(); err != nil {
			return nil, err
		}
	}
	if !slices.IsSortedFunc(cp.Heads, compareHeads) {
		return nil, errors.New("oplog: checkpoint heads are not sorted by (writer_id, stream)")
	}
	for i := 1; i < len(cp.Heads); i++ {
		if compareHeads(cp.Heads[i-1], cp.Heads[i]) == 0 {
			return nil, fmt.Errorf("oplog: duplicate checkpoint head for (%s, %s)", cp.Heads[i].WriterID, cp.Heads[i].Stream)
		}
	}
	return cp.Heads, nil
}

func compareHeads(a, b CheckpointHead) int {
	if c := strings.Compare(a.WriterID, b.WriterID); c != 0 {
		return c
	}
	return strings.Compare(a.Stream, b.Stream)
}

func (h CheckpointHead) validate() error {
	switch {
	case h.WriterID == "":
		return errors.New("oplog: checkpoint head has no writer_id")
	case h.Stream == "":
		return fmt.Errorf("oplog: checkpoint head for %q names no stream", h.WriterID)
	case !isDecimal(h.Counter):
		return fmt.Errorf("oplog: checkpoint head for %q has counter %q, want a decimal string", h.WriterID, h.Counter)
	case !isSHA256Hex(h.Hash):
		return fmt.Errorf("oplog: checkpoint head for %q has hash %q, want 64 hex chars", h.WriterID, h.Hash)
	}
	return nil
}

func isDecimal(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
