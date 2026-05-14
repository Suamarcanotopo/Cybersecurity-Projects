// ©AngelaMos | 2026
// client_test.go

package usgs_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/usgs"
)

func TestClient_FetchDecodesFeatures(t *testing.T) {
	body, err := os.ReadFile("testdata/2_5_day.geojson")
	require.NoError(t, err)

	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = w.Write(body)
		}),
	)
	defer srv.Close()

	c := usgs.NewClient(usgs.ClientConfig{BaseURL: srv.URL})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	feed, err := c.Fetch(ctx)
	require.NoError(t, err)
	require.GreaterOrEqual(t, len(feed.Features), 1)

	f := feed.Features[0]
	require.NotEmpty(t, f.ID)
	require.NotEmpty(t, f.Properties.Place)
	require.GreaterOrEqual(t, f.Properties.Mag, 2.5)
	require.Len(t, f.Geometry.Coordinates, 3)
	require.False(t, f.Properties.OccurredAt().IsZero())
}
