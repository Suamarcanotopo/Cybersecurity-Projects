// ©AngelaMos | 2026
// persister.go

package bus

import (
	"context"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

type Persister interface {
	Save(ctx context.Context, ev events.Event) error
}

type Broadcaster interface {
	Broadcast(topic string, payload []byte)
}

type Broadcast struct {
	Topic   string
	Payload []byte
}
