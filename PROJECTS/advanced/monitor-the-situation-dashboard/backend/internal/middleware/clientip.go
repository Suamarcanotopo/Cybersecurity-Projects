// ©AngelaMos | 2026
// clientip.go

package middleware

import (
	"net"
	"net/http"
	"strings"
)

// ClientIP returns the request's source IP. If trustedHops > 0, it walks back
// that many hops from the right side of X-Forwarded-For (the closest hops are
// the most trusted, since each proxy appends to the right). With trustedHops
// == 0, X-Forwarded-For is ignored entirely and only RemoteAddr is honored —
// the safe default when the binary is reachable directly without a known
// proxy chain. Set trusted_proxy_hops in config to match your deployment
// (e.g., 1 behind nginx, 2 behind nginx+Cloudflare).
func ClientIP(r *http.Request, trustedHops int) string {
	if trustedHops > 0 {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			ips := strings.Split(xff, ",")
			for i := range ips {
				ips[i] = strings.TrimSpace(ips[i])
			}
			idx := len(ips) - trustedHops
			if idx < 0 {
				idx = 0
			}
			if idx < len(ips) && ips[idx] != "" {
				return ips[idx]
			}
		}
		if xri := strings.TrimSpace(r.Header.Get("X-Real-IP")); xri != "" {
			return xri
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
