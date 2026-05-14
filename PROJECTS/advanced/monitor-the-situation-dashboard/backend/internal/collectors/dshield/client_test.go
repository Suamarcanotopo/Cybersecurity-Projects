// ©AngelaMos | 2026
// client_test.go

package dshield_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/dshield"
)

func newFixtureServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc(
		"/api/topports/",
		func(w http.ResponseWriter, r *http.Request) {
			require.Contains(t, r.URL.Path, "/api/topports/records/")
			body, err := os.ReadFile(filepath.Join("testdata", "topports.json"))
			require.NoError(t, err)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		},
	)
	mux.HandleFunc(
		"/api/topips/",
		func(w http.ResponseWriter, _ *http.Request) {
			body, err := os.ReadFile(filepath.Join("testdata", "topips.json"))
			require.NoError(t, err)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		},
	)
	mux.HandleFunc(
		"/api/dailysummary/",
		func(w http.ResponseWriter, r *http.Request) {
			require.True(t, strings.HasPrefix(r.URL.Path, "/api/dailysummary/"))
			body, err := os.ReadFile(
				filepath.Join("testdata", "dailysummary.json"),
			)
			require.NoError(t, err)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		},
	)
	return httptest.NewServer(mux)
}

func TestClient_FetchAllReturnsThreeKinds(t *testing.T) {
	srv := newFixtureServer(t)
	defer srv.Close()

	c := dshield.NewClient(dshield.ClientConfig{BaseURL: srv.URL, TopN: 10})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	snaps, err := c.FetchAll(ctx)
	require.NoError(t, err)
	require.Len(t, snaps, 3)

	kinds := map[string]bool{}
	for _, s := range snaps {
		kinds[s.Kind] = true
		require.NotEmpty(t, s.Payload, "kind %s payload empty", s.Kind)
	}
	require.True(t, kinds[dshield.KindTopPorts])
	require.True(t, kinds[dshield.KindTopIPs])
	require.True(t, kinds[dshield.KindDailySummary])
}

func TestClient_FetchAllUsesYesterdayDate(t *testing.T) {
	var topPortsPath, dailyPath string
	mux := http.NewServeMux()
	mux.HandleFunc(
		"/api/topports/",
		func(w http.ResponseWriter, r *http.Request) {
			topPortsPath = r.URL.Path
			_, _ = w.Write([]byte(`{}`))
		},
	)
	mux.HandleFunc(
		"/api/topips/",
		func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`[]`))
		},
	)
	mux.HandleFunc(
		"/api/dailysummary/",
		func(w http.ResponseWriter, r *http.Request) {
			dailyPath = r.URL.Path
			_, _ = w.Write([]byte(`[]`))
		},
	)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	c := dshield.NewClient(dshield.ClientConfig{BaseURL: srv.URL, TopN: 5})
	_, _ = c.FetchAll(context.Background())

	yesterday := time.Now().UTC().AddDate(0, 0, -1).Format("2006-01-02")
	require.Contains(t, topPortsPath, "/records/5/"+yesterday)
	require.Contains(t, dailyPath, "/dailysummary/"+yesterday)
}
