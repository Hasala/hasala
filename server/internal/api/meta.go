package api

import (
	"net/http"
	"time"
)

const OpVersionCeiling = 4

const (
	metaRate    = 1.0
	metaBurst   = 20
	metaMaxKeys = 4096
)

type MetaResponse struct {
	RPID                   string  `json:"rp_id"`
	MinIOSBuild            int     `json:"min_ios_build"`
	OpVersionCeiling       int     `json:"op_version_ceiling"`
	GmailWatchTopic        *string `json:"gmail_watch_topic"`
	OutlookNotificationURL *string `json:"outlook_notification_url"`
	OutlookLifecycleURL    *string `json:"outlook_lifecycle_url"`
	LogGeneration          int     `json:"log_generation"`
	ServerTime             string  `json:"server_time"`
}

type Meta struct {
	RPID          string
	MinIOSBuild   int
	LogGeneration int
}

func (s *Server) mountMeta(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/meta", s.handleMeta)
}

func (s *Server) handleMeta(w http.ResponseWriter, r *http.Request) {
	if !s.MetaPerIP.Allow(clientKey(r)) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many requests; try again shortly")
		return
	}
	gen := s.Meta.LogGeneration
	if gen < 1 {
		gen = 1
	}
	var topic *string
	if p := s.gmailPush(); p != nil && p.Topic != "" {
		t := p.Topic
		topic = &t
	}
	var notify, life *string
	if p := s.outlookPush(); p != nil && p.NotificationURL != "" && p.LifecycleURL != "" {
		n, l := p.NotificationURL, p.LifecycleURL
		notify, life = &n, &l
	}
	writeJSON(w, http.StatusOK, MetaResponse{
		RPID:                   s.Meta.RPID,
		MinIOSBuild:            s.Meta.MinIOSBuild,
		OpVersionCeiling:       OpVersionCeiling,
		GmailWatchTopic:        topic,
		OutlookNotificationURL: notify,
		OutlookLifecycleURL:    life,
		LogGeneration:          gen,
		ServerTime:             s.now().UTC().Truncate(time.Second).Format(time.RFC3339),
	})
}
