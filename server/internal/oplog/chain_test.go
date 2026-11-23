package oplog

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
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
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func sealBody(t *testing.T, u uuid.UUID, writerID, stream string, counter int64, prev [32]byte, body string) (Row, [32]byte) {
	t.Helper()
	env := blob.Envelope{UserID: u, Stream: stream, WriterID: writerID, WriterCounter: counter}
	s, err := blobtest.Seal3(env, 1, blobtest.TestEpochKey, prev, []byte(body))
	if err != nil {
		t.Fatal(err)
	}
	h := blob.Hash(prev, s)
	flag := TypeFlagEdit
	return Row{
		UserID:        u,
		Stream:        stream,
		WriterID:      writerID,
		WriterCounter: counter,
		TypeFlag:      flag,
		Blob:          s.Bytes,
		SizeBucket:    s.SizeBucket,
		BlobHash:      h[:],
		PrevHash:      prev[:],
	}, h
}

func chainFrom(t *testing.T, u uuid.UUID, writerID, stream string, startCounter int64, prev [32]byte, n int) ([]Row, [32]byte) {
	t.Helper()
	out := make([]Row, 0, n)
	for i := 0; i < n; i++ {
		c := startCounter + int64(i)
		r, h := sealBody(t, u, writerID, stream, c, prev, fmt.Sprintf(`{"w":%q,"s":%q,"c":%d}`, writerID, stream, c))
		prev = h
		out = append(out, r)
	}
	return out, prev
}

func warmPool(t *testing.T, pool *pgxpool.Pool, n int) {
	t.Helper()
	conns := make([]*pgxpool.Conn, 0, n)
	for i := 0; i < n; i++ {
		c, err := pool.Acquire(bg)
		if err != nil {
			t.Fatalf("warm pool: %v", err)
		}
		if err := c.Ping(bg); err != nil {
			t.Fatalf("warm pool ping: %v", err)
		}
		conns = append(conns, c)
	}
	for _, c := range conns {
		c.Release()
	}
}

func assertChainBreak(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("want ErrChainBreak, got nil")
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == uniqueViolation {
		t.Fatalf("the database rejected this, not the chain check: %v", err)
	}
	if !errors.Is(err, ErrChainBreak) {
		t.Fatalf("want ErrChainBreak, got %T: %v", err, err)
	}
}

func countersOf(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, writerID, stream string) []int64 {
	t.Helper()
	rows, err := pool.Query(bg,
		`SELECT writer_counter FROM op_log WHERE user_id=$1 AND writer_id=$2 AND stream=$3 ORDER BY seq`,
		u, writerID, stream)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []int64
	for rows.Next() {
		var c int64
		if err := rows.Scan(&c); err != nil {
			t.Fatal(err)
		}
		got = append(got, c)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return got
}

func storedChain(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, writerID, stream string) []Row {
	t.Helper()
	rows, err := pool.Query(bg,
		`SELECT seq, stream, writer_id, writer_counter, blob, size_bucket, blob_hash, prev_hash
		   FROM op_log WHERE user_id=$1 AND writer_id=$2 AND stream=$3 ORDER BY writer_counter`,
		u, writerID, stream)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []Row
	for rows.Next() {
		r := Row{UserID: u}
		if err := rows.Scan(&r.Seq, &r.Stream, &r.WriterID, &r.WriterCounter,
			&r.Blob, &r.SizeBucket, &r.BlobHash, &r.PrevHash); err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestChainRuleIsPinnedByAGoldenVector(t *testing.T) {
	first := blob.Hash(blob.ZeroHash, blob.Sealed{Bytes: bytesOf(0xab, 1024), SizeBucket: 1024})
	const wantFirst = "b972e78fb27a0866f41fd72ab4687e18aed94a66c8e32314ac654e8247c3e3d3"
	if got := hex.EncodeToString(first[:]); got != wantFirst {
		t.Fatalf("chain hash 1 = %s, want %s", got, wantFirst)
	}
	second := blob.Hash(first, blob.Sealed{Bytes: bytesOf(0xcd, 1024), SizeBucket: 1024})
	const wantSecond = "1eb123521be8de11640db812996ae32d973f6ed53d3eff1f3e080fa377761eb4"
	if got := hex.EncodeToString(second[:]); got != wantSecond {
		t.Fatalf("chain hash 2 = %s, want %s", got, wantSecond)
	}
	if blob.ZeroHash != ([32]byte{}) {
		t.Fatal("ZeroHash is not 32 zero bytes")
	}
	direct := sha256.Sum256(append(make([]byte, 32), bytesOf(0xab, 1024)...))
	if direct != first {
		t.Fatal("blob.Hash is not SHA256(prev || bytes)")
	}
}

func bytesOf(b byte, n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = b
	}
	return out
}

func TestVerifyChainAcceptsAContiguousRun(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 5)
	if err := VerifyChain(rows, 0, blob.ZeroHash); err != nil {
		t.Fatalf("a well-formed chain must verify: %v", err)
	}
	var prev [32]byte
	copy(prev[:], rows[1].BlobHash)
	if err := VerifyChain(rows[2:], 2, prev); err != nil {
		t.Fatalf("a suffix must verify against its own head: %v", err)
	}
}

func TestFirstBlobOfAChainLinksToZeroHash(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 1)
	if err := VerifyChain(rows, 0, blob.ZeroHash); err != nil {
		t.Fatalf("counter 1 chained from ZeroHash must verify: %v", err)
	}
	var junk [32]byte
	junk[0] = 1
	forged, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, junk, 1)
	if err := VerifyChain(forged, 0, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("counter 1 with a non-zero prev must break: %v", err)
	}
}

func TestVerifyChainDetectsADroppedOp(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 5)
	dropped := append(append([]Row{}, rows[:2]...), rows[3:]...)
	if err := VerifyChain(dropped, 0, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("a dropped op must break the chain, got %v", err)
	}
}

func TestVerifyChainDetectsAReorderedOp(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 5)
	swapped := append([]Row{}, rows...)
	swapped[2], swapped[3] = swapped[3], swapped[2]
	if err := VerifyChain(swapped, 0, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("a reordered op must break the chain, got %v", err)
	}
}

func TestVerifyChainDetectsATamperedBlob(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 3)
	rows[1].Blob = append([]byte(nil), rows[1].Blob...)
	rows[1].Blob[600] ^= 0xff
	if err := VerifyChain(rows, 0, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("a tampered blob must break the chain, got %v", err)
	}
}

func TestVerifyChainDetectsAForgedPrevHash(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 3)
	rows[2].PrevHash = bytesOf(0x11, 32)
	if err := VerifyChain(rows, 0, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("a forged prev_hash must break the chain, got %v", err)
	}
}

func TestVerifyChainDetectsAChainThatDoesNotContinueTheHead(t *testing.T) {
	u := uuid.New()
	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 4, blob.ZeroHash, 2)
	if err := VerifyChain(rows, 2, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("counter 4 after head 2 must break, got %v", err)
	}
}

func TestHeadOfAnUnusedChainIsZero(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	c, h, err := a.Head(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot)
	if err != nil {
		t.Fatal(err)
	}
	if c != 0 || h != blob.ZeroHash {
		t.Fatalf("Head = (%d, %x), want (0, zero)", c, h)
	}
}

func TestHeadAdvancesWithEveryAppend(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	rows, want := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 3)
	if _, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows)); err != nil {
		t.Fatal(err)
	}
	c, h, err := a.Head(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot)
	if err != nil {
		t.Fatal(err)
	}
	if c != 3 || h != want {
		t.Fatalf("Head = (%d, %x), want (3, %x)", c, h, want)
	}
	if c, _, err := a.Head(bg, u, "ios-00000000-0000-4000-8000-00000000000b", blob.StreamHot); err != nil || c != 0 {
		t.Fatalf("dev-b head = (%d, %v), want (0, nil)", c, err)
	}
}

func TestClientAppendRejectsCounterGap(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, head := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 2)
	if _, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows)); err != nil {
		t.Fatal(err)
	}
	gapped, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 4, head, 1)
	_, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, gapped, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", gapped))
	assertChainBreak(t, err)

	assertGapFree(t, pool, u, 2)
	if got := nextSeqOf(t, pool, u); got != 3 {
		t.Fatalf("next_seq = %d after a rejected append, want 3", got)
	}
}

func TestClientAppendRejectsForgedPrevHash(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 1)
	if _, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows)); err != nil {
		t.Fatal(err)
	}
	var forged [32]byte
	forged[3] = 0x99
	next, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 2, forged, 1)
	_, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, next, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", next))
	assertChainBreak(t, err)
	assertGapFree(t, pool, u, 1)
}

func TestClientAppendRejectsRecomputedHashMismatch(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 1)
	rows[0].BlobHash = bytesOf(0x42, 32)
	_, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows))
	assertChainBreak(t, err)
	assertGapFree(t, pool, u, 0)
	if got := nextSeqOf(t, pool, u); got != 1 {
		t.Fatalf("next_seq = %d, want 1 — a rejected append burned a seq", got)
	}
}

func TestChainBreakRollsBackTheWholeBatch(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 3)
	rows[2].PrevHash = bytesOf(0x7e, 32)
	_, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows))
	assertChainBreak(t, err)

	assertGapFree(t, pool, u, 0)
	if got := nextSeqOf(t, pool, u); got != 1 {
		t.Fatalf("next_seq = %d, want 1 — the rejected batch burned seqs", got)
	}
}

func TestClientAppendRejectsRowsThatDisagreeWithTheCall(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 1)
	if _, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000b", blob.StreamHot, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000b", rows)); err == nil {
		t.Fatal("a row naming another writer must be rejected, not silently rewritten")
	}
	if _, err := a.AppendClient(bg, uuid.New(), "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, testHeadSig(uuid.New(), "ios-00000000-0000-4000-8000-00000000000a", rows)); err == nil {
		t.Fatal("a row naming another user must be rejected")
	}
	assertGapFree(t, pool, u, 0)
}

func TestResendingACommittedBatchReturnsItsSeqsInsteadOfFailing(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 3)
	first, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows))
	if err != nil {
		t.Fatal(err)
	}
	again, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows))
	if err != nil {
		t.Fatalf("a resend of an already-applied batch must not fail: %v", err)
	}
	if !reflect.DeepEqual(first, again) {
		t.Fatalf("resend returned %v, want the original %v", again, first)
	}
	assertGapFree(t, pool, u, 3)
	if got := nextSeqOf(t, pool, u); got != 4 {
		t.Fatalf("next_seq = %d, want 4 — the resend burned a seq", got)
	}
	prefix, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows[:2], testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows[:2]))
	if err != nil {
		t.Fatalf("a resend of an applied prefix must not fail: %v", err)
	}
	if !reflect.DeepEqual(prefix, first[:2]) {
		t.Fatalf("prefix resend returned %v, want %v", prefix, first[:2])
	}
}

func TestResendingDifferentBytesAtAnAppliedCounterIsAChainBreak(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 1)
	if _, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows)); err != nil {
		t.Fatal(err)
	}
	other, _ := sealBody(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, `{"forked":true}`)
	_, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, []Row{other}, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", []Row{other}))
	assertChainBreak(t, err)
	assertGapFree(t, pool, u, 1)
}

func TestAPartiallyAppliedResendIsRejectedWithoutClaimingAChainBreak(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 3)
	if _, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows[:2], testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows[:2])); err != nil {
		t.Fatal(err)
	}
	_, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows[1:], testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows[1:]))
	if err == nil {
		t.Fatal("a partially-applied batch must be rejected")
	}
	if errors.Is(err, ErrChainBreak) {
		t.Fatalf("a partial resend must not be reported as a chain break: %v", err)
	}
	assertGapFree(t, pool, u, 2)
	if _, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows[2:], testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows[2:])); err != nil {
		t.Fatalf("the suffix must be appendable: %v", err)
	}
	assertGapFree(t, pool, u, 3)
}

func TestTheChainCheckRunsAfterTheCounterLockIsTaken(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 3)
	var seen int64
	prepare := func(ctx context.Context, tx pgx.Tx, rows []Row) error {
		return tx.QueryRow(ctx, `SELECT next_seq FROM oplog_seq WHERE user_id=$1`, u).Scan(&seen)
	}
	if _, err := a.appendRows(bg, rows, prepare); err != nil {
		t.Fatal(err)
	}
	if want := int64(1 + len(rows)); seen != want {
		t.Fatalf("the chain check saw next_seq=%d, want %d: allocSeq has NOT taken the counter lock "+
			"before the chain head is read, so two concurrent uploads from one writer can both "+
			"observe the same head and race for the same counter", seen, want)
	}
}

func TestAnAppendQueuedBehindAnotherSeesTheCommittedHead(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	warmPool(t, pool, 4)

	first, h1 := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 1)
	if _, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, first, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", first)); err != nil {
		t.Fatal(err)
	}

	tx, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	winner, _ := sealBody(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 2, h1, `{"winner":true}`)
	if _, err := a.appendTx(bg, tx, u, []Row{winner}, nil); err != nil {
		t.Fatal(err)
	}

	racer, _ := sealBody(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 2, h1, `{"racer":true}`)
	done := make(chan error, 1)
	go func() {
		_, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, []Row{racer}, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", []Row{racer}))
		done <- err
	}()

	waitForLockWaiter(t, pool)
	if err := tx.Commit(bg); err != nil {
		t.Fatal(err)
	}

	select {
	case err := <-done:
		assertChainBreak(t, err)
	case <-time.After(30 * time.Second):
		t.Fatal("the racing append never returned")
	}
	assertGapFree(t, pool, u, 2)
	if got := countersOf(t, pool, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot); !reflect.DeepEqual(got, []int64{1, 2}) {
		t.Fatalf("counters = %v, want [1 2]", got)
	}
}

func waitForLockWaiter(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		var n int
		if err := pool.QueryRow(bg,
			`SELECT count(*) FROM pg_stat_activity
			  WHERE datname = current_database() AND wait_event_type = 'Lock'`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n > 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("no backend ever blocked on the counter lock; the test premise does not hold")
}

func TestConcurrentDoubleAppendFromOneWriterIsACleanChainBreak(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	warmPool(t, pool, 4)

	const rounds = 25
	counter, head := int64(0), blob.ZeroHash
	for round := 0; round < rounds; round++ {
		bodies := [2]string{fmt.Sprintf(`{"a":%d}`, round), fmt.Sprintf(`{"b":%d}`, round)}
		var racers [2][]Row
		for i, body := range bodies {
			r, _ := sealBody(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, counter+1, head, body)
			racers[i] = []Row{r}
		}
		var (
			wg    sync.WaitGroup
			start = make(chan struct{})
			errs  [2]error
		)
		for i := range racers {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				<-start
				_, errs[i] = a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, racers[i], testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", racers[i]))
			}(i)
		}
		close(start)
		wg.Wait()

		wins := 0
		for i, err := range errs {
			if err == nil {
				wins++
				continue
			}
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == uniqueViolation {
				t.Fatalf("round %d racer %d: the database rejected the append instead of the chain check: %v", round, i, err)
			}
			if !errors.Is(err, ErrChainBreak) {
				t.Fatalf("round %d racer %d: want ErrChainBreak, got %T: %v", round, i, err, err)
			}
		}
		if wins != 1 {
			t.Fatalf("round %d: %d of 2 racers won, want exactly 1 (errs: %v)", round, wins, errs)
		}
		var err error
		if counter, head, err = a.Head(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot); err != nil {
			t.Fatal(err)
		}
		if counter != int64(round+1) {
			t.Fatalf("round %d: head counter = %d, want %d", round, counter, round+1)
		}
	}
	assertGapFree(t, pool, u, rounds)
}

func TestUniqueViolationOnAPositionIsRecognised(t *testing.T) {
	dup := &pgconn.PgError{Code: uniqueViolation, ConstraintName: positionConstraint}
	if !isPositionTaken(fmt.Errorf("wrapped: %w", dup)) {
		t.Fatal("a 23505 on the (writer, stream, counter) key must be recognised")
	}
	other := &pgconn.PgError{Code: uniqueViolation, ConstraintName: "op_log_pkey"}
	if isPositionTaken(other) {
		t.Fatal("a 23505 on the seq primary key is a different failure and must not be translated")
	}
	if isPositionTaken(errors.New("boom")) {
		t.Fatal("a non-pg error must not be translated")
	}
}

func TestAppliedLookupResolvesSeqsAndSpotsAFork(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 2)
	seqs, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows))
	if err != nil {
		t.Fatal(err)
	}
	got, err := appliedSeqs(bg, pool, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows)
	if err != nil {
		t.Fatalf("identical rows must resolve to their seqs: %v", err)
	}
	if !reflect.DeepEqual(got, seqs) {
		t.Fatalf("appliedSeqs = %v, want %v", got, seqs)
	}

	forked := append([]Row(nil), rows...)
	other, _ := sealBody(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 2, blob.ZeroHash, `{"forked":true}`)
	forked[1] = other
	if _, err := appliedSeqs(bg, pool, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, forked); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("different bytes at an applied counter must be a chain break, got %v", err)
	}

	missing, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 5, blob.ZeroHash, 1)
	_, err = appliedSeqs(bg, pool, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, missing)
	if err == nil {
		t.Fatal("a counter that was never stored must not resolve")
	}
	if errors.Is(err, ErrChainBreak) {
		t.Fatalf("an unstored counter is not a chain break: %v", err)
	}
}

func TestAppendClientRejectsABlobSealedForAnotherPosition(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rechain := func(r Row) Row {
		r.WriterCounter = 1
		r.PrevHash = blob.ZeroHash[:]
		h := blob.Hash(blob.ZeroHash, blob.Sealed{Bytes: r.Blob, SizeBucket: r.SizeBucket})
		r.BlobHash = h[:]
		return r
	}

	movedCounter, _ := sealBody(t, u, "ios-00000000-0000-4000-8000-000000000101", blob.StreamHot, 7, blob.ZeroHash, `{"moved":"counter"}`)
	movedCounter = rechain(movedCounter)

	movedUser, _ := sealBody(t, uuid.New(), "ios-00000000-0000-4000-8000-000000000102", blob.StreamHot, 1, blob.ZeroHash, `{"moved":"user"}`)
	movedUser.UserID = u

	movedWriter, _ := sealBody(t, u, "ios-00000000-0000-4000-8000-00000000007a", blob.StreamHot, 1, blob.ZeroHash, `{"moved":"writer"}`)
	movedWriter.WriterID = "ios-00000000-0000-4000-8000-000000000104"

	cases := []struct {
		name, writer string
		row          Row
	}{
		{"sealed at counter 7, stored at counter 1", "ios-00000000-0000-4000-8000-000000000101", movedCounter},
		{"sealed for another user", "ios-00000000-0000-4000-8000-000000000102", movedUser},
		{"sealed by another writer", "ios-00000000-0000-4000-8000-000000000104", movedWriter},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if err := VerifyChain([]Row{c.row}, 0, blob.ZeroHash); err != nil {
				t.Fatalf("premise broken: the chain must verify: %v", err)
			}
			if _, err := a.AppendClient(bg, u, c.writer, blob.StreamHot, []Row{c.row}, testHeadSig(u, c.writer, []Row{c.row})); err == nil {
				t.Fatal("a blob sealed for a different position must not be stored")
			}
		})
	}
	assertGapFree(t, pool, u, 0)
	if got := nextSeqOf(t, pool, u); got != 1 {
		t.Fatalf("next_seq = %d, want 1: a rejected row burned a seq", got)
	}

	ok, _ := sealBody(t, u, "ios-00000000-0000-4000-8000-000000000101", blob.StreamHot, 1, blob.ZeroHash, `{"moved":"counter"}`)
	if _, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-000000000101", blob.StreamHot, []Row{ok}, testHeadSig(u, "ios-00000000-0000-4000-8000-000000000101", []Row{ok})); err != nil {
		t.Fatalf("a correctly sealed row must be accepted: %v", err)
	}
}

func TestVerifyChainDetectsRowsSplicedFromTwoChains(t *testing.T) {
	u := uuid.New()
	base, head := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 2)

	twoWriters, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000b", blob.StreamHot, 3, head, 2)
	if err := VerifyChain(append(append([]Row{}, base...), twoWriters...), 0, blob.ZeroHash); !errors.Is(err, ErrChainBreak) {
		t.Fatalf("two writers spliced into one chain must break, got %v", err)
	}
}

func TestClientAppendRefusesEveryStreamButHot(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}
	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 1)
	for _, stream := range []string{"cold", "", "HOT"} {
		_, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", stream, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows))
		if err == nil {
			t.Fatalf("stream %q must be refused", stream)
		}
		if errors.Is(err, ErrChainBreak) {
			t.Fatalf("refusing stream %q is a protocol rule, not a chain break: %v", stream, err)
		}
	}
	assertGapFree(t, pool, u, 0)
}

func TestPositionTakenIsResolvedAgainstTheStoredRows(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	a := &Appender{Pool: pool}

	rows, _ := chainFrom(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 1, blob.ZeroHash, 2)
	seqs, err := a.AppendClient(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, testHeadSig(u, "ios-00000000-0000-4000-8000-00000000000a", rows))
	if err != nil {
		t.Fatal(err)
	}
	dup := fmt.Errorf("oplog: append: insert row 0 (seq 9): %w",
		&pgconn.PgError{Code: uniqueViolation, ConstraintName: positionConstraint})

	got, err := a.resolveAppendErr(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, dup)
	if err != nil {
		t.Fatalf("a duplicate position holding identical bytes must resolve: %v", err)
	}
	if !reflect.DeepEqual(got, seqs) {
		t.Fatalf("resolved %v, want %v", got, seqs)
	}

	forked := append([]Row(nil), rows...)
	forked[1], _ = sealBody(t, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, 2, blob.ZeroHash, `{"forked":true}`)
	_, err = a.resolveAppendErr(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, forked, dup)
	if !errors.Is(err, ErrPositionTaken) {
		t.Fatalf("want ErrPositionTaken, got %T: %v", err, err)
	}
	if errors.Is(err, ErrChainBreak) {
		t.Fatalf("a server-side invariant violation must not be reported as a chain break: %v", err)
	}

	boom := errors.New("boom")
	if _, err := a.resolveAppendErr(bg, u, "ios-00000000-0000-4000-8000-00000000000a", blob.StreamHot, rows, boom); !errors.Is(err, boom) {
		t.Fatalf("an unrelated error must pass through, got %v", err)
	}
}
