// ©AngelaMos | 2026
// event_test.go

package events_test

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
)

func TestEvent_JSONRoundTrip(t *testing.T) {
	now := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)
	original := events.Event{
		Topic:     events.TopicHeartbeat,
		Timestamp: now,
		Source:    "heartbeat",
		Payload:   map[string]any{"ts": now.Format(time.RFC3339Nano)},
	}

	raw, err := json.Marshal(original)
	require.NoError(t, err)

	var decoded events.Event
	require.NoError(t, json.Unmarshal(raw, &decoded))

	require.Equal(t, original.Topic, decoded.Topic)
	require.Equal(t, original.Source, decoded.Source)
	require.True(t, original.Timestamp.Equal(decoded.Timestamp))
}

func TestTopic_IsValid(t *testing.T) {
	require.True(t, events.TopicHeartbeat.IsValid())
	require.True(t, events.TopicCVENew.IsValid())
	require.False(t, events.Topic("bogus").IsValid())
}

func TestAllTopics_AllValid(t *testing.T) {
	all := events.AllTopics()
	require.NotEmpty(t, all)
	for _, top := range all {
		require.True(t, top.IsValid(), "topic %q should be valid", top)
	}
}
