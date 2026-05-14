// ©AngelaMos | 2026
// envelope_test.go

package ws_test

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/ws"
)

func TestEncodeEnvelope(t *testing.T) {
	out, err := ws.EncodeEnvelope(
		"heartbeat",
		[]byte(`{"ts":"2026-05-01T00:00:00Z"}`),
	)
	require.NoError(t, err)

	var got map[string]any
	require.NoError(t, json.Unmarshal(out, &got))
	require.Equal(t, "heartbeat", got["ch"])
	require.Contains(t, got, "data")
	require.Contains(t, got, "ts")
}

func TestEncodeEnvelope_NilPayload(t *testing.T) {
	out, err := ws.EncodeEnvelope("heartbeat", nil)
	require.NoError(t, err)

	var got map[string]any
	require.NoError(t, json.Unmarshal(out, &got))
	require.Nil(t, got["data"])
}
