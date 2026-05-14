// ©AngelaMos | 2026
// subscriber.go

package ws

import "github.com/carterperez-dev/monitor-the-situation/backend/internal/events"

type subscriber struct {
	topics    map[events.Topic]struct{}
	msgs      chan []byte
	closeSlow func()
}

func newSubscriber(
	topics []events.Topic,
	bufSize int,
	closeSlow func(),
) *subscriber {
	t := make(map[events.Topic]struct{}, len(topics))
	for _, top := range topics {
		t[top] = struct{}{}
	}
	return &subscriber{
		topics:    t,
		msgs:      make(chan []byte, bufSize),
		closeSlow: closeSlow,
	}
}
