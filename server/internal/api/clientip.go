package api

import (
	"context"
	"encoding/hex"
	"net"
	"net/http"
	"net/netip"
	"strings"
)

const cfConnectingIP = "Cf-Connecting-Ip"

type clientKeyCtx struct{}

func ClientKeyFor(r *http.Request, trustCloudflare bool) string {
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		peer = r.RemoteAddr
	}
	if trustCloudflare && isLoopbackHost(peer) {
		if ip, err := netip.ParseAddr(r.Header.Get(cfConnectingIP)); err == nil && ip.Zone() == "" {
			ip = ip.Unmap()
			if ip.Is4() {
				return "4:" + ip.String()
			}
			b := ip.As16()
			return "6:" + hex.EncodeToString(b[:8])
		}
		return "local"
	}
	return "peer:" + peer
}

func prefixKey(key string) (string, bool) {
	if len(key) != 18 || !strings.HasPrefix(key, "6:") {
		return "", false
	}
	return "6p:" + key[2:14], true
}

func isLoopbackHost(host string) bool {
	ip, err := netip.ParseAddr(host)
	return err == nil && ip.Unmap().IsLoopback()
}

func (s *Server) withClientKey(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		k := ClientKeyFor(r, s.TrustCloudflare)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), clientKeyCtx{}, k)))
	})
}

func clientKey(r *http.Request) string {
	if k, ok := r.Context().Value(clientKeyCtx{}).(string); ok {
		return k
	}
	return ClientKeyFor(r, false)
}
