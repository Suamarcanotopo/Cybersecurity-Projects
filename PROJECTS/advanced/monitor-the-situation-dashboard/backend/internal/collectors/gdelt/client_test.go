// ©AngelaMos | 2026
// client_test.go

package gdelt_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/gdelt"
)

func TestClient_FetchThemeDecodesBuckets(t *testing.T) {
	body, err := os.ReadFile("testdata/timelinevol.json")
	require.NoError(t, err)

	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			require.Equal(t, "/api/v2/doc/doc", r.URL.Path)
			require.Equal(
				t,
				"theme:NATURAL_DISASTER",
				r.URL.Query().Get("query"),
			)
			require.Equal(t, "timelinevol", r.URL.Query().Get("mode"))
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		}),
	)
	defer srv.Close()

	c := gdelt.NewClient(gdelt.ClientConfig{BaseURL: srv.URL})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	buckets, err := c.FetchTheme(ctx, "NATURAL_DISASTER")
	require.NoError(t, err)
	require.GreaterOrEqual(t, len(buckets), 1)
	for _, b := range buckets {
		require.False(t, b.Time.IsZero())
		require.Positive(t, b.Count)
		require.Equal(t, "NATURAL_DISASTER", b.Theme)
	}
}
