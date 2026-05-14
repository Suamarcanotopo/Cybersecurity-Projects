// ©AngelaMos | 2026
// client_test.go

package swpc_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/swpc"
)

func newFakeServer(t *testing.T, route, fixture string) *httptest.Server {
	t.Helper()
	body, err := os.ReadFile("testdata/" + fixture)
	require.NoError(t, err)
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !strings.Contains(r.URL.Path, route) {
				http.Error(w, "not found", http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		}),
	)
	t.Cleanup(srv.Close)
	return srv
}

func TestClient_FetchPlasmaDecodesRowArray(t *testing.T) {
	srv := newFakeServer(t, "plasma-5-minute", "plasma.json")
	c := swpc.NewClient(swpc.ClientConfig{BaseURL: srv.URL})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	rows, err := c.FetchPlasma(ctx)
	require.NoError(t, err)
	require.GreaterOrEqual(t, len(rows), 1)
	require.False(t, rows[0].TimeTag.IsZero())
	require.NotEmpty(t, rows[0].Density)
	require.NotEmpty(t, rows[0].Speed)
}

func TestClient_FetchMagDecodesRowArray(t *testing.T) {
	srv := newFakeServer(t, "mag-5-minute", "mag.json")
	c := swpc.NewClient(swpc.ClientConfig{BaseURL: srv.URL})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	rows, err := c.FetchMag(ctx)
	require.NoError(t, err)
	require.GreaterOrEqual(t, len(rows), 1)
}

func TestClient_FetchKpDecodesObjectArray(t *testing.T) {
	srv := newFakeServer(t, "noaa-planetary-k-index", "kp.json")
	c := swpc.NewClient(swpc.ClientConfig{BaseURL: srv.URL})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	rows, err := c.FetchKp(ctx)
	require.NoError(t, err)
	require.GreaterOrEqual(t, len(rows), 1)
	require.False(t, rows[0].TimeTag.IsZero())
	require.GreaterOrEqual(t, rows[0].Kp, 0.0)
}

func TestClient_FetchXrayDecodesObjectArray(t *testing.T) {
	srv := newFakeServer(t, "xrays-1-day", "xray.json")
	c := swpc.NewClient(swpc.ClientConfig{BaseURL: srv.URL})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	rows, err := c.FetchXray(ctx)
	require.NoError(t, err)
	require.GreaterOrEqual(t, len(rows), 1)
	require.False(t, rows[0].TimeTag.IsZero())
	require.Greater(t, rows[0].Flux, 0.0)
}

func TestClient_FetchAlertsDecodes(t *testing.T) {
	srv := newFakeServer(t, "alerts.json", "alerts.json")
	c := swpc.NewClient(swpc.ClientConfig{BaseURL: srv.URL})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	rows, err := c.FetchAlerts(ctx)
	require.NoError(t, err)
	require.GreaterOrEqual(t, len(rows), 1)
	require.False(t, rows[0].IssueDatetime.IsZero())
	require.NotEmpty(t, rows[0].ProductID)
	require.NotEmpty(t, rows[0].Message)
}

func TestParseSWPCTime_AcceptsAllKnownFormats(t *testing.T) {
	cases := []string{
		"2026-05-02 08:20:00.000",
		"2026-04-25T00:00:00",
		"2026-05-01T08:24:00Z",
		"2026-05-01 15:50:32.247",
	}
	for _, s := range cases {
		got, err := swpc.ParseTime(s)
		require.NoError(t, err, "input %q", s)
		require.False(t, got.IsZero())
	}
}
