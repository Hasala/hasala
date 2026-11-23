package auth

import (
	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/pushv2"
)

type Wake struct {
	UserID  uuid.UUID
	Except  string
	Revoked []pushv2.Target
}

func wakeFor(userID uuid.UUID, except string, revoked []pushv2.Target) Wake {
	return Wake{UserID: userID, Except: except, Revoked: revoked}
}
