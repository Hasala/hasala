package oplog

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

var bg = context.Background()

func (a *Appender) appendRaw(ctx context.Context, rows []Row) ([]int64, error) {
	return a.appendRows(ctx, rows, nil)
}

func insertUser(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	tx, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(bg)
	id := insertUserRow(t, tx)
	if err := EnsureSeqRow(bg, tx, id); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(bg); err != nil {
		t.Fatal(err)
	}
	return id
}

func insertUserWithoutSeqRow(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	tx, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(bg)
	id := insertUserRow(t, tx)
	if err := tx.Commit(bg); err != nil {
		t.Fatal(err)
	}
	return id
}

var testWriters = []string{"ios-00000000-0000-4000-8000-00000000000a", "ios-00000000-0000-4000-8000-00000000000b", "ios-00000000-0000-4000-8000-00000000007a", "ios-00000000-0000-4000-8000-000000000100", "ios-00000000-0000-4000-8000-000000000101", "ios-00000000-0000-4000-8000-000000000102", "ios-00000000-0000-4000-8000-000000000103", "ios-00000000-0000-4000-8000-000000000104",
	"ios-00000000-0000-4000-8000-000000000105", "ios-00000000-0000-4000-8000-000000000106", "ios-00000000-0000-4000-8000-000000000107", "ios-00000000-0000-4000-8000-000000000108", "ios-00000000-0000-4000-8000-000000000109"}

func insertUserRow(t *testing.T, tx pgx.Tx) uuid.UUID {
	t.Helper()
	sub := make([]byte, 32)
	if _, err := rand.Read(sub); err != nil {
		t.Fatal(err)
	}
	var id uuid.UUID
	if err := tx.QueryRow(bg,
		`INSERT INTO users (user_handle, created_at, email_norm, email_verified_at, display_name) VALUES ($1, now(), 'u-' || gen_random_uuid() || '@example.test', now(), 'Test User') RETURNING id`,
		sub).Scan(&id); err != nil {
		t.Fatal(err)
	}
	rnd := func(n int) []byte {
		b := make([]byte, n)
		if _, err := rand.Read(b); err != nil {
			t.Fatal(err)
		}
		return b
	}
	if _, err := tx.Exec(bg,
		`INSERT INTO account_keys (user_id, format_version, amk_commitment, authority_pubkey, recovery_pubkey,
		   recovery_wrap, phrase_box, current_epoch, created_at, updated_at)
		 VALUES ($1, 1, $2, $3, $4, $5, $6, 1, now(), now())`,
		id, rnd(32), rnd(32), rnd(32), append([]byte{1, 1}, rnd(125)...), append([]byte{1}, rnd(44)...)); err != nil {
		t.Fatal(err)
	}
	for _, w := range testWriters {
		if _, err := tx.Exec(bg, `INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at)
			VALUES ($1, $2, 'ed25519', $3, $4, now())`, id, w, []byte(testDWK(w).Public().(ed25519.PublicKey)), testDAK(t)); err != nil {
			t.Fatal(err)
		}
	}
	return id
}

func testDWK(writerID string) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte("oplogtest-dwk|" + writerID))
	return ed25519.NewKeyFromSeed(seed[:])
}

func testHeadSig(u uuid.UUID, writerID string, rows []Row) []byte {
	if len(rows) == 0 {
		return nil
	}
	last := rows[len(rows)-1]
	m, err := keyproto.HeadMessage(u, uint64(last.WriterCounter), last.BlobHash, writerID)
	if err != nil {
		return make([]byte, 64)
	}
	return ed25519.Sign(testDWK(writerID), m)
}

func testDAK(t *testing.T) []byte {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	out := []byte{4}
	out = append(out, k.X.FillBytes(make([]byte, 32))...)
	return append(out, k.Y.FillBytes(make([]byte, 32))...)
}

func sealRow(u uuid.UUID, writerID, stream string, counter int64, prev [32]byte) (Row, [32]byte, error) {
	env := blob.Envelope{UserID: u, Stream: stream, WriterID: writerID, WriterCounter: counter}
	body := fmt.Sprintf(`{"writer":%q,"stream":%q,"counter":%d}`, writerID, stream, counter)
	s, err := blobtest.Seal3(env, 1, blobtest.TestEpochKey, prev, []byte(body))
	if err != nil {
		return Row{}, [32]byte{}, err
	}
	h := blob.Hash(prev, s)
	return Row{
		UserID:        u,
		Stream:        stream,
		WriterID:      writerID,
		WriterCounter: counter,
		TypeFlag:      TypeFlagEdit,
		Blob:          s.Bytes,
		SizeBucket:    s.SizeBucket,
		BlobHash:      h[:],
		PrevHash:      prev[:],
	}, h, nil
}

func mustSeal(t *testing.T, u uuid.UUID, writerID, stream string, counter int64, prev [32]byte) (Row, [32]byte) {
	t.Helper()
	r, h, err := sealRow(u, writerID, stream, counter, prev)
	if err != nil {
		t.Fatal(err)
	}
	return r, h
}

func rowsFor(t *testing.T, u uuid.UUID, writerID, stream string, start int64, n int) []Row {
	t.Helper()
	prev := blob.ZeroHash
	out := make([]Row, 0, n)
	for i := 0; i < n; i++ {
		r, h := mustSeal(t, u, writerID, stream, start+int64(i), prev)
		prev = h
		out = append(out, r)
	}
	return out
}

func seqsOf(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) []int64 {
	t.Helper()
	rows, err := pool.Query(bg, `SELECT seq FROM op_log WHERE user_id=$1 ORDER BY seq`, u)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []int64
	for rows.Next() {
		var s int64
		if err := rows.Scan(&s); err != nil {
			t.Fatal(err)
		}
		got = append(got, s)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return got
}

func assertGapFree(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, want int) {
	t.Helper()
	got := seqsOf(t, pool, u)
	for i, s := range got {
		if s != int64(i+1) {
			t.Fatalf("gap at index %d: seq=%d (all seqs: %v)", i, s, got)
		}
	}
	if len(got) != want {
		t.Fatalf("want %d rows, got %d", want, len(got))
	}
}

func nextSeqOf(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) int64 {
	t.Helper()
	var n int64
	if err := pool.QueryRow(bg, `SELECT next_seq FROM oplog_seq WHERE user_id=$1`, u).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestAppendAssignsContiguousSeqs(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	seqs, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 3))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(seqs, []int64{1, 2, 3}) {
		t.Fatalf("got %v, want [1 2 3]", seqs)
	}

	seqs, err = a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 4, 2))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(seqs, []int64{4, 5}) {
		t.Fatalf("got %v, want [4 5]", seqs)
	}
	assertGapFree(t, pool, u, 5)
}

func TestConcurrentAppendsAreGapFreeAndCommitOrderMatchesSeqOrder(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	const writers, perWriter = 8, 25
	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			id := fmt.Sprintf("ios-00000000-0000-4000-8000-%012x", 0x100+w)
			prev := blob.ZeroHash
			for c := 1; c <= perWriter; c++ {
				r, h, err := sealRow(u, id, blob.StreamHot, int64(c), prev)
				if err != nil {
					t.Errorf("%s counter %d: seal: %v", id, c, err)
					return
				}
				prev = h
				if _, err := a.appendRaw(bg, []Row{r}); err != nil {
					t.Errorf("%s counter %d: append: %v", id, c, err)
					return
				}
			}
		}(w)
	}
	wg.Wait()

	assertGapFree(t, pool, u, writers*perWriter)
	max, err := a.MaxSeq(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if max != writers*perWriter {
		t.Fatalf("MaxSeq = %d, want %d", max, writers*perWriter)
	}
	if got := nextSeqOf(t, pool, u); got != writers*perWriter+1 {
		t.Fatalf("next_seq = %d, want %d", got, writers*perWriter+1)
	}
}

func TestConcurrentMultiRowAppendsAllocateContiguousBlocks(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	const writers, batches, perBatch = 6, 10, 3
	var mu sync.Mutex
	var blocks [][]int64
	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			id := fmt.Sprintf("ios-00000000-0000-4000-8000-%012x", 0x100+w)
			prev := blob.ZeroHash
			for b := 0; b < batches; b++ {
				batch := make([]Row, 0, perBatch)
				for i := 0; i < perBatch; i++ {
					counter := int64(b*perBatch + i + 1)
					r, h, err := sealRow(u, id, blob.StreamHot, counter, prev)
					if err != nil {
						t.Errorf("%s counter %d: seal: %v", id, counter, err)
						return
					}
					prev = h
					batch = append(batch, r)
				}
				got, err := a.appendRaw(bg, batch)
				if err != nil {
					t.Errorf("%s batch %d: append: %v", id, b, err)
					return
				}
				mu.Lock()
				blocks = append(blocks, got)
				mu.Unlock()
			}
		}(w)
	}
	wg.Wait()

	total := writers * batches * perBatch
	assertGapFree(t, pool, u, total)
	seen := make(map[int64]int, total)
	for _, blk := range blocks {
		if len(blk) != perBatch {
			t.Fatalf("block %v has %d seqs, want %d", blk, len(blk), perBatch)
		}
		for i, s := range blk {
			if s != blk[0]+int64(i) {
				t.Fatalf("block %v is not contiguous", blk)
			}
			seen[s]++
		}
	}
	if len(seen) != total {
		t.Fatalf("the returned blocks cover %d distinct seqs, want %d", len(seen), total)
	}
	for s := int64(1); s <= int64(total); s++ {
		if seen[s] != 1 {
			t.Fatalf("seq %d was returned by %d blocks, want exactly 1", s, seen[s])
		}
	}
}

func TestNoTransientGapIsEverVisibleToAConcurrentReader(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	const writers, perWriter = 6, 20
	total := writers * perWriter

	done := make(chan struct{})
	type report struct {
		observations, partials int
		hole                   string
	}
	var rep report
	var readerWG sync.WaitGroup
	readerWG.Add(1)
	go func() {
		defer readerWG.Done()
		for {
			select {
			case <-done:
				return
			default:
			}
			rows, err := pool.Query(bg, `SELECT seq FROM op_log WHERE user_id=$1 ORDER BY seq`, u)
			if err != nil {
				rep.hole = fmt.Sprintf("query: %v", err)
				return
			}
			var got []int64
			for rows.Next() {
				var s int64
				if err := rows.Scan(&s); err != nil {
					rows.Close()
					rep.hole = fmt.Sprintf("scan: %v", err)
					return
				}
				got = append(got, s)
			}
			rows.Close()
			rep.observations++
			if len(got) > 0 && len(got) < total {
				rep.partials++
			}
			for i, s := range got {
				if s != int64(i+1) {
					rep.hole = fmt.Sprintf("reader saw a hole at index %d: seq=%d (all: %v)", i, s, got)
					return
				}
			}
		}
	}()

	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			id := fmt.Sprintf("ios-00000000-0000-4000-8000-%012x", 0x100+w)
			prev := blob.ZeroHash
			for c := 1; c <= perWriter; c++ {
				r, h, err := sealRow(u, id, blob.StreamHot, int64(c), prev)
				if err != nil {
					t.Errorf("%s counter %d: seal: %v", id, c, err)
					return
				}
				prev = h
				if _, err := a.appendRaw(bg, []Row{r}); err != nil {
					t.Errorf("%s counter %d: append: %v", id, c, err)
					return
				}
			}
		}(w)
	}
	wg.Wait()
	close(done)
	readerWG.Wait()

	if rep.hole != "" {
		t.Fatal(rep.hole)
	}
	if rep.partials == 0 {
		t.Fatalf("reader took %d observations but never caught a partial state; the test proved nothing", rep.observations)
	}
	t.Logf("reader took %d observations, %d of them partial, and never saw a hole", rep.observations, rep.partials)
	assertGapFree(t, pool, u, total)
}

func TestARolledBackAppendLeavesNoGap(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	first := rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 1)
	if _, err := a.appendRaw(bg, first); err != nil {
		t.Fatal(err)
	}

	if _, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 1)); err == nil {
		t.Fatal("expected a duplicate (writer_id, stream, writer_counter) to be rejected")
	}

	if got := nextSeqOf(t, pool, u); got != 2 {
		t.Fatalf("the rolled-back append burned a seq: next_seq = %d, want 2", got)
	}
	seqs, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 2, 1))
	if err != nil {
		t.Fatal(err)
	}
	if seqs[0] != 2 {
		t.Fatalf("next append got seq %d, want 2 — the failed append left a hole", seqs[0])
	}
	assertGapFree(t, pool, u, 2)
}

func TestAFailedBatchAppendsNothingAndBurnsNoSeq(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	if _, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 2)); err != nil {
		t.Fatal(err)
	}
	bad := rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 3, 3)
	bad[2], _ = mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash)
	if _, err := a.appendRaw(bg, bad); err == nil {
		t.Fatal("expected the colliding batch to fail")
	}
	assertGapFree(t, pool, u, 2)
	if got := nextSeqOf(t, pool, u); got != 3 {
		t.Fatalf("next_seq = %d, want 3 — the failed batch burned seqs", got)
	}
}

func TestOneCallMaySpanWritersAndCountersAreIndependent(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	first, _ := mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash)
	second, _ := mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000b", blob.StreamHot, 1, blob.ZeroHash)
	seqs, err := a.appendRaw(bg, []Row{first, second})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(seqs, []int64{1, 2}) {
		t.Fatalf("got %v, want [1 2]", seqs)
	}
}

func TestSeqRowExistsBeforeTheFirstAppend(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	if got := nextSeqOf(t, pool, u); got != 1 {
		t.Fatalf("next_seq = %d before any append, want 1", got)
	}
}

func TestEnsureSeqRowIsIdempotent(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	if _, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 2)); err != nil {
		t.Fatal(err)
	}
	tx, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(bg)
	if err := EnsureSeqRow(bg, tx, u); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(bg); err != nil {
		t.Fatal(err)
	}
	if got := nextSeqOf(t, pool, u); got != 3 {
		t.Fatalf("next_seq = %d after a repeat EnsureSeqRow, want 3", got)
	}
}

func TestAppendCreatesTheSeqRowWhenItIsMissing(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUserWithoutSeqRow(t, pool)
	a := &Appender{Pool: pool}
	seqs, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 2))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(seqs, []int64{1, 2}) {
		t.Fatalf("got %v, want [1 2]", seqs)
	}
}

func TestSeqIsPerUser(t *testing.T) {
	pool := pgtest.New(t)
	a := &Appender{Pool: pool}
	u1, u2 := insertUser(t, pool), insertUser(t, pool)
	for i := int64(1); i <= 3; i++ {
		for _, u := range []uuid.UUID{u1, u2} {
			seqs, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, i, 1))
			if err != nil {
				t.Fatal(err)
			}
			if seqs[0] != i {
				t.Fatalf("user %s got seq %d, want %d", u, seqs[0], i)
			}
		}
	}
	assertGapFree(t, pool, u1, 3)
	assertGapFree(t, pool, u2, 3)
}

func TestAppendRejectsMixedUsers(t *testing.T) {
	pool := pgtest.New(t)
	u1, u2 := insertUser(t, pool), insertUser(t, pool)
	a := &Appender{Pool: pool}
	mixed := append(rowsFor(t, u1, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 1), rowsFor(t, u2, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 1)...)
	if _, err := a.appendRaw(bg, mixed); err == nil {
		t.Fatal("expected two user_ids in one call to be rejected")
	}
	if got := len(seqsOf(t, pool, u1)); got != 0 {
		t.Fatalf("rejected call still wrote %d rows", got)
	}
}

func TestAppendRejectsAnUnknownUser(t *testing.T) {
	pool := pgtest.New(t)
	a := &Appender{Pool: pool}
	ghost := uuid.New()
	if _, err := a.appendRaw(bg, rowsFor(t, ghost, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 1)); err == nil {
		t.Fatal("expected an append for a nonexistent user to be rejected")
	}
}

func TestAppendOfNothingIsANoOp(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	seqs, err := a.appendRaw(bg, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(seqs) != 0 {
		t.Fatalf("got %v, want no seqs", seqs)
	}
	if got := nextSeqOf(t, pool, u); got != 1 {
		t.Fatalf("next_seq = %d, want 1 — an empty append consumed a seq", got)
	}
}

func TestAppendRejectsMalformedRows(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	good, _ := mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash)

	mutate := func(f func(r *Row)) []Row {
		r := good
		r.Blob = append([]byte(nil), good.Blob...)
		r.BlobHash = append([]byte(nil), good.BlobHash...)
		r.PrevHash = append([]byte(nil), good.PrevHash...)
		f(&r)
		return []Row{r}
	}

	cases := []struct {
		name string
		rows []Row
	}{
		{"zero user", mutate(func(r *Row) { r.UserID = uuid.Nil })},
		{"unknown stream", mutate(func(r *Row) { r.Stream = "hott" })},
		{"empty stream", mutate(func(r *Row) { r.Stream = "" })},
		{"empty writer", mutate(func(r *Row) { r.WriterID = "" })},
		{"zero counter", mutate(func(r *Row) { r.WriterCounter = 0 })},
		{"negative counter", mutate(func(r *Row) { r.WriterCounter = -1 })},
		{"unknown type flag", mutate(func(r *Row) { r.TypeFlag = "ingested" })},
		{"empty blob", mutate(func(r *Row) { r.Blob = nil })},
		{"blob is not a bucket", mutate(func(r *Row) { r.Blob = r.Blob[:len(r.Blob)-1] })},
		{"size bucket disagrees with blob", mutate(func(r *Row) { r.SizeBucket = 4 << 10 })},
		{"short blob hash", mutate(func(r *Row) { r.BlobHash = r.BlobHash[:31] })},
		{"short prev hash", mutate(func(r *Row) { r.PrevHash = r.PrevHash[:31] })},
		{"caller-assigned seq", mutate(func(r *Row) { r.Seq = 7 })},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := a.appendRaw(bg, c.rows); err == nil {
				t.Fatal("expected an error")
			}
		})
	}
	if got := nextSeqOf(t, pool, u); got != 1 {
		t.Fatalf("next_seq = %d after only-invalid appends, want 1", got)
	}
	assertGapFree(t, pool, u, 0)
}

func TestMaxSeq(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	got, err := a.MaxSeq(bg, u)
	if err != nil {
		t.Fatal(err)
	}
	if got != 0 {
		t.Fatalf("MaxSeq = %d before any append, want 0", got)
	}
	if _, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 4)); err != nil {
		t.Fatal(err)
	}
	if got, err = a.MaxSeq(bg, u); err != nil {
		t.Fatal(err)
	} else if got != 4 {
		t.Fatalf("MaxSeq = %d, want 4", got)
	}
}

func TestStoredRowRoundTripsAndTheBlobStillOpens(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	before := time.Now().Add(-time.Second)
	in, _ := mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash)
	if _, err := a.appendRaw(bg, []Row{in}); err != nil {
		t.Fatal(err)
	}

	var out Row
	err := pool.QueryRow(bg, `SELECT user_id, seq, stream, writer_id, writer_counter,
		type_flag, blob, size_bucket, blob_hash, prev_hash, created_at
		FROM op_log WHERE user_id=$1 AND seq=1`, u).Scan(
		&out.UserID, &out.Seq, &out.Stream, &out.WriterID, &out.WriterCounter,
		&out.TypeFlag, &out.Blob, &out.SizeBucket, &out.BlobHash, &out.PrevHash, &out.CreatedAt)
	if err != nil {
		t.Fatal(err)
	}
	if out.Seq != 1 || out.Stream != blob.StreamHot || out.WriterID != "ios-00000000-0000-4000-8000-00000000000a" ||
		out.WriterCounter != 1 || out.TypeFlag != TypeFlagEdit || out.SizeBucket != in.SizeBucket {
		t.Fatalf("row round-tripped wrong: %+v", out)
	}
	if out.CreatedAt.Before(before) || out.CreatedAt.After(time.Now().Add(time.Minute)) {
		t.Fatalf("created_at = %v, want ~now", out.CreatedAt)
	}
	plain, err := blobtest.Open3(blob.Envelope{
		UserID: out.UserID, Stream: out.Stream, WriterID: out.WriterID, WriterCounter: out.WriterCounter,
	}, blobtest.TestEpochKey, [32]byte(out.PrevHash), out.Blob)
	if err != nil {
		t.Fatalf("stored blob does not open: %v", err)
	}
	if string(plain) != `{"writer":"ios-00000000-0000-4000-8000-00000000000a","stream":"hot","counter":1}` {
		t.Fatalf("plaintext = %s", plain)
	}
}

func TestCallerSuppliedCreatedAtIsHonoured(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	want := time.Date(2026, 3, 4, 5, 6, 7, 0, time.UTC)
	r, _ := mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash)
	r.CreatedAt = want
	if _, err := a.appendRaw(bg, []Row{r}); err != nil {
		t.Fatal(err)
	}
	var got time.Time
	if err := pool.QueryRow(bg, `SELECT created_at FROM op_log WHERE user_id=$1 AND seq=1`, u).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if !got.Equal(want) {
		t.Fatalf("created_at = %v, want %v", got, want)
	}
}

func TestDatabaseConstraintsBackstopTheGoValidation(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	if _, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 1)); err != nil {
		t.Fatal(err)
	}

	ins := `INSERT INTO op_log (user_id, seq, stream, writer_id, writer_counter,
		type_flag, blob, size_bucket, blob_hash, prev_hash)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`

	base, _ := mustSeal(t, u, "ios-00000000-0000-4000-8000-00000000000b", blob.StreamHot, 1, blob.ZeroHash)
	type row struct {
		seq                  int64
		stream, writer, flag string
		counter              int64
		blb, bhash, phash    []byte
		bucket               int
	}
	valid := func() row {
		return row{seq: 2, stream: blob.StreamHot, writer: "ios-00000000-0000-4000-8000-00000000000b", flag: TypeFlagEdit,
			counter: 1, blb: base.Blob, bhash: base.BlobHash, phash: base.PrevHash, bucket: base.SizeBucket}
	}
	exec := func(r row) error {
		_, err := pool.Exec(bg, ins, u, r.seq, r.stream, r.writer, r.counter, r.flag,
			r.blb, r.bucket, r.bhash, r.phash)
		return err
	}

	cases := []struct {
		name       string
		mutate     func(*row)
		constraint string
	}{
		{"duplicate seq", func(r *row) { r.seq = 1 }, "op_log_pkey"},
		{"unknown stream", func(r *row) { r.stream = "warm" }, "op_log_aad_matches_position"},
		{"unknown type flag", func(r *row) { r.flag = "ingest" }, "op_log_type_flag_is_edit"},
		{"blob shorter than its bucket", func(r *row) { r.blb = r.blb[:len(r.blb)-1] },
			"op_log_blob_fills_bucket"},
		{"size_bucket disagrees with the blob", func(r *row) { r.bucket = 4 << 10 },
			"op_log_blob_fills_bucket"},
		{"blob hash is not 32 bytes", func(r *row) { r.bhash = r.bhash[:31] },
			"op_log_hashes_are_sha256"},
		{"prev hash is not 32 bytes", func(r *row) { r.phash = append(r.phash, 0) },
			"op_log_hashes_are_sha256"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := valid()
			c.mutate(&r)
			err := exec(r)
			if err == nil {
				t.Fatal("expected the database to reject this row")
			}
			var pgErr *pgconn.PgError
			if !errors.As(err, &pgErr) {
				t.Fatalf("want a PgError, got %T: %v", err, err)
			}
			if pgErr.ConstraintName != c.constraint {
				t.Fatalf("rejected by %q, want %q: %v", pgErr.ConstraintName, c.constraint, err)
			}
		})
	}

	if err := exec(valid()); err != nil {
		t.Fatalf("the baseline row must be accepted: %v", err)
	}
	r := valid()
	r.seq = 3
	if _, name := pgErrConstraint(exec(r)); name != "op_log_position_uniq" {
		t.Fatalf("a second row at (dev-b, hot, 1) was not refused by op_log_position_uniq")
	}
	stray, _ := mustSeal(t, u, "ios-00000000-0000-4000-8000-000000000079", blob.StreamHot, 1, blob.ZeroHash)
	r = valid()
	r.seq, r.writer = 3, "ios-00000000-0000-4000-8000-000000000079"
	r.blb, r.bhash, r.phash, r.bucket = stray.Blob, stray.BlobHash, stray.PrevHash, stray.SizeBucket
	if _, name := pgErrConstraint(exec(r)); name != "op_log_writer_fk" {
		t.Fatalf("a row for an unenrolled writer was not refused by op_log_writer_fk")
	}

}

func pgErrConstraint(err error) (string, string) {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code, pgErr.ConstraintName
	}
	return "", ""
}

func TestAnAbandonedTransactionReturnsItsSeqs(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	tx, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	seqs, err := a.appendTx(bg, tx, u, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 3), nil)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(seqs, []int64{1, 2, 3}) {
		t.Fatalf("in-transaction seqs = %v, want [1 2 3]", seqs)
	}
	if err := tx.Rollback(bg); err != nil {
		t.Fatal(err)
	}

	if got := nextSeqOf(t, pool, u); got != 1 {
		t.Fatalf("next_seq = %d after a rolled-back allocation, want 1", got)
	}
	got, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 1))
	if err != nil {
		t.Fatal(err)
	}
	if got[0] != 1 {
		t.Fatalf("the next append got seq %d, want 1 — the abandoned transaction burned seqs", got[0])
	}
	assertGapFree(t, pool, u, 1)
}

func TestACorruptedCounterFailsLoudlyRatherThanOverwritingHistory(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	if _, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, 2)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bg, `DELETE FROM oplog_seq WHERE user_id=$1`, u); err != nil {
		t.Fatal(err)
	}
	if _, err := a.appendRaw(bg, rowsFor(t, u, "ios-00000000-0000-4000-8000-00000000000b", blob.StreamHot, 1, 1)); err == nil {
		t.Fatal("a reset counter must not be allowed to reuse a committed seq")
	}
	assertGapFree(t, pool, u, 2)
}

func TestAppendPinsReadCommittedRegardlessOfTheDatabaseDefault(t *testing.T) {
	pool, owner := pgtest.NewWithOwner(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	var dbName string
	if err := pool.QueryRow(bg, `SELECT current_database()`).Scan(&dbName); err != nil {
		t.Fatal(err)
	}
	if _, err := owner.Exec(bg,
		`ALTER DATABASE `+dbName+` SET default_transaction_isolation = 'repeatable read'`); err != nil {
		t.Fatal(err)
	}
	pool.Reset()

	tx, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	var iso string
	if err := tx.QueryRow(bg, `SHOW transaction_isolation`).Scan(&iso); err != nil {
		t.Fatal(err)
	}
	_ = tx.Rollback(bg)
	if iso != "repeatable read" {
		t.Fatalf("unpinned transaction_isolation = %q; the test premise does not hold", iso)
	}

	const writers, perWriter = 6, 10
	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			id := fmt.Sprintf("ios-00000000-0000-4000-8000-%012x", 0x100+w)
			prev := blob.ZeroHash
			for c := 1; c <= perWriter; c++ {
				r, h, err := sealRow(u, id, blob.StreamHot, int64(c), prev)
				if err != nil {
					t.Errorf("%s counter %d: seal: %v", id, c, err)
					return
				}
				prev = h
				if _, err := a.appendRaw(bg, []Row{r}); err != nil {
					t.Errorf("%s counter %d: append: %v", id, c, err)
					return
				}
			}
		}(w)
	}
	wg.Wait()
	assertGapFree(t, pool, u, writers*perWriter)
}
