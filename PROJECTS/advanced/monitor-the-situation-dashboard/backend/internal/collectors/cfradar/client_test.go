// ©AngelaMos | 2026
// client_test.go

package cfradar_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/cfradar"
)

func newRadarServer(t *testing.T, authHits *atomic.Int32) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc(
		"/client/v4/radar/annotations/outages",
		func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") == "Bearer test-token" {
				authHits.Add(1)
			}
			body, err := os.ReadFile("testdata/outages.json")
			require.NoError(t, err)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		},
	)
	mux.HandleFunc(
		"/client/v4/radar/bgp/hijacks/events",
		func(w http.ResponseWriter, _ *http.Request) {
			body, err := os.ReadFile("testdata/hijacks.json")
			require.NoError(t, err)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		},
	)
	return httptest.NewServer(mux)
}

func TestClient_FetchOutagesSendsBearerAndDecodes(t *testing.T) {
	var hits atomic.Int32
	srv := newRadarServer(t, &hits)
	defer srv.Close()

	c := cfradar.NewClient(cfradar.ClientConfig{
		BaseURL:     srv.URL,
		BearerToken: "test-token",
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	body, err := c.FetchOutages(ctx)
	require.NoError(t, err)
	require.Len(t, body.Annotations, 2)
	require.Equal(t, "outage-2026-04-30-DE-DTAG", body.Annotations[0].ID)
	require.Equal(t, []string{"DE"}, body.Annotations[0].Locations)
	require.Equal(t, []int32{3320}, body.Annotations[0].ASNs)
	require.EqualValues(t, 1, hits.Load())
}

func TestClient_FetchHijacksDecodes(t *testing.T) {
	var hits atomic.Int32
	srv := newRadarServer(t, &hits)
	defer srv.Close()

	c := cfradar.NewClient(cfradar.ClientConfig{
		BaseURL:     srv.URL,
		BearerToken: "test-token",
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	body, err := c.FetchHijacks(ctx, 7)
	require.NoError(t, err)
	require.Len(t, body.Events, 2)
	require.EqualValues(t, 7700001, body.Events[0].ID)
	require.EqualValues(t, 9, body.Events[0].Confidence)
	require.Equal(t, []string{"203.0.113.0/24"}, body.Events[0].Prefixes)
}

func TestClient_FetchOutagesFailsOnSuccessFalse(t *testing.T) {
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write(
				[]byte(
					`{"success":false,"errors":[{"message":"unauthorized"}]}`,
				),
			)
		}),
	)
	defer srv.Close()

	c := cfradar.NewClient(
		cfradar.ClientConfig{BaseURL: srv.URL, BearerToken: "x"},
	)
	_, err := c.FetchOutages(context.Background())
	require.Error(t, err)
}
