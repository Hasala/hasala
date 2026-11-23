package api

import (
	"context"
	"net/http"
	"time"
)

const healthzTimeout = 2 * time.Second

type healthBody struct {
	Status string `json:"status"`
	DB     string `json:"db"`
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), healthzTimeout)
	defer cancel()

	if s.Pool == nil || s.Pool.Ping(ctx) != nil {
		writeJSON(w, http.StatusServiceUnavailable, healthBody{Status: "degraded", DB: "down"})
		return
	}
	writeJSON(w, http.StatusOK, healthBody{Status: "ok", DB: "ok"})
}
