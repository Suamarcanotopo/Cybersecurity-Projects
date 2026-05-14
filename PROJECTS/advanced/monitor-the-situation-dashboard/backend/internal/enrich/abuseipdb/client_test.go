// ©AngelaMos | 2026
// client_test.go

package abuseipdb_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/enrich/abuseipdb"
)

func TestClient_LookupDecodesVerdict(t *testing.T) {
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			require.Equal(t, "/api/v2/check", r.URL.Path)
			require.Equal(t, "118.25.6.39", r.URL.Query().Get("ipAddress"))
			require.Equal(t, "90", r.URL.Query().Get("maxAgeInDays"))
			require.Equal(t, "test-key", r.Header.Get("Key"))
			body, err := os.ReadFile("testdata/check_lookup.json")
			require.NoError(t, err)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		}),
	)
	defer srv.Close()

	c := abuseipdb.NewClient(
		abuseipdb.ClientConfig{BaseURL: srv.URL, APIKey: "test-key"},
	)
	v, err := c.Lookup(context.Background(), "118.25.6.39")
	require.NoError(t, err)
	require.Equal(t, "118.25.6.39", v.IPAddress)
	require.Equal(t, "CN", v.CountryCode)
	require.Equal(t, 100, v.AbuseConfidenceScore)
	require.Equal(t, "Tencent Cloud Computing", v.ISP)
}

func TestClient_LookupReturnsErrUnknownIPOn404(t *testing.T) {
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusNotFound)
		}),
	)
	defer srv.Close()

	c := abuseipdb.NewClient(
		abuseipdb.ClientConfig{BaseURL: srv.URL, APIKey: "k"},
	)
	_, err := c.Lookup(context.Background(), "10.0.0.1")
	require.ErrorIs(t, err, abuseipdb.ErrUnknownIP)
}

func TestClient_LookupReturnsErrUnknownIPOnEmptyData(t *testing.T) {
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{}}`))
		}),
	)
	defer srv.Close()

	c := abuseipdb.NewClient(
		abuseipdb.ClientConfig{BaseURL: srv.URL, APIKey: "k"},
	)
	_, err := c.Lookup(context.Background(), "10.0.0.1")
	require.ErrorIs(t, err, abuseipdb.ErrUnknownIP)
}
