// ©AngelaMos | 2026
// event.go

package events

import "time"

type Event struct {
	Topic     Topic     `json:"topic"`
	Timestamp time.Time `json:"timestamp"`
	Source    string    `json:"source"`
	Payload   any       `json:"payload"`
}
