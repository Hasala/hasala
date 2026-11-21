package keyproto

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/google/uuid"
)

const (
	NonceSize        = 32
	Ed25519KeySize   = 32
	Ed25519SigSize   = 64
	DAKKeySize       = 65
	DAKSigSize       = 64
	HashSize         = 32
	WriterIDSize     = 40
	UUIDStringSize   = 36
	RegistrationSize = 201
	RevocationSize   = 142
	SessionBindSize  = 96
	DeletionSize     = 94
	BootstrapMsgSize = 84
	RecoverySignSize = 155
	RecoveryRotSize  = 154
	EpochRotateSize  = 91
	HeadMessageSize  = 119
	PasskeyAddSize   = 150
	WrapPutSize      = 115
	DeviceStepUpSize = 98
	ResetApproveSize = 145
	ResetFinishSize  = 87
	EmailChangeSize  = 87
	DeviceFreezeSize = 113
)

const (
	AuthKindNone     byte = 0x00
	AuthKindPasskey  byte = 0x01
	AuthKindPassword byte = 0x02
)

var ErrFieldLength = errors.New("keyproto: field has the wrong length")

var zero32 = make([]byte, 32)

func need(name string, b []byte, n int) error {
	if len(b) != n {
		return fmt.Errorf("%w: %s is %d bytes, want %d", ErrFieldLength, name, len(b), n)
	}
	return nil
}

func needWriter(id string) error {
	if len(id) != WriterIDSize {
		return fmt.Errorf("%w: writer_id is %d bytes, want %d", ErrFieldLength, len(id), WriterIDSize)
	}
	for i := 0; i < len(id); i++ {
		if id[i] == 0 {
			return fmt.Errorf("%w: writer_id contains 0x00", ErrFieldLength)
		}
	}
	return nil
}

func prefix(domain string, capacity int) []byte {
	m := make([]byte, 0, capacity)
	m = append(m, domain...)
	return append(m, 0x00)
}

func sum(b []byte) []byte {
	s := sha256.Sum256(b)
	return s[:]
}

func RegisterChallenge(nonce, authorityPub []byte) ([32]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return [32]byte{}, err
	}
	if err := need("authority_pubkey", authorityPub, Ed25519KeySize); err != nil {
		return [32]byte{}, err
	}
	m := prefix(DomainRegister, 19+NonceSize+Ed25519KeySize)
	m = append(m, nonce...)
	m = append(m, authorityPub...)
	return sha256.Sum256(m), nil
}

func RegistrationMessage(nonce []byte, writerID string, dwkPub, dakPub []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	if err := need("pubkey", dwkPub, Ed25519KeySize); err != nil {
		return nil, err
	}
	if err := need("dak_pubkey", dakPub, DAKKeySize); err != nil {
		return nil, err
	}
	m := prefix(DomainWriterRegistration, RegistrationSize)
	m = append(m, nonce...)
	m = append(m, 0x00)
	m = append(m, writerID...)
	m = append(m, 0x00)
	m = append(m, dwkPub...)
	return append(m, dakPub...), nil
}

func RevocationMessage(nonce []byte, writerID string, finalCounter uint64, finalHead []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	if err := need("final_head", finalHead, HashSize); err != nil {
		return nil, err
	}
	m := prefix(DomainWriterRevocation, RevocationSize)
	m = append(m, nonce...)
	m = append(m, 0x00)
	m = append(m, writerID...)
	m = append(m, 0x00)
	m = binary.BigEndian.AppendUint64(m, finalCounter)
	return append(m, finalHead...), nil
}

func SessionBindMessage(loginChallenge []byte, writerID string) ([]byte, error) {
	if err := need("login_challenge", loginChallenge, NonceSize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	m := prefix(DomainSessionBind, SessionBindSize)
	m = append(m, loginChallenge...)
	m = append(m, 0x00)
	return append(m, writerID...), nil
}

func DeletionMessage(nonce []byte, userID uuid.UUID) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainAccountDelete, DeletionSize)
	m = append(m, nonce...)
	m = append(m, 0x00)
	return append(m, userID.String()...), nil
}

func BootstrapMessage(nonce, payload []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainBootstrap, BootstrapMsgSize)
	m = append(m, nonce...)
	return append(m, sum(payload)...), nil
}

func RecoverySigninMessage(nonce []byte, authKind byte, h1, h2, h3 []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if authKind != AuthKindPasskey && authKind != AuthKindPassword {
		return nil, fmt.Errorf("%w: auth_kind 0x%02x is not passkey or password", ErrFieldLength, authKind)
	}
	for i, h := range [][]byte{h1, h2, h3} {
		if err := need(fmt.Sprintf("H%d", i+1), h, HashSize); err != nil {
			return nil, err
		}
	}
	m := prefix(DomainRecoverySignin, RecoverySignSize)
	m = append(m, nonce...)
	m = append(m, authKind)
	m = append(m, h1...)
	m = append(m, h2...)
	return append(m, h3...), nil
}

func RecoverySigninPasskey(nonce, clientDataJSON, attestationObject, prfWrap []byte) ([]byte, error) {
	h3 := zero32
	if prfWrap != nil {
		h3 = sum(prfWrap)
	}
	return RecoverySigninMessage(nonce, AuthKindPasskey, sum(clientDataJSON), sum(attestationObject), h3)
}

func RecoverySigninPassword(nonce, sNew []byte) ([]byte, error) {
	return RecoverySigninMessage(nonce, AuthKindPassword, sum(sNew), zero32, zero32)
}

func RecoveryRotateMessage(nonce, newRecoveryPub, newWrap, newBox []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if err := need("new_recovery_pubkey", newRecoveryPub, Ed25519KeySize); err != nil {
		return nil, err
	}
	m := prefix(DomainRecoveryRotate, RecoveryRotSize)
	m = append(m, nonce...)
	m = append(m, newRecoveryPub...)
	m = append(m, sum(newWrap)...)
	return append(m, sum(newBox)...), nil
}

func EpochRotateMessage(nonce []byte, newEpoch uint32, keyring []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainEpochRotate, EpochRotateSize)
	m = append(m, nonce...)
	m = binary.BigEndian.AppendUint32(m, newEpoch)
	return append(m, sum(keyring)...), nil
}

func HeadMessage(userID uuid.UUID, counter uint64, blobHash []byte, writerID string) ([]byte, error) {
	if err := need("blob_hash", blobHash, HashSize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	m := prefix(DomainWriterHead, HeadMessageSize)
	m = append(m, userID[:]...)
	m = binary.BigEndian.AppendUint64(m, counter)
	m = append(m, blobHash...)
	m = append(m, 0x00)
	return append(m, writerID...), nil
}

func PasskeyAddMessage(nonce, clientDataJSON, attestationObject, prfWrap []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainPasskeyAdd, PasskeyAddSize)
	m = append(m, nonce...)
	m = append(m, sum(clientDataJSON)...)
	m = append(m, sum(attestationObject)...)
	if prfWrap == nil {
		return append(m, zero32...), nil
	}
	return append(m, sum(prfWrap)...), nil
}

func WrapPutMessage(nonce, credentialID, wrap []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainWrapPut, WrapPutSize)
	m = append(m, nonce...)
	m = append(m, sum(credentialID)...)
	return append(m, sum(wrap)...), nil
}

func DeviceStepUpMessage(c [32]byte, writerID string) ([]byte, error) {
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	m := prefix(DomainStepUpDevice, DeviceStepUpSize)
	m = append(m, c[:]...)
	m = append(m, 0x00)
	return append(m, writerID...), nil
}

func ResetApproveMessage(nonce []byte, userID uuid.UUID, ekPub []byte, writerID string) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if err := need("ek_pub", ekPub, Ed25519KeySize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	m := prefix(DomainResetApprove, ResetApproveSize)
	m = append(m, nonce...)
	m = append(m, userID[:]...)
	m = append(m, sum(ekPub)...)
	m = append(m, 0x00)
	return append(m, writerID...), nil
}

func ResetFinishMessage(nonce, sNew []byte) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainResetFinish, ResetFinishSize)
	m = append(m, nonce...)
	return append(m, sum(sNew)...), nil
}

func EmailChangeMessage(nonce []byte, newEmailNorm string) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	m := prefix(DomainEmailChange, EmailChangeSize)
	m = append(m, nonce...)
	return append(m, sum([]byte(newEmailNorm))...), nil
}

func DeviceFreezeMessage(nonce []byte, userID uuid.UUID, writerID string) ([]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return nil, err
	}
	if err := needWriter(writerID); err != nil {
		return nil, err
	}
	m := prefix(DomainDeviceFreeze, DeviceFreezeSize)
	m = append(m, nonce...)
	m = append(m, userID[:]...)
	m = append(m, 0x00)
	return append(m, writerID...), nil
}
