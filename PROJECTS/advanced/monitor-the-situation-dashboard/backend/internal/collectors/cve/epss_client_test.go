// ©AngelaMos | 2026
// epss_client_test.go

package cve_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/cve"
)

func TestEPSSClient_BatchLookupDecodesScores(t *testing.T) {
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ids := r.URL.Query().Get("cve")
			require.Contains(t, ids, "CVE-2024-3094")
			body, err := os.ReadFile("testdata/epss_batch.json")
			require.NoError(t, err)
			_, _ = w.Write(body)
		}),
	)
	defer srv.Close()

	c := cve.NewEPSSClient(cve.EPSSClientConfig{BaseURL: srv.URL})
	scores, err := c.LookupBatch(
		context.Background(),
		[]string{"CVE-2024-3094", "CVE-2024-21413"},
	)
	require.NoError(t, err)
	require.NotEmpty(t, scores)

	got := scores["CVE-2024-3094"]
	require.InDelta(t, 0.84588, got.Score, 0.0001)
	require.InDelta(t, 0.99335, got.Percentile, 0.0001)
}

func TestEPSSClient_ChunksOver100PerRequest(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			hits.Add(1)
			_, _ = w.Write([]byte(`{"data":[]}`))
		}),
	)
	defer srv.Close()

	c := cve.NewEPSSClient(cve.EPSSClientConfig{BaseURL: srv.URL})

	ids := make([]string, 250)
	for i := range ids {
		ids[i] = "CVE-2024-X"
	}
	_, err := c.LookupBatch(context.Background(), ids)
	require.NoError(t, err)
	require.EqualValues(t, 3, hits.Load())
}

func TestEPSSClient_EmptyInputReturnsEmptyMap(t *testing.T) {
	c := cve.NewEPSSClient(cve.EPSSClientConfig{BaseURL: "http://invalid"})
	out, err := c.LookupBatch(context.Background(), nil)
	require.NoError(t, err)
	require.Empty(t, out)
}
