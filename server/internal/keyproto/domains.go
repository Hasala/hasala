package keyproto

const (
	DomainRegister            = "hasala/v1/register"
	DomainStepUp              = "hasala/v1/step-up"
	DomainStepUpParams        = "hasala/v1/step-up-params"
	DomainRecoveryKey         = "hasala/v1/recovery-key"
	DomainWrapRecovery        = "hasala/v1/wrap/recovery"
	DomainWrapPRF             = "hasala/v1/wrap/prf"
	DomainWrap                = "hasala/v1/wrap"
	DomainPRFSaltUnlock       = "hasala/v1/prf-salt/unlock"
	DomainAMKCommitment       = "hasala/v1/amk-commitment"
	DomainEpochKey            = "hasala/v1/epoch-key"
	DomainBlobKey             = "hasala/v1/blob-key"
	DomainBlob                = "hasala/v1/blob"
	DomainWriterRegistration  = "hasala/v1/writer-registration"
	DomainWriterRevocation    = "hasala/v1/writer-revocation"
	DomainSessionBind         = "hasala/v1/session-bind"
	DomainAccountDelete       = "hasala/v1/account-delete"
	DomainBootstrap           = "hasala/v1/bootstrap"
	DomainRecoverySignin      = "hasala/v1/recovery-signin"
	DomainRecoveryRotate      = "hasala/v1/recovery-rotate"
	DomainEpochRotate         = "hasala/v1/epoch-rotate"
	DomainKeyringKey          = "hasala/v1/keyring-key"
	DomainKeyring             = "hasala/v1/keyring"
	DomainDeviceComparison    = "hasala/v1/device-comparison"
	DomainMailboxRoute        = "hasala/v1/mailbox-route"
	DomainMailboxRouteKeyID   = "hasala/v1/mailbox-route-key-id"
	DomainPassword            = "hasala/v1/password"
	DomainServerPasswordSalt  = "hasala/v1/server/password-salt"
	DomainServerPasswordPeppr = "hasala/v1/server/password-pepper"
	DomainServerEmailCode     = "hasala/v1/server/email-code"
	DomainServerEmailTag      = "hasala/v1/server/email-tag"
	DomainStepUpDevice        = "hasala/v1/step-up-device"
	DomainWriterHead          = "hasala/v1/writer-head"
	DomainPasskeyAdd          = "hasala/v1/passkey-add"
	DomainWrapPut             = "hasala/v1/wrap-put"
	DomainPhraseBoxKey        = "hasala/v1/phrase-box-key"
	DomainPhraseBox           = "hasala/v1/phrase-box"
	DomainResetCode           = "hasala/v1/reset-code"
	DomainResetApprove        = "hasala/v1/reset-approve"
	DomainResetFinish         = "hasala/v1/reset-finish"
	DomainEmailChange         = "hasala/v1/email-change"
	DomainServerAuthKeyID     = "hasala/v1/server/auth-key-id"
	DomainDeviceFreeze        = "hasala/v1/device-freeze"
	DomainServerInviteMint    = "hasala/v1/server/invite-mint"
)

type Domain struct {
	ID     string `json:"id"`
	String string `json:"string"`
}

func Registry() []Domain {
	return []Domain{
		{"D01", DomainRegister},
		{"D02", DomainStepUp},
		{"D03", DomainStepUpParams},
		{"D04", DomainRecoveryKey},
		{"D05", DomainWrapRecovery},
		{"D06", DomainWrapPRF},
		{"D07", DomainWrap},
		{"D08", DomainPRFSaltUnlock},
		{"D09", DomainAMKCommitment},
		{"D10", DomainEpochKey},
		{"D11", DomainBlobKey},
		{"D12", DomainBlob},
		{"D13", DomainWriterRegistration},
		{"D14", DomainWriterRevocation},
		{"D15", DomainSessionBind},
		{"D16", DomainAccountDelete},
		{"D17", DomainBootstrap},
		{"D18", DomainRecoverySignin},
		{"D19", DomainRecoveryRotate},
		{"D20", DomainEpochRotate},
		{"D21", DomainKeyringKey},
		{"D22", DomainKeyring},
		{"D23", DomainDeviceComparison},
		{"D24", DomainMailboxRoute},
		{"D25", DomainMailboxRouteKeyID},
		{"D26", DomainPassword},
		{"D27", DomainServerPasswordSalt},
		{"D28", DomainServerPasswordPeppr},
		{"D29", DomainServerEmailCode},
		{"D30", DomainServerEmailTag},
		{"D31", DomainStepUpDevice},
		{"D32", DomainWriterHead},
		{"D33", DomainPasskeyAdd},
		{"D34", DomainWrapPut},
		{"D35", DomainPhraseBoxKey},
		{"D36", DomainPhraseBox},
		{"D37", DomainResetCode},
		{"D38", DomainResetApprove},
		{"D39", DomainResetFinish},
		{"D40", DomainEmailChange},
		{"D41", DomainServerAuthKeyID},
		{"D42", DomainDeviceFreeze},
		{"D43", DomainServerInviteMint},
	}
}
