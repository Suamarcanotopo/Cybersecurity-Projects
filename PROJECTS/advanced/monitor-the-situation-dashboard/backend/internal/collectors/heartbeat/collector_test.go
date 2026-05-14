// ©AngelaMos | 2026
// collector_test.go

package heartbeat_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/heartbeat"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type collectingEmitter struct {
	mu     sync.Mutex
	events []events.Event
}

func (c *collectingEmitter) Emit(ev events.Event) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.events = append(c.events, ev)
}

func (c *collectingEmitter) Count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.events)
}

func (c *collectingEmitter) Last() events.Event {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.events[len(c.events)-1]
}

func TestCollector_EmitsAtInterval(t *testing.T) {
	emitter := &collectingEmitter{}
	c := heartbeat.New(heartbeat.Config{
		Interval: 50 * time.Millisecond,
		Emitter:  emitter,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		200*time.Millisecond,
	)
	defer cancel()

	err := c.Run(ctx)
	require.ErrorIs(t, err, context.DeadlineExceeded)

	require.GreaterOrEqual(t, emitter.Count(), 3)
	last := emitter.Last()
	require.Equal(t, events.TopicHeartbeat, last.Topic)
	require.Equal(t, "heartbeat", last.Source)
}

func TestCollector_EmitsImmediatelyOnStart(t *testing.T) {
	emitter := &collectingEmitter{}
	c := heartbeat.New(heartbeat.Config{
		Interval: time.Hour,
		Emitter:  emitter,
	})

	ctx, cancel := context.WithTimeout(
		context.Background(),
		50*time.Millisecond,
	)
	defer cancel()

	_ = c.Run(ctx)
	require.Equal(
		t,
		1,
		emitter.Count(),
		"should emit one tick immediately on start",
	)
}
