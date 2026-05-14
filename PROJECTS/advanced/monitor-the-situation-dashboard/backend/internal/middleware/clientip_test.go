// ©AngelaMos | 2026
// clientip_test.go

package middleware_test

import (
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/middleware"
)

func TestClientIP_TrustedHopsZero_IgnoresXFF(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.0.5:54321"
	r.Header.Set("X-Forwarded-For", "1.2.3.4")
	r.Header.Set("X-Real-IP", "1.2.3.4")

	require.Equal(t, "10.0.0.5", middleware.ClientIP(r, 0))
}

func TestClientIP_TrustedHopsOne_PeelsRightmost(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.0.5:54321"
	r.Header.Set("X-Forwarded-For", "203.0.113.1, 10.0.0.5")

	require.Equal(t, "10.0.0.5", middleware.ClientIP(r, 1))
}

func TestClientIP_TrustedHopsTwo_PeelsTwoFromRight(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.0.5:54321"
	r.Header.Set("X-Forwarded-For", "203.0.113.1, 198.51.100.7, 10.0.0.5")

	require.Equal(t, "198.51.100.7", middleware.ClientIP(r, 2))
}

func TestClientIP_TrustedHopsExceedsList_ReturnsLeftmost(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.0.5:54321"
	r.Header.Set("X-Forwarded-For", "203.0.113.1, 10.0.0.5")

	require.Equal(t, "203.0.113.1", middleware.ClientIP(r, 5))
}

func TestClientIP_TrustedHopsOne_NoXFF_FallsBackToRemoteAddr(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.0.5:54321"

	require.Equal(t, "10.0.0.5", middleware.ClientIP(r, 1))
}

func TestClientIP_TrustedHopsOne_HonorsXRealIP(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.0.5:54321"
	r.Header.Set("X-Real-IP", "203.0.113.42")

	require.Equal(t, "203.0.113.42", middleware.ClientIP(r, 1))
}
