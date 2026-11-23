package api

import (
	"sync"
	"time"
)

type Limiter struct {
	rate        float64
	burst       float64
	maxKeys     int
	prefixQuota int
	now         func() time.Time

	mu         sync.Mutex
	buckets    map[string]*bucket
	prefixKeys map[string]int
	nextSweep  time.Time
	fallback   bucket
}

type bucket struct {
	tokens float64
	last   time.Time
}

func NewLimiter(rate, burst float64, maxKeys int, now func() time.Time) *Limiter {
	if now == nil {
		now = time.Now
	}
	if burst < 1 {
		burst = 1
	}
	if maxKeys < 1 {
		maxKeys = 1
	}
	return &Limiter{
		rate:    rate,
		burst:   burst,
		maxKeys: maxKeys,
		now:     now,
		buckets: make(map[string]*bucket),
	}
}

const prefixQuotaShare = 64

func NewClientLimiter(rate, burst float64, maxKeys int, now func() time.Time) *Limiter {
	l := NewLimiter(rate, burst, maxKeys, now)
	l.prefixQuota = max(l.maxKeys/prefixQuotaShare, 1)
	l.prefixKeys = make(map[string]int)
	return l
}

func (l *Limiter) Allow(key string) bool { return l.AllowN(key, 1) }

func (l *Limiter) AllowN(key string, n float64) bool {
	if l == nil {
		return true
	}
	if n < 1 {
		n = 1
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()

	b, ok := l.buckets[key]
	if !ok && l.prefixQuota > 0 {
		key = l.keyWithinQuota(key, now)
		b, ok = l.buckets[key]
	}
	if !ok {
		if len(l.buckets) >= l.maxKeys {
			l.sweep(now)
		}
		if len(l.buckets) >= l.maxKeys {
			return take(&l.fallback, l.rate, l.burst, now, n)
		}
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
		if p, ok := prefixKey(key); ok && l.prefixQuota > 0 {
			l.prefixKeys[p]++
		}
	}
	return take(b, l.rate, l.burst, now, n)
}

func (l *Limiter) keyWithinQuota(key string, now time.Time) string {
	p, ok := prefixKey(key)
	if !ok || l.prefixKeys[p] < l.prefixQuota {
		return key
	}
	if l.rate > 0 && !now.Before(l.nextSweep) {
		l.sweep(now)
		l.nextSweep = now.Add(time.Duration(l.burst / l.rate * float64(time.Second)))
	}
	if l.prefixKeys[p] < l.prefixQuota {
		return key
	}
	return p
}

func (l *Limiter) RefundN(key string, n float64) {
	if l == nil {
		return
	}
	if n < 1 {
		n = 1
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.buckets[key]
	if !ok {
		b = &l.fallback
		if b.last.IsZero() {
			return
		}
	}
	b.tokens += n
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
}

func (s *Server) ensureLimiter(l **Limiter, rate, burst float64, keys int) {
	if *l == nil {
		*l = NewLimiter(rate, burst, keys, s.now)
	}
}

func (s *Server) ensureClientLimiter(l **Limiter, rate, burst float64, keys int) {
	if *l == nil {
		*l = NewClientLimiter(rate, burst, keys, s.now)
	}
}

func take(b *bucket, rate, burst float64, now time.Time, n float64) bool {
	if b.last.IsZero() {
		b.tokens, b.last = burst, now
	}
	if elapsed := now.Sub(b.last).Seconds(); elapsed > 0 {
		b.tokens += elapsed * rate
		if b.tokens > burst {
			b.tokens = burst
		}
		b.last = now
	}
	if b.tokens < n {
		return false
	}
	b.tokens -= n
	return true
}

func (l *Limiter) sweep(now time.Time) {
	for k, b := range l.buckets {
		refilled := b.tokens + now.Sub(b.last).Seconds()*l.rate
		if refilled >= l.burst {
			l.forget(k)
		}
	}
}

func (l *Limiter) forget(key string) {
	delete(l.buckets, key)
	p, ok := prefixKey(key)
	if !ok {
		return
	}
	switch l.prefixKeys[p] {
	case 0:
	case 1:
		delete(l.prefixKeys, p)
	default:
		l.prefixKeys[p]--
	}
}
