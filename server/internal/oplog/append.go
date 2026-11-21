package oplog

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/budget"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

const TypeFlagEdit = "edit"

type Row struct {
	UserID        uuid.UUID
	Seq           int64
	Stream        string
	WriterID      string
	WriterCounter int64
	TypeFlag      string
	Blob          []byte
	SizeBucket    int
	BlobHash      []byte
	PrevHash      []byte
	HeadSig       []byte
	CreatedAt     time.Time
}

func (r Row) validate() error {
	switch {
	case r.UserID == uuid.Nil:
		return errors.New("user_id is zero")
	case r.Seq != 0:
		return fmt.Errorf("seq is server-assigned; leave it zero (got %d)", r.Seq)
	case r.Stream != blob.StreamHot:
		return fmt.Errorf("stream is %q, want %q", r.Stream, blob.StreamHot)
	case r.WriterID == "":
		return errors.New("writer_id is empty")
	case r.WriterCounter < 1:
		return fmt.Errorf("writer_counter is %d, and counters are 1-based", r.WriterCounter)
	case r.TypeFlag != TypeFlagEdit:
		return fmt.Errorf("type_flag is %q, want %q", r.TypeFlag, TypeFlagEdit)
	case len(r.Blob) == 0:
		return errors.New("blob is empty")
	case len(r.BlobHash) != 32:
		return fmt.Errorf("blob_hash is %d bytes, want 32", len(r.BlobHash))
	case len(r.PrevHash) != 32:
		return fmt.Errorf("prev_hash is %d bytes, want 32", len(r.PrevHash))
	}
	bucket, err := blob.BucketFor(len(r.Blob))
	if err != nil {
		return fmt.Errorf("blob is %d bytes: %w", len(r.Blob), err)
	}
	if bucket != len(r.Blob) {
		return fmt.Errorf("blob is %d bytes, which is not a size bucket", len(r.Blob))
	}
	if r.SizeBucket != len(r.Blob) {
		return fmt.Errorf("size_bucket is %d but the blob is %d bytes", r.SizeBucket, len(r.Blob))
	}

	if err := blob.LooksSealed(r.Blob); err != nil {
		return err
	}

	aad, err := blob.EmbeddedAAD(r.Blob)
	if err != nil {
		return fmt.Errorf("blob framing is unreadable: %w", err)
	}
	want := blob.Envelope{
		UserID: r.UserID, Stream: r.Stream, WriterID: r.WriterID, WriterCounter: r.WriterCounter,
	}.AAD()
	if !bytes.Equal(aad, want) {
		return fmt.Errorf("blob was sealed for position %q but is being stored at %q", aad, want)
	}
	return nil
}

type Appender struct {
	Pool   *pgxpool.Pool
	Budget *budget.Gate
}

func EnsureSeqRow(ctx context.Context, tx pgx.Tx, userID uuid.UUID) error {
	if userID == uuid.Nil {
		return errors.New("oplog: EnsureSeqRow: user_id is zero")
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO oplog_seq (user_id) VALUES ($1) ON CONFLICT DO NOTHING`, userID); err != nil {
		return fmt.Errorf("oplog: ensure seq row: %w", err)
	}
	return nil
}

func (a *Appender) appendRows(ctx context.Context, rows []Row, prepare prepareFunc) ([]int64, error) {
	if len(rows) == 0 {
		return nil, nil
	}
	userID := rows[0].UserID
	for i, r := range rows {
		if r.UserID != userID {
			return nil, fmt.Errorf("oplog: append: row %d belongs to user %s, row 0 to %s", i, r.UserID, userID)
		}
		if r.Seq != 0 {
			return nil, fmt.Errorf("oplog: append: row %d: seq is server-assigned; leave it zero (got %d)", i, r.Seq)
		}
	}

	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return nil, fmt.Errorf("oplog: append: begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)

	seqs, err := a.appendTx(ctx, tx, userID, rows, prepare)
	if err != nil {
		pgtx.Rollback(ctx, tx)
		return nil, a.budget().RecordRefusal(ctx, err)
	}
	if err := tx.Commit(ctx); err != nil {
		if commitOutcomeKnown(err) {
			return nil, fmt.Errorf("oplog: append: commit: %w", err)
		}
		return nil, fmt.Errorf("oplog: append: commit: %w: %w", errCommitUnanswered, err)
	}
	return seqs, nil
}

func commitOutcomeKnown(err error) bool {
	var pgErr *pgconn.PgError
	return errors.Is(err, pgx.ErrTxCommitRollback) || errors.As(err, &pgErr)
}

type prepareFunc func(ctx context.Context, tx pgx.Tx, rows []Row) error

func (a *Appender) appendTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, rows []Row, prepare prepareFunc) ([]int64, error) {
	var frozen bool
	if err := tx.QueryRow(ctx, `SELECT frozen_at IS NOT NULL FROM users WHERE id = $1 FOR KEY SHARE`, userID).Scan(&frozen); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, errors.New("oplog: append: no such account")
		}
		return nil, fmt.Errorf("oplog: append: lock the account: %w", err)
	}
	if frozen {
		return nil, ErrAccountFrozen
	}
	if err := EnsureSeqRow(ctx, tx, userID); err != nil {
		return nil, err
	}
	start, err := allocSeq(ctx, tx, userID, len(rows))
	if err != nil {
		return nil, err
	}
	if prepare != nil {
		if err := prepare(ctx, tx, rows); err != nil {
			return nil, err
		}
	}
	for i, r := range rows {
		if err := r.validate(); err != nil {
			return nil, fmt.Errorf("oplog: append: row %d: %w", i, err)
		}
	}
	if err := a.admit(ctx, tx, userID, rows); err != nil {
		return nil, err
	}
	seqs := make([]int64, len(rows))
	for i := range rows {
		seqs[i] = start + int64(i)
	}
	if err := insertRows(ctx, tx, rows, seqs); err != nil {
		return nil, err
	}
	return seqs, nil
}

func (a *Appender) budget() *budget.Gate {
	if a.Budget != nil {
		return a.Budget
	}
	return budget.New(a.Pool)
}

func (a *Appender) admit(ctx context.Context, tx pgx.Tx, userID uuid.UUID, rows []Row) error {
	var n int64
	for _, r := range rows {
		n += int64(len(r.Blob))
	}
	if err := a.budget().Admit(ctx, tx, userID, budget.ResourceOplogHotBytes, n); err != nil {
		return fmt.Errorf("oplog: append: %w", err)
	}
	return nil
}

const insertRowSQL = `INSERT INTO op_log
	(user_id, seq, stream, writer_id, writer_counter, type_flag,
	 blob, size_bucket, blob_hash, prev_hash, head_sig, created_at)
	VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11, coalesce($12::timestamptz, now()))`

func allocSeq(ctx context.Context, tx pgx.Tx, userID uuid.UUID, n int) (int64, error) {
	var start int64
	err := tx.QueryRow(ctx,
		`UPDATE oplog_seq SET next_seq = next_seq + $2 WHERE user_id = $1 RETURNING next_seq - $2`,
		userID, int64(n)).Scan(&start)
	if err != nil {
		return 0, fmt.Errorf("oplog: allocate %d seqs for user %s: %w", n, userID, err)
	}
	return start, nil
}

func insertRows(ctx context.Context, tx pgx.Tx, rows []Row, seqs []int64) error {
	batch := &pgx.Batch{}
	for i, r := range rows {
		var createdAt *time.Time
		if !r.CreatedAt.IsZero() {
			t := r.CreatedAt
			createdAt = &t
		}
		var headSig any
		if r.HeadSig != nil {
			headSig = r.HeadSig
		}
		batch.Queue(insertRowSQL, r.UserID, seqs[i], r.Stream, r.WriterID, r.WriterCounter,
			r.TypeFlag, r.Blob, r.SizeBucket, r.BlobHash, r.PrevHash, headSig, createdAt)
	}
	br := tx.SendBatch(ctx, batch)
	var firstErr error
	for i := range rows {
		if _, err := br.Exec(); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("oplog: append: insert row %d (seq %d): %w", i, seqs[i], err)
		}
	}
	if err := br.Close(); err != nil && firstErr == nil {
		firstErr = fmt.Errorf("oplog: append: insert batch: %w", err)
	}
	return firstErr
}

func (a *Appender) MaxSeq(ctx context.Context, userID uuid.UUID) (int64, error) {
	var max int64
	err := a.Pool.QueryRow(ctx,
		`SELECT coalesce(max(seq), 0) FROM op_log WHERE user_id = $1`, userID).Scan(&max)
	if err != nil {
		return 0, fmt.Errorf("oplog: max seq for user %s: %w", userID, err)
	}
	return max, nil
}
