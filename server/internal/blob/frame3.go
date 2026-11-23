package blob

import (
	"bytes"
	"encoding/binary"
	"fmt"
)

const (
	Version3 = 3

	FixedHeaderSize = 7
	EpochSize       = 4
	PayloadLenSize  = 4

	MaxEpoch = 1<<31 - 1

	minTail = 67
)

const (
	CheckBucket  = "bucket"
	CheckVersion = "version"
	CheckEpoch   = "epoch"
	CheckAADLen  = "aad_len"
	CheckNonce   = "nonce"
	CheckTag     = "tag"
	CheckTail    = "tail"
	CheckGzip    = "gzip"
)

type RefusalError struct {
	Check string
}

func (e *RefusalError) Error() string {
	return "blob: not a sealed v3 frame: check " + e.Check + " failed"
}

var (
	zero12 = make([]byte, 12)
	zero16 = make([]byte, 16)
	zero32 = make([]byte, 32)
	gzipID = []byte{0x1f, 0x8b, 0x08}
)

func LooksSealed(b []byte) error {
	n := len(b)
	if !IsBucket(n) {
		return &RefusalError{Check: CheckBucket}
	}
	if b[0] != Version3 {
		return &RefusalError{Check: CheckVersion}
	}
	if e := binary.BigEndian.Uint32(b[1:5]); e == 0 || e > MaxEpoch {
		return &RefusalError{Check: CheckEpoch}
	}
	l := int(binary.BigEndian.Uint16(b[5:7]))
	if l+minTail > n {
		return &RefusalError{Check: CheckAADLen}
	}
	if bytes.Equal(b[7+l:19+l], zero12) {
		return &RefusalError{Check: CheckNonce}
	}
	if bytes.Equal(b[n-16:], zero16) {
		return &RefusalError{Check: CheckTag}
	}
	if bytes.Equal(b[n-48:n-16], zero32) {
		return &RefusalError{Check: CheckTail}
	}
	if bytes.Equal(b[23+l:26+l], gzipID) {
		return &RefusalError{Check: CheckGzip}
	}
	return nil
}

type FrameV3 struct {
	Epoch uint32
	AAD   []byte
}

func Parse3(b []byte) (FrameV3, error) {
	if err := LooksSealed(b); err != nil {
		return FrameV3{}, err
	}
	l := int(binary.BigEndian.Uint16(b[5:7]))
	return FrameV3{
		Epoch: binary.BigEndian.Uint32(b[1:5]),
		AAD:   b[FixedHeaderSize : FixedHeaderSize+l],
	}, nil
}

func EmbeddedAAD(b []byte) ([]byte, error) {
	f, err := Parse3(b)
	if err != nil {
		return nil, err
	}
	return f.AAD, nil
}

func KeyEpoch(b []byte) (uint32, error) {
	f, err := Parse3(b)
	if err != nil {
		return 0, err
	}
	return f.Epoch, nil
}

func Header3(e Envelope, epoch uint32) ([]byte, error) {
	if err := e.Validate(); err != nil {
		return nil, err
	}
	if epoch == 0 || epoch > MaxEpoch {
		return nil, fmt.Errorf("%w: key epoch %d is outside 1..%d", ErrInvalidEnvelope, epoch, MaxEpoch)
	}
	aad := e.AAD()
	h := make([]byte, FixedHeaderSize+len(aad))
	h[0] = Version3
	binary.BigEndian.PutUint32(h[1:5], epoch)
	binary.BigEndian.PutUint16(h[5:7], uint16(len(aad)))
	copy(h[FixedHeaderSize:], aad)
	return h, nil
}
