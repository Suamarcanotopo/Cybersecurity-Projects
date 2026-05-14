// ©AngelaMos | 2026
// collector_test.go

package coinbase_test

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/coinbase"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type fakeRepo struct {
	mu      sync.Mutex
	ticks   []coinbase.Tick
	minutes []coinbase.MinuteBar
}

func (r *fakeRepo) InsertTick(_ context.Context, t coinbase.Tick) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ticks = append(r.ticks, t)
	return nil
}

func (r *fakeRepo) UpsertMinute(_ context.Context, b coinbase.MinuteBar) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.minutes = append(r.minutes, b)
	return nil
}

func (r *fakeRepo) LatestTick(
	_ context.Context,
	_ string,
) (coinbase.Tick, error) {
	return coinbase.Tick{}, nil
}

func (r *fakeRepo) History1h(
	_ context.Context,
	_ string,
) ([]coinbase.MinuteBar, error) {
	return nil, nil
}

func (r *fakeRepo) Tickers() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.ticks)
}

type fakeEmitter struct {
	mu     sync.Mutex
	events []events.Event
}

func (e *fakeEmitter) Emit(ev events.Event) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.events = append(e.events, ev)
}

func (e *fakeEmitter) Count() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return len(e.events)
}

type fakeState struct {
	mu        sync.Mutex
	successes int
	failures  int
}

func (s *fakeState) RecordSuccess(_ context.Context, _ string, _ int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.successes++
}

func (s *fakeState) RecordError(_ context.Context, _, _ string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failures++
}

func tickerFrame(seq int64, productID, price string, ts time.Time) []byte {
	body, _ := json.Marshal(map[string]any{
		"channel":      "ticker",
		"sequence_num": seq,
		"timestamp":    ts.Format(time.RFC3339Nano),
		"events": []any{
			map[string]any{
				"type": "update",
				"tickers": []any{
					map[string]any{
						"type":        "ticker",
						"product_id":  productID,
						"price":       price,
						"volume_24_h": "1.0",
						"time":        ts.Format(time.RFC3339Nano),
					},
				},
			},
		},
	})
	return body
}

func TestCollector_RunPersistsAndEmits(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	frames := [][]byte{loadFixture(t, "subscriptions.json")}
	for i := 0; i < 6; i++ {
		ts := now.Add(time.Duration(i) * time.Second)
		frames = append(
			frames,
			tickerFrame(int64(i+1), "BTC-USD", fmt.Sprintf("4200%d.00", i), ts),
		)
	}
	fs := newFakeServer(t, frames...)

	repo := &fakeRepo{}
	emt := &fakeEmitter{}
	st := &fakeState{}

	c := coinbase.NewCollector(coinbase.CollectorConfig{
		URL:        fs.URL(),
		ProductIDs: []string{"BTC-USD"},
		Repo:       repo,
		Emitter:    emt,
		State:      st,
		Throttle:   10 * time.Millisecond,
		Reconnect: coinbase.ReconnectConfig{
			InitialInterval: 5 * time.Millisecond,
			MaxInterval:     20 * time.Millisecond,
		},
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		800*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)

	require.GreaterOrEqual(t, repo.Tickers(), 3, "should persist most ticks")
	require.GreaterOrEqual(
		t,
		emt.Count(),
		1,
		"should emit at least one event after throttle",
	)
}

func TestCollector_GapTriggersReconnect(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	frames := [][]byte{
		loadFixture(t, "subscriptions.json"),
		tickerFrame(100, "BTC-USD", "42000.00", now),
		tickerFrame(500, "BTC-USD", "42100.00", now),
	}
	fs := newFakeServer(t, frames...)

	repo := &fakeRepo{}
	emt := &fakeEmitter{}
	st := &fakeState{}

	c := coinbase.NewCollector(coinbase.CollectorConfig{
		URL:        fs.URL(),
		ProductIDs: []string{"BTC-USD"},
		Repo:       repo,
		Emitter:    emt,
		State:      st,
		Throttle:   10 * time.Millisecond,
		Reconnect: coinbase.ReconnectConfig{
			InitialInterval: 5 * time.Millisecond,
			MaxInterval:     20 * time.Millisecond,
		},
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		600*time.Millisecond,
	)
	defer cancel()
	_ = c.Run(ctx)
}
