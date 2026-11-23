package googlejwt

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	jose "github.com/go-jose/go-jose/v4"
)

const maxJWKSBytes = 256 << 10

const jwksFetchTimeout = 10 * time.Second

const jwksRefresh = time.Minute

const jwksStaleMax = time.Hour

type cachingKeySet struct {
	jwksURL  string
	refresh  time.Duration
	staleMax time.Duration
	now      func() time.Time

	mu          sync.Mutex
	inflight    *inflightFetch
	keys        []jose.JSONWebKey
	fetchedAt   time.Time
	attemptedAt time.Time
}

var keySetAlgs = []jose.SignatureAlgorithm{jose.RS256}

func (r *cachingKeySet) VerifySignature(ctx context.Context, jwt string) ([]byte, error) {
	jws, err := jose.ParseSigned(jwt, keySetAlgs)
	if err != nil {
		return nil, fmt.Errorf("parse jws: %w", err)
	}
	if len(jws.Signatures) != 1 {
		return nil, fmt.Errorf("id token carries %d signatures, want exactly 1", len(jws.Signatures))
	}
	kid := jws.Signatures[0].Header.KeyID

	keys, err := r.currentKeys(ctx)
	if err != nil {
		return nil, err
	}
	for i := range keys {
		key := keys[i]
		if key.Use != "" && key.Use != "sig" {
			continue
		}
		if kid != "" && key.KeyID != kid {
			continue
		}
		if payload, err := jws.Verify(&key); err == nil {
			return payload, nil
		}
	}
	return nil, fmt.Errorf("no key published at %s verifies this token (kid %q)", r.jwksURL, kid)
}

func (r *cachingKeySet) currentKeys(ctx context.Context) ([]jose.JSONWebKey, error) {
	if keys, ok := r.freshKeys(); ok {
		return keys, nil
	}

	r.mu.Lock()
	if r.inflight == nil {
		if !r.attemptedAt.IsZero() && r.now().Sub(r.attemptedAt) < r.refresh {
			r.mu.Unlock()
			return r.staleKeys()
		}
		fl := &inflightFetch{done: make(chan struct{})}
		r.inflight = fl
		go r.fetch(context.WithoutCancel(ctx), fl)
	}
	fl := r.inflight
	r.mu.Unlock()

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-fl.done:
	}
	if fl.err != nil {
		return r.staleKeys()
	}
	return fl.keys, nil
}

type inflightFetch struct {
	done chan struct{}
	keys []jose.JSONWebKey
	err  error
}

func (r *cachingKeySet) fetch(ctx context.Context, fl *inflightFetch) {
	fetchCtx, cancel := context.WithTimeout(ctx, jwksFetchTimeout)
	defer cancel()
	keys, err := fetchJWKS(fetchCtx, r.jwksURL)
	fl.keys, fl.err = keys, err

	now := r.now()
	r.mu.Lock()
	switch {
	case err == nil:
		r.keys, r.fetchedAt, r.attemptedAt = keys, now, now
	case errors.Is(err, context.Canceled):
	default:
		r.attemptedAt = now
	}
	r.inflight = nil
	r.mu.Unlock()
	close(fl.done)
}

func (r *cachingKeySet) freshKeys() ([]jose.JSONWebKey, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.keys == nil {
		return nil, false
	}
	return r.keys, r.now().Sub(r.fetchedAt) < r.refresh
}

func (r *cachingKeySet) staleKeys() ([]jose.JSONWebKey, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.keys == nil {
		return nil, fmt.Errorf("jwks %s is unavailable and nothing is cached", r.jwksURL)
	}
	if age := r.now().Sub(r.fetchedAt); age >= r.staleMax {
		return nil, fmt.Errorf("jwks %s could not be refreshed for %s, which exceeds the %s limit",
			r.jwksURL, age, r.staleMax)
	}
	return r.keys, nil
}

func fetchJWKS(ctx context.Context, url string) ([]jose.JSONWebKey, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("jwks %s: %s", url, resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxJWKSBytes))
	if err != nil {
		return nil, fmt.Errorf("jwks %s: %w", url, err)
	}
	var set jose.JSONWebKeySet
	if err := json.Unmarshal(body, &set); err != nil {
		return nil, fmt.Errorf("jwks %s: %w", url, err)
	}
	if len(set.Keys) == 0 {
		return nil, fmt.Errorf("jwks %s: no keys", url)
	}
	return set.Keys, nil
}
