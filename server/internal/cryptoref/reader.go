package cryptoref

import (
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

type Outcome struct {
	Kind   string `json:"kind"`
	Reason string `json:"reason,omitempty"`
	Alarm  bool   `json:"alarm,omitempty"`
	Epoch  uint32 `json:"epoch,omitempty"`
}

func (o Outcome) HardStop() bool {
	return o.Kind == "tampered" || o.Kind == "updateRequired" || o.Kind == "needsUnlock"
}

func (o Outcome) String() string {
	switch {
	case o.Kind == "needsUnlock":
		return fmt.Sprintf("needsUnlock(%d)", o.Epoch)
	case o.Reason != "" && o.Alarm:
		return o.Kind + "(" + o.Reason + ", alarm)"
	case o.Reason != "":
		return o.Kind + "(" + o.Reason + ")"
	}
	return o.Kind
}

func tampered(r string) Outcome { return Outcome{Kind: "tampered", Reason: r} }
func setAside(r string, alarm bool) Outcome {
	return Outcome{Kind: "setAside", Reason: r, Alarm: alarm}
}

type Row struct {
	Stream        string `json:"stream"`
	WriterID      string `json:"writer_id"`
	WriterCounter int64  `json:"writer_counter"`
	SizeBucket    int    `json:"size_bucket"`
	Blob          []byte `json:"-"`
	BlobHash      []byte `json:"-"`
	PrevHash      []byte `json:"-"`
	HeadSig       []byte `json:"-"`
}

type RosterEntry struct {
	Pub          []byte
	Live         bool
	FinalCounter int64
	FinalHead    []byte
}

type Head struct {
	Counter int64
	Hash    [32]byte
}

type ReaderState struct {
	User        uuid.UUID
	Roster      map[string]RosterEntry
	Heads       map[string]Head
	Keys        map[uint32][]byte
	EpochHWM    uint32
	ServerEpoch uint32
	OwnWriter   string
	OwnHead     int64
	Schema      int
	KnownTypes  map[string]bool
}

type PageResult struct {
	Rows []Outcome `json:"rows"`
	Stop *Stop     `json:"hard_stop,omitempty"`
}

type Stop struct {
	Row     int     `json:"row"`
	Outcome Outcome `json:"outcome"`
}

func ReadPage(st ReaderState, rows []Row) PageResult {
	stop := func(i int, o Outcome) PageResult {
		return PageResult{Rows: []Outcome{}, Stop: &Stop{Row: i, Outcome: o}}
	}
	for i, r := range rows {
		if !rowShapeOK(r) {
			return stop(i, tampered("rowShape"))
		}
		if _, ok := st.Roster[r.WriterID]; !ok {
			return stop(i, tampered("unknownWriter"))
		}
		if st.OwnWriter != "" && r.WriterID == st.OwnWriter && r.WriterCounter > st.OwnHead {
			return stop(i, tampered("ownChainConflict"))
		}
	}
	tip := map[string]Head{}
	for w, h := range st.Heads {
		tip[w] = h
	}
	for i, r := range rows {
		h := tip[r.WriterID]
		if r.WriterCounter != h.Counter+1 || !bytes.Equal(r.PrevHash, h.Hash[:]) {
			return stop(i, tampered("chainBreak"))
		}
		got := sha256.Sum256(append(append([]byte(nil), r.PrevHash...), r.Blob...))
		if !bytes.Equal(got[:], r.BlobHash) {
			return stop(i, tampered("chainBreak"))
		}
		tip[r.WriterID] = Head{Counter: r.WriterCounter, Hash: got}
	}
	last := map[string]int{}
	for i, r := range rows {
		last[r.WriterID] = i
	}
	writers := make([]string, 0, len(last))
	for w := range last {
		writers = append(writers, w)
	}
	sort.Slice(writers, func(a, b int) bool { return last[writers[a]] < last[writers[b]] })
	for _, w := range writers {
		e := st.Roster[w]
		for i, r := range rows {
			if r.WriterID != w || e.Live {
				continue
			}
			if r.WriterCounter > e.FinalCounter ||
				(r.WriterCounter == e.FinalCounter && !bytes.Equal(r.BlobHash, e.FinalHead)) {
				return stop(i, tampered("afterRevocation"))
			}
		}
		i := last[w]
		r := rows[i]
		if r.HeadSig == nil {
			return stop(i, tampered("headUnsigned"))
		}
		msg, err := keyproto.HeadMessage(st.User, uint64(r.WriterCounter), r.BlobHash, w)
		if err != nil || !keyproto.VerifyEd25519(e.Pub, msg, r.HeadSig) {
			return stop(i, tampered("headInvalid"))
		}
	}
	out := PageResult{Rows: []Outcome{}}
	for i, r := range rows {
		o := st.open(r)
		if o.Kind == "updateRequired" && !st.Roster[r.WriterID].Live {
			o = setAside("opsUndecodable", false)
		}
		if o.HardStop() {
			out.Stop = &Stop{Row: i, Outcome: o}
			return out
		}
		out.Rows = append(out.Rows, o)
	}
	return out
}

var writerGrammarOK = keyproto.ValidWriterID

func rowShapeOK(r Row) bool {
	return r.Stream == blob.StreamHot && writerGrammarOK(r.WriterID) && r.WriterCounter >= 1 &&
		r.SizeBucket == len(r.Blob) && blob.IsBucket(len(r.Blob)) &&
		len(r.BlobHash) == 32 && len(r.PrevHash) == 32
}

func (st ReaderState) open(r Row) Outcome {
	b := r.Blob
	switch {
	case b[0] > blob.Version3:
		return Outcome{Kind: "updateRequired"}
	case b[0] != blob.Version3:
		return tampered("legacyFrame")
	}
	n := len(b)
	l := int(binary.BigEndian.Uint16(b[5:7]))
	e := binary.BigEndian.Uint32(b[1:5])
	if l+67 > n || e == 0 || e > blob.MaxEpoch {
		return tampered("badHeader")
	}
	if e > st.EpochHWM && st.ServerEpoch < e {
		return tampered("epochInvalid")
	}
	want := blob.Envelope{UserID: st.User, Stream: blob.StreamHot, WriterID: r.WriterID, WriterCounter: r.WriterCounter}.AAD()
	if subtle.ConstantTimeCompare(b[blob.FixedHeaderSize:blob.FixedHeaderSize+l], want) != 1 {
		return tampered("aadMismatch")
	}
	key, ok := st.Keys[e]
	if !ok {
		return Outcome{Kind: "needsUnlock", Epoch: e}
	}
	region, err := blobtest.OpenRegion3(key, [32]byte(r.PrevHash), b)
	if err != nil {
		return setAside("aeadFailed", true)
	}
	g, err := blobtest.RegionPayload(region)
	if err != nil {
		return setAside("regionMalformed", false)
	}
	pt, err := blobtest.GunzipStrict(g)
	if err != nil {
		return setAside("payloadInvalid", false)
	}
	return st.decode(pt)
}

func (st ReaderState) decode(pt []byte) Outcome {
	var env struct {
		V    *int              `json:"v"`
		Kind string            `json:"kind"`
		Ops  []json.RawMessage `json:"ops"`
	}
	if err := json.Unmarshal(pt, &env); err != nil || env.V == nil || env.Kind != "ops" {
		return setAside("opsUndecodable", false)
	}
	if *env.V > st.Schema+1 {
		return setAside("opsUndecodable", false)
	}
	if *env.V > st.Schema {
		return Outcome{Kind: "updateRequired"}
	}
	for _, raw := range env.Ops {
		var op struct {
			V    *int   `json:"v"`
			Type string `json:"type"`
		}
		if err := json.Unmarshal(raw, &op); err != nil || op.V == nil {
			return setAside("opsUndecodable", false)
		}
		if *op.V > st.Schema+1 {
			return setAside("opsUndecodable", false)
		}
		if *op.V > st.Schema {
			return Outcome{Kind: "updateRequired"}
		}
		if !st.KnownTypes[op.Type] {
			return setAside("opsUndecodable", false)
		}
	}
	return Outcome{Kind: "opened"}
}
