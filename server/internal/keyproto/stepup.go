package keyproto

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"regexp"
	"slices"
)

type Action string

const (
	ActionPasskeyAdd         Action = "passkey.add"
	ActionPasskeyDelete      Action = "passkey.delete"
	ActionKeysBootstrap      Action = "keys.bootstrap"
	ActionKeysWrapPut        Action = "keys.wrap.put"
	ActionKeysWrapDelete     Action = "keys.wrap.delete"
	ActionKeysRecoveryRotate Action = "keys.recovery.rotate"
	ActionKeysEpochRotate    Action = "keys.epoch.rotate"
	ActionWriterRevoke       Action = "writer.revoke"
	ActionMailboxLink        Action = "mailbox.link"
	ActionMailboxUnlink      Action = "mailbox.unlink"
	ActionSessionLogoutAll   Action = "session.logout_all"
	ActionAccountDelete      Action = "account.delete"
	ActionPasswordSet        Action = "password.set"
	ActionPasswordChange     Action = "password.change"
	ActionPasswordRemove     Action = "password.remove"
	ActionPasswordReset      Action = "password.reset"
	ActionEmailChange        Action = "email.change"
	ActionPhraseView         Action = "phrase.view"
	ActionAccountFreeze      Action = "account.freeze"
	ActionAccountUnfreeze    Action = "account.unfreeze"
)

type ProofKind string

const (
	ProofPasskey    ProofKind = "passkey"
	ProofDevice     ProofKind = "device"
	ProofDeviceCode ProofKind = "device_code"
)

var (
	passkeyOnly = []ProofKind{ProofPasskey}
	passkeyDev  = []ProofKind{ProofPasskey, ProofDevice}
)

var proofKinds = []struct {
	action Action
	kinds  []ProofKind
}{
	{ActionPasskeyAdd, passkeyDev},
	{ActionPasskeyDelete, passkeyDev},
	{ActionKeysBootstrap, passkeyOnly},
	{ActionKeysWrapPut, passkeyOnly},
	{ActionKeysWrapDelete, passkeyDev},
	{ActionKeysRecoveryRotate, passkeyDev},
	{ActionKeysEpochRotate, passkeyDev},
	{ActionWriterRevoke, passkeyDev},
	{ActionMailboxLink, passkeyDev},
	{ActionMailboxUnlink, passkeyDev},
	{ActionSessionLogoutAll, passkeyDev},
	{ActionAccountDelete, passkeyDev},
	{ActionPasswordSet, passkeyOnly},
	{ActionPasswordChange, passkeyDev},
	{ActionPasswordRemove, passkeyOnly},
	{ActionPasswordReset, []ProofKind{ProofDeviceCode}},
	{ActionEmailChange, passkeyDev},
	{ActionPhraseView, passkeyOnly},
	{ActionAccountFreeze, passkeyDev},
	{ActionAccountUnfreeze, passkeyDev},
}

func Actions() []Action {
	out := make([]Action, len(proofKinds))
	for i, r := range proofKinds {
		out[i] = r.action
	}
	return out
}

func AllowedProofs(a Action) []ProofKind {
	for _, r := range proofKinds {
		if r.action == a {
			return append([]ProofKind(nil), r.kinds...)
		}
	}
	return nil
}

func ProofAllowed(a Action, kind ProofKind) bool { return slices.Contains(AllowedProofs(a), kind) }

var actionGrammar = regexp.MustCompile(`^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$`)

func ValidAction(a Action) bool { return AllowedProofs(a) != nil }

func EncTuple(fields ...[]byte) []byte {
	n := 0
	for _, f := range fields {
		n += 4 + len(f)
	}
	out := make([]byte, 0, n)
	for _, f := range fields {
		out = binary.BigEndian.AppendUint32(out, uint32(len(f)))
		out = append(out, f...)
	}
	return out
}

func checkAction(a Action) error {
	if len(a) == 0 || len(a) > 48 || !actionGrammar.MatchString(string(a)) {
		return fmt.Errorf("%w: action %q is not a step-up action name", ErrFieldLength, a)
	}
	return nil
}

func ParamsHash(a Action, fields ...[]byte) ([32]byte, error) {
	if err := checkAction(a); err != nil {
		return [32]byte{}, err
	}
	enc := EncTuple(fields...)
	m := prefix(DomainStepUpParams, len(DomainStepUpParams)+2+len(a)+len(enc))
	m = append(m, a...)
	m = append(m, 0x00)
	m = append(m, enc...)
	return sha256.Sum256(m), nil
}

func StepUpChallenge(nonce []byte, a Action, paramsHash [32]byte) ([32]byte, error) {
	if err := need("nonce", nonce, NonceSize); err != nil {
		return [32]byte{}, err
	}
	if err := checkAction(a); err != nil {
		return [32]byte{}, err
	}
	m := prefix(DomainStepUp, len(DomainStepUp)+1+NonceSize+len(a)+1+32)
	m = append(m, nonce...)
	m = append(m, a...)
	m = append(m, 0x00)
	m = append(m, paramsHash[:]...)
	return sha256.Sum256(m), nil
}
