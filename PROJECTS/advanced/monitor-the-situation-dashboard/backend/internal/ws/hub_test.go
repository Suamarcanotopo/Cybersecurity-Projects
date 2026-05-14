// ©AngelaMos | 2026
// hub_test.go

package ws_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	cdrws "github.com/coder/websocket"
	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/ws"
)

func TestHub_SubscribeAndReceive(t *testing.T) {
	hub := ws.NewHub(ws.HubConfig{})

	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			c, err := cdrws.Accept(
				w,
				r,
				&cdrws.AcceptOptions{InsecureSkipVerify: true},
			)
			require.NoError(t, err)
			_ = hub.Serve(r.Context(), c, []events.Topic{events.TopicHeartbeat})
		}),
	)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	conn, _, err := cdrws.Dial(ctx, wsURL, nil)
	require.NoError(t, err)
	defer func() { _ = conn.CloseNow() }()

	require.Eventually(t, func() bool {
		return hub.SubscriberCount() == 1
	}, time.Second, 10*time.Millisecond)

	hub.Broadcast(events.TopicHeartbeat, []byte(`{"ts":"x"}`))

	_, msg, err := conn.Read(ctx)
	require.NoError(t, err)
	require.Contains(t, string(msg), `"ch":"heartbeat"`)
}

func TestHub_TopicFiltering(t *testing.T) {
	hub := ws.NewHub(ws.HubConfig{})

	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			c, err := cdrws.Accept(
				w,
				r,
				&cdrws.AcceptOptions{InsecureSkipVerify: true},
			)
			require.NoError(t, err)
			_ = hub.Serve(r.Context(), c, []events.Topic{events.TopicHeartbeat})
		}),
	)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	conn, _, err := cdrws.Dial(ctx, wsURL, nil)
	require.NoError(t, err)
	defer func() { _ = conn.CloseNow() }()

	require.Eventually(t, func() bool {
		return hub.SubscriberCount() == 1
	}, time.Second, 10*time.Millisecond)

	hub.Broadcast(events.TopicCVENew, []byte(`{"id":"CVE-2026-0001"}`))
	hub.Broadcast(events.TopicHeartbeat, []byte(`{"ts":"y"}`))

	readCtx, readCancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer readCancel()

	_, msg, err := conn.Read(readCtx)
	require.NoError(t, err)
	require.Contains(t, string(msg), `"ch":"heartbeat"`)
	require.NotContains(t, string(msg), "CVE-2026-0001")
}

// TestHub_ClientMessageDoesNotKillConnection: regression for the bug
// where Hub.Serve used c.CloseRead(ctx), which silently closes the
// connection with StatusPolicyViolation on receiving any client→server
// message. The frontend's setReady() handshake sends a `{"op":"init"}`
// line, which would trigger this and put the dashboard into a 10-second
// flap loop. Hub now drains client messages instead.
func TestHub_ClientMessageDoesNotKillConnection(t *testing.T) {
	hub := ws.NewHub(ws.HubConfig{})

	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			c, err := cdrws.Accept(
				w,
				r,
				&cdrws.AcceptOptions{InsecureSkipVerify: true},
			)
			require.NoError(t, err)
			_ = hub.Serve(r.Context(), c, []events.Topic{events.TopicHeartbeat})
		}),
	)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	conn, _, err := cdrws.Dial(ctx, wsURL, nil)
	require.NoError(t, err)
	defer func() { _ = conn.CloseNow() }()

	require.Eventually(t, func() bool {
		return hub.SubscriberCount() == 1
	}, time.Second, 10*time.Millisecond)

	require.NoError(
		t,
		conn.Write(ctx, cdrws.MessageText, []byte(`{"op":"init"}`)),
	)

	// Server must keep delivering events — pre-fix this Broadcast would
	// race with the Policy-Violation close from CloseRead and frequently
	// fail to reach the client.
	time.Sleep(100 * time.Millisecond)
	hub.Broadcast(events.TopicHeartbeat, []byte(`{"ts":"after-init"}`))

	readCtx, readCancel := context.WithTimeout(ctx, time.Second)
	defer readCancel()
	_, msg, err := conn.Read(readCtx)
	require.NoError(t, err, "connection must survive client init message")
	require.Contains(t, string(msg), "after-init")
	require.Equal(t, 1, hub.SubscriberCount())
}

func TestHub_SlowConsumerClosed(t *testing.T) {
	hub := ws.NewHub(ws.HubConfig{SubscriberBufferSize: 2})

	srv := httptest.NewServer(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			c, err := cdrws.Accept(
				w,
				r,
				&cdrws.AcceptOptions{InsecureSkipVerify: true},
			)
			require.NoError(t, err)
			_ = hub.Serve(r.Context(), c, []events.Topic{events.TopicHeartbeat})
		}),
	)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	conn, _, err := cdrws.Dial(ctx, wsURL, nil)
	require.NoError(t, err)
	defer func() { _ = conn.CloseNow() }()

	require.Eventually(t, func() bool {
		return hub.SubscriberCount() == 1
	}, time.Second, 10*time.Millisecond)

	for i := 0; i < 200; i++ {
		hub.Broadcast(events.TopicHeartbeat, []byte(`{"i":1}`))
	}

	var ce cdrws.CloseError
	for {
		_, _, err = conn.Read(ctx)
		if err == nil {
			continue
		}
		if errors.As(err, &ce) {
			break
		}
		t.Fatalf("expected close error, got %v", err)
	}
	require.Equal(t, cdrws.StatusPolicyViolation, ce.Code)
}
