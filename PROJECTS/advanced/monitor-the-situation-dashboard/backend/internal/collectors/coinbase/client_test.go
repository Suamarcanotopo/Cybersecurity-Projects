// ©AngelaMos | 2026
// client_test.go

package coinbase_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/coinbase"
)

type fakeServer struct {
	t        *testing.T
	frames   [][]byte
	received []string
	mu       sync.Mutex
	srv      *httptest.Server
}

func newFakeServer(t *testing.T, frames ...[]byte) *fakeServer {
	t.Helper()
	fs := &fakeServer{t: t, frames: frames}
	fs.srv = httptest.NewServer(http.HandlerFunc(fs.handle))
	t.Cleanup(fs.srv.Close)
	return fs
}

func (fs *fakeServer) URL() string {
	return "ws" + strings.TrimPrefix(fs.srv.URL, "http")
}

func (fs *fakeServer) Received() []string {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	out := make([]string, len(fs.received))
	copy(out, fs.received)
	return out
}

func (fs *fakeServer) handle(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	for i := 0; i < 2; i++ {
		_, msg, err := conn.Read(ctx)
		if err != nil {
			return
		}
		fs.mu.Lock()
		fs.received = append(fs.received, string(msg))
		fs.mu.Unlock()
	}

	for _, frame := range fs.frames {
		if err := conn.Write(ctx, websocket.MessageText, frame); err != nil {
			return
		}
	}

	<-ctx.Done()
}

func loadFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	require.NoError(t, err)
	return b
}

func TestClient_DialSubscribesTickerAndHeartbeats(t *testing.T) {
	fs := newFakeServer(t,
		loadFixture(t, "subscriptions.json"),
		loadFixture(t, "ticker.json"),
	)

	d := coinbase.NewWSDialer(coinbase.DialerConfig{
		URL:        fs.URL(),
		ProductIDs: []string{"BTC-USD", "ETH-USD"},
	})

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	conn, err := d.Dial(ctx)
	require.NoError(t, err)
	defer conn.Close()

	frame, err := conn.ReadFrame(ctx)
	require.NoError(t, err)
	require.Equal(t, coinbase.FrameTypeSubscriptions, frame.Kind)

	frame, err = conn.ReadFrame(ctx)
	require.NoError(t, err)
	require.Equal(t, coinbase.FrameTypeTicker, frame.Kind)
	require.Len(t, frame.Tickers, 1)
	require.Equal(t, "BTC-USD", frame.Tickers[0].ProductID)
	require.Equal(t, "42163.45", frame.Tickers[0].Price.String())

	require.Eventually(t, func() bool {
		recv := fs.Received()
		if len(recv) < 2 {
			return false
		}
		var subTicker, subHB struct {
			Type       string   `json:"type"`
			ProductIDs []string `json:"product_ids"`
			Channel    string   `json:"channel"`
		}
		if err := json.Unmarshal([]byte(recv[0]), &subTicker); err != nil {
			return false
		}
		if err := json.Unmarshal([]byte(recv[1]), &subHB); err != nil {
			return false
		}
		return subTicker.Type == "subscribe" &&
			subTicker.Channel == "ticker" &&
			len(subTicker.ProductIDs) == 2 &&
			subHB.Type == "subscribe" &&
			subHB.Channel == "heartbeats"
	}, time.Second, 20*time.Millisecond)
}

func TestClient_DecodeSnapshotFrameYieldsAllTickers(t *testing.T) {
	fs := newFakeServer(t,
		loadFixture(t, "subscriptions.json"),
		loadFixture(t, "snapshot.json"),
	)

	d := coinbase.NewWSDialer(coinbase.DialerConfig{
		URL:        fs.URL(),
		ProductIDs: []string{"BTC-USD", "ETH-USD"},
	})

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	conn, err := d.Dial(ctx)
	require.NoError(t, err)
	defer conn.Close()

	for {
		frame, err := conn.ReadFrame(ctx)
		require.NoError(t, err)
		if frame.Kind == coinbase.FrameTypeSnapshot {
			require.Len(t, frame.Tickers, 2)
			return
		}
	}
}

func TestClient_DecodeHeartbeatExposesCurrentTime(t *testing.T) {
	fs := newFakeServer(t,
		loadFixture(t, "subscriptions.json"),
		loadFixture(t, "heartbeats.json"),
	)

	d := coinbase.NewWSDialer(
		coinbase.DialerConfig{URL: fs.URL(), ProductIDs: []string{"BTC-USD"}},
	)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	conn, err := d.Dial(ctx)
	require.NoError(t, err)
	defer conn.Close()

	for {
		frame, err := conn.ReadFrame(ctx)
		require.NoError(t, err)
		if frame.Kind == coinbase.FrameTypeHeartbeats {
			require.False(t, frame.HeartbeatTime.IsZero())
			return
		}
	}
}
