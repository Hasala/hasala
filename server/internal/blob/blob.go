package blob

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/google/uuid"
)

const (
	NonceSize = 12
	TagSize   = 16

	MaxPlaintext = 2 << 20

	aadSeparator = "|"
)

const StreamHot = "hot"

var Buckets = []int{1 << 10, 4 << 10, 16 << 10, 64 << 10, 256 << 10, 512 << 10, 1024 << 10}

const MaxBucket = 1 << 20

var (
	ErrMalformed       = errors.New("blob: malformed")
	ErrTooLarge        = errors.New("blob exceeds the largest size bucket")
	ErrInvalidEnvelope = errors.New("invalid blob envelope")
)

func BucketFor(n int) (int, error) {
	if n < 0 {
		return 0, fmt.Errorf("%w: negative length %d", ErrMalformed, n)
	}
	for _, b := range Buckets {
		if n <= b {
			return b, nil
		}
	}
	return 0, fmt.Errorf("%w: %d bytes exceeds %d", ErrTooLarge, n, MaxBucket)
}

func IsBucket(n int) bool {
	for _, b := range Buckets {
		if n == b {
			return true
		}
	}
	return false
}

type Envelope struct {
	UserID        uuid.UUID
	Stream        string
	WriterID      string
	WriterCounter int64
}

func (e Envelope) AAD() []byte {
	return []byte(strings.Join([]string{
		e.UserID.String(),
		e.Stream,
		e.WriterID,
		strconv.FormatInt(e.WriterCounter, 10),
	}, aadSeparator))
}

func (e Envelope) Validate() error {
	switch {
	case e.UserID == uuid.Nil:
		return fmt.Errorf("%w: user_id is zero", ErrInvalidEnvelope)
	case e.Stream != StreamHot:
		return fmt.Errorf("%w: stream is %q, want %q", ErrInvalidEnvelope, e.Stream, StreamHot)
	case e.WriterID == "":
		return fmt.Errorf("%w: writer_id is empty", ErrInvalidEnvelope)
	case e.WriterCounter < 1:
		return fmt.Errorf("%w: writer_counter is %d, and counters are 1-based", ErrInvalidEnvelope, e.WriterCounter)
	case strings.Contains(e.WriterID, aadSeparator):
		return fmt.Errorf("%w: writer_id may not contain %q", ErrInvalidEnvelope, aadSeparator)
	}
	if l := len(e.AAD()); l+minTail > Buckets[0] || l > 0xFFFF {
		return fmt.Errorf("%w: an AAD of %d bytes does not fit the smallest bucket", ErrInvalidEnvelope, l)
	}
	return nil
}

type Sealed struct {
	Bytes      []byte
	SizeBucket int
}

var ZeroHash [32]byte

func Hash(prev [32]byte, s Sealed) [32]byte {
	h := sha256.New()
	h.Write(prev[:])
	h.Write(s.Bytes)
	var out [32]byte
	copy(out[:], h.Sum(nil))
	return out
}
