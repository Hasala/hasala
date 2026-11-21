package headroom

import (
	"errors"
	"sync"
	"testing"
	"time"
)

type sampler struct {
	mu    sync.Mutex
	avail uint64
	err   error
	calls int
	paths []string
}

func (s *sampler) read(path string) (uint64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	s.paths = append(s.paths, path)
	return s.avail, s.err
}

func (s *sampler) set(avail uint64, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.avail, s.err = avail, err
}

func (s *sampler) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

func newFuse(t *testing.T, floor uint64, s *sampler) *Fuse {
	t.Helper()
	f := New("/scratch", floor, time.Hour)
	f.Sample = s.read
	f.Logf = func(string, ...any) {}
	return f
}

func TestTheFuseTripsBelowTheFloorAndClearsAboveIt(t *testing.T) {
	s := &sampler{avail: 100}
	f := newFuse(t, 1000, s)

	if f.Tripped() {
		t.Fatal("a fuse that has never sampled is tripped; it must start open")
	}
	if err := f.Check(); err != nil {
		t.Fatalf("Check: %v", err)
	}
	if !f.Tripped() {
		t.Fatal("100 bytes free against a 1000 byte floor did not trip the fuse")
	}

	s.set(1000, nil)
	if err := f.Check(); err != nil {
		t.Fatalf("Check: %v", err)
	}
	if f.Tripped() {
		t.Fatal("exactly the floor is not BELOW the floor; the fuse must be clear")
	}

	s.set(999, nil)
	if err := f.Check(); err != nil {
		t.Fatalf("Check: %v", err)
	}
	if !f.Tripped() {
		t.Fatal("one byte below the floor did not trip the fuse")
	}

	s.set(1<<40, nil)
	if err := f.Check(); err != nil {
		t.Fatalf("Check: %v", err)
	}
	if f.Tripped() {
		t.Fatal("the fuse stayed tripped with a terabyte free")
	}
}

func TestASamplingFailureKeepsThePreviousState(t *testing.T) {
	s := &sampler{avail: 10}
	f := newFuse(t, 1000, s)
	if err := f.Check(); err != nil {
		t.Fatalf("Check: %v", err)
	}
	if !f.Tripped() {
		t.Fatal("setup: the fuse should be tripped")
	}

	boom := errors.New("statfs exploded")
	s.set(1<<40, boom)
	if err := f.Check(); !errors.Is(err, boom) {
		t.Fatalf("Check returned %v, want the sampling error", err)
	}
	if !f.Tripped() {
		t.Fatal("a failed sample CLEARED the fuse; an unmeasured disk must not read as headroom")
	}

	s.set(1<<40, nil)
	if err := f.Check(); err != nil {
		t.Fatalf("Check: %v", err)
	}
	if f.Tripped() {
		t.Fatal("setup: the fuse should be clear")
	}
	s.set(0, boom)
	if err := f.Check(); !errors.Is(err, boom) {
		t.Fatalf("Check returned %v, want the sampling error", err)
	}
	if f.Tripped() {
		t.Fatal("a failed sample TRIPPED the fuse; a stat error must not stop every write on the box")
	}
}

func TestStartSamplesBeforeTheFirstTick(t *testing.T) {
	s := &sampler{avail: 0}
	f := newFuse(t, 1000, s)
	f.Start()
	defer f.Stop()
	if !f.Tripped() {
		t.Fatal("Start did not sample synchronously: the fuse was open on a full disk")
	}
	if got := s.count(); got != 1 {
		t.Fatalf("sampled %d times, want exactly 1", got)
	}
	if s.paths[0] != "/scratch" {
		t.Fatalf("sampled %q, want the path the fuse was constructed with", s.paths[0])
	}
}

func TestTheFuseKeepsSamplingUntilStopped(t *testing.T) {
	s := &sampler{avail: 1 << 40}
	f := New("/scratch", 1000, time.Millisecond)
	f.Sample = s.read
	f.Logf = func(string, ...any) {}
	f.Start()

	s.set(0, nil)
	deadline := time.Now().Add(2 * time.Second)
	for !f.Tripped() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !f.Tripped() {
		t.Fatal("the fuse never re-sampled: it stayed open after the disk filled")
	}

	f.Stop()
	before := s.count()
	time.Sleep(20 * time.Millisecond)
	if after := s.count(); after != before {
		t.Fatalf("the fuse sampled %d more times after Stop", after-before)
	}
	if !f.Tripped() {
		t.Fatal("Stop cleared the fuse")
	}
	f.Stop()
}

func TestStartIsIdempotent(t *testing.T) {
	s := &sampler{avail: 1 << 40}
	f := newFuse(t, 1000, s)
	f.Start()
	f.Start()
	defer f.Stop()
	if got := s.count(); got != 1 {
		t.Fatalf("sampled %d times after two Starts, want 1", got)
	}
}

func TestANilFuseIsNeverTripped(t *testing.T) {
	var f *Fuse
	if f.Tripped() {
		t.Fatal("a nil fuse reported tripped")
	}
}

func TestNewAppliesTheDefaults(t *testing.T) {
	f := New("/", 0, 0)
	if f.Floor() != DefaultFloor {
		t.Fatalf("floor = %d, want %d", f.Floor(), DefaultFloor)
	}
	if f.interval != DefaultInterval {
		t.Fatalf("interval = %v, want %v", f.interval, DefaultInterval)
	}
	if DefaultFloor != 8<<30 {
		t.Fatalf("DefaultFloor = %d, want the design's 8 GB", DefaultFloor)
	}
	if f.Path() != "/" {
		t.Fatalf("path = %q", f.Path())
	}
}

func TestTheRealSamplerReadsAFilesystem(t *testing.T) {
	avail, err := statfsAvail(t.TempDir())
	if err != nil {
		t.Fatalf("statfsAvail: %v", err)
	}
	if avail == 0 {
		t.Fatal("statfsAvail reported 0 bytes available on the test temp dir")
	}
}
