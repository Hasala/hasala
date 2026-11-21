package blobtest

import (
	"bytes"
	"compress/gzip"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"github.com/salehtl/hasala/server/internal/blob"
)

type (
	Envelope = blob.Envelope
	Sealed   = blob.Sealed
)

const (
	Version = 1

	versionSize    = 1
	aadLenSize     = 2
	payloadLenSize = 4

	NonceSize = blob.NonceSize
	TagSize   = blob.TagSize

	MaxPlaintext = blob.MaxPlaintext

	aadSeparator = "|"
)

const StreamCold = "cold"

const StreamHot = blob.StreamHot

var (
	ErrSetAside           = errors.New("blob cannot be opened")
	ErrUnsupportedVersion = fmt.Errorf("%w: unsupported envelope version", ErrSetAside)
	ErrAADMismatch        = fmt.Errorf("%w: associated data mismatch", ErrSetAside)
	ErrMalformed          = fmt.Errorf("%w: malformed envelope", ErrSetAside)
	ErrTooLarge           = blob.ErrTooLarge
	ErrInvalidEnvelope    = blob.ErrInvalidEnvelope
)

func validateV1(e Envelope) error {
	if e.Stream == StreamCold {
		e.Stream = blob.StreamHot
	}
	if err := e.Validate(); err != nil {
		return err
	}
	if n := overhead(len(e.AAD())); n > blob.Buckets[0] {
		return fmt.Errorf("%w: framing overhead %d does not fit the smallest bucket", ErrInvalidEnvelope, n)
	}
	return nil
}

func BucketFor(n int) (int, error) { return blob.BucketFor(n) }

type Sealer interface {
	Seal(e Envelope, plaintext []byte) (Sealed, error)
	Open(e Envelope, s Sealed) ([]byte, error)
}

type PlaintextSealer struct{}

var _ Sealer = PlaintextSealer{}

func overhead(aadLen int) int {
	return versionSize + aadLenSize + aadLen + NonceSize + payloadLenSize + TagSize
}

func SealedRegion(b []byte) (start, end int, err error) {
	if len(b) < versionSize+aadLenSize {
		return 0, 0, fmt.Errorf("%w: %d bytes is shorter than the header", ErrMalformed, len(b))
	}
	aadLen := int(binary.BigEndian.Uint16(b[versionSize : versionSize+aadLenSize]))
	start = versionSize + aadLenSize + aadLen + NonceSize
	end = len(b) - TagSize
	if end < start+payloadLenSize {
		return 0, 0, fmt.Errorf("%w: aadLen %d leaves no room for a payload", ErrMalformed, aadLen)
	}
	return start, end, nil
}

func EmbeddedAAD(b []byte) ([]byte, error) {
	start, _, err := SealedRegion(b)
	if err != nil {
		return nil, err
	}
	return b[versionSize+aadLenSize : start-NonceSize], nil
}

func (PlaintextSealer) Seal(e Envelope, plaintext []byte) (Sealed, error) {
	if err := validateV1(e); err != nil {
		return Sealed{}, err
	}
	if len(plaintext) > MaxPlaintext {
		return Sealed{}, fmt.Errorf("%w: plaintext is %d bytes, cap is %d", ErrTooLarge, len(plaintext), MaxPlaintext)
	}
	aad := e.AAD()

	payload, err := compress(plaintext)
	if err != nil {
		return Sealed{}, err
	}
	bucket, err := blob.BucketFor(overhead(len(aad)) + len(payload))
	if err != nil {
		return Sealed{}, err
	}

	out := make([]byte, bucket)
	out[0] = Version
	binary.BigEndian.PutUint16(out[versionSize:versionSize+aadLenSize], uint16(len(aad)))
	copy(out[versionSize+aadLenSize:], aad)

	start, end, err := SealedRegion(out)
	if err != nil {
		return Sealed{}, err
	}
	region := out[start:end]
	binary.BigEndian.PutUint32(region[:payloadLenSize], uint32(len(payload)))
	copy(region[payloadLenSize:], payload)

	return Sealed{Bytes: out, SizeBucket: bucket}, nil
}

func (PlaintextSealer) Open(e Envelope, s Sealed) ([]byte, error) {
	if err := validateV1(e); err != nil {
		return nil, err
	}
	b := s.Bytes
	if s.SizeBucket != 0 && s.SizeBucket != len(b) {
		return nil, fmt.Errorf("%w: %d bytes declared as bucket %d", ErrMalformed, len(b), s.SizeBucket)
	}
	if !blob.IsBucket(len(b)) {
		return nil, fmt.Errorf("%w: %d bytes is not a size bucket", ErrMalformed, len(b))
	}
	if b[0] != Version {
		return nil, fmt.Errorf("%w: %d", ErrUnsupportedVersion, b[0])
	}

	start, end, err := SealedRegion(b)
	if err != nil {
		return nil, err
	}
	aad, err := EmbeddedAAD(b)
	if err != nil {
		return nil, err
	}
	if subtle.ConstantTimeCompare(aad, e.AAD()) != 1 {
		return nil, fmt.Errorf("%w: sealed at a different position", ErrAADMismatch)
	}

	region := b[start:end]
	n := int(binary.BigEndian.Uint32(region[:payloadLenSize]))
	if n < 0 || n > len(region)-payloadLenSize {
		return nil, fmt.Errorf("%w: payload length %d runs past the sealed region", ErrMalformed, n)
	}
	return decompress(region[payloadLenSize : payloadLenSize+n])
}

func compress(plaintext []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, fmt.Errorf("blob: gzip: %w", err)
	}
	if _, err := zw.Write(plaintext); err != nil {
		return nil, fmt.Errorf("blob: gzip: %w", err)
	}
	if err := zw.Close(); err != nil {
		return nil, fmt.Errorf("blob: gzip: %w", err)
	}
	return buf.Bytes(), nil
}

func decompress(payload []byte) ([]byte, error) {
	zr, err := gzip.NewReader(bytes.NewReader(payload))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	defer zr.Close()
	out, err := io.ReadAll(io.LimitReader(zr, MaxPlaintext+1))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	if len(out) > MaxPlaintext {
		return nil, fmt.Errorf("%w: decompressed payload exceeds %d bytes", ErrMalformed, MaxPlaintext)
	}
	return out, nil
}

var ZeroHash = blob.ZeroHash

func Hash(prev [32]byte, s Sealed) [32]byte { return blob.Hash(prev, s) }

var Buckets = blob.Buckets

const MaxBucket = blob.MaxBucket
