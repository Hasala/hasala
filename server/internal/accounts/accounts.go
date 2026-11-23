package accounts

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var ErrNoSuchAccount = errors.New("accounts: no such account")

func SetReview(ctx context.Context, tx pgx.Tx, userID uuid.UUID, on bool) (was bool, err error) {
	err = tx.QueryRow(ctx,
		`WITH old AS (SELECT id, review_account FROM users WHERE id = $1 FOR UPDATE)
		 UPDATE users u SET review_account = $2 FROM old WHERE u.id = old.id RETURNING old.review_account`,
		userID, on).Scan(&was)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNoSuchAccount
	}
	if err != nil {
		return false, fmt.Errorf("accounts: set the review flag: %w", err)
	}
	return was, nil
}

func Review(ctx context.Context, q interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}, userID uuid.UUID) (bool, error) {
	var on bool
	err := q.QueryRow(ctx, `SELECT review_account FROM users WHERE id = $1`, userID).Scan(&on)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNoSuchAccount
	}
	return on, err
}
