package api

import (
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
)

type KeyHistoryEntry struct {
	ID                 string    `json:"id"`
	WriterID           string    `json:"writer_id"`
	Alg                string    `json:"alg"`
	PubKey             string    `json:"pubkey"`
	DAKPubkey          *string   `json:"dak_pubkey"`
	Event              string    `json:"event"`
	AuthorizedBy       string    `json:"authorized_by"`
	AuthorizerWriterID *string   `json:"authorizer_writer_id"`
	FinalCounter       *string   `json:"final_counter"`
	FinalHead          *string   `json:"final_head"`
	Nonce              string    `json:"nonce"`
	Signature          string    `json:"signature"`
	At                 time.Time `json:"at"`
}

type KeyHistoryResponse struct {
	Entries []KeyHistoryEntry `json:"entries"`
}

func (s *Server) handleKeyHistory(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	log, err := s.Writers.KeyHistory(r.Context(), userID)
	if err != nil {
		s.logf("api: key history for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	out := KeyHistoryResponse{Entries: make([]KeyHistoryEntry, 0, len(log))}
	str := func(s string) *string { return &s }
	for _, e := range log {
		x := KeyHistoryEntry{
			ID: strconv.FormatInt(e.ID, 10), WriterID: e.WriterID, Alg: e.Alg, PubKey: b64(e.PubKey),
			Event: e.Event, AuthorizedBy: e.AuthorizedBy, Nonce: b64(e.Nonce), Signature: b64(e.Signature), At: e.At,
		}
		if e.DAKPubkey != nil {
			x.DAKPubkey = str(b64(e.DAKPubkey))
		}
		if e.AuthorizerWriterID != "" {
			x.AuthorizerWriterID = str(e.AuthorizerWriterID)
		}
		if e.FinalCounter != nil {
			x.FinalCounter = str(strconv.FormatInt(*e.FinalCounter, 10))
		}
		if e.FinalHead != nil {
			x.FinalHead = str(b64(e.FinalHead))
		}
		out.Entries = append(out.Entries, x)
	}
	writeJSON(w, http.StatusOK, out)
}
