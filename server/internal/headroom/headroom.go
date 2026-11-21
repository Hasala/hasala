package headroom

import (
	"errors"
	"log"
	"sync"
	"sync/atomic"
	"time"
)

const (
	DefaultFloor uint64 = 8 << 30

	DefaultInterval = 30 * time.Second
)

type Fuse struct {
	path     string
	floor    uint64
	interval time.Duration

	Sample func(path string) (avail uint64, err error)

	Logf func(format string, args ...any)

	tripped atomic.Bool

	mu   sync.Mutex
	stop chan struct{}
	done chan struct{}
}

func New(path string, floor uint64, interval time.Duration) *Fuse {
	if floor == 0 {
		floor = DefaultFloor
	}
	if interval <= 0 {
		interval = DefaultInterval
	}
	return &Fuse{path: path, floor: floor, interval: interval, Sample: statfsAvail}
}

func (f *Fuse) Floor() uint64 { return f.floor }

func (f *Fuse) Path() string { return f.path }

func (f *Fuse) Tripped() bool {
	if f == nil {
		return false
	}
	return f.tripped.Load()
}

func (f *Fuse) Check() error {
	sample := f.Sample
	if sample == nil {
		sample = statfsAvail
	}
	avail, err := sample(f.path)
	if err != nil {
		f.logf("headroom: statfs %s: %v (the fuse keeps its previous state: tripped=%v)",
			f.path, err, f.tripped.Load())
		return err
	}
	f.set(avail < f.floor, avail)
	return nil
}

func (f *Fuse) set(tripped bool, avail uint64) {
	if was := f.tripped.Swap(tripped); was == tripped {
		return
	}
	if tripped {
		f.logf("headroom: TRIPPED: %s has %d bytes free, below the %d byte floor; "+
			"ALL durable writes are refused, INCLUDING SIGN-IN, until it clears. Reads keep serving.",
			f.path, avail, f.floor)
		return
	}
	f.logf("headroom: cleared: %s has %d bytes free, above the %d byte floor; writes resume.",
		f.path, avail, f.floor)
}

func (f *Fuse) Start() {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.stop != nil {
		return
	}
	_ = f.Check()
	stop, done := make(chan struct{}), make(chan struct{})
	f.stop, f.done = stop, done
	go func() {
		defer close(done)
		t := time.NewTicker(f.interval)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				_ = f.Check()
			}
		}
	}()
}

func (f *Fuse) Stop() {
	f.mu.Lock()
	stop, done := f.stop, f.done
	f.stop, f.done = nil, nil
	f.mu.Unlock()
	if stop == nil {
		return
	}
	close(stop)
	<-done
}

func (f *Fuse) logf(format string, args ...any) {
	if f.Logf != nil {
		f.Logf(format, args...)
		return
	}
	log.Printf(format, args...)
}

var errUnsupported = errors.New("headroom: free-space sampling is not implemented on this platform")
