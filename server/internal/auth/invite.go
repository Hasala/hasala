package auth

import (
	"context"
	"crypto/sha256"
	"fmt"
	"time"

	"github.com/salehtl/hasala/server/internal/invites"
)

var ErrNotInvited = invites.ErrNotInvited

func NormalizeInviteCode(raw string) string { return invites.Normalize(raw) }

func InviteCodeHash(code string) []byte { return invites.CodeHash(code) }

type MintOptions struct {
	Note     string
	TTL      time.Duration
	Review   bool
	EmailTag []byte
	LinkKey  []byte
	Now      time.Time
}

func MintInvite(ctx context.Context, q queryExecer, o MintOptions) (string, error) {
	code, err := invites.NewCode()
	if err != nil {
		return "", fmt.Errorf("auth: MintInvite: %w", err)
	}
	ttl := o.TTL
	if ttl == 0 {
		ttl = invites.DefaultTTL
	}
	now := o.Now
	if now.IsZero() {
		now = time.Now()
	}
	var note, tag, link any
	if o.Note != "" {
		note = o.Note
	}
	if len(o.EmailTag) > 0 {
		tag = o.EmailTag
	}
	if len(o.LinkKey) > 0 {
		h := sha256.Sum256(o.LinkKey)
		link = h[:]
	}
	if _, err := q.Exec(ctx,
		`INSERT INTO invite_codes (code_hash, link_key_hash, email_tag, origin, review, state, note, ttl,
		   created_at, minted_at, expires_at, mint_count)
		 VALUES ($1, $2, $3, 'cli', $4, 'active', $5, $6, $7, $7, $8, 1)`,
		InviteCodeHash(code), link, tag, o.Review, note, ttl, now, now.Add(ttl)); err != nil {
		return "", fmt.Errorf("auth: MintInvite: %w", err)
	}
	return code, nil
}
