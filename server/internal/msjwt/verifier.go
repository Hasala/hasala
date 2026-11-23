package msjwt

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/salehtl/hasala/server/internal/googlejwt"
)

const (
	ConsumersTenantID = "9188040d-6c67-4c5b-b112-36a304b66dad"
	ConsumersIssuer   = "https://login.microsoftonline.com/" + ConsumersTenantID + "/v2.0"
	ConsumersJWKSURL  = "https://login.microsoftonline.com/consumers/discovery/v2.0/keys"
)

var (
	ErrTokenRejected     = googlejwt.ErrTokenRejected
	ErrKeySetUnavailable = googlejwt.ErrKeySetUnavailable
	ErrMalformed         = googlejwt.ErrMalformed
	ErrTenant            = fmt.Errorf("%w: not the consumers tenant", ErrTokenRejected)
)

type Verifier struct {
	Audience string
	JWKSURL  string
	Now      func() time.Time

	once  sync.Once
	inner *googlejwt.Verifier
}

type Claims struct {
	Tid, Oid, Sub, Email, PreferredUsername, Nonce string
	Aud                                            []string
	Iat                                            time.Time
}

func (v *Verifier) init() {
	jwks := v.JWKSURL
	if jwks == "" {
		jwks = ConsumersJWKSURL
	}
	v.inner = &googlejwt.Verifier{
		Issuers:  []string{ConsumersIssuer},
		Audience: v.Audience,
		JWKSURL:  jwks,
		Now:      v.Now,
	}
}

func (v *Verifier) Verify(ctx context.Context, token string) (Claims, error) {
	v.once.Do(v.init)
	g, err := v.inner.Verify(ctx, token)
	if err != nil {
		return Claims{}, err
	}
	var ms struct {
		Tid               string `json:"tid"`
		Oid               string `json:"oid"`
		PreferredUsername string `json:"preferred_username"`
	}
	parts := strings.Split(token, ".")
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || json.Unmarshal(raw, &ms) != nil {
		return Claims{}, fmt.Errorf("%w: verified payload", ErrMalformed)
	}
	if ms.Tid != ConsumersTenantID {
		return Claims{}, fmt.Errorf("%w: tid %q", ErrTenant, ms.Tid)
	}
	return Claims{
		Tid: ms.Tid, Oid: ms.Oid, Sub: g.Sub, Email: g.Email, PreferredUsername: ms.PreferredUsername, Nonce: g.Nonce,
		Aud: g.Aud, Iat: g.Iat,
	}, nil
}

func (c Claims) Address() string {
	if c.Email != "" {
		return c.Email
	}
	if strings.Contains(c.PreferredUsername, "@") {
		return c.PreferredUsername
	}
	return ""
}
