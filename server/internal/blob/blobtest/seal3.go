package blobtest

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"github.com/salehtl/hasala/server/internal/blob"
)

const (
	domainBlob    = "hasala/v1/blob"
	domainBlobKey = "hasala/v1/blob-key"
)

var TestEpochKey = bytes.Repeat([]byte{0x42}, 32)

func SealRegion3(epochKey, header []byte, prevHash [32]byte, nonce, region []byte) ([]byte, error) {
	if len(epochKey) != 32 {
		return nil, fmt.Errorf("blobtest: epoch key is %d bytes, want 32", len(epochKey))
	}
	if len(nonce) != blob.NonceSize {
		return nil, fmt.Errorf("blobtest: nonce is %d bytes, want %d", len(nonce), blob.NonceSize)
	}
	ad := associatedData(header, prevHash)
	key, err := blobKey(epochKey, nonce, ad)
	if err != nil {
		return nil, err
	}
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 0, len(header)+len(nonce)+len(region)+blob.TagSize)
	out = append(out, header...)
	out = append(out, nonce...)
	return gcm.Seal(out, nonce, region, ad), nil
}

func BlobKey3(epochKey, header []byte, prevHash [32]byte, nonce []byte) ([]byte, error) {
	return blobKey(epochKey, nonce, associatedData(header, prevHash))
}

func associatedData(header []byte, prevHash [32]byte) []byte {
	ad := make([]byte, 0, len(domainBlob)+1+len(header)+32)
	ad = append(ad, domainBlob...)
	ad = append(ad, 0)
	ad = append(ad, header...)
	return append(ad, prevHash[:]...)
}

func blobKey(epochKey, nonce, ad []byte) ([]byte, error) {
	sum := sha256.Sum256(ad)
	info := append(append([]byte(domainBlobKey), 0), sum[:]...)
	return hkdf.Key(sha256.New, epochKey, nonce, string(info), 32)
}

func newGCM(key []byte) (cipher.AEAD, error) {
	c, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(c)
}

func Seal3(e blob.Envelope, epoch uint32, epochKey []byte, prevHash [32]byte, plaintext []byte) (blob.Sealed, error) {
	header, err := blob.Header3(e, epoch)
	if err != nil {
		return blob.Sealed{}, err
	}
	if len(plaintext) > blob.MaxPlaintext {
		return blob.Sealed{}, fmt.Errorf("%w: plaintext is %d bytes, cap is %d", blob.ErrTooLarge, len(plaintext), blob.MaxPlaintext)
	}
	g, err := gzip3(plaintext)
	if err != nil {
		return blob.Sealed{}, err
	}
	bucket, err := blob.BucketFor(len(header) + blob.NonceSize + 4 + len(g) + blob.TagSize)
	if err != nil {
		return blob.Sealed{}, err
	}
	region := make([]byte, bucket-len(header)-blob.NonceSize-blob.TagSize)
	binary.BigEndian.PutUint32(region[:4], uint32(len(g)))
	copy(region[4:], g)
	for attempt := 0; attempt < 2; attempt++ {
		nonce := make([]byte, blob.NonceSize)
		if _, err := rand.Read(nonce); err != nil {
			return blob.Sealed{}, err
		}
		frame, err := SealRegion3(epochKey, header, prevHash, nonce, region)
		if err != nil {
			return blob.Sealed{}, err
		}
		if len(frame) != bucket {
			return blob.Sealed{}, fmt.Errorf("blobtest: frame is %d bytes, want bucket %d", len(frame), bucket)
		}
		if blob.LooksSealed(frame) == nil {
			return blob.Sealed{Bytes: frame, SizeBucket: bucket}, nil
		}
	}
	return blob.Sealed{}, errors.New("blobtest: sealer fault: two seals in a row tripped LooksSealed")
}

func MustSeal3(e blob.Envelope, prevHash [32]byte, plaintext []byte) blob.Sealed {
	s, err := Seal3(e, 1, TestEpochKey, prevHash, plaintext)
	if err != nil {
		panic(err)
	}
	return s
}

func Open3(e blob.Envelope, epochKey []byte, prevHash [32]byte, frame []byte) ([]byte, error) {
	f, err := blob.Parse3(frame)
	if err != nil {
		return nil, err
	}
	if subtle.ConstantTimeCompare(f.AAD, e.AAD()) != 1 {
		return nil, ErrAADMismatch
	}
	region, err := OpenRegion3(epochKey, prevHash, frame)
	if err != nil {
		return nil, fmt.Errorf("%w: aead: %v", ErrSetAside, err)
	}
	g, err := RegionPayload(region)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	out, err := GunzipStrict(g)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	return out, nil
}

func OpenRegion3(epochKey []byte, prevHash [32]byte, frame []byte) ([]byte, error) {
	if len(frame) < blob.FixedHeaderSize {
		return nil, errors.New("blobtest: frame is shorter than its header")
	}
	l := int(binary.BigEndian.Uint16(frame[5:7]))
	hl := blob.FixedHeaderSize + l
	if hl+blob.NonceSize+blob.TagSize > len(frame) {
		return nil, errors.New("blobtest: aad_len runs past the frame")
	}
	header, nonce, ct := frame[:hl], frame[hl:hl+blob.NonceSize], frame[hl+blob.NonceSize:]
	ad := associatedData(header, prevHash)
	key, err := blobKey(epochKey, nonce, ad)
	if err != nil {
		return nil, err
	}
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	return gcm.Open(nil, nonce, ct, ad)
}

func RegionPayload(region []byte) ([]byte, error) {
	if len(region) < 4 {
		return nil, errors.New("blobtest: region is shorter than its length field")
	}
	m := int(binary.BigEndian.Uint32(region[:4]))
	if m < 0 || m > len(region)-4 {
		return nil, fmt.Errorf("blobtest: payload length %d runs past the region", m)
	}
	return region[4 : 4+m], nil
}

func GunzipStrict(g []byte) ([]byte, error) {
	br := bytes.NewReader(g)
	zr, err := gzip.NewReader(br)
	if err != nil {
		return nil, err
	}
	zr.Multistream(false)
	out, err := io.ReadAll(io.LimitReader(zr, blob.MaxPlaintext+1))
	if err != nil {
		return nil, err
	}
	if len(out) > blob.MaxPlaintext {
		return nil, fmt.Errorf("blobtest: plaintext exceeds %d bytes", blob.MaxPlaintext)
	}
	if br.Len() != 0 {
		return nil, fmt.Errorf("blobtest: %d bytes follow the gzip member", br.Len())
	}
	return out, nil
}

func Gzip(plaintext []byte) ([]byte, error) { return gzip3(plaintext) }

func Region3(g []byte, n int) ([]byte, error) {
	if len(g)+4 > n {
		return nil, fmt.Errorf("blobtest: %d bytes of payload do not fit a %d-byte region", len(g), n)
	}
	r := make([]byte, n)
	binary.BigEndian.PutUint32(r[:4], uint32(len(g)))
	copy(r[4:], g)
	return r, nil
}

func SealWithNonce3(e blob.Envelope, epoch uint32, epochKey []byte, prevHash [32]byte, nonce, plaintext []byte) (blob.Sealed, error) {
	header, err := blob.Header3(e, epoch)
	if err != nil {
		return blob.Sealed{}, err
	}
	g, err := gzip3(plaintext)
	if err != nil {
		return blob.Sealed{}, err
	}
	bucket, err := blob.BucketFor(len(header) + blob.NonceSize + 4 + len(g) + blob.TagSize)
	if err != nil {
		return blob.Sealed{}, err
	}
	region, err := Region3(g, bucket-len(header)-blob.NonceSize-blob.TagSize)
	if err != nil {
		return blob.Sealed{}, err
	}
	frame, err := SealRegion3(epochKey, header, prevHash, nonce, region)
	if err != nil {
		return blob.Sealed{}, err
	}
	return blob.Sealed{Bytes: frame, SizeBucket: bucket}, nil
}

func gzip3(plaintext []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	if _, err := zw.Write(plaintext); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
