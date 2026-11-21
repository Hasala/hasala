package banks

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

var ErrBadBank = errors.New("banks: not a bank name")

var ErrListFull = errors.New("banks: the list of other bank names is full")

const MaxOtherKeys = 1000

type Querier interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Begin(ctx context.Context) (pgx.Tx, error)
}

func Text(x string) (string, error) {
	fields := strings.Fields(x)
	s := strings.Join(fields, " ")
	n := 0
	for _, r := range s {
		n++
		switch {
		case unicode.IsLetter(r), unicode.IsMark(r), unicode.Is(unicode.Nd, r), r == ' ':
		case strings.ContainsRune("&.'-()/", r):
		default:
			return "", ErrBadBank
		}
	}
	if n < 1 || n > 64 {
		return "", ErrBadBank
	}
	return s, nil
}

func Key(x string) (string, error) {
	t, err := Text(x)
	if err != nil {
		return "", err
	}
	t = strings.ToLower(t)
	t = strings.Map(func(r rune) rune {
		if strings.ContainsRune(".'-()/", r) {
			return ' '
		}
		return r
	}, t)
	k := strings.Join(strings.Fields(t), " ")
	if k == "" {
		return "", ErrBadBank
	}
	return k, nil
}

type Choice struct {
	Slug      string
	OtherText string
	OtherKey  string
	Supported bool
	Name      string
}

func Catalog(ctx context.Context, q Querier, slug string) (name string, supported, ok bool, err error) {
	var status string
	err = q.QueryRow(ctx, `SELECT name, status FROM banks WHERE slug = $1`, slug).Scan(&name, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, false, nil
	}
	if err != nil {
		return "", false, false, err
	}
	return name, status == "supported", true, nil
}

func Resolve(ctx context.Context, q Querier, bank, otherBank string) (Choice, error) {
	if bank != "other" {
		if otherBank != "" {
			return Choice{}, ErrBadBank
		}
		name, sup, ok, err := Catalog(ctx, q, bank)
		if err != nil {
			return Choice{}, err
		}
		if !ok {
			return Choice{}, ErrBadBank
		}
		return Choice{Slug: bank, Supported: sup, Name: name}, nil
	}
	if otherBank == "" {
		return Choice{Name: "Another bank"}, nil
	}
	text, err := Text(otherBank)
	if err != nil {
		return Choice{}, err
	}
	key, err := Key(otherBank)
	if err != nil {
		return Choice{}, err
	}
	var (
		slug, name, status string
	)
	err = q.QueryRow(ctx, `SELECT slug, name, status FROM banks WHERE slug = $1 OR $1 = ANY(aliases) LIMIT 1`, key).
		Scan(&slug, &name, &status)
	if err == nil {
		return Choice{Slug: slug, Supported: status == "supported", Name: name}, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return Choice{}, err
	}
	return Choice{OtherText: text, OtherKey: key, Name: "Another bank"}, nil
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func Record(ctx context.Context, q Querier, c Choice, userID *uuid.UUID, senderDomain string, now time.Time) error {
	if c.Slug == "" && c.OtherKey == "" {
		return ErrBadBank
	}
	if senderDomain != "" && userID == nil {
		return ErrBadDomain
	}
	if c.Supported {
		return nil
	}
	source := "web"
	if userID != nil {
		source = "app"
	}
	conflict := `ON CONFLICT DO NOTHING`
	if senderDomain != "" {
		conflict = `ON CONFLICT (user_id, (coalesce(bank_slug, 'other:' || other_key))) WHERE user_id IS NOT NULL
		 DO UPDATE SET sender_domain = coalesce(bank_requests.sender_domain, EXCLUDED.sender_domain)`
	}
	tx, err := q.Begin(ctx)
	if err != nil {
		return fmt.Errorf("banks: record: %w", err)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	if c.OtherKey != "" {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('hasala/bank_requests/other_keys'))`); err != nil {
			return fmt.Errorf("banks: lock names: %w", err)
		}
		var known bool
		var distinct int
		if err := tx.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM bank_requests WHERE other_key = $1),
			        (SELECT count(DISTINCT other_key) FROM bank_requests WHERE other_key IS NOT NULL)`,
			c.OtherKey).Scan(&known, &distinct); err != nil {
			return fmt.Errorf("banks: count names: %w", err)
		}
		if !known && distinct >= MaxOtherKeys {
			return ErrListFull
		}
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO bank_requests (bank_slug, other_key, other_text, source, user_id, sender_domain, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7) `+conflict,
		nullable(c.Slug), nullable(c.OtherKey), nullable(c.OtherText), source, userID, nullable(senderDomain), now); err != nil {
		return fmt.Errorf("banks: record: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("banks: record: %w", err)
	}
	return nil
}
