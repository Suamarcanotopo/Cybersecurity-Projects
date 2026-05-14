// ©AngelaMos | 2026
// client_test.go

package httpx_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/httpx"
)

func TestClient_GetJSONHonorsRateLimit(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			hits.Add(1)
			_, _ = w.Write([]byte(`{"ok":true}`))
		}),
	)
	defer srv.Close()

	c := httpx.New(httpx.Config{
		Name:                     "test",
		BaseURL:                  srv.URL,
		Rate:                     rate.Every(50 * time.Millisecond),
		Burst:                    1,
		ConsecutiveFailureBudget: 5,
		BreakerTimeout:           time.Second,
	})

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	start := time.Now()
	for i := 0; i < 3; i++ {
		var out struct {
			Ok bool `json:"ok"`
		}
		require.NoError(t, c.GetJSON(ctx, "/", nil, &out))
		require.True(t, out.Ok)
	}
	require.GreaterOrEqual(t, time.Since(start), 100*time.Millisecond)
	require.EqualValues(t, 3, hits.Load())
}

func TestClient_RetriesOn429WithRetryAfter(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			if hits.Add(1) == 1 {
				w.Header().Set("Retry-After", "1")
				w.WriteHeader(http.StatusTooManyRequests)
				return
			}
			_, _ = w.Write([]byte(`{"ok":true}`))
		}),
	)
	defer srv.Close()

	c := httpx.New(httpx.Config{
		Name:                     "retry",
		BaseURL:                  srv.URL,
		Rate:                     rate.Inf,
		Burst:                    10,
		ConsecutiveFailureBudget: 5,
		BreakerTimeout:           time.Second,
		MaxRetryElapsed:          3 * time.Second,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()

	var out struct {
		Ok bool `json:"ok"`
	}
	require.NoError(t, c.GetJSON(ctx, "/", nil, &out))
	require.True(t, out.Ok)
	require.EqualValues(t, 2, hits.Load())
}

func TestClient_RetriesOn5xx(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			if hits.Add(1) < 3 {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			_, _ = w.Write([]byte(`{"ok":true}`))
		}),
	)
	defer srv.Close()

	c := httpx.New(httpx.Config{
		Name:                     "5xx",
		BaseURL:                  srv.URL,
		Rate:                     rate.Inf,
		Burst:                    10,
		ConsecutiveFailureBudget: 10,
		BreakerTimeout:           time.Second,
		MaxRetryElapsed:          5 * time.Second,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	var out struct {
		Ok bool `json:"ok"`
	}
	require.NoError(t, c.GetJSON(ctx, "/", nil, &out))
	require.EqualValues(t, 3, hits.Load())
}

func TestClient_PermanentErrorOn4xx(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			hits.Add(1)
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`bad`))
		}),
	)
	defer srv.Close()

	c := httpx.New(httpx.Config{
		Name:                     "perm",
		BaseURL:                  srv.URL,
		Rate:                     rate.Inf,
		Burst:                    10,
		ConsecutiveFailureBudget: 10,
		BreakerTimeout:           time.Second,
		MaxRetryElapsed:          3 * time.Second,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	var out struct{}
	err := c.GetJSON(ctx, "/", nil, &out)
	require.Error(t, err)
	require.EqualValues(t, 1, hits.Load())
}

func TestClient_AddsBearerAndAPIKeyHeaders(t *testing.T) {
	var bearer, apiKey, ua string
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			bearer = r.Header.Get("Authorization")
			apiKey = r.Header.Get("X-Custom-Key")
			ua = r.Header.Get("User-Agent")
			_, _ = w.Write([]byte(`{}`))
		}),
	)
	defer srv.Close()

	c := httpx.New(httpx.Config{
		Name:                     "headers",
		BaseURL:                  srv.URL,
		BearerToken:              "bearer-abc",
		APIKey:                   "key-xyz",
		APIKeyHeader:             "X-Custom-Key",
		UserAgent:                "monitor-test/1.0",
		Rate:                     rate.Inf,
		Burst:                    1,
		ConsecutiveFailureBudget: 5,
		BreakerTimeout:           time.Second,
	})

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	var out struct{}
	require.NoError(t, c.GetJSON(ctx, "/", nil, &out))
	require.Equal(t, "Bearer bearer-abc", bearer)
	require.Equal(t, "key-xyz", apiKey)
	require.Equal(t, "monitor-test/1.0", ua)
}
