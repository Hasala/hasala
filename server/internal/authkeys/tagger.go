package authkeys

import (
	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

type EmailTagger struct{ kTag, kInvite []byte }

func NewEmailTagger(authKey []byte) (*EmailTagger, error) {
	if len(authKey) != KeySize {
		return nil, ErrKeyFile
	}
	k, err := subkey(authKey, keyproto.DomainServerEmailTag)
	if err != nil {
		return nil, err
	}
	inv, err := subkey(authKey, keyproto.DomainServerInviteMint)
	if err != nil {
		return nil, err
	}
	return &EmailTagger{kTag: k, kInvite: inv}, nil
}

func (t *EmailTagger) EmailTag(emailNorm string) []byte { return mac(t.kTag, []byte(emailNorm)) }

func (t *EmailTagger) InviteSecrets(inviteID uuid.UUID, mailID int64) (code, link []byte) {
	return inviteSecrets(t.kInvite, inviteID, mailID)
}
