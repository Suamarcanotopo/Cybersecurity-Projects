// ©AngelaMos | 2026
// client_test.go

package wikipedia_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/wikipedia"
)

func TestClient_FetchDecodesITNResponse(t *testing.T) {
	body, err := os.ReadFile("testdata/itn_response.json")
	require.NoError(t, err)

	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			require.Equal(t, "/w/api.php", r.URL.Path)
			require.Equal(t, "parse", r.URL.Query().Get("action"))
			require.Equal(t, "Template:In_the_news", r.URL.Query().Get("page"))
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		}),
	)
	defer srv.Close()

	c := wikipedia.NewClient(wikipedia.ClientConfig{BaseURL: srv.URL})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	resp, err := c.Fetch(ctx)
	require.NoError(t, err)
	require.NotZero(t, resp.RevID)
	require.NotEmpty(t, resp.HTML)
}
