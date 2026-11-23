package auth

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

const AlgEd25519 = "ed25519"

const (
	EventRegistered     = "registered"
	EventRevoked        = "revoked"
	AuthorizedAuthority = "authority"
	AuthorizedDevice    = "device"
)

const (
	ChallengeNonceBytes = keyproto.NonceSize
	ChallengeTTL        = 5 * time.Minute
	MaxLiveWriters      = 20
	challengeRetention  = 24 * time.Hour
)

var (
	ErrKeysRequired       = errors.New("auth: the account has no keys yet")
	ErrBadWriterID        = errors.New("auth: writer id does not match the §4.8 grammar")
	ErrWriterMalformed    = errors.New("auth: writer request is malformed")
	ErrBadSignature       = errors.New("auth: signature or nonce did not verify")
	ErrTooManyDevices     = errors.New("auth: the account has the maximum of live writers")
	ErrHeadMoved          = errors.New("auth: the target's head is not the pinned one")
	ErrNoSuchWriter       = errors.New("auth: no such writer")
	ErrWriterRevoked      = errors.New("auth: the writer is revoked")
	ErrDeviceOtherAccount = errors.New("auth: the signing-in device is not a writer of this account")
)

type Writer struct {
	UserID       uuid.UUID
	WriterID     string
	Alg          string
	PubKey       []byte
	DAKPubkey    []byte
	RegisteredAt time.Time
	RevokedAt    time.Time
}

func (w Writer) Live() bool { return w.RevokedAt.IsZero() }

type Writers struct {
	Pool   *pgxpool.Pool
	Mail   *Mailer
	StepUp *StepUp
	Now    func() time.Time
	Record func(purgeledger.Entry)
	Hold   purgeledger.HoldFunc
}

func (w *Writers) now() time.Time {
	if w.Now != nil {
		return w.Now()
	}
	return time.Now()
}

func (w *Writers) Challenge(ctx context.Context, userID uuid.UUID) ([]byte, time.Time, error) {
	if w.Pool == nil {
		return nil, time.Time{}, errors.New("auth: Writers.Pool is nil")
	}
	if userID == uuid.Nil {
		return nil, time.Time{}, errors.New("auth: writer challenge: user id is zero")
	}
	nonce, err := randBytes(ChallengeNonceBytes)
	if err != nil {
		return nil, time.Time{}, err
	}
	now := w.now()
	exp := now.Add(ChallengeTTL)
	if _, err := w.Pool.Exec(ctx,
		`INSERT INTO writer_challenges (nonce, user_id, issued_at, expires_at) VALUES ($1,$2,$3,$4)`,
		nonce, userID, now, exp); err != nil {
		return nil, time.Time{}, fmt.Errorf("auth: writer challenge for user %s: %w", userID, err)
	}
	_, _ = w.Pool.Exec(ctx, `DELETE FROM writer_challenges WHERE expires_at < $1`, now.Add(-challengeRetention))
	return nonce, exp, nil
}

func consumeChallenge(ctx context.Context, pool *pgxpool.Pool, now time.Time, userID uuid.UUID, nonce []byte) error {
	if len(nonce) != ChallengeNonceBytes {
		return fmt.Errorf("%w: nonce is %d bytes", ErrBadSignature, len(nonce))
	}
	var expires time.Time
	err := pool.QueryRow(ctx,
		`UPDATE writer_challenges SET used_at = $3
		  WHERE nonce = $1 AND user_id = $2 AND used_at IS NULL
		 RETURNING expires_at`, nonce, userID, now).Scan(&expires)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("%w: unknown, foreign or used writer challenge", ErrBadSignature)
	}
	if err != nil {
		return fmt.Errorf("auth: consume writer challenge: %w", err)
	}
	if !expires.After(now) {
		return fmt.Errorf("%w: writer challenge expired", ErrBadSignature)
	}
	return nil
}

type Registration struct {
	WriterID  string
	Alg       string
	PubKey    []byte
	DAKPubkey []byte
	Nonce     []byte
	Sig       []byte
}

func (r Registration) checkShape() error {
	if !keyproto.ValidWriterID(r.WriterID) {
		return ErrBadWriterID
	}
	if r.Alg != AlgEd25519 {
		return fmt.Errorf("%w: alg is not Ed25519", ErrWriterMalformed)
	}
	if err := keyproto.CheckEd25519PublicKey(r.PubKey); err != nil {
		return fmt.Errorf("%w: pubkey: %v", ErrWriterMalformed, err)
	}
	if _, err := keyproto.ParseDAK(r.DAKPubkey); err != nil {
		return fmt.Errorf("%w: dak_pubkey: %v", ErrWriterMalformed, err)
	}
	if len(r.Sig) != keyproto.Ed25519SigSize {
		return fmt.Errorf("%w: sig is %d bytes", ErrBadSignature, len(r.Sig))
	}
	return nil
}

func authorityKey(ctx context.Context, q querier, userID uuid.UUID) ([]byte, error) {
	var k []byte
	err := q.QueryRow(ctx, `SELECT authority_pubkey FROM account_keys WHERE user_id = $1`, userID).Scan(&k)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrKeysRequired
	}
	if err != nil {
		return nil, fmt.Errorf("auth: read authority key: %w", err)
	}
	return k, nil
}

func (w *Writers) Register(ctx context.Context, userID uuid.UUID, sessionHash []byte, r Registration) error {
	if w.Pool == nil {
		return errors.New("auth: Writers.Pool is nil")
	}
	aak, err := authorityKey(ctx, w.Pool, userID)
	if err != nil {
		return err
	}
	if err := r.checkShape(); err != nil {
		return err
	}
	var taken bool
	if err := w.Pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM writers WHERE user_id = $1 AND (writer_id = $2 OR pubkey = $3 OR dak_pubkey = $4))`,
		userID, r.WriterID, r.PubKey, r.DAKPubkey).Scan(&taken); err != nil {
		return fmt.Errorf("auth: register writer: %w", err)
	}
	if taken {
		return fmt.Errorf("%w: the writer id, key or DAK is already enrolled", ErrWriterMalformed)
	}
	if err := consumeChallenge(ctx, w.Pool, w.now(), userID, r.Nonce); err != nil {
		return err
	}
	msg, err := keyproto.RegistrationMessage(r.Nonce, r.WriterID, r.PubKey, r.DAKPubkey)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrWriterMalformed, err)
	}
	if !keyproto.VerifyEd25519(aak, msg, r.Sig) {
		return fmt.Errorf("%w: the RegistrationMessage does not verify under the authority key", ErrBadSignature)
	}

	tx, err := pgtx.BeginReadCommitted(ctx, w.Pool)
	if err != nil {
		return fmt.Errorf("auth: register writer: begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	if err := lockUser(ctx, tx, userID); err != nil {
		return err
	}
	var live int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM writers WHERE user_id = $1 AND revoked_at IS NULL`, userID).Scan(&live); err != nil {
		return fmt.Errorf("auth: register writer: count: %w", err)
	}
	if live >= MaxLiveWriters {
		return ErrTooManyDevices
	}
	if err := insertWriterTx(ctx, tx, userID, r, w.now()); err != nil {
		return err
	}
	if err := recordEventTx(ctx, tx, w.Mail, userID, AuthEvent{Kind: EventDeviceAdded, WriterID: r.WriterID}, w.now()); err != nil {
		return err
	}
	if err := bindSessionTx(ctx, tx, sessionHash, userID, r.WriterID); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("auth: register writer: commit: %w", err)
	}
	return nil
}

func insertWriterTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, r Registration, now time.Time) error {
	if _, err := tx.Exec(ctx,
		`INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at) VALUES ($1,$2,$3,$4,$5,$6)`,
		userID, r.WriterID, r.Alg, r.PubKey, r.DAKPubkey, now); err != nil {
		if uniqueViolation(err) != nil {
			return fmt.Errorf("%w: the writer id, key or DAK is already enrolled", ErrWriterMalformed)
		}
		return fmt.Errorf("auth: insert writer %s: %w", r.WriterID, err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO key_history (user_id, writer_id, alg, pubkey, dak_pubkey, event, authorized_by, nonce, signature, at)
		 VALUES ($1,$2,$3,$4,$5,'registered','authority',$6,$7,$8)`,
		userID, r.WriterID, r.Alg, r.PubKey, r.DAKPubkey, r.Nonce, r.Sig, now); err != nil {
		return fmt.Errorf("auth: append key history (registered %s): %w", r.WriterID, err)
	}
	return nil
}

func lockUser(ctx context.Context, tx pgx.Tx, userID uuid.UUID) error {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("%w: no such user", ErrWriterMalformed)
	}
	if err != nil {
		return fmt.Errorf("auth: lock user %s: %w", userID, err)
	}
	return nil
}

type Revocation struct {
	WriterID       string
	SignerWriterID string
	Nonce          []byte
	FinalCounter   int64
	FinalHead      []byte
	Sig            []byte
	StepUp         *StepUpObject
}

func (w *Writers) Revoke(ctx context.Context, userID uuid.UUID, session SessionInfo, r Revocation) (Wake, error) {
	if w.Pool == nil || w.StepUp == nil {
		return Wake{}, errors.New("auth: Writers is not configured")
	}
	if !keyproto.ValidWriterID(r.WriterID) || !keyproto.ValidWriterID(r.SignerWriterID) {
		return Wake{}, ErrBadWriterID
	}
	if r.FinalCounter < 0 || len(r.FinalHead) != keyproto.HashSize || len(r.Sig) != keyproto.Ed25519SigSize {
		return Wake{}, fmt.Errorf("%w: final_counter, final_head or sig is malformed", ErrWriterMalformed)
	}
	if r.StepUp == nil {
		return Wake{}, ErrStepUpRequired
	}
	if err := consumeChallenge(ctx, w.Pool, w.now(), userID, r.Nonce); err != nil {
		return Wake{}, err
	}
	if _, err := keyproto.RevocationMessage(r.Nonce, r.WriterID, uint64(r.FinalCounter), r.FinalHead); err != nil {
		return Wake{}, fmt.Errorf("%w: %v", ErrWriterMalformed, err)
	}
	ph, err := keyproto.ParamsHash(keyproto.ActionWriterRevoke, []byte(r.WriterID))
	if err != nil {
		return Wake{}, err
	}
	g := Guarded{UserID: userID, SessionHash: session.Hash, BoundWriter: session.WriterID,
		Action: keyproto.ActionWriterRevoke, ParamsHash: ph, StepUp: r.StepUp}
	var (
		held   purgeledger.Held
		tokens []pushv2.Target
	)
	err = w.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, p Proven) error {
		if _, err := tx.Exec(ctx, `SELECT 1 FROM users WHERE id = $1 FOR KEY SHARE`, userID); err != nil {
			return fmt.Errorf("auth: revoke: lock the account: %w", err)
		}
		var revoked *time.Time
		err := tx.QueryRow(ctx,
			`SELECT revoked_at FROM writers WHERE user_id = $1 AND writer_id = $2 FOR UPDATE`,
			userID, r.WriterID).Scan(&revoked)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNoSuchWriter
		}
		if err != nil {
			return fmt.Errorf("auth: revoke: lock target: %w", err)
		}
		if revoked != nil {
			return ErrWriterRevoked
		}
		counter, head, err := writerHead(ctx, tx, userID, r.WriterID)
		if err != nil {
			return err
		}
		if counter != r.FinalCounter || !bytes.Equal(head, r.FinalHead) {
			return fmt.Errorf("%w: the writer's counter is %d", ErrHeadMoved, counter)
		}
		wr := writerRevocation{UserID: userID, WriterID: r.WriterID, SignerWriterID: r.SignerWriterID,
			FinalCounter: r.FinalCounter, FinalHead: r.FinalHead, Nonce: r.Nonce, Sig: r.Sig}
		if ok, err := wr.verifiesTx(ctx, tx); err != nil || !ok {
			return fmt.Errorf("%w: the RevocationMessage does not verify under a live signer", ErrBadSignature)
		}
		now := w.now()
		so, err := revokeWriterTx(ctx, tx, wr, true, now, now)
		if err != nil {
			return err
		}
		if r.WriterID != session.WriterID {
			tokens = so.tokens
		}
		if so.unlinked {
			if err := RecordQuietEventTx(ctx, tx, userID, AuthEvent{Kind: EventMailboxUnlinked,
				WriterID: session.WriterID, CredentialID: p.CredentialID}, now); err != nil {
				return err
			}
		}
		if held, err = w.Hold.Tx(ctx, tx, purgeledger.Entry{ID: userID, At: now, Kind: purgeledger.KindDevice, Device: &purgeledger.Device{
			WriterID: r.WriterID, SignerWriterID: r.SignerWriterID, FinalCounter: r.FinalCounter,
			FinalHead: r.FinalHead, Nonce: r.Nonce, Sig: r.Sig}}); err != nil {
			return err
		}
		return recordEventTx(ctx, tx, w.Mail, userID, AuthEvent{Kind: EventDeviceRemoved, WriterID: r.WriterID}, now)
	})
	if err != nil {
		return Wake{}, err
	}
	held.Release(w.Record)
	return wakeFor(userID, session.WriterID, tokens), nil
}

type writerRevocation struct {
	UserID         uuid.UUID
	WriterID       string
	SignerWriterID string
	FinalCounter   int64
	FinalHead      []byte
	Nonce          []byte
	Sig            []byte
}

func (r writerRevocation) verifiesTx(ctx context.Context, tx pgx.Tx) (bool, error) {
	var (
		signerKey  []byte
		signerLive bool
	)
	err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		r.UserID, r.SignerWriterID).Scan(&signerKey, &signerLive)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	msg, err := keyproto.RevocationMessage(r.Nonce, r.WriterID, uint64(r.FinalCounter), r.FinalHead)
	if err != nil {
		return false, nil
	}
	return signerLive && keyproto.VerifyEd25519(signerKey, msg, r.Sig), nil
}

type writerSignOut struct {
	changed  bool
	unlinked bool
	tokens   []pushv2.Target
}

func revokeWriterTx(ctx context.Context, tx pgx.Tx, r writerRevocation, retire bool, at, now time.Time) (writerSignOut, error) {
	var so writerSignOut
	if retire {
		if _, err := tx.Exec(ctx,
			`UPDATE writers SET revoked_at = $3 WHERE user_id = $1 AND writer_id = $2 AND revoked_at IS NULL`,
			r.UserID, r.WriterID, at); err != nil {
			return so, fmt.Errorf("auth: revoke writer %s: %w", r.WriterID, err)
		}
		var pub []byte
		if err := tx.QueryRow(ctx, `SELECT pubkey FROM writers WHERE user_id = $1 AND writer_id = $2`, r.UserID, r.WriterID).Scan(&pub); err != nil {
			return so, fmt.Errorf("auth: revoke: read key: %w", err)
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO key_history (user_id, writer_id, alg, pubkey, event, authorized_by, authorizer_writer_id,
			   final_counter, final_head, nonce, signature, at)
			 VALUES ($1,$2,'ed25519',$3,'revoked','device',$4,$5,$6,$7,$8,$9)`,
			r.UserID, r.WriterID, pub, r.SignerWriterID, r.FinalCounter, r.FinalHead, r.Nonce, r.Sig, at); err != nil {
			return so, fmt.Errorf("auth: append key history (revoked %s): %w", r.WriterID, err)
		}
	}
	tag, err := tx.Exec(ctx,
		`UPDATE sessions SET revoked_at = $3, revoked_reason = 'writer'
		  WHERE user_id = $1 AND writer_id = $2 AND revoked_at IS NULL`,
		r.UserID, r.WriterID, now)
	if err != nil {
		return so, fmt.Errorf("auth: revoke the writer's sessions: %w", err)
	}
	so.changed = tag.RowsAffected() > 0
	if so.tokens, err = takePushTokens(ctx, tx, `user_id = $1 AND writer_id = $2`, r.UserID, r.WriterID); err != nil {
		return so, err
	}
	so.changed = so.changed || len(so.tokens) > 0
	tag, err = tx.Exec(ctx,
		`DELETE FROM password_reset_ceremonies WHERE user_id = $1 AND approved_by_writer = $2 AND consumed_at IS NULL`,
		r.UserID, r.WriterID)
	if err != nil {
		return so, fmt.Errorf("auth: revoke: drop the writer's pending approvals: %w", err)
	}
	so.changed = so.changed || tag.RowsAffected() > 0
	if so.unlinked, err = dropHeldMailboxLinkTx(ctx, tx, r.UserID, r.WriterID); err != nil {
		return so, err
	}
	return so, nil
}

func dropHeldMailboxLinkTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, writerID string) (bool, error) {
	tag, err := tx.Exec(ctx, `DELETE FROM mailbox_links WHERE user_id = $1 AND holder_writer_id = $2`, userID, writerID)
	if err != nil {
		return false, fmt.Errorf("auth: revoke: drop the writer's mailbox link: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}

func writerHead(ctx context.Context, tx pgx.Tx, userID uuid.UUID, writerID string) (int64, []byte, error) {
	var (
		c int64
		h []byte
	)
	err := tx.QueryRow(ctx,
		`SELECT writer_counter, blob_hash FROM op_log
		  WHERE user_id = $1 AND writer_id = $2 AND stream = 'hot'
		  ORDER BY writer_counter DESC LIMIT 1`, userID, writerID).Scan(&c, &h)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, make([]byte, 32), nil
	}
	if err != nil {
		return 0, nil, fmt.Errorf("auth: read the writer's head: %w", err)
	}
	return c, h, nil
}

func (w *Writers) Roster(ctx context.Context, userID uuid.UUID) ([]Writer, error) {
	if w.Pool == nil {
		return nil, errors.New("auth: Writers.Pool is nil")
	}
	rows, err := w.Pool.Query(ctx,
		`SELECT user_id, writer_id, alg, pubkey, dak_pubkey, registered_at, revoked_at
		   FROM writers WHERE user_id = $1 ORDER BY registered_at, writer_id`, userID)
	if err != nil {
		return nil, fmt.Errorf("auth: roster for user %s: %w", userID, err)
	}
	defer rows.Close()
	var out []Writer
	for rows.Next() {
		var (
			wr      Writer
			revoked *time.Time
		)
		if err := rows.Scan(&wr.UserID, &wr.WriterID, &wr.Alg, &wr.PubKey, &wr.DAKPubkey, &wr.RegisteredAt, &revoked); err != nil {
			return nil, fmt.Errorf("auth: scan writer: %w", err)
		}
		if revoked != nil {
			wr.RevokedAt = *revoked
		}
		out = append(out, wr)
	}
	return out, rows.Err()
}
