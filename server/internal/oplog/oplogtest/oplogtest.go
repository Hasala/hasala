package oplogtest

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/blob/blobtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/oplog"
)

var bg = context.Background()

func WID(n int) string { return fmt.Sprintf("ios-00000000-0000-4000-8000-%012x", n) }

func DWK(writerID string) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte("oplogtest-dwk|" + writerID))
	return ed25519.NewKeyFromSeed(seed[:])
}

func DAK(t testing.TB) []byte {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	out := []byte{4}
	out = append(out, k.X.FillBytes(make([]byte, 32))...)
	return append(out, k.Y.FillBytes(make([]byte, 32))...)
}

func HeadSig(userID uuid.UUID, writerID string, rows []oplog.Row) []byte {
	last := rows[len(rows)-1]
	m, err := keyproto.HeadMessage(userID, uint64(last.WriterCounter), last.BlobHash, writerID)
	if err != nil {
		panic(err)
	}
	return ed25519.Sign(DWK(writerID), m)
}

func NewUser(t testing.TB, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	id := NewUserWithoutKeys(t, pool)
	AddKeys(t, pool, id)
	return id
}

func NewUserWithoutKeys(t testing.TB, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	tx, err := pool.Begin(bg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(bg) }()
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
	if err := oplog.EnsureSeqRow(bg, tx, id); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(bg); err != nil {
		t.Fatal(err)
	}
	return id
}

func AddKeys(t testing.TB, pool *pgxpool.Pool, userID uuid.UUID) {
	t.Helper()
	rnd := func(n int) []byte {
		b := make([]byte, n)
		if _, err := rand.Read(b); err != nil {
			t.Fatal(err)
		}
		return b
	}
	wrap := append([]byte{1, 1}, rnd(125)...)
	box := append([]byte{1}, rnd(44)...)
	if _, err := pool.Exec(bg,
		`INSERT INTO account_keys (user_id, format_version, amk_commitment, authority_pubkey, recovery_pubkey,
		   recovery_wrap, phrase_box, current_epoch, created_at, updated_at)
		 VALUES ($1, 1, $2, $3, $4, $5, $6, 1, now(), now())
		 ON CONFLICT (user_id) DO NOTHING`,
		userID, rnd(32), rnd(32), rnd(32), wrap, box); err != nil {
		t.Fatalf("oplogtest: account keys: %v", err)
	}
}

func NewWriter(t testing.TB, pool *pgxpool.Pool, userID uuid.UUID, writerID string) ed25519.PrivateKey {
	t.Helper()
	priv := DWK(writerID)
	if _, err := pool.Exec(bg,
		`INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at) VALUES ($1, $2, 'ed25519', $3, $4, now())`,
		userID, writerID, []byte(priv.Public().(ed25519.PublicKey)), DAK(t)); err != nil {
		t.Fatalf("oplogtest: enrol writer %s: %v", writerID, err)
	}
	return priv
}

func Rows(t testing.TB, userID uuid.UUID, writerID string, counter int64, prev [32]byte, n int) []oplog.Row {
	t.Helper()
	out := make([]oplog.Row, 0, n)
	for i := 0; i < n; i++ {
		c := counter + int64(i) + 1
		env := blob.Envelope{UserID: userID, Stream: blob.StreamHot, WriterID: writerID, WriterCounter: c}
		s, err := blobtest.Seal3(env, 1, blobtest.TestEpochKey, prev,
			[]byte(fmt.Sprintf(`{"v":4,"kind":"ops","ops":[{"n":%d}]}`, c)))
		if err != nil {
			t.Fatalf("oplogtest: seal counter %d: %v", c, err)
		}
		h := blob.Hash(prev, s)
		out = append(out, oplog.Row{
			UserID: userID, Stream: blob.StreamHot, WriterID: writerID, WriterCounter: c,
			TypeFlag: oplog.TypeFlagEdit, Blob: s.Bytes, SizeBucket: s.SizeBucket,
			BlobHash: append([]byte(nil), h[:]...), PrevHash: append([]byte(nil), prev[:]...),
		})
		prev = h
	}
	return out
}

func Append(t testing.TB, pool *pgxpool.Pool, userID uuid.UUID, writerID string, n int) []int64 {
	t.Helper()
	ap := &oplog.Appender{Pool: pool}
	counter, head, err := ap.Head(bg, userID, writerID, blob.StreamHot)
	if err != nil {
		t.Fatal(err)
	}
	rows := Rows(t, userID, writerID, counter, head, n)
	seqs, err := ap.AppendClient(bg, userID, writerID, blob.StreamHot, rows, HeadSig(userID, writerID, rows))
	if err != nil {
		t.Fatalf("oplogtest: append %d rows for %s: %v", n, writerID, err)
	}
	return seqs
}

func Opaque(n int) []byte {
	out := make([]byte, 0, n)
	seed := sha256.Sum256([]byte("oplogtest"))
	for len(out) < n {
		seed = sha256.Sum256(seed[:])
		out = append(out, seed[:]...)
	}
	return out[:n]
}
