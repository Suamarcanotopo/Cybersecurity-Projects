// ©AngelaMos | 2026
// handler_test.go

package ws_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	cdrws "github.com/coder/websocket"
	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/ws"
)

func TestHandler_PerIPCap_RejectsBeyondLimit(t *testing.T) {
	hub := ws.NewHub(ws.HubConfig{})
	h := ws.NewHandlerWithConfig(ws.HandlerConfig{
		Hub:           hub,
		MaxConnsPerIP: 2,
	})
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			r.RemoteAddr = "203.0.113.7:1111"
			h.ServeHTTP(w, r)
		}),
	)
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	conns := make([]*cdrws.Conn, 0, 2)
	for i := 0; i < 2; i++ {
		c, _, err := cdrws.Dial(ctx, wsURL, nil)
		require.NoError(t, err)
		conns = append(conns, c)
	}
	require.Eventually(t, func() bool {
		return hub.SubscriberCount() == 2
	}, time.Second, 10*time.Millisecond)

	_, resp, err := cdrws.Dial(ctx, wsURL, nil)
	require.Error(t, err, "third connection from same IP must be rejected")
	if resp != nil {
		require.Equal(t, http.StatusTooManyRequests, resp.StatusCode)
	}

	for _, c := range conns {
		_ = c.CloseNow()
	}
}

func TestHandler_HubCapacity_RefusesNewConn(t *testing.T) {
	hub := ws.NewHub(ws.HubConfig{MaxSubscribers: 1})
	h := ws.NewHandlerWithConfig(ws.HandlerConfig{
		Hub:           hub,
		MaxConnsPerIP: 100,
	})
	var ipMu sync.Mutex
	ipCounter := 0
	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ipMu.Lock()
			ipCounter++
			r.RemoteAddr = "10.0.0." + string(rune('0'+ipCounter)) + ":1111"
			ipMu.Unlock()
			h.ServeHTTP(w, r)
		}),
	)
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	c1, _, err := cdrws.Dial(ctx, wsURL, nil)
	require.NoError(t, err)
	defer func() { _ = c1.CloseNow() }()

	require.Eventually(t, func() bool {
		return hub.SubscriberCount() == 1
	}, time.Second, 10*time.Millisecond)

	c2, _, err := cdrws.Dial(ctx, wsURL, nil)
	if err == nil {
		_, _, readErr := c2.Read(ctx)
		require.Error(
			t,
			readErr,
			"second connection should be closed by hub at capacity",
		)
		_ = c2.CloseNow()
	}
}
