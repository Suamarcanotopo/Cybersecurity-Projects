// ©AngelaMos | 2026
// broadcaster.go

package ws

import "github.com/carterperez-dev/monitor-the-situation/backend/internal/events"

type HubBroadcaster struct {
	Hub *Hub
}

func (b HubBroadcaster) Broadcast(topic string, payload []byte) {
	b.Hub.Broadcast(events.Topic(topic), payload)
}
