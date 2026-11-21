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

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

var ErrChainBreak = errors.New("writer hash chain break")

const (
	uniqueViolation    = "23505"
	positionConstraint = "op_log_position_uniq"
)

var errBatchAlreadyApplied = errors.New("oplog: batch already applied")

var ErrPositionTaken = errors.New("oplog: chain position already held by different bytes")

var ErrPartiallyApplied = errors.New("oplog: this batch is partly applied already: read the chain head and resend only the rows above it")

type querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

func (a *Appender) Head(ctx context.Context, userID uuid.UUID, writerID, stream string) (int64, [32]byte, error) {
	return headOf(ctx, a.Pool, userID, writerID, stream)
}

func headOf(ctx context.Context, q querier, userID uuid.UUID, writerID, stream string) (int64, [32]byte, error) {
	var (
		counter int64
		hash    []byte
	)
	err := q.QueryRow(ctx,
		`SELECT writer_counter, blob_hash FROM op_log
		  WHERE user_id = $1 AND writer_id = $2 AND stream = $3
		  ORDER BY writer_counter DESC LIMIT 1`, userID, writerID, stream).Scan(&counter, &hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, blob.ZeroHash, nil
	}
	if err != nil {
		return 0, blob.ZeroHash, fmt.Errorf("oplog: head of (%s, %s) for user %s: %w", writerID, stream, userID, err)
	}
	if len(hash) != 32 {
		return 0, blob.ZeroHash, fmt.Errorf("oplog: head of (%s, %s) for user %s: blob_hash is %d bytes", writerID, stream, userID, len(hash))
	}
	return counter, [32]byte(hash), nil
}

func VerifyChain(rows []Row, fromCounter int64, fromHash [32]byte) error {
	if len(rows) == 0 {
		return nil
	}
	writerID, stream := rows[0].WriterID, rows[0].Stream
	prev := fromHash
	want := fromCounter + 1
	for i, r := range rows {
		if r.WriterID != writerID || r.Stream != stream {
			return fmt.Errorf("%w: row %d is (%s, %s), but the chain is (%s, %s)",
				ErrChainBreak, i, r.WriterID, r.Stream, writerID, stream)
		}
		if r.WriterCounter != want {
			return fmt.Errorf("%w: (%s, %s) row %d has counter %d, want %d",
				ErrChainBreak, writerID, stream, i, r.WriterCounter, want)
		}
		if !bytes.Equal(r.PrevHash, prev[:]) {
			return fmt.Errorf("%w: (%s, %s) counter %d links to %x, but the chain is at %x",
				ErrChainBreak, writerID, stream, r.WriterCounter, r.PrevHash, prev)
		}
		got := blob.Hash(prev, blob.Sealed{Bytes: r.Blob, SizeBucket: r.SizeBucket})
		if !bytes.Equal(r.BlobHash, got[:]) {
			return fmt.Errorf("%w: (%s, %s) counter %d claims hash %x, but its bytes hash to %x",
				ErrChainBreak, writerID, stream, r.WriterCounter, r.BlobHash, got)
		}
		prev = got
		want++
	}
	return nil
}

func (a *Appender) AppendClient(ctx context.Context, userID uuid.UUID, writerID, stream string, rows []Row, headSig []byte) ([]int64, error) {
	seqs, _, err := a.AppendClientOutcome(ctx, userID, writerID, stream, rows, headSig)
	return seqs, err
}

type AppendOutcome int

const (
	AppendAddedNothing AppendOutcome = iota
	AppendAddedRows
	AppendMayHaveAddedRows
)

var errCommitUnanswered = errors.New("the commit got no answer")

func (a *Appender) AppendClientOutcome(ctx context.Context, userID uuid.UUID, writerID, stream string, rows []Row, headSig []byte) ([]int64, AppendOutcome, error) {
	if len(rows) == 0 {
		return nil, AppendAddedNothing, nil
	}
	if stream != blob.StreamHot {
		return nil, AppendAddedNothing, fmt.Errorf("oplog: append client: stream %q, want %q", stream, blob.StreamHot)
	}

	batch := make([]Row, len(rows))
	copy(batch, rows)
	for i := range batch {
		r := &batch[i]
		if r.UserID != uuid.Nil && r.UserID != userID {
			return nil, AppendAddedNothing, fmt.Errorf("oplog: append client: row %d names user %s, the call names %s", i, r.UserID, userID)
		}
		if r.WriterID != "" && r.WriterID != writerID {
			return nil, AppendAddedNothing, fmt.Errorf("oplog: append client: row %d names writer %q, the call names %q", i, r.WriterID, writerID)
		}
		if r.Stream != "" && r.Stream != stream {
			return nil, AppendAddedNothing, fmt.Errorf("oplog: append client: row %d names stream %q, the call names %q", i, r.Stream, stream)
		}
		if r.HeadSig != nil {
			return nil, AppendAddedNothing, fmt.Errorf("oplog: append client: row %d carries a head_sig; the batch's travels beside the rows", i)
		}
		r.UserID, r.WriterID, r.Stream = userID, writerID, stream
		if r.TypeFlag == "" {
			r.TypeFlag = TypeFlagEdit
		}
		if r.TypeFlag != TypeFlagEdit {
			return nil, AppendAddedNothing, fmt.Errorf("oplog: append client: row %d has type_flag %q, want %q", i, r.TypeFlag, TypeFlagEdit)
		}
		if err := r.validate(); err != nil {
			return nil, AppendAddedNothing, fmt.Errorf("oplog: append client: row %d: %w", i, err)
		}
	}
	var claimedPrev [32]byte
	copy(claimedPrev[:], batch[0].PrevHash)
	if err := VerifyChain(batch, batch[0].WriterCounter-1, claimedPrev); err != nil {
		return nil, AppendAddedNothing, err
	}
	last := &batch[len(batch)-1]
	headMsg, err := keyproto.HeadMessage(userID, uint64(last.WriterCounter), last.BlobHash, writerID)
	if err != nil {
		return nil, AppendAddedNothing, fmt.Errorf("%w: %v", ErrHeadSignature, err)
	}

	var replayed []int64
	prepare := func(ctx context.Context, tx pgx.Tx, rows []Row) error {
		var (
			pub     []byte
			revoked *time.Time
		)
		err := tx.QueryRow(ctx,
			`SELECT pubkey, revoked_at FROM writers WHERE user_id = $1 AND writer_id = $2 FOR SHARE`,
			userID, writerID).Scan(&pub, &revoked)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrUnknownWriter
		}
		if err != nil {
			return fmt.Errorf("oplog: read writer %s: %w", writerID, err)
		}
		if revoked != nil {
			return ErrWriterRevoked
		}
		headCounter, headHash, err := headOf(ctx, tx, userID, writerID, stream)
		if err != nil {
			return err
		}
		if rows[0].WriterCounter <= headCounter {
			seqs, err := appliedSeqs(ctx, tx, userID, writerID, stream, rows)
			if err != nil {
				return err
			}
			replayed = seqs
			return errBatchAlreadyApplied
		}
		if rows[0].WriterCounter != headCounter+1 {
			return fmt.Errorf("%w: (%s, %s) is at counter %d, this batch starts at %d",
				ErrChainBreak, writerID, stream, headCounter, rows[0].WriterCounter)
		}
		if !bytes.Equal(rows[0].PrevHash, headHash[:]) {
			return fmt.Errorf("%w: (%s, %s) counter %d links to %x, but the stored head is %x",
				ErrChainBreak, writerID, stream, rows[0].WriterCounter, rows[0].PrevHash, headHash)
		}
		var current int64
		err = tx.QueryRow(ctx, `SELECT current_epoch FROM account_keys WHERE user_id = $1 FOR SHARE`, userID).Scan(&current)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrKeysRequired
		}
		if err != nil {
			return fmt.Errorf("oplog: read current epoch: %w", err)
		}
		for i := range rows {
			e, err := blob.KeyEpoch(rows[i].Blob)
			if err != nil {
				return err
			}
			if int64(e) != current {
				return &StaleEpochError{Frame: e, Current: current}
			}
		}
		if !keyproto.VerifyEd25519(pub, headMsg, headSig) {
			return ErrHeadSignature
		}
		rows[len(rows)-1].HeadSig = headSig
		return nil
	}

	seqs, err := a.appendRows(ctx, batch, prepare)
	if errors.Is(err, errBatchAlreadyApplied) {
		return replayed, AppendAddedNothing, nil
	}
	if err == nil {
		return seqs, AppendAddedRows, nil
	}
	outcome := AppendAddedNothing
	if errors.Is(err, errCommitUnanswered) {
		outcome = AppendMayHaveAddedRows
	}
	seqs, err = a.resolveAppendErr(ctx, userID, writerID, stream, batch, err)
	return seqs, outcome, err
}

var (
	ErrHeadSignature = errors.New("oplog: the batch head signature does not verify")
	ErrUnknownWriter = errors.New("oplog: no such writer on this account")
	ErrWriterRevoked = errors.New("oplog: the writer is revoked")
	ErrKeysRequired  = errors.New("oplog: the account has no keys")
	ErrAccountFrozen = errors.New("oplog: the account is frozen")
	ErrStaleEpoch    = errors.New("oplog: a frame's key epoch is not the account's current epoch")
)

type StaleEpochError struct {
	Frame   uint32
	Current int64
}

func (e *StaleEpochError) Error() string {
	return fmt.Sprintf("oplog: frame key epoch %d, the account's current epoch is %d", e.Frame, e.Current)
}

func (e *StaleEpochError) Is(target error) bool { return target == ErrStaleEpoch }

func (a *Appender) resolveAppendErr(ctx context.Context, userID uuid.UUID, writerID, stream string, batch []Row, err error) ([]int64, error) {
	if !isPositionTaken(err) {
		return nil, err
	}
	applied, resolveErr := appliedSeqs(ctx, a.Pool, userID, writerID, stream, batch)
	if resolveErr != nil {
		return nil, fmt.Errorf("%w: (%s, %s): %v", ErrPositionTaken, writerID, stream, resolveErr)
	}
	return applied, nil
}

func appliedSeqs(ctx context.Context, q querier, userID uuid.UUID, writerID, stream string, rows []Row) ([]int64, error) {
	counters := make([]int64, len(rows))
	for i, r := range rows {
		counters[i] = r.WriterCounter
	}
	q1, err := q.Query(ctx,
		`SELECT writer_counter, seq, blob_hash FROM op_log
		  WHERE user_id = $1 AND writer_id = $2 AND stream = $3 AND writer_counter = ANY($4)`,
		userID, writerID, stream, counters)
	if err != nil {
		return nil, fmt.Errorf("oplog: read applied rows for (%s, %s): %w", writerID, stream, err)
	}
	defer q1.Close()
	type stored struct {
		seq  int64
		hash []byte
	}
	found := make(map[int64]stored, len(rows))
	for q1.Next() {
		var (
			counter, seq int64
			hash         []byte
		)
		if err := q1.Scan(&counter, &seq, &hash); err != nil {
			return nil, fmt.Errorf("oplog: read applied rows for (%s, %s): %w", writerID, stream, err)
		}
		found[counter] = stored{seq: seq, hash: hash}
	}
	if err := q1.Err(); err != nil {
		return nil, fmt.Errorf("oplog: read applied rows for (%s, %s): %w", writerID, stream, err)
	}

	out := make([]int64, len(rows))
	for i, r := range rows {
		s, ok := found[r.WriterCounter]
		if !ok {
			return nil, fmt.Errorf("%w: (%s, %s) counter %d is not stored, but this batch also contains counters that are",
				ErrPartiallyApplied, writerID, stream, r.WriterCounter)
		}
		if !bytes.Equal(s.hash, r.BlobHash) {
			return nil, fmt.Errorf("%w: (%s, %s) counter %d already holds different bytes (stored %x, submitted %x)",
				ErrChainBreak, writerID, stream, r.WriterCounter, s.hash, r.BlobHash)
		}
		out[i] = s.seq
	}
	return out, nil
}

func isPositionTaken(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == uniqueViolation && pgErr.ConstraintName == positionConstraint
}
