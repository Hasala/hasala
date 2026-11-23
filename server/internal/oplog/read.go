package oplog

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/salehtl/hasala/server/internal/blob"
)

var ErrUnknownStream = errors.New("oplog: unknown stream")

type HashRow struct {
	Seq           int64
	Stream        string
	WriterID      string
	WriterCounter int64
	BlobHash      []byte
	PrevHash      []byte

	headSigned bool
}

const readPageSQL = `
SELECT seq, stream, writer_id, writer_counter, type_flag,
       blob, size_bucket, blob_hash, prev_hash, head_sig, created_at
  FROM (
    SELECT seq, stream, writer_id, writer_counter, type_flag,
           blob, size_bucket, blob_hash, prev_hash, head_sig, created_at,
           sum(size_bucket) OVER (ORDER BY seq) AS running,
           row_number()     OVER (ORDER BY seq) AS rn
      FROM op_log
     WHERE user_id = $1 AND stream = $2 AND seq > $3
     ORDER BY seq
     LIMIT $4
  ) page
 WHERE page.rn = 1 OR page.running <= $5
 ORDER BY page.seq`

func Read(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, stream string, after int64, limit, maxBytes int) ([]Row, error) {
	if err := checkStream(stream); err != nil {
		return nil, err
	}
	if pool == nil {
		return nil, errors.New("oplog: read: pool is nil")
	}
	if limit < 1 {
		limit = 1
	}
	if maxBytes < 1 {
		maxBytes = 1
	}
	q, err := pool.Query(ctx, readPageSQL, userID, stream, after, limit, int64(maxBytes))
	if err != nil {
		return nil, fmt.Errorf("oplog: read %s log for user %s: %w", stream, userID, err)
	}
	defer q.Close()

	var (
		out   []Row
		total int
	)
	for q.Next() {
		r, err := scanRow(q, userID)
		if err != nil {
			return nil, fmt.Errorf("oplog: read %s log for user %s: %w", stream, userID, err)
		}
		if len(out) > 0 && total+len(r.Blob) > maxBytes {
			break
		}
		total += len(r.Blob)
		out = append(out, r)
	}
	if err := q.Err(); err != nil {
		return nil, fmt.Errorf("oplog: read %s log for user %s: %w", stream, userID, err)
	}
	q.Close()
	if n := len(out); n > 0 && out[n-1].HeadSig == nil {
		tail, err := pool.Query(ctx,
			`SELECT seq, stream, writer_id, writer_counter, type_flag,
			        blob, size_bucket, blob_hash, prev_hash, head_sig, created_at
			   FROM op_log WHERE user_id = $1 AND stream = $2 AND seq > $3
			  ORDER BY seq LIMIT $4`, userID, stream, out[n-1].Seq, maxBatchTail)
		if err != nil {
			return nil, fmt.Errorf("oplog: read %s batch tail for user %s: %w", stream, userID, err)
		}
		defer tail.Close()
		for tail.Next() {
			r, err := scanRow(tail, userID)
			if err != nil {
				return nil, fmt.Errorf("oplog: read %s batch tail for user %s: %w", stream, userID, err)
			}
			out = append(out, r)
			if r.HeadSig != nil {
				break
			}
		}
		if err := tail.Err(); err != nil {
			return nil, fmt.Errorf("oplog: read %s batch tail for user %s: %w", stream, userID, err)
		}
	}
	return out, nil
}

func scanRow(q pgx.Rows, userID uuid.UUID) (Row, error) {
	r := Row{UserID: userID}
	err := q.Scan(&r.Seq, &r.Stream, &r.WriterID, &r.WriterCounter, &r.TypeFlag,
		&r.Blob, &r.SizeBucket, &r.BlobHash, &r.PrevHash, &r.HeadSig, &r.CreatedAt)
	return r, err
}

const maxBatchTail = 7

func Hashes(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, stream string, after int64, limit int) ([]HashRow, error) {
	if err := checkStream(stream); err != nil {
		return nil, err
	}
	if pool == nil {
		return nil, errors.New("oplog: hashes: pool is nil")
	}
	if limit < 1 {
		limit = 1
	}
	q, err := pool.Query(ctx,
		`SELECT seq, stream, writer_id, writer_counter, blob_hash, prev_hash, head_sig IS NOT NULL
		   FROM op_log
		  WHERE user_id = $1 AND stream = $2 AND seq > $3
		  ORDER BY seq
		  LIMIT $4`, userID, stream, after, limit+maxBatchTail)
	if err != nil {
		return nil, fmt.Errorf("oplog: read %s hashes for user %s: %w", stream, userID, err)
	}
	defer q.Close()

	var out []HashRow
	for q.Next() {
		var (
			h      HashRow
			signed bool
		)
		if err := q.Scan(&h.Seq, &h.Stream, &h.WriterID, &h.WriterCounter, &h.BlobHash, &h.PrevHash, &signed); err != nil {
			return nil, fmt.Errorf("oplog: read %s hashes for user %s: %w", stream, userID, err)
		}
		if len(out) >= limit && out[len(out)-1].headSigned {
			break
		}
		h.headSigned = signed
		out = append(out, h)
	}
	if err := q.Err(); err != nil {
		return nil, fmt.Errorf("oplog: read %s hashes for user %s: %w", stream, userID, err)
	}
	return out, nil
}

func StreamMaxSeq(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, stream string) (int64, error) {
	if err := checkStream(stream); err != nil {
		return 0, err
	}
	if pool == nil {
		return 0, errors.New("oplog: stream max seq: pool is nil")
	}
	var max int64
	err := pool.QueryRow(ctx,
		`SELECT coalesce(max(seq), 0) FROM op_log WHERE user_id = $1 AND stream = $2`,
		userID, stream).Scan(&max)
	if err != nil {
		return 0, fmt.Errorf("oplog: max %s seq for user %s: %w", stream, userID, err)
	}
	return max, nil
}

func checkStream(stream string) error {
	if stream != blob.StreamHot {
		return fmt.Errorf("%w: %q, want %q", ErrUnknownStream, stream, blob.StreamHot)
	}
	return nil
}
