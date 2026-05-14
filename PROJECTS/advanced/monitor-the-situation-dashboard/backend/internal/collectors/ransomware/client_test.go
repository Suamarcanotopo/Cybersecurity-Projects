// ©AngelaMos | 2026
// client_test.go

package ransomware_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/ransomware"
)

func TestClient_FetchRecentVictimsDecodes(t *testing.T) {
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			body, err := os.ReadFile("testdata/recentvictims.json")
			require.NoError(t, err)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(body)
		}),
	)
	defer srv.Close()

	c := ransomware.NewClient(ransomware.ClientConfig{BaseURL: srv.URL})
	vs, err := c.FetchRecent(context.Background())
	require.NoError(t, err)
	require.Len(t, vs, 3)
	require.Equal(t, "Acme Healthcare Corp", vs[0].PostTitle)
	require.Equal(t, "lockbit", vs[0].GroupName)
}

func TestVictim_IDIsStableAndCollisionFree(t *testing.T) {
	d, _ := time.Parse(time.RFC3339, "2026-05-01T00:00:00Z")
	v1 := ransomware.Victim{PostTitle: "X", GroupName: "lockbit", Discovered: d}
	v2 := ransomware.Victim{PostTitle: "X", GroupName: "lockbit", Discovered: d}
	v3 := ransomware.Victim{PostTitle: "Y", GroupName: "lockbit", Discovered: d}

	require.Equal(t, v1.ID(), v2.ID())
	require.NotEqual(t, v1.ID(), v3.ID())
}
