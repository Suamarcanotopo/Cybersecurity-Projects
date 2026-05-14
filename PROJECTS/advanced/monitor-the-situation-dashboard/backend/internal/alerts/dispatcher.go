// ©AngelaMos | 2026
// dispatcher.go

package alerts

import (
	"context"
	"log/slog"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

// Dispatcher reads from a bus subscriber channel and pushes each event
// into the engine. Separate from the engine itself so the bus->engine
// wiring is testable in isolation.
type Dispatcher struct {
	in     <-chan events.Event
	engine *Engine
	logger *slog.Logger
}

func NewDispatcher(
	in <-chan events.Event,
	engine *Engine,
	logger *slog.Logger,
) *Dispatcher {
	if logger == nil {
		logger = slog.Default()
	}
	return &Dispatcher{in: in, engine: engine, logger: logger}
}

func (d *Dispatcher) Run(ctx context.Context) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case ev, ok := <-d.in:
			if !ok {
				return nil
			}
			d.engine.Evaluate(ctx, ev)
		}
	}
}
