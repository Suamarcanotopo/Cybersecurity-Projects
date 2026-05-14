// ©AngelaMos | 2026
// sequencer_test.go

package coinbase_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/coinbase"
)

func TestSequencer_FirstObservationIsBaseline(t *testing.T) {
	s := coinbase.NewSequencer()
	require.False(t, s.Observe(100), "first sequence number must not be a gap")
}

func TestSequencer_ConsecutiveSequencesAreInOrder(t *testing.T) {
	s := coinbase.NewSequencer()
	for i := int64(50); i < 60; i++ {
		require.False(t, s.Observe(i), "i=%d", i)
	}
}

func TestSequencer_GapTriggersReportSignal(t *testing.T) {
	s := coinbase.NewSequencer()
	require.False(t, s.Observe(50))
	require.False(t, s.Observe(51))
	require.True(t, s.Observe(60), "skipping 52-59 must report gap")
}

func TestSequencer_ResetClearsBaseline(t *testing.T) {
	s := coinbase.NewSequencer()
	s.Observe(100)
	s.Reset()
	require.False(t, s.Observe(9999))
}

func TestSequencer_DuplicateSequenceTreatedAsGap(t *testing.T) {
	s := coinbase.NewSequencer()
	require.False(t, s.Observe(100))
	require.True(t, s.Observe(100), "replaying the same seq is a gap")
}

func TestSequencer_BackwardSequenceTreatedAsGap(t *testing.T) {
	s := coinbase.NewSequencer()
	require.False(t, s.Observe(100))
	require.True(t, s.Observe(90))
}
