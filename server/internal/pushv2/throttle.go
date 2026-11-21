package pushv2

import (
	"container/list"
	"time"

	"github.com/google/uuid"
)

const (
	mailWindow      = 300 * time.Second
	syncWindow      = 120 * time.Second
	capWindow       = time.Hour
	mailCap         = 6
	totalCap        = 12
	cooldownFor     = 60 * time.Second
	throttleMaxKeys = 10_000
)

type tokenState struct {
	key       string
	t         Target
	windowEnd map[Reason]time.Time
	pending   map[Reason]bool
	owner     map[Reason]uuid.UUID
	mailSends []time.Time
	allSends  []time.Time
	coolUntil time.Time
	elem      *list.Element
}

type throttle struct {
	states map[string]*tokenState
	lru    *list.List
}

func newThrottle() *throttle {
	return &throttle{states: map[string]*tokenState{}, lru: list.New()}
}

type decision uint8

const (
	sendNow decision = iota + 1
	deferred
	dropCap
	dropCool
)

func windowFor(r Reason) time.Duration {
	switch r {
	case ReasonMail:
		return mailWindow
	case ReasonSync:
		return syncWindow
	}
	return 0
}

func tokenKey(t Target) string { return t.Environment + ":" + t.TokenHex }

func exempt(r Reason) bool { return r == ReasonSecurity || r == ReasonAccountGone }

func (th *throttle) state(t Target) *tokenState {
	key := tokenKey(t)
	if s, ok := th.states[key]; ok {
		th.lru.MoveToFront(s.elem)
		return s
	}
	s := &tokenState{key: key, t: t, windowEnd: map[Reason]time.Time{}, pending: map[Reason]bool{},
		owner: map[Reason]uuid.UUID{}}
	s.elem = th.lru.PushFront(s)
	th.states[key] = s
	for th.lru.Len() > throttleMaxKeys {
		old := th.lru.Back()
		th.lru.Remove(old)
		delete(th.states, old.Value.(*tokenState).key)
	}
	return s
}

func prune(ts []time.Time, now time.Time) []time.Time {
	i := 0
	for i < len(ts) && now.Sub(ts[i]) >= capWindow {
		i++
	}
	return ts[i:]
}

func (s *tokenState) capped(r Reason, now time.Time) bool {
	s.mailSends = prune(s.mailSends, now)
	s.allSends = prune(s.allSends, now)
	if exempt(r) {
		return false
	}
	if r == ReasonMail && len(s.mailSends) >= mailCap {
		return true
	}
	return len(s.allSends) >= totalCap
}

func (s *tokenState) count(r Reason, now time.Time) {
	if exempt(r) {
		return
	}
	if r == ReasonMail {
		s.mailSends = append(s.mailSends, now)
	}
	s.allSends = append(s.allSends, now)
}

func (th *throttle) admit(t Target, r Reason, now time.Time, owner uuid.UUID) decision {
	s := th.state(t)
	if !exempt(r) && now.Before(s.coolUntil) {
		return dropCool
	}
	if w := windowFor(r); w > 0 {
		if end, ok := s.windowEnd[r]; ok && now.Before(end) {
			s.pending[r] = true
			s.owner[r] = owner
			return deferred
		}
		if s.capped(r, now) {
			return dropCap
		}
		s.windowEnd[r] = now.Add(w)
		s.pending[r] = false
		s.count(r, now)
		return sendNow
	}
	if s.capped(r, now) {
		return dropCap
	}
	s.count(r, now)
	return sendNow
}

type trailing struct {
	t     Target
	r     Reason
	owner uuid.UUID
}

func (th *throttle) due(now time.Time, paused func(Target) bool) (out []trailing, dropped []Reason) {
	for _, s := range th.states {
		for r, end := range s.windowEnd {
			if now.Before(end) {
				continue
			}
			delete(s.windowEnd, r)
			if !s.pending[r] {
				continue
			}
			s.pending[r] = false
			if paused(s.t) || now.Before(s.coolUntil) || s.capped(r, now) {
				dropped = append(dropped, r)
				continue
			}
			s.windowEnd[r] = now.Add(windowFor(r))
			out = append(out, trailing{t: s.t, r: r, owner: s.owner[r]})
		}
	}
	return out, dropped
}

func (th *throttle) charge(w trailing, now time.Time) bool {
	s, ok := th.states[tokenKey(w.t)]
	if !ok || s.capped(w.r, now) {
		return false
	}
	s.count(w.r, now)
	return true
}

func (th *throttle) cool(t Target, now time.Time) {
	th.state(t).coolUntil = now.Add(cooldownFor)
}

func (th *throttle) forget(t Target) {
	key := tokenKey(t)
	if s, ok := th.states[key]; ok {
		th.lru.Remove(s.elem)
		delete(th.states, key)
	}
}
