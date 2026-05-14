// ©AngelaMos | 2026
// client_test.go

package greynoise_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/enrich/greynoise"
)

func TestClient_LookupDecodesVerdict(t *testing.T) {
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			require.Equal(t, "/v3/community/8.8.8.8", r.URL.Path)
			require.Equal(t, "test-key", r.Header.Get("key"))
			body, err := os.ReadFile("testdata/ip_lookup.json")
			require.NoError(t, err)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		}),
	)
	defer srv.Close()

	c := greynoise.NewClient(
		greynoise.ClientConfig{BaseURL: srv.URL, APIKey: "test-key"},
	)
	v, err := c.Lookup(context.Background(), "8.8.8.8")
	require.NoError(t, err)
	require.Equal(t, "8.8.8.8", v.IP)
	require.True(t, v.Riot)
	require.Equal(t, "benign", v.Classification)
}

func TestClient_LookupReturnsErrUnknownIPOn404(t *testing.T) {
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusNotFound)
		}),
	)
	defer srv.Close()

	c := greynoise.NewClient(
		greynoise.ClientConfig{BaseURL: srv.URL, APIKey: "k"},
	)
	_, err := c.Lookup(context.Background(), "10.0.0.1")
	require.ErrorIs(t, err, greynoise.ErrUnknownIP)
}
