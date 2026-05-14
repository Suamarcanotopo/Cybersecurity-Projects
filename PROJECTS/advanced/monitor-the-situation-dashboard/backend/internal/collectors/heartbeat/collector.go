// ©AngelaMos | 2026
// collector.go

package heartbeat

import (
	"context"
	"time"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const defaultInterval = 5 * time.Second

type Emitter interface {
	Emit(ev events.Event)
}

type Config struct {
	Interval time.Duration
	Emitter  Emitter
}

type Collector struct {
	cfg Config
}

func New(cfg Config) *Collector {
	if cfg.Interval <= 0 {
		cfg.Interval = defaultInterval
	}
	return &Collector{cfg: cfg}
}

func (c *Collector) Name() string { return "heartbeat" }

func (c *Collector) Run(ctx context.Context) error {
	ticker := time.NewTicker(c.cfg.Interval)
	defer ticker.Stop()

	c.emitNow()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			c.emitNow()
		}
	}
}

func (c *Collector) emitNow() {
	now := time.Now().UTC()
	c.cfg.Emitter.Emit(events.Event{
		Topic:     events.TopicHeartbeat,
		Timestamp: now,
		Source:    c.Name(),
		Payload: map[string]string{
			"ts": now.Format(time.RFC3339Nano),
		},
	})
}
