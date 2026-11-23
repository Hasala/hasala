package api

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/budget"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/oplog"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

type Row struct {
	Seq           string    `json:"seq"`
	Stream        string    `json:"stream"`
	WriterID      string    `json:"writer_id"`
	WriterCounter string    `json:"writer_counter"`
	TypeFlag      string    `json:"type_flag"`
	SizeBucket    int       `json:"size_bucket"`
	BlobHash      string    `json:"blob_hash"`
	PrevHash      string    `json:"prev_hash"`
	CreatedAt     time.Time `json:"created_at"`
	Blob          string    `json:"blob"`
	HeadSig       *string   `json:"head_sig"`
}

type PullResponse struct {
	Stream   string `json:"stream"`
	Rows     []Row  `json:"rows"`
	Next     string `json:"next"`
	Complete bool   `json:"complete"`
}

type HashEntry struct {
	Seq           string `json:"seq"`
	WriterID      string `json:"writer_id"`
	WriterCounter string `json:"writer_counter"`
	BlobHash      string `json:"blob_hash"`
	PrevHash      string `json:"prev_hash"`
}

type HashesResponse struct {
	Stream   string      `json:"stream"`
	Hashes   []HashEntry `json:"hashes"`
	Next     string      `json:"next"`
	Complete bool        `json:"complete"`
}

type UploadBlob struct {
	WriterCounter string `json:"writer_counter"`
	PrevHash      string `json:"prev_hash"`
	BlobHash      string `json:"blob_hash"`
	TypeFlag      string `json:"type_flag"`
	SizeBucket    int    `json:"size_bucket"`
	Blob          string `json:"blob"`
}

type UploadRequest struct {
	WriterID string       `json:"writer_id"`
	Stream   string       `json:"stream"`
	Blobs    []UploadBlob `json:"blobs"`
	HeadSig  string       `json:"head_sig"`
}

type UploadResponse struct {
	Seqs []string `json:"seqs"`
}

type accountSlots struct {
	mu    sync.Mutex
	inUse map[uuid.UUID]int
}

func (p *accountSlots) acquire(u uuid.UUID, limit int) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.inUse == nil {
		p.inUse = map[uuid.UUID]int{}
	}
	if p.inUse[u] >= limit {
		return false
	}
	p.inUse[u]++
	return true
}

func (p *accountSlots) release(u uuid.UUID) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.inUse[u]--; p.inUse[u] <= 0 {
		delete(p.inUse, u)
	}
}

func (s *Server) pullAdmitted(w http.ResponseWriter, userID uuid.UUID) bool {
	if !s.pulls.acquire(userID, maxConcurrentPulls) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many pulls; try again shortly")
		return false
	}
	if !s.PullPerUser.Allow(userID.String()) {
		s.pulls.release(userID)
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many pulls; try again shortly")
		return false
	}
	return true
}

func (s *Server) handlePull(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.pullAdmitted(w, userID) {
		return
	}
	defer s.pulls.release(userID)
	stream, after, limit, ok := pageParams(w, r, defaultPullLimit, maxPullLimit)
	if !ok {
		return
	}

	rows, err := oplog.Read(r.Context(), s.Pool, userID, stream, after, limit, s.PullByteBudget)
	if err != nil {
		s.logf("api: pull %s for %s: %v", stream, userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out := PullResponse{Stream: stream, Rows: make([]Row, 0, len(rows))}
	next := after
	for _, row := range rows {
		next = row.Seq
		var headSig *string
		if row.HeadSig != nil {
			hs := base64.StdEncoding.EncodeToString(row.HeadSig)
			headSig = &hs
		}
		out.Rows = append(out.Rows, Row{
			HeadSig:       headSig,
			Seq:           strconv.FormatInt(row.Seq, 10),
			Stream:        row.Stream,
			WriterID:      row.WriterID,
			WriterCounter: strconv.FormatInt(row.WriterCounter, 10),
			TypeFlag:      row.TypeFlag,
			SizeBucket:    row.SizeBucket,
			BlobHash:      hex.EncodeToString(row.BlobHash),
			PrevHash:      hex.EncodeToString(row.PrevHash),
			CreatedAt:     row.CreatedAt,
			Blob:          base64.StdEncoding.EncodeToString(row.Blob),
		})
	}
	out.Next = strconv.FormatInt(next, 10)

	if out.Complete, ok = s.pageComplete(w, r, userID, "pull", stream, after, next); !ok {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleHashes(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.pullAdmitted(w, userID) {
		return
	}
	defer s.pulls.release(userID)
	stream, after, limit, ok := pageParams(w, r, defaultHashLimit, maxHashLimit)
	if !ok {
		return
	}

	hashes, err := oplog.Hashes(r.Context(), s.Pool, userID, stream, after, limit)
	if err != nil {
		s.logf("api: hashes %s for %s: %v", stream, userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out := HashesResponse{Stream: stream, Hashes: make([]HashEntry, 0, len(hashes))}
	next := after
	for _, h := range hashes {
		next = h.Seq
		out.Hashes = append(out.Hashes, HashEntry{
			Seq:           strconv.FormatInt(h.Seq, 10),
			WriterID:      h.WriterID,
			WriterCounter: strconv.FormatInt(h.WriterCounter, 10),
			BlobHash:      hex.EncodeToString(h.BlobHash),
			PrevHash:      hex.EncodeToString(h.PrevHash),
		})
	}
	out.Next = strconv.FormatInt(next, 10)
	if out.Complete, ok = s.pageComplete(w, r, userID, "hashes", stream, after, next); !ok {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func pageParams(w http.ResponseWriter, r *http.Request, def, max int) (stream string, after int64, limit int, ok bool) {
	if stream, ok = checkStream(w, r.URL.Query().Get("stream")); !ok {
		return "", 0, 0, false
	}
	after, err := parseCursor(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return "", 0, 0, false
	}
	if limit, err = parseLimit(r, def, max); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return "", 0, 0, false
	}
	return stream, after, limit, true
}

func (s *Server) pageComplete(w http.ResponseWriter, r *http.Request, userID uuid.UUID, what, stream string, after, next int64) (complete, ok bool) {
	maxSeq, err := oplog.StreamMaxSeq(r.Context(), s.Pool, userID, stream)
	if err != nil {
		s.logf("api: %s %s max seq for %s: %v", what, stream, userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return false, false
	}
	if after > maxSeq {
		writeErr(w, http.StatusConflict, "cursor_ahead", "after is past the end of the stream")
		return false, false
	}
	return next >= maxSeq, true
}

func checkStream(w http.ResponseWriter, stream string) (string, bool) {
	if stream == "" {
		return blob.StreamHot, true
	}
	if stream != blob.StreamHot {
		writeErr(w, http.StatusBadRequest, "bad_stream", "stream must be "+strconv.Quote(blob.StreamHot))
		return "", false
	}
	return stream, true
}

func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.uploads.acquire(userID, maxConcurrentUploads) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many uploads; try again shortly")
		return
	}
	defer s.uploads.release(userID)
	if !s.SyncPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many uploads; try again shortly")
		return
	}
	var req UploadRequest
	if !decodeBody(w, r, maxUploadBytes, &req) {
		return
	}
	var ok bool
	if req.Stream, ok = checkStream(w, req.Stream); !ok {
		return
	}
	if len(req.Blobs) == 0 {
		writeErr(w, http.StatusBadRequest, "bad_request", "blobs is empty")
		return
	}
	if len(req.Blobs) > maxUploadBlobs {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large",
			"at most "+strconv.Itoa(maxUploadBlobs)+" blobs per upload")
		return
	}
	headSig, err := base64.StdEncoding.DecodeString(req.HeadSig)
	if err != nil || len(headSig) != keyproto.Ed25519SigSize {
		writeErr(w, http.StatusBadRequest, "bad_signature", "head_sig must be a 64-byte signature in base64")
		return
	}
	if !keyproto.ValidWriterID(req.WriterID) {
		writeErr(w, http.StatusBadRequest, "bad_writer_id", "writer_id does not match the ios-<uuid v4> grammar")
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	if info.WriterID == "" {
		writeErr(w, http.StatusForbidden, "writer_unbound", "")
		return
	}
	if req.WriterID != info.WriterID {
		writeErr(w, http.StatusForbidden, "writer_mismatch", "")
		return
	}
	if !s.requireBound(w, r, info) {
		return
	}
	var hasKeys bool
	if err := s.Pool.QueryRow(r.Context(),
		`SELECT EXISTS (SELECT 1 FROM account_keys WHERE user_id = $1)`, userID).Scan(&hasKeys); err != nil {
		s.logf("api: upload for %s: read keys: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if !hasKeys {
		writeErr(w, http.StatusForbidden, "keys_required", "")
		return
	}

	rows := make([]oplog.Row, 0, len(req.Blobs))
	for i, b := range req.Blobs {
		row, refusal := decodeUploadBlob(userID, req.WriterID, req.Stream, b)
		if refusal != nil {
			if refusal.code == "plaintext_refused" {
				s.logf("api: upload for %s: blob %d refused as plaintext (%s)", userID, i, refusal.detail)
			}
			writeErr(w, refusal.status, refusal.code, "blobs["+strconv.Itoa(i)+"]: "+refusal.detail)
			return
		}
		rows = append(rows, row)
	}

	var claimedPrev [32]byte
	copy(claimedPrev[:], rows[0].PrevHash)
	if err := oplog.VerifyChain(rows, rows[0].WriterCounter-1, claimedPrev); err != nil {
		s.logf("api: upload for %s: batch is not internally chained: %v", userID, err)
		writeErr(w, http.StatusBadRequest, "bad_request",
			"the blobs in this batch do not chain to each other: counters must be consecutive, "+
				"each prev_hash must be the previous blob_hash, and each blob_hash must be "+
				"SHA256(prev_hash || blob)")
		return
	}

	var uploadBytes int
	for _, row := range rows {
		uploadBytes += len(row.Blob)
	}
	if !s.SyncUploadBytes.AllowN(userID.String(), float64(uploadBytes)) {
		s.logf("api: upload for %s: %d bytes over the upload byte budget", userID, uploadBytes)
		w.Header().Set("Retry-After", "60")
		writeErr(w, http.StatusTooManyRequests, "upload_bytes",
			"this account has uploaded more than its share of data recently; "+
				"the queued changes are safe on this device and will upload shortly")
		return
	}

	seqs, outcome, err := s.Appender.AppendClientOutcome(r.Context(), userID, req.WriterID, req.Stream, rows, headSig)
	if outcome == oplog.AppendAddedNothing {
		s.SyncUploadBytes.RefundN(userID.String(), float64(uploadBytes))
	}
	if err != nil {
		s.writeAppendErr(w, r, userID, err)
		return
	}
	out := UploadResponse{Seqs: make([]string, len(seqs))}
	for i, q := range seqs {
		out.Seqs[i] = strconv.FormatInt(q, 10)
	}
	s.wakeOthers(r.Context(), userID, req.WriterID, pushv2.ReasonSync)
	writeJSON(w, http.StatusOK, out)
}

type uploadRefusal struct {
	status       int
	code, detail string
}

func refuseBlob(status int, code, detail string) *uploadRefusal {
	return &uploadRefusal{status: status, code: code, detail: detail}
}

func decodeUploadBlob(userID uuid.UUID, writerID, stream string, b UploadBlob) (oplog.Row, *uploadRefusal) {
	counter, err := strconv.ParseInt(b.WriterCounter, 10, 64)
	if err != nil || counter < 1 {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "writer_counter must be a decimal integer of at least 1")
	}
	raw, err := base64.StdEncoding.DecodeString(b.Blob)
	if err != nil {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "blob is not base64")
	}
	if len(raw) > blob.MaxBucket {
		return oplog.Row{}, refuseBlob(http.StatusRequestEntityTooLarge, "too_large",
			"blob is "+strconv.Itoa(len(raw))+" bytes, cap is "+strconv.Itoa(blob.MaxBucket))
	}
	if b.SizeBucket != len(raw) {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_bucket",
			"size_bucket is "+strconv.Itoa(b.SizeBucket)+" but the blob is "+strconv.Itoa(len(raw))+" bytes")
	}
	if !blob.IsBucket(len(raw)) {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_bucket",
			"blob is "+strconv.Itoa(len(raw))+" bytes, which is not a size bucket")
	}
	frame, err := blob.Parse3(raw)
	if err != nil {
		var re *blob.RefusalError
		if errors.As(err, &re) {
			return oplog.Row{}, refuseBlob(http.StatusBadRequest, "plaintext_refused", re.Check)
		}
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "plaintext_refused", "framing")
	}
	want := blob.Envelope{UserID: userID, Stream: stream, WriterID: writerID, WriterCounter: counter}
	if err := want.Validate(); err != nil {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "the position this blob claims is not a valid one")
	}
	if !bytes.Equal(frame.AAD, want.AAD()) {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "aad_mismatch",
			"the blob was sealed for a different position than the one it is being stored at")
	}
	blobHash, err := hex.DecodeString(b.BlobHash)
	if err != nil || len(blobHash) != 32 {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "blob_hash must be 64 hex characters")
	}
	prevHash, err := hex.DecodeString(b.PrevHash)
	if err != nil || len(prevHash) != 32 {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "prev_hash must be 64 hex characters")
	}
	if b.TypeFlag != "" && b.TypeFlag != oplog.TypeFlagEdit {
		return oplog.Row{}, refuseBlob(http.StatusBadRequest, "bad_request", "type_flag must be "+strconv.Quote(oplog.TypeFlagEdit))
	}
	return oplog.Row{
		UserID:        userID,
		Stream:        stream,
		WriterID:      writerID,
		WriterCounter: counter,
		TypeFlag:      oplog.TypeFlagEdit,
		Blob:          raw,
		SizeBucket:    len(raw),
		BlobHash:      blobHash,
		PrevHash:      prevHash,
	}, nil
}

func (s *Server) writeAppendErr(w http.ResponseWriter, r *http.Request, userID uuid.UUID, err error) {
	var stale *oplog.StaleEpochError
	switch {
	case errors.As(err, &stale):
		s.logf("api: upload for %s: %v", userID, err)
		writeErr(w, http.StatusConflict, "stale_epoch", "current_epoch "+strconv.FormatInt(stale.Current, 10))
	case errors.Is(err, oplog.ErrHeadSignature), errors.Is(err, oplog.ErrWriterRevoked),
		errors.Is(err, oplog.ErrUnknownWriter), errors.Is(err, oplog.ErrKeysRequired):
		s.writeKeyErr(w, r, err)
	case errors.Is(err, oplog.ErrAccountFrozen):
		s.logf("api: upload for %s: refused, the account froze during the upload", userID)
		writeErr(w, http.StatusForbidden, "account_frozen", "")
	case errors.Is(err, oplog.ErrPartiallyApplied):
		writeErr(w, http.StatusConflict, "conflict",
			"read the chain head and resend only the rows above it")
	case errors.Is(err, oplog.ErrChainBreak):
		writeErr(w, http.StatusConflict, "chain_break", err.Error())
	case errors.Is(err, budget.ErrRefused):
		var refused *budget.RefusedError
		if errors.As(err, &refused) {
			s.logf("api: upload for %s: over the account ceiling: %v", userID, err)
			writeJSON(w, http.StatusRequestEntityTooLarge, errorBody{
				Error: "account_full",
				Detail: "this account is at its storage ceiling; nothing in this upload was stored, " +
					"and it stays queued on this device",
				Budget: &BudgetInfo{Resource: refused.Resource, Have: refused.Have, Delta: refused.Delta, Limit: refused.Limit},
			})
			return
		}
		s.logf("api: upload for %s: over the account ceiling, without detail: %v", userID, err)
		writeErr(w, http.StatusRequestEntityTooLarge, "account_full",
			"this account is at its storage ceiling; nothing in this upload was stored")
	case errors.Is(err, oplog.ErrPositionTaken):
		s.logf("api: upload for %s: %v", userID, err)
		writeErr(w, http.StatusConflict, "conflict", "that chain position is already held")
	default:
		s.logf("api: upload for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
	}
}
