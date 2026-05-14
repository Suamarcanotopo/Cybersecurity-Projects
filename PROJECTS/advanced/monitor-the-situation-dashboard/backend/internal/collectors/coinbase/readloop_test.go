// ©AngelaMos | 2026
// readloop_test.go

package coinbase_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/coinbase"
)

func TestReadLoop_DeliversTickerFrames(t *testing.T) {
	fs := newFakeServer(
		t,
		loadFixture(t, "subscriptions.json"),
		[]byte(
			`{"channel":"ticker","sequence_num":1000,"timestamp":"2026-05-01T22:30:00Z","events":[{"type":"update","tickers":[{"product_id":"BTC-USD","price":"42000.00","volume_24_h":"1.0","time":"2026-05-01T22:30:00Z"}]}]}`,
		),
		[]byte(
			`{"channel":"ticker","sequence_num":1001,"timestamp":"2026-05-01T22:30:01Z","events":[{"type":"update","tickers":[{"product_id":"BTC-USD","price":"42001.00","volume_24_h":"1.0","time":"2026-05-01T22:30:01Z"}]}]}`,
		),
	)

	d := coinbase.NewWSDialer(
		coinbase.DialerConfig{URL: fs.URL(), ProductIDs: []string{"BTC-USD"}},
	)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	conn, err := d.Dial(ctx)
	require.NoError(t, err)
	defer conn.Close()

	seq := coinbase.NewSequencer()
	mu := sync.Mutex{}
	tickerFrames := 0

	loopCtx, loopCancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer loopCancel()

	err = coinbase.ReadLoop(
		loopCtx,
		conn,
		seq,
		func(_ context.Context, f coinbase.Frame) error {
			mu.Lock()
			defer mu.Unlock()
			if f.Kind == coinbase.FrameTypeTicker {
				tickerFrames++
			}
			return nil
		},
	)
	require.True(
		t,
		errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) ||
			err == nil,
	)
	mu.Lock()
	defer mu.Unlock()
	require.GreaterOrEqual(t, tickerFrames, 2)
}

func TestReadLoop_GapIsLoggedButLoopContinues(t *testing.T) {
	fs := newFakeServer(
		t,
		loadFixture(t, "subscriptions.json"),
		[]byte(
			`{"channel":"ticker","sequence_num":100,"timestamp":"2026-05-01T22:30:00Z","events":[{"type":"update","tickers":[{"product_id":"BTC-USD","price":"42000.00","volume_24_h":"1.0","time":"2026-05-01T22:30:00Z"}]}]}`,
		),
		[]byte(
			`{"channel":"ticker","sequence_num":250,"timestamp":"2026-05-01T22:30:01Z","events":[{"type":"update","tickers":[{"product_id":"BTC-USD","price":"42001.00","volume_24_h":"1.0","time":"2026-05-01T22:30:01Z"}]}]}`,
		),
	)

	d := coinbase.NewWSDialer(
		coinbase.DialerConfig{URL: fs.URL(), ProductIDs: []string{"BTC-USD"}},
	)
	ctx, cancel := context.WithTimeout(
		context.Background(),
		600*time.Millisecond,
	)
	defer cancel()
	conn, err := d.Dial(ctx)
	require.NoError(t, err)
	defer conn.Close()

	seq := coinbase.NewSequencer()
	delivered := 0
	loopErr := coinbase.ReadLoop(
		ctx,
		conn,
		seq,
		func(_ context.Context, f coinbase.Frame) error {
			if f.Kind == coinbase.FrameTypeTicker {
				delivered++
			}
			return nil
		},
	)
	require.True(
		t,
		errors.Is(loopErr, context.DeadlineExceeded) || errors.Is(loopErr, context.Canceled) ||
			loopErr == nil,
	)
	require.Equal(
		t,
		2,
		delivered,
		"both ticker frames must be delivered despite the gap",
	)
}

func TestReadLoop_SnapshotResetsSequencer(t *testing.T) {
	fs := newFakeServer(
		t,
		loadFixture(t, "subscriptions.json"),
		loadFixture(t, "snapshot.json"),
		[]byte(
			`{"channel":"ticker","sequence_num":2,"timestamp":"2026-05-01T22:30:02Z","events":[{"type":"update","tickers":[{"product_id":"BTC-USD","price":"42164.00","volume_24_h":"1.0","time":"2026-05-01T22:30:02Z"}]}]}`,
		),
	)

	d := coinbase.NewWSDialer(
		coinbase.DialerConfig{URL: fs.URL(), ProductIDs: []string{"BTC-USD"}},
	)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	conn, err := d.Dial(ctx)
	require.NoError(t, err)
	defer conn.Close()

	seq := coinbase.NewSequencer()
	mu := sync.Mutex{}
	kinds := []coinbase.FrameType{}

	loopCtx, loopCancel := context.WithTimeout(ctx, 800*time.Millisecond)
	defer loopCancel()
	err = coinbase.ReadLoop(
		loopCtx,
		conn,
		seq,
		func(_ context.Context, f coinbase.Frame) error {
			mu.Lock()
			defer mu.Unlock()
			kinds = append(kinds, f.Kind)
			return nil
		},
	)
	require.True(
		t,
		errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) ||
			err == nil,
	)

	mu.Lock()
	defer mu.Unlock()
	require.Contains(t, kinds, coinbase.FrameTypeSnapshot)
	require.Contains(t, kinds, coinbase.FrameTypeTicker)
}
