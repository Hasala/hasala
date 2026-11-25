package api

import (
	"net/http"
)

type Fuse interface {
	Tripped() bool
}

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

func writeAccountSuspended(w http.ResponseWriter) {
	writeErr(w, http.StatusForbidden, "account_suspended",
		"this account is paused, so changes are not being accepted; "+
			"your data is still here and still readable")
}
