package api

import (
	"context"
	"errors"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/auth"
)

type Fuse interface {
	Tripped() bool
}

const statusSuspended = "suspended"

func isRead(method string) bool {
	return method == http.MethodGet || method == http.MethodHead
}

func (s *Server) headroomGate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !isRead(r.Method) && !fuseExempt(r.URL.Path) && s.fuseTripped() {
			s.logf("api: %s: refused, the headroom fuse is tripped", route(r))
			w.Header().Set("Retry-After", "60")
			writeErr(w, http.StatusServiceUnavailable, "no_headroom",
				"the server is low on disk space and is not accepting writes; "+
					"your data is safe on this device and will upload when it resumes")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) fuseTripped() bool {
	return s.Headroom != nil && s.Headroom.Tripped()
}

func fuseExempt(path string) bool {
	switch path {
	case "/hooks/gmail/pubsub", outlookHookPath, outlookLifecyclePath:
		return true
	}
	return false
}

func (s *Server) accountStatus(ctx context.Context, userID uuid.UUID) (auth.AccountStatus, error) {
	var (
		status string
		frozen bool
	)
	err := s.Pool.QueryRow(ctx, `SELECT status, frozen_at IS NOT NULL FROM users WHERE id = $1`, userID).Scan(&status, &frozen)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return auth.AccountStatus{}, errors.New("api: no users row for a session that resolved")
		}
		return auth.AccountStatus{}, err
	}
	return auth.AccountStatus{Suspended: status == statusSuspended, Frozen: frozen}, nil
}

func writeAccountSuspended(w http.ResponseWriter) {
	writeErr(w, http.StatusForbidden, "account_suspended",
		"this account is paused, so changes are not being accepted; "+
			"your data is still here and still readable")
}
