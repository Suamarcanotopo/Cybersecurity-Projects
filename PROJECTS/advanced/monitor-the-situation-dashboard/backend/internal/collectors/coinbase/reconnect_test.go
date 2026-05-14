// ©AngelaMos | 2026
// reconnect_test.go

package coinbase_test

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/coinbase"
)

type stubDialer struct {
	failsBeforeOK int32
	called        atomic.Int32
}

func (d *stubDialer) Dial(_ context.Context) (*coinbase.Conn, error) {
	n := d.called.Add(1)
	if n <= d.failsBeforeOK {
		return nil, errors.New("transient dial failure")
	}
	return &coinbase.Conn{}, nil
}

func TestReconnect_StopsOnContextCancel(t *testing.T) {
	d := &stubDialer{failsBeforeOK: 0}

	ctx, cancel := context.WithTimeout(
		context.Background(),
		80*time.Millisecond,
	)
	defer cancel()

	calls := atomic.Int32{}
	err := coinbase.Reconnect(ctx, d, coinbase.ReconnectConfig{
		InitialInterval: 5 * time.Millisecond,
		MaxInterval:     20 * time.Millisecond,
	}, func(_ context.Context, _ *coinbase.Conn) error {
		calls.Add(1)
		return errors.New("upstream closed")
	})
	require.True(
		t,
		errors.Is(err, context.DeadlineExceeded) ||
			errors.Is(err, context.Canceled),
	)
	require.Greater(
		t,
		calls.Load(),
		int32(1),
		"callback should fire multiple times before ctx expires",
	)
}

func TestReconnect_TransientDialFailureBacksOffThenSucceeds(t *testing.T) {
	d := &stubDialer{failsBeforeOK: 3}
	ctx, cancel := context.WithTimeout(
		context.Background(),
		500*time.Millisecond,
	)
	defer cancel()

	cbInvocations := atomic.Int32{}
	err := coinbase.Reconnect(ctx, d, coinbase.ReconnectConfig{
		InitialInterval: 10 * time.Millisecond,
		MaxInterval:     50 * time.Millisecond,
	}, func(_ context.Context, _ *coinbase.Conn) error {
		cbInvocations.Add(1)
		return errors.New("force loop")
	})
	require.True(
		t,
		errors.Is(err, context.DeadlineExceeded) ||
			errors.Is(err, context.Canceled),
	)
	require.GreaterOrEqual(
		t,
		d.called.Load(),
		int32(4),
		"must dial at least 4 times (3 failures + 1 success)",
	)
	require.GreaterOrEqual(t, cbInvocations.Load(), int32(1))
}

func TestReconnect_PermanentErrorFromCallbackPropagates(t *testing.T) {
	d := &stubDialer{failsBeforeOK: 0}
	sentinel := errors.New("hard stop")

	ctx, cancel := context.WithTimeout(
		context.Background(),
		200*time.Millisecond,
	)
	defer cancel()

	err := coinbase.Reconnect(ctx, d, coinbase.ReconnectConfig{
		InitialInterval: 5 * time.Millisecond,
		MaxInterval:     10 * time.Millisecond,
	}, func(_ context.Context, _ *coinbase.Conn) error {
		return coinbase.PermanentReconnectError(sentinel)
	})
	require.ErrorIs(t, err, sentinel)
}
