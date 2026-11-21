package outlookpush

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"sync/atomic"
)

const MaxValidationToken = 256

const MaxEntries = 100

const clientStateLen = 43

func ValidToken(tok string) bool {
	if tok == "" || len(tok) > MaxValidationToken {
		return false
	}
	for i := 0; i < len(tok); i++ {
		if tok[i] < 0x20 || tok[i] > 0x7e {
			return false
		}
	}
	return true
}

const (
	EventReauthorizationRequired = "reauthorizationRequired"
	EventSubscriptionRemoved     = "subscriptionRemoved"
	EventMissed                  = "missed"
)

var ErrMalformed = errors.New("outlookpush: malformed notification")

type Parsed struct {
	Hashes         [][sha256.Size]byte
	BadClientState int
	Ignored        int
	Removed        [][sha256.Size]byte
	Reauthorize    [][sha256.Size]byte
}

type entry struct {
	ClientState    *string `json:"clientState"`
	LifecycleEvent string  `json:"lifecycleEvent"`
}

func Parse(body []byte, lifecycle bool) (Parsed, error) {
	var env struct {
		Value []json.RawMessage `json:"value"`
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	if err := dec.Decode(&env); err != nil {
		return Parsed{}, ErrMalformed
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return Parsed{}, ErrMalformed
	}
	if len(env.Value) == 0 || len(env.Value) > MaxEntries {
		return Parsed{}, ErrMalformed
	}
	var p Parsed
	seen := make(map[[sha256.Size]byte]bool, len(env.Value))
	removed := make(map[[sha256.Size]byte]bool)
	reauthorize := make(map[[sha256.Size]byte]bool)
	for _, raw := range env.Value {
		var e entry
		if err := json.Unmarshal(raw, &e); err != nil {
			p.BadClientState++
			continue
		}
		if lifecycle && !wakes(e.LifecycleEvent) {
			p.Ignored++
			continue
		}
		if e.ClientState == nil || !wellFormed(*e.ClientState) {
			p.BadClientState++
			continue
		}
		h := sha256.Sum256([]byte(*e.ClientState))
		if !seen[h] {
			seen[h] = true
			p.Hashes = append(p.Hashes, h)
		}
		if lifecycle && e.LifecycleEvent == EventSubscriptionRemoved && !removed[h] {
			removed[h] = true
			p.Removed = append(p.Removed, h)
		}
		if lifecycle && e.LifecycleEvent == EventReauthorizationRequired && !reauthorize[h] {
			reauthorize[h] = true
			p.Reauthorize = append(p.Reauthorize, h)
		}
	}
	return p, nil
}

func wakes(event string) bool {
	switch event {
	case EventReauthorizationRequired, EventSubscriptionRemoved, EventMissed:
		return true
	}
	return false
}

func wellFormed(cs string) bool {
	if len(cs) != clientStateLen {
		return false
	}
	for i := 0; i < len(cs); i++ {
		c := cs[i]
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

type Counters struct {
	Validations, BadValidation, ValidationWithBody       atomic.Int64
	Notifications, Malformed                             atomic.Int64
	BadClientState, Unknown, LinkLimited, Ignored, Woken atomic.Int64
}
