package console

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"
)

const healthDBTimeout = 2 * time.Second

type refusalLog struct {
	mu    sync.Mutex
	times []time.Time
	total uint64
}

const refusalLogMax = 1024

func (l *refusalLog) add(t time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.times) == refusalLogMax {
		l.times = l.times[1:]
	}
	l.times = append(l.times, t)
	l.total++
}

func (l *refusalLog) count() uint64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.total
}

func (l *refusalLog) since(t time.Time) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := 0
	for _, x := range l.times {
		if x.After(t) {
			n++
		}
	}
	return n
}

type HealthBody struct {
	Status           string `json:"status"`
	DB               string `json:"db"`
	ASC              string `json:"asc"`
	TunnelRefusals24 int    `json:"tunnel_refusals_24h"`
}

const metricsContentType = "text/plain; version=0.0.4; charset=utf-8"

const metricsText = `# HELP hasala_console_tunnel_refusals_total Requests with a Cloudflare header that the console refused since it started.
# TYPE hasala_console_tunnel_refusals_total counter
hasala_console_tunnel_refusals_total %d
# HELP hasala_console_tunnel_refusals_24h Requests with a Cloudflare header that the console refused in the last 24 hours.
# TYPE hasala_console_tunnel_refusals_24h gauge
hasala_console_tunnel_refusals_24h %d
# HELP hasala_console_db_up 1 when the console reaches its database, 0 when it does not.
# TYPE hasala_console_db_up gauge
hasala_console_db_up %d
`

func (c *Console) dbUp(r *http.Request) bool {
	ctx, cancel := context.WithTimeout(r.Context(), healthDBTimeout)
	defer cancel()
	return c.Pool != nil && c.Pool.Ping(ctx) == nil
}

func (c *Console) HealthHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, r *http.Request) {
		up := 0
		if c.dbUp(r) {
			up = 1
		}
		w.Header().Set("Content-Type", metricsContentType)
		w.Header().Set("Cache-Control", "no-store")
		_, _ = fmt.Fprintf(w, metricsText, c.tunnel.count(), c.tunnel.since(c.now().Add(-24*time.Hour)), up)
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		b := HealthBody{Status: "ok", DB: "ok", ASC: "disabled",
			TunnelRefusals24: c.tunnel.since(c.now().Add(-24 * time.Hour))}
		if !c.dbUp(r) {
			b.DB = "down"
		}
		code := http.StatusOK
		if b.DB != "ok" || b.TunnelRefusals24 > 0 {
			b.Status, code = "fail", http.StatusServiceUnavailable
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(b)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	return mux
}
