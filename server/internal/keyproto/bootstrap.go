package keyproto

import (
	"encoding/binary"
	"fmt"

	"github.com/google/uuid"
)

const BootstrapPayloadVersion = 0x01

type BootstrapPayload struct {
	UserID          uuid.UUID
	AMKCommitment   []byte
	AuthorityPubkey []byte
	RecoveryPubkey  []byte
	RecoveryWrap    []byte
	PhraseBox       []byte
	EmailHash       []byte
	AuthKind        byte
	AuthHash        []byte
	WriterPubkey    []byte
	WriterDAK       []byte
	WriterID        string
	CredentialID    []byte
	PRFWrap         []byte
}

func (p BootstrapPayload) Bytes() ([]byte, error) {
	if p.UserID == uuid.Nil {
		return nil, fmt.Errorf("%w: user_id is zero", ErrShape)
	}
	for _, f := range []struct {
		name string
		b    []byte
		n    int
	}{
		{"amk_commitment", p.AMKCommitment, 32},
		{"authority_pubkey", p.AuthorityPubkey, 32},
		{"recovery_pubkey", p.RecoveryPubkey, 32},
		{"email_hash", p.EmailHash, 32},
		{"auth_hash", p.AuthHash, 32},
		{"writer.pubkey", p.WriterPubkey, 32},
		{"writer.dak_pubkey", p.WriterDAK, DAKKeySize},
	} {
		if err := need(f.name, f.b, f.n); err != nil {
			return nil, err
		}
	}
	if err := CheckRecoveryWrap(p.RecoveryWrap); err != nil {
		return nil, err
	}
	if err := CheckPhraseBox(p.PhraseBox); err != nil {
		return nil, err
	}
	if p.AuthKind > AuthKindPassword {
		return nil, fmt.Errorf("%w: auth_kind 0x%02x", ErrShape, p.AuthKind)
	}
	if !ValidWriterID(p.WriterID) {
		return nil, fmt.Errorf("%w: writer_id does not match the §4.8 grammar", ErrShape)
	}
	c, w := len(p.CredentialID), len(p.PRFWrap)
	switch {
	case c == 0 && w == 0:
	case c == 0 || w == 0:
		return nil, fmt.Errorf("%w: a PRF wrap needs both its credential id and its wrap", ErrShape)
	default:
		if err := CheckCredentialID(p.CredentialID); err != nil {
			return nil, err
		}
		if err := CheckPRFWrap(p.PRFWrap); err != nil {
			return nil, err
		}
	}

	out := make([]byte, 0, 501+c+w)
	out = append(out, BootstrapPayloadVersion)
	out = append(out, p.UserID[:]...)
	out = append(out, p.AMKCommitment...)
	out = append(out, p.AuthorityPubkey...)
	out = append(out, p.RecoveryPubkey...)
	out = binary.BigEndian.AppendUint32(out, 1)
	out = binary.BigEndian.AppendUint16(out, WrapSize)
	out = append(out, p.RecoveryWrap...)
	out = binary.BigEndian.AppendUint16(out, PhraseBoxSize)
	out = append(out, p.PhraseBox...)
	out = append(out, p.EmailHash...)
	out = append(out, p.AuthKind)
	out = append(out, p.AuthHash...)
	out = append(out, 0x01)
	out = append(out, p.WriterPubkey...)
	out = append(out, p.WriterDAK...)
	out = append(out, byte(WriterIDSize))
	out = append(out, p.WriterID...)
	out = binary.BigEndian.AppendUint16(out, uint16(c))
	out = append(out, p.CredentialID...)
	out = binary.BigEndian.AppendUint16(out, uint16(w))
	out = append(out, p.PRFWrap...)
	return out, nil
}

func (p BootstrapPayload) CheckKeys() error {
	for _, k := range []struct {
		name string
		b    []byte
	}{
		{"authority_pubkey", p.AuthorityPubkey},
		{"recovery_pubkey", p.RecoveryPubkey},
		{"writer.pubkey", p.WriterPubkey},
	} {
		if err := CheckEd25519PublicKey(k.b); err != nil {
			return fmt.Errorf("%s: %w", k.name, err)
		}
	}
	if !distinct(p.AuthorityPubkey, p.RecoveryPubkey, p.WriterPubkey) {
		return fmt.Errorf("%w: the authority, recovery and writer keys must differ", ErrShape)
	}
	if _, err := ParseDAK(p.WriterDAK); err != nil {
		return err
	}
	return nil
}
