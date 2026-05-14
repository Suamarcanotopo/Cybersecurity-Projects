// ©AngelaMos | 2026
// client_test.go

package kev_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/kev"
)

func TestKEVClient_FetchCatalogDecodes(t *testing.T) {
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			body, err := os.ReadFile("testdata/kev_catalog.json")
			require.NoError(t, err)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		}),
	)
	defer srv.Close()

	c := kev.NewClient(kev.ClientConfig{URL: srv.URL})
	cat, err := c.FetchCatalog(context.Background())
	require.NoError(t, err)
	require.NotEmpty(t, cat.Vulnerabilities)
	require.NotEmpty(t, cat.Vulnerabilities[0].CveID)
}

func TestKEVClient_RejectsServerError(t *testing.T) {
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusBadRequest)
		}),
	)
	defer srv.Close()

	c := kev.NewClient(kev.ClientConfig{URL: srv.URL})
	_, err := c.FetchCatalog(context.Background())
	require.Error(t, err)
}
