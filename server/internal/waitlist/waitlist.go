package waitlist

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/banks"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/mail"
	"github.com/salehtl/hasala/server/internal/mailq"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

var (
	ErrBadEmail    = errors.New("waitlist: not an email address")
	ErrBadRequest  = errors.New("waitlist: malformed submission")
	ErrFull        = errors.New("waitlist: the list is full")
	ErrLinkExpired = errors.New("waitlist: the link is unknown or expired")
)

const (
	ConfirmTTL = 7 * 24 * time.Hour
	LeaveTTL   = 90 * 24 * time.Hour
	TokenLen   = 43
)

type Service struct {
	Pool                *pgxpool.Pool
	Tagger              mailq.Tagger
	WebBase             string
	MaxOpen, MaxPending int
	ConfirmedRetention  time.Duration
	OnConfirmed         func()
	Record              func(purgeledger.Entry)
	Hold                purgeledger.HoldFunc

	mu        sync.Mutex
	countsAt  time.Time
	open, pen int
}

func New(pool *pgxpool.Pool, tagger mailq.Tagger, webBase string) *Service {
	return &Service{Pool: pool, Tagger: tagger, WebBase: strings.TrimSuffix(webBase, "/"),
		MaxOpen: 10_000, MaxPending: 2_000, ConfirmedRetention: 180 * 24 * time.Hour}
}

type Submission struct {
	Email, Bank, OtherBank, Source string
}

func (s *Service) full(ctx context.Context) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Since(s.countsAt) > time.Minute {
		if err := s.Pool.QueryRow(ctx,
			`SELECT count(*) FILTER (WHERE state IN ('pending','confirmed','invited')),
			        count(*) FILTER (WHERE state = 'pending') FROM waitlist_entries`).Scan(&s.open, &s.pen); err != nil {
			return false, err
		}
		s.countsAt = time.Now()
	}
	return s.open >= s.MaxOpen || s.pen >= s.MaxPending, nil
}

func (s *Service) Validate(ctx context.Context, sub Submission) (string, banks.Choice, error) {
	email, err := keyproto.EmailNorm(sub.Email)
	if err != nil || sub.Email == "" {
		return "", banks.Choice{}, ErrBadEmail
	}
	if sub.Source != "web" {
		return "", banks.Choice{}, ErrBadRequest
	}
	if sub.Bank == "" {
		return "", banks.Choice{}, banks.ErrBadBank
	}
	choice, err := banks.Resolve(ctx, s.Pool, sub.Bank, sub.OtherBank)
	if err != nil {
		return "", banks.Choice{}, err
	}
	return email, choice, nil
}

func (s *Service) Submit(ctx context.Context, email string, c banks.Choice) (string, error) {
	if s.Tagger == nil {
		return "", errors.New("waitlist: no auth key: email_tag cannot be computed")
	}
	full, err := s.full(ctx)
	if err != nil {
		return "", err
	}
	if full {
		return "", ErrFull
	}
	tag := s.Tagger.EmailTag(email)
	var outcome string
	err = s.Pool.QueryRow(ctx, `SELECT waitlist_submit($1, $2, $3, $4, $5, $6, 'web')`,
		tag, email, mailq.Hint(email), nullable(c.Slug), nullable(c.OtherText), nullable(c.OtherKey)).Scan(&outcome)
	if err != nil {
		return "", fmt.Errorf("waitlist: submit: %w", err)
	}
	return outcome, nil
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func DecodeToken(token string) ([]byte, bool) {
	if len(token) != TokenLen {
		return nil, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(raw) != 32 {
		return nil, false
	}
	sum := sha256.Sum256(raw)
	return sum[:], true
}

func (s *Service) Confirm(ctx context.Context, token string) (string, error) {
	hash, ok := DecodeToken(token)
	if !ok {
		return "", ErrBadRequest
	}
	tx, err := pgtx.BeginReadCommitted(ctx, s.Pool)
	if err != nil {
		return "", err
	}
	defer pgtx.Rollback(ctx, tx)
	var (
		entry uuid.UUID
		state string
	)
	err = tx.QueryRow(ctx,
		`SELECT e.id, e.state FROM waitlist_tokens t JOIN waitlist_entries e ON e.id = t.entry_id
		  WHERE t.token_hash = $1 AND t.purpose = 'confirm' AND t.expires_at > now()
		  FOR UPDATE OF e`, hash).Scan(&entry, &state)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrLinkExpired
	}
	if err != nil {
		return "", fmt.Errorf("waitlist: confirm: %w", err)
	}
	if state != "pending" {
		return "already_confirmed", nil
	}
	if _, err := tx.Exec(ctx,
		`UPDATE waitlist_entries SET state = 'confirmed', confirmed_at = now(), updated_at = now() WHERE id = $1`,
		entry); err != nil {
		return "", err
	}
	used, err := tx.Exec(ctx, `UPDATE waitlist_tokens SET used_at = now() WHERE token_hash = $1`, hash)
	if err != nil {
		return "", err
	}
	if used.RowsAffected() == 0 {
		return "", ErrLinkExpired
	}
	if _, err := tx.Exec(ctx,
		`DELETE FROM waitlist_tokens WHERE entry_id = $1 AND purpose = 'confirm' AND used_at IS NULL`, entry); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `SELECT waitlist_derive_request($1)`, entry); err != nil {
		return "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	if s.OnConfirmed != nil {
		s.OnConfirmed()
	}
	return "confirmed", nil
}

func (s *Service) Leave(ctx context.Context, token string) error {
	hash, ok := DecodeToken(token)
	if !ok {
		return ErrBadRequest
	}
	tx, err := pgtx.BeginReadCommitted(ctx, s.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	var entry uuid.UUID
	err = tx.QueryRow(ctx,
		`SELECT entry_id FROM waitlist_tokens WHERE token_hash = $1 AND purpose = 'leave' AND expires_at > now()`,
		hash).Scan(&entry)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("waitlist: leave: %w", err)
	}
	if err := DeleteEntryTx(ctx, tx, entry); err != nil {
		return err
	}
	held, err := s.Hold.Tx(ctx, tx, purgeledger.Entry{ID: entry, At: time.Now(), Kind: purgeledger.KindWaitlistLeave})
	if err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	held.Release(s.Record)
	return nil
}

func DeleteEntryTx(ctx context.Context, tx pgx.Tx, entry uuid.UUID) error {
	if _, err := tx.Exec(ctx,
		`UPDATE invite_codes SET state = 'revoked', closed_at = now()
		  WHERE waitlist_entry_id = $1 AND state IN ('awaiting_testflight','queued','active')`, entry); err != nil {
		return fmt.Errorf("waitlist: revoke the entry's invite: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM waitlist_entries WHERE id = $1`, entry); err != nil {
		return fmt.Errorf("waitlist: delete entry: %w", err)
	}
	return nil
}

func DeleteBouncedEntryTx(ctx context.Context, tx pgx.Tx, entry uuid.UUID) error {
	if _, err := tx.Exec(ctx,
		`UPDATE mail_log SET waitlist_entry_id = NULL, recipient = NULL
		  WHERE waitlist_entry_id = $1 AND kind = 'invite' AND final_at IS NOT NULL`, entry); err != nil {
		return fmt.Errorf("waitlist: detach the entry's invite mail: %w", err)
	}
	return DeleteEntryTx(ctx, tx, entry)
}

func OnInviteRedeemedTx(ctx context.Context, tx pgx.Tx, inviteID, userID uuid.UUID, accountTag []byte) error {
	rows, err := tx.Query(ctx,
		`SELECT waitlist_entry_id FROM invite_codes WHERE id = $1 AND waitlist_entry_id IS NOT NULL
		 UNION
		 SELECT id FROM waitlist_entries WHERE $2::bytea IS NOT NULL AND email_tag = $2 AND state <> 'joined'`,
		inviteID, accountTag)
	if err != nil {
		return fmt.Errorf("waitlist: join hook: %w", err)
	}
	entries, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return fmt.Errorf("waitlist: join hook: %w", err)
	}
	for _, e := range entries {
		if _, err := tx.Exec(ctx,
			`UPDATE waitlist_entries SET state = 'joined', joined_at = now(), email_norm = NULL, updated_at = now(),
			        invited_at = coalesce(invited_at, now()), confirmed_at = coalesce(confirmed_at, now())
			  WHERE id = $1`, e); err != nil {
			return fmt.Errorf("waitlist: join: %w", err)
		}
		if _, err := tx.Exec(ctx, `DELETE FROM waitlist_tokens WHERE entry_id = $1 AND purpose = 'confirm'`, e); err != nil {
			return fmt.Errorf("waitlist: join: drop the entry's confirm links: %w", err)
		}
		if _, err := tx.Exec(ctx,
			`UPDATE invite_codes SET state = 'revoked', closed_at = now()
			  WHERE waitlist_entry_id = $1 AND id <> $2 AND state IN ('awaiting_testflight','queued','active')`,
			e, inviteID); err != nil {
			return fmt.Errorf("waitlist: join: revoke the entry's other invites: %w", err)
		}
		if _, err := tx.Exec(ctx,
			`DELETE FROM bank_requests r WHERE r.waitlist_entry_id = $1 AND EXISTS (
			   SELECT 1 FROM bank_requests u WHERE u.user_id = $2
			      AND coalesce(u.bank_slug, 'other:' || u.other_key) = coalesce(r.bank_slug, 'other:' || r.other_key))`,
			e, userID); err != nil {
			return fmt.Errorf("waitlist: join requests: %w", err)
		}
		if _, err := tx.Exec(ctx,
			`UPDATE bank_requests SET user_id = $2, waitlist_entry_id = NULL WHERE waitlist_entry_id = $1`,
			e, userID); err != nil {
			return fmt.Errorf("waitlist: join requests: %w", err)
		}
	}
	return nil
}

func OnAddressTakenTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, accountTag []byte) error {
	return OnInviteRedeemedTx(ctx, tx, uuid.Nil, userID, accountTag)
}

func MintToken(ctx context.Context, tx pgx.Tx, entry uuid.UUID, purpose string) (string, error) {
	ttl := ConfirmTTL
	if purpose == "leave" {
		ttl = LeaveTTL
	} else if purpose != "confirm" {
		return "", fmt.Errorf("waitlist: token purpose %q", purpose)
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	if _, err := tx.Exec(ctx,
		`INSERT INTO waitlist_tokens (token_hash, entry_id, purpose, created_at, expires_at)
		 VALUES ($1, $2, $3, now(), now() + $4::interval)`,
		sum[:], entry, purpose, fmt.Sprintf("%d seconds", int64(ttl/time.Second))); err != nil {
		return "", fmt.Errorf("waitlist: mint %s token: %w", purpose, err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

const UnsubscribeURL = "https://api.hasala.app/api/v1/waitlist/unsubscribe"

type Leave struct{ Page, OneClick string }

func LeaveLinks(ctx context.Context, tx pgx.Tx, webBase string, entry uuid.UUID) (Leave, error) {
	tok, err := MintToken(ctx, tx, entry, "leave")
	if err != nil {
		return Leave{}, err
	}
	return Leave{Page: strings.TrimSuffix(webBase, "/") + "/waitlist/leave#" + tok,
		OneClick: UnsubscribeURL + "?token=" + tok}, nil
}

func (s *Service) Sweep(ctx context.Context) (string, error) {
	var total int64
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`DELETE FROM waitlist_entries WHERE state = 'pending'
		    AND coalesce(last_confirm_sent_at, created_at) < now() - interval '7 days'`, nil},
		{`DELETE FROM waitlist_entries WHERE state = 'confirmed' AND confirmed_at < now() - $1::interval`,
			[]any{fmt.Sprintf("%d seconds", int64(s.ConfirmedRetention/time.Second))}},
		{`DELETE FROM waitlist_entries WHERE state = 'joined' AND joined_at < now() - interval '30 days'`, nil},
		{`DELETE FROM waitlist_tokens WHERE expires_at < now() OR used_at < now() - interval '1 day'`, nil},
	} {
		tag, err := s.Pool.Exec(ctx, q.sql, q.args...)
		if err != nil {
			return "", fmt.Errorf("waitlist: sweep: %w", err)
		}
		total += tag.RowsAffected()
	}
	if total == 0 {
		return "", nil
	}
	return fmt.Sprintf("%d waitlist rows swept", total), nil
}

type entryView struct {
	email                         *string
	state                         string
	bankName                      *string
	confirmedAt, invitedAt, until *time.Time
}

func readEntry(ctx context.Context, tx pgx.Tx, id uuid.UUID) (entryView, error) {
	var v entryView
	err := tx.QueryRow(ctx,
		`SELECT e.email_norm, e.state, b.name, e.confirmed_at, e.invited_at,
		        (SELECT max(expires_at) FROM invite_codes i WHERE i.waitlist_entry_id = e.id AND i.state = 'active')
		   FROM waitlist_entries e LEFT JOIN banks b ON b.slug = e.bank_slug
		  WHERE e.id = $1 FOR UPDATE OF e`, id).
		Scan(&v.email, &v.state, &v.bankName, &v.confirmedAt, &v.invitedAt, &v.until)
	return v, staleIfGone(err)
}

func readEntryIn(ctx context.Context, tx pgx.Tx, id uuid.UUID, states ...string) (entryView, error) {
	v, err := readEntry(ctx, tx, id)
	if err != nil {
		return v, staleIfGone(err)
	}
	if !slices.Contains(states, v.state) {
		return v, ErrStale
	}
	return v, nil
}

func staleIfGone(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrStale
	}
	return err
}

var ErrStale error = mailq.Stale("waitlist: the entry no longer needs this email")

func toMessage(row mailq.Row, r mailq.Rendered) mail.Message {
	return mail.Message{To: row.Recipient, Subject: r.Subject, Text: r.Text, HTML: r.HTML}
}

func withLeave(row mailq.Row, r mailq.Rendered, leave Leave) mail.Message {
	m := toMessage(row, r)
	m.Unsubscribe = leave.OneClick
	return m
}

func dateOf(t *time.Time) string {
	if t == nil {
		return ""
	}
	return mailq.Date(*t)
}

const inviteWhy = "You're getting this because someone asked for a Hasala invite for this address at hasala.app."

func (s *Service) Register(q *mailq.Queue) {
	q.Register("bank_supported", mailq.RenderFunc(s.renderBankSupported))
	q.Register("waitlist", mailq.RenderFunc(func(ctx context.Context, tx pgx.Tx, row mailq.Row) (mail.Message, error) {
		if row.EntryID == nil {
			return mail.Message{}, ErrStale
		}
		v, err := readEntryIn(ctx, tx, *row.EntryID, "pending")
		if err != nil {
			return mail.Message{}, err
		}
		confirm, err := MintToken(ctx, tx, *row.EntryID, "confirm")
		if err != nil {
			return mail.Message{}, err
		}
		leave, err := LeaveLinks(ctx, tx, s.WebBase, *row.EntryID)
		if err != nil {
			return mail.Message{}, err
		}
		bank := "Another bank"
		if v.bankName != nil {
			bank = *v.bankName
		}
		r, err := mailq.RenderTemplate("waitlist", mailq.Content{Email: row.Recipient, BankName: bank,
			ConfirmURL: s.WebBase + "/waitlist/confirm#" + confirm, LeaveURL: leave.Page, Why: inviteWhy})
		return withLeave(row, r, leave), err
	}))
	q.Register("waitlist_already", mailq.RenderFunc(func(ctx context.Context, tx pgx.Tx, row mailq.Row) (mail.Message, error) {
		if row.EntryID == nil {
			return mail.Message{}, ErrStale
		}
		v, err := readEntryIn(ctx, tx, *row.EntryID, "confirmed", "invited")
		if err != nil {
			return mail.Message{}, err
		}
		leave, err := LeaveLinks(ctx, tx, s.WebBase, *row.EntryID)
		if err != nil {
			return mail.Message{}, err
		}
		r, err := mailq.RenderTemplate("waitlist_already", mailq.Content{Email: row.Recipient, LeaveURL: leave.Page,
			Invited: v.state == "invited", ConfirmedOn: dateOf(v.confirmedAt), InvitedOn: dateOf(v.invitedAt),
			Until: dateOf(v.until), Why: inviteWhy})
		return withLeave(row, r, leave), err
	}))
	q.Register("waitlist_has_account", mailq.RenderFunc(func(ctx context.Context, tx pgx.Tx, row mailq.Row) (mail.Message, error) {
		var name *string
		err := tx.QueryRow(ctx, `SELECT to_jsonb(u) ->> 'display_name' FROM users u WHERE email_norm = $1`,
			row.Recipient).Scan(&name)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return mail.Message{}, err
		}
		greeting := "Hi,"
		if err == nil && name != nil {
			greeting = mail.Greeting(*name)
		}
		r, err := mailq.RenderTemplate("waitlist_has_account", mailq.Content{Greeting: greeting, Email: row.Recipient,
			Why: inviteWhy})
		return toMessage(row, r), err
	}))
}

func (s *Service) renderBankSupported(ctx context.Context, tx pgx.Tx, row mailq.Row) (mail.Message, error) {
	if row.BankSlug == nil {
		return mail.Message{}, ErrStale
	}
	var bank, status string
	if err := tx.QueryRow(ctx, `SELECT name, status FROM banks WHERE slug = $1`, *row.BankSlug).
		Scan(&bank, &status); err != nil {
		return mail.Message{}, staleIfGone(err)
	}
	if status != "supported" {
		return mail.Message{}, ErrStale
	}
	if row.UserID != nil {
		var name string
		if err := tx.QueryRow(ctx, `SELECT display_name FROM users WHERE id = $1 AND email_norm = $2`,
			*row.UserID, row.Recipient).Scan(&name); err != nil {
			return mail.Message{}, staleIfGone(err)
		}
		r, err := mailq.RenderTemplate("bank_supported", mailq.Content{Greeting: mail.Greeting(name),
			Email: row.Recipient, BankName: bank, AccountAudience: true,
			Why: "You're getting this because you asked for " + bank + " in Hasala."})
		return toMessage(row, r), err
	}
	if row.EntryID == nil {
		return mail.Message{}, ErrStale
	}
	if _, err := readEntryIn(ctx, tx, *row.EntryID, "confirmed", "invited"); err != nil {
		return mail.Message{}, err
	}
	leave, err := LeaveLinks(ctx, tx, s.WebBase, *row.EntryID)
	if err != nil {
		return mail.Message{}, err
	}
	r, err := mailq.RenderTemplate("bank_supported", mailq.Content{Email: row.Recipient, BankName: bank,
		LeaveURL: leave.Page, Why: inviteWhy})
	return withLeave(row, r, leave), err
}
