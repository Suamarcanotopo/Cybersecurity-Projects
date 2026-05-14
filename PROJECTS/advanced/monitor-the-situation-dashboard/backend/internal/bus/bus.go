// ©AngelaMos | 2026
// bus.go

package bus

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

const (
	defaultBufferSize     = 512
	defaultSubscriberSize = 256
)

type Config struct {
	BufferSize  int
	Persister   Persister
	Broadcaster Broadcaster
	Logger      *slog.Logger
}

type Bus struct {
	ch          chan events.Event
	persister   Persister
	broadcaster Broadcaster
	logger      *slog.Logger
	dropped     atomic.Uint64

	subsMu      sync.RWMutex
	subscribers []chan events.Event
	subDropped  atomic.Uint64
}

func New(cfg Config) *Bus {
	if cfg.BufferSize <= 0 {
		cfg.BufferSize = defaultBufferSize
	}
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &Bus{
		ch:          make(chan events.Event, cfg.BufferSize),
		persister:   cfg.Persister,
		broadcaster: cfg.Broadcaster,
		logger:      logger,
	}
}

func (b *Bus) Emit(ev events.Event) {
	select {
	case b.ch <- ev:
	default:
		b.dropped.Add(1)
		b.logger.Warn("event bus full, dropped",
			"topic", ev.Topic, "source", ev.Source)
	}
}

func (b *Bus) DroppedCount() uint64 {
	return b.dropped.Load()
}

// SubscriberDroppedCount counts events dropped to channel subscribers
// (separate from the main bus drop counter).
func (b *Bus) SubscriberDroppedCount() uint64 {
	return b.subDropped.Load()
}

// Subscribe returns a buffered channel that receives every event the bus
// sees. Slow subscribers drop events rather than block the persist+
// broadcast hot path; SubscriberDroppedCount reports total drops. Wire
// subscribers at startup before Run() begins.
func (b *Bus) Subscribe() <-chan events.Event {
	b.subsMu.Lock()
	defer b.subsMu.Unlock()
	ch := make(chan events.Event, defaultSubscriberSize)
	b.subscribers = append(b.subscribers, ch)
	return ch
}

func (b *Bus) Run(ctx context.Context) error {
	defer b.closeSubscribers()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case ev := <-b.ch:
			if b.persister != nil {
				if err := b.persister.Save(ctx, ev); err != nil {
					b.logger.Error("persist event failed",
						"err", err, "topic", ev.Topic)
				}
			}
			if b.broadcaster != nil {
				payload, err := json.Marshal(ev.Payload)
				if err != nil {
					b.logger.Error("marshal payload failed",
						"err", err, "topic", ev.Topic)
					continue
				}
				b.broadcaster.Broadcast(string(ev.Topic), payload)
			}
			b.fanout(ev)
		}
	}
}

func (b *Bus) fanout(ev events.Event) {
	b.subsMu.RLock()
	subs := b.subscribers
	b.subsMu.RUnlock()
	for _, ch := range subs {
		select {
		case ch <- ev:
		default:
			b.subDropped.Add(1)
		}
	}
}

func (b *Bus) closeSubscribers() {
	b.subsMu.Lock()
	defer b.subsMu.Unlock()
	for _, ch := range b.subscribers {
		close(ch)
	}
	b.subscribers = nil
}
