package verify

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/oplog"
)

type Finding struct {
	ID     string    `json:"id"`
	UserID uuid.UUID `json:"user_id"`
	Detail string    `json:"detail"`
}

const (
	S1SeqDense           = "S1_seq_dense"
	S2WriterChain        = "S2_writer_chain"
	S3AADMatchesRow      = "S3_aad_matches_row"
	S4BucketValid        = "S4_bucket_valid"
	S5CounterMatchesHead = "S5_counter_matches_head"
	S6Sealed             = "S6_sealed"

	U1UsageDrift = "U1_usage_drift"
)

const (
	pageRows  = 512
	pageBytes = 8 << 20
)

const maxFindings = 2000

func Structural(ctx context.Context, pool *pgxpool.Pool) ([]Finding, error) {
	return StructuralFor(ctx, pool, nil)
}

func StructuralFor(ctx context.Context, pool *pgxpool.Pool, users []uuid.UUID) ([]Finding, error) {
	if pool == nil {
		return nil, errors.New("verify: pool is nil")
	}
	targets, err := userList(ctx, pool, users)
	if err != nil {
		return nil, err
	}
	var out []Finding
	for _, u := range targets {
		f, err := structuralUser(ctx, pool, u)
		if err != nil {
			return nil, err
		}
		out = append(out, f...)
		if len(out) >= maxFindings {
			return append(out[:maxFindings], truncated()), nil
		}
	}
	return out, nil
}

func truncated() Finding {
	return Finding{ID: "truncated", Detail: fmt.Sprintf("stopped after %d findings; fix these and re-run", maxFindings)}
}

func userList(ctx context.Context, pool *pgxpool.Pool, want []uuid.UUID) ([]uuid.UUID, error) {
	if len(want) > 0 {
		out := slices.Clone(want)
		slices.SortFunc(out, func(a, b uuid.UUID) int { return bytes.Compare(a[:], b[:]) })
		return out, nil
	}
	rows, err := pool.Query(ctx, `SELECT id FROM users ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("verify: list users: %w", err)
	}
	out, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return nil, fmt.Errorf("verify: list users: %w", err)
	}
	return out, nil
}

func structuralUser(ctx context.Context, pool *pgxpool.Pool, u uuid.UUID) ([]Finding, error) {
	var out []Finding

	var n, lo, hi int64
	if err := pool.QueryRow(ctx,
		`SELECT count(*), coalesce(min(seq),0), coalesce(max(seq),0) FROM op_log WHERE user_id = $1`,
		u).Scan(&n, &lo, &hi); err != nil {
		return nil, fmt.Errorf("verify: seq density for user %s: %w", u, err)
	}
	if n > 0 && (lo != 1 || hi != n) {
		out = append(out, Finding{ID: S1SeqDense, UserID: u, Detail: fmt.Sprintf(
			"%d rows spanning seq %d..%d: a dense log has min 1 and max == count, so %d position(s) are missing",
			n, lo, hi, hi-n)})
	}

	var (
		nextSeq int64
		headSeq int64
		haveSeq bool
	)
	err := pool.QueryRow(ctx, `
		SELECT s.next_seq, coalesce(max(o.seq), 0)
		  FROM oplog_seq s LEFT JOIN op_log o ON o.user_id = s.user_id
		 WHERE s.user_id = $1
		 GROUP BY s.next_seq`, u).Scan(&nextSeq, &headSeq)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		if n > 0 {
			out = append(out, Finding{ID: S5CounterMatchesHead, UserID: u, Detail: fmt.Sprintf(
				"%d op rows exist but this account has no oplog_seq row, so there is nothing "+
					"left that knows how many ops it should have", n)})
		}
	case err != nil:
		return nil, fmt.Errorf("verify: seq counter for user %s: %w", u, err)
	default:
		haveSeq = true
	}
	if haveSeq && nextSeq != headSeq+1 {
		out = append(out, Finding{ID: S5CounterMatchesHead, UserID: u, Detail: fmt.Sprintf(
			"oplog_seq.next_seq is %d and the highest stored seq is %d: %d op(s) were assigned "+
				"a position and are no longer stored", nextSeq, headSeq, nextSeq-1-headSeq)})
	}

	for _, stream := range []string{blob.StreamHot} {
		f, err := structuralStream(ctx, pool, u, stream)
		if err != nil {
			return nil, err
		}
		out = append(out, f...)
	}
	return out, nil
}

type chain struct {
	wantCounter int64
	prev        [32]byte
}

func structuralStream(ctx context.Context, pool *pgxpool.Pool, u uuid.UUID, stream string) ([]Finding, error) {
	var (
		out    []Finding
		chains = map[string]*chain{}
		after  int64
	)
	for {
		rows, err := oplog.Read(ctx, pool, u, stream, after, pageRows, pageBytes)
		if err != nil {
			return nil, fmt.Errorf("verify: read %s log for user %s: %w", stream, u, err)
		}
		if len(rows) == 0 {
			return out, nil
		}
		for _, r := range rows {
			after = r.Seq
			out = append(out, checkBucket(u, r)...)
			out = append(out, checkSealed(u, r)...)
			out = append(out, checkAAD(u, r)...)

			c, ok := chains[r.WriterID]
			if !ok {
				c = &chain{wantCounter: 1, prev: blob.ZeroHash}
				chains[r.WriterID] = c
			}
			out = append(out, checkChain(u, r, c)...)
		}
		if len(out) > maxFindings {
			return out, nil
		}
	}
}

func checkBucket(u uuid.UUID, r oplog.Row) []Finding {
	var out []Finding
	if len(r.Blob) != r.SizeBucket {
		out = append(out, Finding{ID: S4BucketValid, UserID: u, Detail: fmt.Sprintf(
			"seq %d: blob is %d bytes but size_bucket says %d", r.Seq, len(r.Blob), r.SizeBucket)})
	}
	if !slices.Contains(blob.Buckets, r.SizeBucket) {
		out = append(out, Finding{ID: S4BucketValid, UserID: u, Detail: fmt.Sprintf(
			"seq %d: size_bucket %d is not one of the seven rungs %v", r.Seq, r.SizeBucket, blob.Buckets)})
	}
	return out
}

func checkSealed(u uuid.UUID, r oplog.Row) []Finding {
	var re *blob.RefusalError
	if err := blob.LooksSealed(r.Blob); errors.As(err, &re) {
		return []Finding{{ID: S6Sealed, UserID: u, Detail: fmt.Sprintf(
			"seq %d: the blob does not look sealed (check %s failed)", r.Seq, re.Check)}}
	}
	return nil
}

func checkAAD(u uuid.UUID, r oplog.Row) []Finding {
	want := blob.Envelope{
		UserID: u, Stream: r.Stream, WriterID: r.WriterID, WriterCounter: r.WriterCounter,
	}
	got, err := blob.EmbeddedAAD(r.Blob)
	if err != nil {
		return []Finding{{ID: S3AADMatchesRow, UserID: u, Detail: fmt.Sprintf(
			"seq %d: the blob's framing is unreadable, so it carries no position at all", r.Seq)}}
	}
	if !bytes.Equal(got, want.AAD()) {
		return []Finding{{ID: S3AADMatchesRow, UserID: u, Detail: fmt.Sprintf(
			"seq %d: the blob was sealed for a different position than the row it occupies "+
				"(row says stream %q, writer %q, counter %d)", r.Seq, r.Stream, r.WriterID, r.WriterCounter)}}
	}
	return nil
}

func checkChain(u uuid.UUID, r oplog.Row, c *chain) []Finding {
	var out []Finding
	switch {
	case r.WriterCounter != c.wantCounter:
		out = append(out, Finding{ID: S2WriterChain, UserID: u, Detail: fmt.Sprintf(
			"seq %d: writer %q on the %s stream is at counter %d, but the chain expected %d",
			r.Seq, r.WriterID, r.Stream, r.WriterCounter, c.wantCounter)})
	case !bytes.Equal(r.PrevHash, c.prev[:]):
		out = append(out, Finding{ID: S2WriterChain, UserID: u, Detail: fmt.Sprintf(
			"seq %d: writer %q counter %d links to a prev_hash that is not the chain's head",
			r.Seq, r.WriterID, r.WriterCounter)})
	default:
		got := blob.Hash(c.prev, blob.Sealed{Bytes: r.Blob, SizeBucket: r.SizeBucket})
		if !bytes.Equal(r.BlobHash, got[:]) {
			out = append(out, Finding{ID: S2WriterChain, UserID: u, Detail: fmt.Sprintf(
				"seq %d: writer %q counter %d stores a blob_hash its own bytes do not produce",
				r.Seq, r.WriterID, r.WriterCounter)})
		}
	}
	c.wantCounter = r.WriterCounter + 1
	if len(r.BlobHash) == 32 {
		c.prev = [32]byte(r.BlobHash)
	} else {
		c.prev = blob.ZeroHash
	}
	return out
}
