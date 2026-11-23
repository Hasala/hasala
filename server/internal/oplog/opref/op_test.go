package opref

import (
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"
)

func ingestID() string { return strings.Repeat("a", 64) }

func newerVersion() string { return strconv.Itoa(SchemaVersion + 1) }

func TestDuplicateDispositionRequiresSchemaV2AndClosedPayload(t *testing.T) {
	parent := int64(1)
	base := Op{V: 2, Type: OpTxnDuplicateDisposition, OpID: "01J000000000000000000000D1",
		AuthoredAt: time.Date(2026, 6, 5, 10, 0, 0, 0, time.UTC), Entity: &EntityRef{Kind: "txn", ID: "T2"},
		ParentVersion: &parent, Payload: json.RawMessage(`{"other_txn_id":"T1","disposition":"same"}`)}
	if err := base.Validate(); err != nil {
		t.Fatal(err)
	}
	v1 := base
	v1.V = 1
	if err := v1.Validate(); err == nil {
		t.Fatal("schema v1 must not accept the v2 op")
	}
	for _, payload := range []string{`{"other_txn_id":"T1"}`, `{"other_txn_id":"","disposition":"same"}`, `{"other_txn_id":"T1","disposition":"maybe"}`} {
		bad := base
		bad.Payload = json.RawMessage(payload)
		if err := bad.Validate(); err == nil {
			t.Fatalf("accepted payload %s", payload)
		}
	}
}

func TestConfigurationOpsAreParentFreeV3Facts(t *testing.T) {
	for _, o := range configOps() {
		if err := o.Validate(); err != nil {
			t.Fatalf("%s: %v", o.Type, err)
		}
		if !o.Type.ParentFree() {
			t.Fatalf("%s must be parent-free: configuration is a positional fact, not a versioned entity", o.Type)
		}
		if o.Type.MinVersion() != 3 {
			t.Fatalf("%s requires schema v%d, want v3", o.Type, o.Type.MinVersion())
		}

		older := o
		older.V = 2
		if err := older.Validate(); err == nil {
			t.Fatalf("%s at v2 must be refused: a v2 client would read it as one of its own", o.Type)
		}

		entity := o
		entity.Entity = &EntityRef{Kind: "config", ID: "x"}
		if err := entity.Validate(); err == nil {
			t.Fatalf("%s naming an entity must be refused", o.Type)
		}

		parent := int64(1)
		versioned := o
		versioned.ParentVersion = &parent
		if err := versioned.Validate(); err == nil {
			t.Fatalf("%s carrying a parent_version must be refused", o.Type)
		}
	}
}

func TestConfigurationOpsHardStopAnOlderReader(t *testing.T) {
	body := []byte(`{"v":` + strconv.Itoa(SchemaVersion) + `,"kind":"ops","ops":[` +
		`{"v":` + strconv.Itoa(SchemaVersion) + `,"type":"bank_declared","op_id":"01J000000000000000000000B1",` +
		`"authored_at":"2026-06-05T10:00:00Z","parent_version":null,"payload":{"bank":"dib","active":true}},` +
		`{"v":` + newerVersion() + `,"type":"bank_declared","op_id":"01J000000000000000000000B2",` +
		`"authored_at":"2026-06-05T10:00:00Z","parent_version":null,"payload":{"bank":"enbd","active":true}}]}`)
	ops, err := DecodeBlob(body)
	if !errors.Is(err, ErrUnknownNewerVersion) {
		t.Fatalf("DecodeBlob = %v, want ErrUnknownNewerVersion", err)
	}
	if ops != nil {
		t.Fatalf("a hard stop must yield no ops, got %d -- skipping the unknown op and folding the rest is exactly what this forbids", len(ops))
	}
}

func txnOp() Op {
	return Op{
		V:          SchemaVersion,
		Type:       OpTxnIngested,
		OpID:       "01J000000000000000000000A1",
		AuthoredAt: time.Date(2026, 6, 5, 10, 0, 0, 0, time.UTC),
		Entity:     &EntityRef{Kind: "txn", ID: "01J000000000000000000000T1"},
		IngestID:   ingestID(),
		Payload: json.RawMessage(`{"amount_minor":"25000","currency":"AED","direction":"debit",` +
			`"posted_at":"2026-06-05T00:00:00Z","merchant_raw":"CARREFOUR","last4":"8642",` +
			`"is_transfer":false,"tier":"template","needs_review":false,"unparsed":false,` +
			`"template_id":"dib.card.v1","template_version":1,"normalizer_version":1}`),
	}
}

func rateOp() Op {
	return Op{
		V:          SchemaVersion,
		Type:       OpRateSet,
		OpID:       "01J000000000000000000000R1",
		AuthoredAt: time.Date(2026, 6, 5, 10, 0, 0, 0, time.UTC),
		Payload:    json.RawMessage(`{"currency":"USD","rate_micro":"3672500"}`),
	}
}

func TestDecodeBlobRejectsUnknownNewerVersion(t *testing.T) {
	_, err := DecodeBlob([]byte(`{"v":` + newerVersion() + `,"kind":"ops","ops":[]}`))
	if !errors.Is(err, ErrUnknownNewerVersion) {
		t.Fatalf("want ErrUnknownNewerVersion, got %v", err)
	}
}

func TestDecodeBlobRejectsANewerOpInsideAKnownBlob(t *testing.T) {
	b := []byte(`{"v":` + strconv.Itoa(SchemaVersion) + `,"kind":"ops","ops":[{"v":` + newerVersion() +
		`,"type":"txn_ingested","op_id":"x",` +
		`"authored_at":"2026-06-05T10:00:00Z","parent_version":null,"payload":{}}]}`)
	if _, err := DecodeBlob(b); !errors.Is(err, ErrUnknownNewerVersion) {
		t.Fatalf("want ErrUnknownNewerVersion, got %v", err)
	}
}

func TestRateOpsAreParentFree(t *testing.T) {
	for _, ty := range []OpType{OpRateSet, OpRateUnset, OpHomeCurrencySet, OpWriterCheckpoint} {
		if !ty.ParentFree() {
			t.Fatalf("%s must be parent-free (spec §3.7)", ty)
		}
	}
	for _, ty := range []OpType{OpTxnIngested, OpTxnSuperseded, OpTxnCategorized, OpTxnSplit, OpTxnEdited, OpRuleAdded} {
		if ty.ParentFree() {
			t.Fatalf("%s must participate in causality", ty)
		}
	}
}

func TestValidateRejectsParentOnParentFreeOp(t *testing.T) {
	p := int64(3)
	o := rateOp()
	o.ParentVersion = &p
	if err := o.Validate(); err == nil {
		t.Fatal("rate_set with a parent_version must be rejected: rates are append-only, never versioned entities")
	}
	o = rateOp()
	o.Entity = &EntityRef{Kind: "rate", ID: "USD"}
	if err := o.Validate(); err == nil {
		t.Fatal("rate_set naming an entity must be rejected: rates are not entities")
	}
}

func TestValidateRequiresEntityOnCausalOps(t *testing.T) {
	o := txnOp()
	o.Entity = nil
	if err := o.Validate(); err == nil {
		t.Fatal("a causal op with no entity must be rejected")
	}
	o = txnOp()
	o.Entity = &EntityRef{Kind: "txn"}
	if err := o.Validate(); err == nil {
		t.Fatal("an entity with no id must be rejected")
	}
}

func TestValidateRequiresIngestIDOnIngestOps(t *testing.T) {
	o := txnOp()
	o.Type = OpTxnSuperseded
	v := int64(1)
	o.ParentVersion = &v
	o.IngestID = ""
	if err := o.Validate(); err == nil {
		t.Fatal("txn_superseded without ingest_id must be rejected")
	}
	o.IngestID = "not-hex"
	if err := o.Validate(); err == nil {
		t.Fatal("a non-sha256 ingest_id must be rejected")
	}
	o.IngestID = ingestID()
	if err := o.Validate(); err != nil {
		t.Fatalf("valid txn_superseded rejected: %v", err)
	}
}

func TestValidateRejectsMalformedOps(t *testing.T) {
	for name, mut := range map[string]func(*Op){
		"no version":      func(o *Op) { o.V = 0 },
		"newer version":   func(o *Op) { o.V = SchemaVersion + 1 },
		"no op id":        func(o *Op) { o.OpID = "" },
		"no type":         func(o *Op) { o.Type = "" },
		"unknown type":    func(o *Op) { o.Type = "txn_teleported" },
		"zero authored":   func(o *Op) { o.AuthoredAt = time.Time{} },
		"empty payload":   func(o *Op) { o.Payload = nil },
		"invalid payload": func(o *Op) { o.Payload = json.RawMessage(`{`) },
	} {
		o := txnOp()
		mut(&o)
		if err := o.Validate(); err == nil {
			t.Fatalf("%s: expected an error", name)
		}
	}
}

func TestEncodeDecodeRoundTrip(t *testing.T) {
	in := []Op{txnOp(), rateOp()}
	b, err := EncodeBlob(in)
	if err != nil {
		t.Fatal(err)
	}
	if k, err := KindOf(b); err != nil || k != KindOps {
		t.Fatalf("KindOf = %q, %v", k, err)
	}
	out, err := DecodeBlob(b)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != len(in) {
		t.Fatalf("got %d ops, want %d", len(out), len(in))
	}
	for i := range in {
		if out[i].Type != in[i].Type || out[i].OpID != in[i].OpID ||
			!out[i].AuthoredAt.Equal(in[i].AuthoredAt) ||
			string(out[i].Payload) != string(in[i].Payload) {
			t.Fatalf("op %d changed across the wire:\n got %+v\nwant %+v", i, out[i], in[i])
		}
	}
	if out[0].Entity == nil || *out[0].Entity != *in[0].Entity {
		t.Fatalf("entity lost: %+v", out[0].Entity)
	}
	if out[1].Entity != nil || out[1].ParentVersion != nil {
		t.Fatalf("parent-free op grew a parent: %+v", out[1])
	}
}

func TestEncodeCanonicalisesAuthoredAtToUTC(t *testing.T) {
	o := txnOp()
	o.AuthoredAt = o.AuthoredAt.In(time.FixedZone("GST", 4*3600))
	b, err := EncodeBlob([]Op{o})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"authored_at":"2026-06-05T10:00:00Z"`) {
		t.Fatalf("authored_at must be canonical RFC3339 UTC on the wire: %s", b)
	}
}

func TestEncodeTruncatesAuthoredAtToMilliseconds(t *testing.T) {
	o := txnOp()
	o.AuthoredAt = o.AuthoredAt.Add(1500 * time.Microsecond)
	b, err := EncodeBlob([]Op{o})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"authored_at":"2026-06-05T10:00:00.001Z"`) {
		t.Fatalf("authored_at must be truncated to milliseconds: %s", b)
	}
	out, err := DecodeBlob(b)
	if err != nil {
		t.Fatal(err)
	}
	if got := out[0].AuthoredAt; got.Nanosecond()%int(time.Millisecond) != 0 {
		t.Fatalf("decoded authored_at %v is finer than a millisecond", got)
	}
}

func TestEncodeBlobRejectsInvalidOps(t *testing.T) {
	o := txnOp()
	o.IngestID = ""
	if _, err := EncodeBlob([]Op{o}); err == nil {
		t.Fatal("EncodeBlob must not emit an op that Validate rejects")
	}
}

func TestRawBodyIsNotAnOpBlob(t *testing.T) {
	b, err := EncodeRawBody(RawBody{V: 1, Kind: KindRawBody, IngestID: ingestID(),
		ReceivedAt: time.Now().UTC(), RawBase64: "aGk="})
	if err != nil {
		t.Fatal(err)
	}
	if k, _ := KindOf(b); k != "raw_body" {
		t.Fatalf("KindOf = %q", k)
	}
	if _, err := DecodeBlob(b); err == nil {
		t.Fatal("a raw-body blob must not decode as an op list (invariant I16)")
	}
	ops, err := EncodeBlob([]Op{txnOp()})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeRawBody(ops); err == nil {
		t.Fatal("an op blob must not decode as a raw body (invariant I16)")
	}
	got, err := DecodeRawBody(b)
	if err != nil {
		t.Fatal(err)
	}
	if got.IngestID != ingestID() || got.RawBase64 != "aGk=" {
		t.Fatalf("raw body round trip lost data: %+v", got)
	}
}

func TestCheckpointHeadsAreSortedAndStreamed(t *testing.T) {
	heads := []CheckpointHead{
		{WriterID: "ingest", Stream: "hot", Counter: "9", Hash: strings.Repeat("b", 64)},
		{WriterID: "dev-a", Stream: "hot", Counter: "12", Hash: strings.Repeat("c", 64)},
		{WriterID: "ingest", Stream: "cold", Counter: "9", Hash: strings.Repeat("d", 64)},
	}
	p, err := EncodeCheckpointPayload(heads)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"heads":[` +
		`{"writer_id":"dev-a","stream":"hot","counter":"12","hash":"` + strings.Repeat("c", 64) + `"},` +
		`{"writer_id":"ingest","stream":"cold","counter":"9","hash":"` + strings.Repeat("d", 64) + `"},` +
		`{"writer_id":"ingest","stream":"hot","counter":"9","hash":"` + strings.Repeat("b", 64) + `"}]}`
	if string(p) != want {
		t.Fatalf("canonical checkpoint payload:\n got %s\nwant %s", p, want)
	}
	if strings.Contains(string(p), `"counter":12`) {
		t.Fatal("counters must be decimal strings on the wire")
	}

	got, err := DecodeCheckpointPayload(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[0].WriterID != "dev-a" || got[1].Stream != "cold" {
		t.Fatalf("decode lost the canonical order: %+v", got)
	}

	if _, err := EncodeCheckpointPayload([]CheckpointHead{
		{WriterID: "dev-a", Counter: "1", Hash: strings.Repeat("c", 64)},
	}); err == nil {
		t.Fatal("a head with no stream must be rejected: chains are per (writer_id, stream)")
	}
	if _, err := EncodeCheckpointPayload([]CheckpointHead{
		{WriterID: "dev-a", Stream: "hot", Counter: "1", Hash: strings.Repeat("c", 64)},
		{WriterID: "dev-a", Stream: "hot", Counter: "2", Hash: strings.Repeat("c", 64)},
	}); err == nil {
		t.Fatal("two heads for one (writer_id, stream) must be rejected")
	}
	if _, err := DecodeCheckpointPayload(json.RawMessage(`{"heads":[` +
		`{"writer_id":"ingest","stream":"hot","counter":"9","hash":"` + strings.Repeat("b", 64) + `"},` +
		`{"writer_id":"dev-a","stream":"hot","counter":"12","hash":"` + strings.Repeat("c", 64) + `"}]}`)); err == nil {
		t.Fatal("an unsorted heads array must be rejected: its encoding is not canonical")
	}
}

func TestDecodeTruncatesAuthoredAtToMilliseconds(t *testing.T) {
	for _, tc := range []struct {
		wire string
		want time.Time
	}{
		{"2026-06-05T10:00:00.0000015Z", time.Date(2026, 6, 5, 10, 0, 0, 0, time.UTC)},
		{"2026-06-05T10:00:00.0015Z", time.Date(2026, 6, 5, 10, 0, 0, 1e6, time.UTC)},
		{"2026-06-05T14:00:00.5+04:00", time.Date(2026, 6, 5, 10, 0, 0, 5e8, time.UTC)},
	} {
		b := []byte(`{"v":1,"kind":"ops","ops":[{"v":1,"type":"rate_set","op_id":"r",` +
			`"authored_at":"` + tc.wire + `","parent_version":null,"payload":{}}]}`)
		ops, err := DecodeBlob(b)
		if err != nil {
			t.Fatalf("%s: %v", tc.wire, err)
		}
		got := ops[0].AuthoredAt
		if !got.Equal(tc.want) {
			t.Fatalf("decoded %s as %v, want %v — Go and JS must read the same instant",
				tc.wire, got, tc.want)
		}
		if got.Nanosecond()%int(time.Millisecond) != 0 {
			t.Fatalf("decoded %s with sub-millisecond precision a JS Date cannot hold: %v", tc.wire, got)
		}
	}
}

func TestGoldenOpBytes(t *testing.T) {
	got, err := EncodeBlob(goldenOps())
	if err != nil {
		t.Fatal(err)
	}
	want := `{"v":1,"kind":"ops","ops":[` +
		`{"v":1,"type":"txn_ingested","op_id":"01J000000000000000000000I1",` +
		`"authored_at":"2026-06-05T10:00:00Z","entity":{"kind":"txn","id":"T1"},` +
		`"parent_version":null,"ingest_id":"` + strings.Repeat("a", 64) + `",` +
		`"payload":{"amount_minor":"25000","currency":"AED"}},` +
		`{"v":1,"type":"txn_categorized","op_id":"01J000000000000000000000A1",` +
		`"authored_at":"2026-06-05T10:00:00Z","entity":{"kind":"txn","id":"T1"},` +
		`"parent_version":3,"payload":{"category":"groceries"}},` +
		`{"v":1,"type":"rate_set","op_id":"01J000000000000000000000R1",` +
		`"authored_at":"2026-06-05T10:00:00Z","parent_version":null,` +
		`"payload":{"currency":"USD","rate_micro":"3672500"}}]}`
	if string(got) != want {
		t.Fatalf("op wire encoding changed — Task 10's TypeScript mirror is written against these bytes:\n got %s\nwant %s", got, want)
	}

	if strings.Count(string(got), `"parent_version"`) != 3 {
		t.Fatalf("parent_version must be present on every op, null included: %s", got)
	}
	if strings.Count(string(got), `"ingest_id"`) != 1 {
		t.Fatalf("ingest_id must appear on the ingest op and be omitted when empty: %s", got)
	}
}

func TestGoldenRawBodyBytes(t *testing.T) {
	got, err := EncodeRawBody(RawBody{
		IngestID:   strings.Repeat("a", 64),
		ReceivedAt: time.Date(2026, 6, 5, 10, 0, 0, 0, time.UTC),
		RawBase64:  "aGk=",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"v":1,"kind":"raw_body","ingest_id":"` + strings.Repeat("a", 64) +
		`","received_at":"2026-06-05T10:00:00Z","raw_base64":"aGk="}`
	if string(got) != want {
		t.Fatalf("raw body wire encoding changed:\n got %s\nwant %s", got, want)
	}
}

func TestValidateRejectsIngestIDOnNonIngestOps(t *testing.T) {
	o := rateOp()
	o.IngestID = "junk"
	if err := o.Validate(); err == nil {
		t.Fatal("rate_set carrying an ingest_id must be rejected")
	}
	o = txnOp()
	o.Type = OpTxnCategorized
	o.Payload = json.RawMessage(`{"category":"groceries"}`)
	if err := o.Validate(); err == nil {
		t.Fatal("txn_categorized carrying an ingest_id must be rejected")
	}
	o.IngestID = ""
	if err := o.Validate(); err != nil {
		t.Fatalf("txn_categorized without an ingest_id must validate: %v", err)
	}
}

func TestDecodeRawBodyRejectsBadVersions(t *testing.T) {
	for _, v := range []string{"0", "-5"} {
		b := []byte(`{"v":` + v + `,"kind":"raw_body","ingest_id":"` + ingestID() +
			`","received_at":"2026-06-05T10:00:00Z","raw_base64":"aGk="}`)
		if _, err := DecodeRawBody(b); err == nil {
			t.Fatalf("raw body v%s must be rejected", v)
		}
	}
	b := []byte(`{"v":` + newerVersion() + `,"kind":"raw_body","ingest_id":"` + ingestID() +
		`","received_at":"2026-06-05T10:00:00Z","raw_base64":"aGk="}`)
	if _, err := DecodeRawBody(b); !errors.Is(err, ErrUnknownNewerVersion) {
		t.Fatalf("a newer raw body must hard-stop like a newer op blob, got %v", err)
	}
}

func TestKindOfRejectsNonBlobs(t *testing.T) {
	for _, in := range []string{``, `[]`, `{"v":1}`, `not json`} {
		if _, err := KindOf([]byte(in)); err == nil {
			t.Fatalf("KindOf(%q) must fail", in)
		}
	}
}

func TestWireTimeAcceptsExactlyWhatTypeScriptAccepts(t *testing.T) {
	for _, s := range []string{
		"2026-06-05T24:00:00Z",
		"2026-02-30T10:00:00Z",
		"2026-02-29T00:00:00Z",
		"2026-13-05T10:00:00Z",
		"2026-06-05T10:60:00Z",
		"2026-06-05T10:00:60Z",
		"2026-06-05T10:00:00+24:00",
		"2026-06-05T10:00:00+24:60",
		"2026-06-05T10:00:00+00:60",
		"2026-06-05t10:00:00z",
		"2026-06-05 10:00:00Z",
		"2026-06-05T10:00:00",
		"2026-06-05T10:00:00.Z",
		"2026-06-05",
		"June 5 2026",
		"",
	} {
		if _, err := parseWireTime(s); err == nil {
			t.Errorf("parseWireTime(%q) must be refused: the TypeScript executor refuses it", s)
		}
	}

	for _, tc := range []struct {
		wire string
		want time.Time
	}{
		{"2026-06-05T10:00:00Z", time.Date(2026, 6, 5, 10, 0, 0, 0, time.UTC)},
		{"2026-06-05T10:00:00.5Z", time.Date(2026, 6, 5, 10, 0, 0, 5e8, time.UTC)},
		{"2026-06-05T14:00:00.5+04:00", time.Date(2026, 6, 5, 10, 0, 0, 5e8, time.UTC)},
		{"2026-06-05T10:00:00-00:00", time.Date(2026, 6, 5, 10, 0, 0, 0, time.UTC)},
		{"2026-06-05T10:00:00+23:59", time.Date(2026, 6, 4, 10, 1, 0, 0, time.UTC)},
		{"2024-02-29T00:00:00Z", time.Date(2024, 2, 29, 0, 0, 0, 0, time.UTC)},
		{"2000-02-29T00:00:00Z", time.Date(2000, 2, 29, 0, 0, 0, 0, time.UTC)},
	} {
		got, err := parseWireTime(tc.wire)
		if err != nil {
			t.Errorf("parseWireTime(%q): %v", tc.wire, err)
			continue
		}
		if !got.Equal(tc.want) {
			t.Errorf("parseWireTime(%q) = %v, want %v", tc.wire, got.UTC(), tc.want)
		}
	}
}

func TestDecodeRejectsOutOfRangeTimestampsInABlob(t *testing.T) {
	for _, wire := range []string{"2026-02-30T10:00:00Z", "2026-06-05T24:00:00Z", "2026-06-05T10:00:00+24:00"} {
		if _, err := DecodeBlob(timeProbeBlob(wire)); err == nil {
			t.Errorf("an op carrying authored_at %q must not decode", wire)
		} else if errors.Is(err, ErrUnknownNewerVersion) {
			t.Errorf("authored_at %q must not be reported as an unknown newer version", wire)
		}
	}
	body := func(receivedAt string) []byte {
		return []byte(`{"v":1,"kind":"raw_body","ingest_id":"` + ingestID() +
			`","received_at":"` + receivedAt + `","raw_base64":"aGk="}`)
	}
	if _, err := DecodeRawBody(body("2026-02-30T10:00:00Z")); err == nil {
		t.Error("a cold record with a rolled-over received_at must not decode")
	}
	if _, err := DecodeRawBody(body("2026-06-05T10:00:00Z")); err != nil {
		t.Errorf("a well-formed cold record must decode: %v", err)
	}
}

func TestDecodeRawBodyValidatesItsPayload(t *testing.T) {
	body := func(raw string) []byte {
		return []byte(`{"v":1,"kind":"raw_body","ingest_id":"` + ingestID() +
			`","received_at":"2026-06-05T10:00:00Z","raw_base64":"` + raw + `"}`)
	}
	for _, raw := range []string{
		"a GK=",
		"aGk",
		"aG!=",
		"-_8=",
		"not b64",
	} {
		if _, err := DecodeRawBody(body(raw)); err == nil {
			t.Errorf("raw_base64 %q must be refused", raw)
		}
	}
	r, err := DecodeRawBody(body("aGk="))
	if err != nil {
		t.Fatal(err)
	}
	if r.RawBase64 != "aGk=" {
		t.Fatalf("raw_base64 round trip lost data: %q", r.RawBase64)
	}
	if _, err := DecodeRawBody([]byte(`{"v":1,"kind":"raw_body","ingest_id":"` + ingestID() +
		`","raw_base64":"aGk="}`)); err == nil {
		t.Error("a cold record with no received_at must be refused")
	}
	if _, err := DecodeRawBody([]byte(`{"v":1,"kind":"raw_body","ingest_id":"` + ingestID() +
		`","received_at":"0001-01-01T00:00:00Z","raw_base64":"aGk="}`)); err == nil {
		t.Error("a cold record with a zero received_at must be refused")
	}
}
