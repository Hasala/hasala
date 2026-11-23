package mail

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"sync"
)

type Message struct {
	To, Subject, Text, HTML string
	Unsubscribe             string
}

type Sender interface {
	Send(ctx context.Context, m Message) (providerID string, err error)
}

var (
	ErrPermanent = errors.New("mail: refused permanently")
	ErrBounced   = errors.New("mail: the recipient is a permanent bounce")
	ErrAuth      = errors.New("mail: the provider refused the credentials")
)

var ErrNotConfigured = fmt.Errorf("%w: not configured", ErrPermanent)

type Unconfigured struct{}

func (Unconfigured) Send(context.Context, Message) (string, error) { return "", ErrNotConfigured }

type Fake struct {
	mu     sync.Mutex
	sent   []Message
	Err    error
	ErrFor func(Message) error
	Max    int
}

func (f *Fake) Send(_ context.Context, m Message) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.Err != nil {
		return "", f.Err
	}
	if f.ErrFor != nil {
		if err := f.ErrFor(m); err != nil {
			return "", err
		}
	}
	f.sent = append(f.sent, m)
	n := len(f.sent)
	if f.Max > 0 && len(f.sent) > f.Max {
		f.sent = append([]Message(nil), f.sent[len(f.sent)-f.Max:]...)
	}
	return "fake-" + strconv.Itoa(n), nil
}

func (f *Fake) Sent() []Message {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Message(nil), f.sent...)
}

func (f *Fake) To(addr string) []Message {
	var out []Message
	for _, m := range f.Sent() {
		if m.To == addr {
			out = append(out, m)
		}
	}
	return out
}

func (f *Fake) Reset() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = nil
}
