package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type KeyHistoryEntry struct {
	ID                 int64
	WriterID           string
	Alg                string
	PubKey             []byte
	DAKPubkey          []byte
	Event              string
	AuthorizedBy       string
	AuthorizerWriterID string
	FinalCounter       *int64
	FinalHead          []byte
	Nonce              []byte
	Signature          []byte
	At                 time.Time
}

func (w *Writers) KeyHistory(ctx context.Context, userID uuid.UUID) ([]KeyHistoryEntry, error) {
	if w == nil || w.Pool == nil {
		return nil, errors.New("auth: Writers.Pool is nil")
	}
	rows, err := w.Pool.Query(ctx,
		`SELECT id, writer_id, alg, pubkey, dak_pubkey, event, authorized_by, authorizer_writer_id,
		        final_counter, final_head, nonce, signature, at
		   FROM key_history WHERE user_id = $1 ORDER BY id`, userID)
	if err != nil {
		return nil, fmt.Errorf("auth: key history for user %s: %w", userID, err)
	}
	defer rows.Close()
	var out []KeyHistoryEntry
	for rows.Next() {
		var (
			e     KeyHistoryEntry
			authz *string
		)
		if err := rows.Scan(&e.ID, &e.WriterID, &e.Alg, &e.PubKey, &e.DAKPubkey, &e.Event, &e.AuthorizedBy, &authz,
			&e.FinalCounter, &e.FinalHead, &e.Nonce, &e.Signature, &e.At); err != nil {
			return nil, fmt.Errorf("auth: scan key history entry: %w", err)
		}
		if authz != nil {
			e.AuthorizerWriterID = *authz
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("auth: key history for user %s: %w", userID, err)
	}
	return out, nil
}
