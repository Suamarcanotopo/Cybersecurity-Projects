// ©AngelaMos | 2026
// bus_test.go

package bus_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/bus"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type capturePersister struct {
	mu    sync.Mutex
	saved []events.Event
}

func (c *capturePersister) Save(_ context.Context, ev events.Event) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.saved = append(c.saved, ev)
	return nil
}

func (c *capturePersister) Count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.saved)
}

type captureBroadcaster struct {
	mu   sync.Mutex
	sent []bus.Broadcast
}

func (b *captureBroadcaster) Broadcast(topic string, payload []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.sent = append(b.sent, bus.Broadcast{Topic: topic, Payload: payload})
}

func (b *captureBroadcaster) Count() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.sent)
}

func TestBus_EmitFlowsThroughDispatcher(t *testing.T) {
	persist := &capturePersister{}
	cast := &captureBroadcaster{}

	b := bus.New(bus.Config{
		BufferSize:  16,
		Persister:   persist,
		Broadcaster: cast,
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan error, 1)
	go func() { done <- b.Run(ctx) }()

	now := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)
	b.Emit(events.Event{
		Topic:     events.TopicHeartbeat,
		Timestamp: now,
		Source:    "heartbeat",
		Payload:   map[string]string{"ts": now.Format(time.RFC3339Nano)},
	})

	require.Eventually(t, func() bool {
		return persist.Count() == 1 && cast.Count() == 1
	}, 2*time.Second, 10*time.Millisecond)

	cancel()
	require.ErrorIs(t, <-done, context.Canceled)
}

func TestBus_DropOnFullBuffer(t *testing.T) {
	persist := &capturePersister{}
	cast := &captureBroadcaster{}

	b := bus.New(bus.Config{
		BufferSize:  1,
		Persister:   persist,
		Broadcaster: cast,
	})

	for i := 0; i < 50; i++ {
		b.Emit(events.Event{Topic: events.TopicHeartbeat, Source: "stress"})
	}
	require.Positive(t, b.DroppedCount())
}
