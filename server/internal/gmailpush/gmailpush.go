package gmailpush

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

type RouteKey struct{ k []byte }

var ErrRouteKey = errors.New("gmailpush: the route key file holds exactly 64 hex characters")

func ParseRouteKey(s string) (RouteKey, error) {
	s = strings.TrimSuffix(strings.TrimSuffix(s, "\n"), "\r")
	if len(s) != 64 {
		return RouteKey{}, ErrRouteKey
	}
	k, err := hex.DecodeString(s)
	if err != nil {
		return RouteKey{}, ErrRouteKey
	}
	return RouteKey{k: k}, nil
}

func NewRouteKey(raw []byte) (RouteKey, error) {
	if len(raw) != 32 {
		return RouteKey{}, ErrRouteKey
	}
	return RouteKey{k: append([]byte(nil), raw...)}, nil
}

func NormalizeAddress(x string) string {
	x = strings.Trim(x, " \t\r\n")
	b := []byte(x)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	return string(b)
}

const (
	ProviderGmail   = "gmail"
	ProviderOutlook = "outlook"
)

func (r RouteKey) AddressHMACFor(provider, address string) []byte {
	m := hmac.New(sha256.New, r.k)
	m.Write([]byte(keyproto.DomainMailboxRoute))
	m.Write([]byte{0})
	m.Write([]byte(provider))
	m.Write([]byte{0})
	m.Write([]byte(NormalizeAddress(address)))
	return m.Sum(nil)
}

func (r RouteKey) SubjectHMACFor(provider, subject string) []byte {
	m := hmac.New(sha256.New, r.k)
	m.Write([]byte(keyproto.DomainMailboxRoute))
	m.Write([]byte{0})
	m.Write([]byte(provider + "-sub"))
	m.Write([]byte{0})
	m.Write([]byte(subject))
	return m.Sum(nil)
}

func (r RouteKey) AddressHMAC(address string) []byte { return r.AddressHMACFor(ProviderGmail, address) }

func (r RouteKey) KeyID() []byte {
	m := hmac.New(sha256.New, r.k)
	m.Write([]byte(keyproto.DomainMailboxRouteKeyID))
	return m.Sum(nil)[:8]
}

func (r RouteKey) Valid() bool { return len(r.k) == 32 }

func CheckKeyID(ctx context.Context, pool *pgxpool.Pool, r RouteKey) error {
	rows, err := pool.Query(ctx, `SELECT DISTINCT route_key_id FROM mailbox_links`)
	if err != nil {
		return fmt.Errorf("gmailpush: read route key ids: %w", err)
	}
	defer rows.Close()
	want := r.KeyID()
	for rows.Next() {
		var id []byte
		if err := rows.Scan(&id); err != nil {
			return err
		}
		if !bytes.Equal(id, want) {
			return fmt.Errorf("gmailpush: mailbox_links were made under another route key: put the "+
				"previous HASALA_MAILBOX_ROUTE_KEY_FILE back, or run hasalad mailbox rekey --drop-links --keep-key-id %s "+
				"(devices then offer \"Reconnect Gmail\")", hex.EncodeToString(want))
		}
	}
	return rows.Err()
}

type Notice struct {
	EmailAddress string
}

var (
	ErrMalformed           = errors.New("gmailpush: malformed push")
	ErrForeignSubscription = errors.New("gmailpush: push for another subscription")
)

const maxData = 1024

func ParseEnvelope(body []byte, subscription string) (Notice, error) {
	var env struct {
		Message *struct {
			Data string `json:"data"`
		} `json:"message"`
		Subscription string `json:"subscription"`
	}
	if err := json.Unmarshal(body, &env); err != nil || env.Message == nil {
		return Notice{}, ErrMalformed
	}
	if env.Subscription != subscription {
		return Notice{}, ErrForeignSubscription
	}
	if base64.StdEncoding.DecodedLen(len(env.Message.Data)) > maxData+3 {
		return Notice{}, ErrMalformed
	}
	data, err := base64.StdEncoding.DecodeString(env.Message.Data)
	if err != nil {
		if data, err = base64.URLEncoding.DecodeString(env.Message.Data); err != nil {
			return Notice{}, ErrMalformed
		}
	}
	if len(data) > maxData {
		return Notice{}, ErrMalformed
	}
	var n struct {
		EmailAddress *string         `json:"emailAddress"`
		HistoryID    json.RawMessage `json:"historyId"`
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&n); err != nil || n.EmailAddress == nil || *n.EmailAddress == "" || len(*n.EmailAddress) > 320 {
		return Notice{}, ErrMalformed
	}
	if !validHistoryID(n.HistoryID) {
		return Notice{}, ErrMalformed
	}
	return Notice{EmailAddress: *n.EmailAddress}, nil
}

func validHistoryID(raw json.RawMessage) bool {
	s := strings.TrimSpace(string(raw))
	if s == "" {
		return false
	}
	if s[0] == '"' {
		var str string
		if json.Unmarshal(raw, &str) != nil {
			return false
		}
		s = str
	}
	if s == "" || len(s) > 20 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

type Holder struct {
	UserID   uuid.UUID
	WriterID string
}

type Counters struct {
	Pushes, Woken, Malformed, ForeignSubscription, Unknown, LinkLimited, Unauthorized, Forbidden atomic.Int64
}

type Waker interface {
	WakeWriter(ctx context.Context, userID uuid.UUID, writerID string, r pushv2.Reason)
}

type QueueingWaker interface {
	TryWakeWriter(ctx context.Context, userID uuid.UUID, writerID string, r pushv2.Reason) bool
}

func ForgetUnrelayedWatches(ctx context.Context, pool *pgxpool.Pool, relayed ...string) error {
	if relayed == nil {
		relayed = []string{}
	}
	if _, err := pool.Exec(ctx,
		`UPDATE mailbox_links SET watch_expires_at = NULL, updated_at = now()
		  WHERE watch_expires_at IS NOT NULL AND provider <> ALL($1)`, relayed); err != nil {
		return fmt.Errorf("gmailpush: forget watches: %w", err)
	}
	return nil
}

type ConfirmingWaker interface {
	TryWakeWriterConfirmed(ctx context.Context, userID uuid.UUID, writerID string, r pushv2.Reason, sent func()) bool
}

const (
	unconfirmedNudgeAge = 12*time.Hour - 14*time.Minute
	confirmNudgeFor     = 5 * time.Second
)

func Nudge(ctx context.Context, pool *pgxpool.Pool, w Waker, providers ...string) (string, error) {
	if len(providers) == 0 {
		return "", nil
	}
	var markAge time.Duration
	cw, confirming := w.(ConfirmingWaker)
	if confirming {
		markAge = unconfirmedNudgeAge
	}
	rows, err := pool.Query(ctx,
		`WITH due AS (
		   SELECT user_id, provider, last_nudge_at FROM mailbox_links
		    WHERE provider = ANY($1)
		      AND (watch_expires_at IS NULL AND created_at < now() - interval '1 hour'
		           OR watch_expires_at < now() + interval '36 hours')
		      AND (last_nudge_at IS NULL OR last_nudge_at < now() - interval '12 hours')
		    LIMIT 500
		    FOR UPDATE SKIP LOCKED)
		 UPDATE mailbox_links m SET last_nudge_at = now() - $2::interval
		   FROM due WHERE m.user_id = due.user_id AND m.provider = due.provider
		 RETURNING m.user_id, m.provider, m.holder_writer_id, due.last_nudge_at, m.last_nudge_at`, providers, markAge)
	if err != nil {
		return "", fmt.Errorf("gmailpush: nudge: %w", err)
	}
	type nudged struct {
		h          Holder
		provider   string
		prev, mark *time.Time
	}
	var due []nudged
	for rows.Next() {
		var n nudged
		if err := rows.Scan(&n.h.UserID, &n.provider, &n.h.WriterID, &n.prev, &n.mark); err != nil {
			rows.Close()
			return "", err
		}
		due = append(due, n)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return "", err
	}
	wake := func(n nudged) bool {
		w.WakeWriter(ctx, n.h.UserID, n.h.WriterID, pushv2.ReasonNudge)
		return true
	}
	if qw, ok := w.(QueueingWaker); ok {
		wake = func(n nudged) bool {
			return qw.TryWakeWriter(ctx, n.h.UserID, n.h.WriterID, pushv2.ReasonNudge)
		}
	}
	if confirming {
		wake = func(n nudged) bool {
			return cw.TryWakeWriterConfirmed(ctx, n.h.UserID, n.h.WriterID, pushv2.ReasonNudge, func() {
				confirmNudge(context.WithoutCancel(ctx), pool, n.h.UserID, n.provider, n.mark)
			})
		}
	}
	sent := 0
	for _, n := range due {
		if wake(n) {
			sent++
			continue
		}
		if _, err := pool.Exec(ctx,
			`UPDATE mailbox_links SET last_nudge_at = $3
			  WHERE user_id = $1 AND provider = $2 AND last_nudge_at = $4`,
			n.h.UserID, n.provider, n.prev, n.mark); err != nil {
			return "", fmt.Errorf("gmailpush: nudge: take back the mark: %w", err)
		}
	}
	if len(due) == 0 {
		return "", nil
	}
	if sent < len(due) {
		return fmt.Sprintf("nudged %d mailbox holder(s); %d not queued", sent, len(due)-sent), nil
	}
	return fmt.Sprintf("nudged %d mailbox holder(s)", sent), nil
}

func confirmNudge(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, provider string, mark *time.Time) {
	ctx, cancel := context.WithTimeout(ctx, confirmNudgeFor)
	defer cancel()
	if _, err := pool.Exec(ctx,
		`UPDATE mailbox_links SET last_nudge_at = now()
		  WHERE user_id = $1 AND provider = $2 AND last_nudge_at = $3`, userID, provider, mark); err != nil {
		slog.Warn("gmailpush: nudge: confirm the mark", "err", err.Error())
	}
}
