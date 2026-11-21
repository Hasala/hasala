package authkeys

import (
	"context"
	"errors"
	"sync"
	"time"
)

var ErrGateBusy = errors.New("authkeys: the password hash gate is busy")

const (
	DefaultGateQueue = 16
	DefaultGateWait  = 2 * time.Second
)

type Gate struct {
	queue int
	wait  time.Duration

	mu      sync.Mutex
	free    int
	waiters []chan struct{}
}

func NewGate(concurrency, queue int, wait time.Duration) *Gate {
	if concurrency < 1 {
		concurrency = 1
	}
	if queue < 0 {
		queue = DefaultGateQueue
	}
	if wait <= 0 {
		wait = DefaultGateWait
	}
	return &Gate{free: concurrency, queue: queue, wait: wait}
}

func (g *Gate) Acquire(ctx context.Context) (release func(), err error) {
	if g == nil {
		return func() {}, nil
	}
	g.mu.Lock()
	if g.free > 0 && len(g.waiters) == 0 {
		g.free--
		g.mu.Unlock()
		return g.releaser(), nil
	}
	if len(g.waiters) >= g.queue {
		g.mu.Unlock()
		return nil, ErrGateBusy
	}
	ch := make(chan struct{})
	g.waiters = append(g.waiters, ch)
	g.mu.Unlock()

	t := time.NewTimer(g.wait)
	defer t.Stop()
	var why error
	select {
	case <-ch:
		return g.releaser(), nil
	case <-t.C:
		why = ErrGateBusy
	case <-ctx.Done():
		why = ctx.Err()
	}
	g.mu.Lock()
	for i, w := range g.waiters {
		if w == ch {
			g.waiters = append(g.waiters[:i], g.waiters[i+1:]...)
			g.mu.Unlock()
			return nil, why
		}
	}
	g.mu.Unlock()
	g.releaser()()
	return nil, why
}

func (g *Gate) releaser() func() {
	var once sync.Once
	return func() {
		once.Do(func() {
			g.mu.Lock()
			defer g.mu.Unlock()
			if len(g.waiters) > 0 {
				ch := g.waiters[0]
				g.waiters = g.waiters[1:]
				close(ch)
				return
			}
			g.free++
		})
	}
}

func (g *Gate) Do(ctx context.Context, f func() error) error {
	release, err := g.Acquire(ctx)
	if err != nil {
		return err
	}
	defer release()
	return f()
}

func (k *Keys) HashGated(ctx context.Context, g *Gate, s, pwSalt []byte, generation int) ([]byte, error) {
	var out []byte
	err := g.Do(ctx, func() error {
		var err error
		out, err = k.VerifierHash(s, pwSalt, generation)
		return err
	})
	return out, err
}
