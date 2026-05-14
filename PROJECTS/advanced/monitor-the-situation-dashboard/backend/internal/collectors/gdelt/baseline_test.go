// ©AngelaMos | 2026
// baseline_test.go

package gdelt_test

import (
	"math"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/gdelt"
)

func TestBaseline_EmptyReturnsZeroZ(t *testing.T) {
	b := gdelt.NewThemeState(96)
	require.InDelta(t, 0.0, b.ZScore(100), 0.0001)
}

func TestBaseline_StableThenSpikeReturnsHighZ(t *testing.T) {
	b := gdelt.NewThemeState(96)
	now := time.Now().UTC()
	for i := 0; i < 96; i++ {
		b.Push(
			gdelt.Bucket{
				Score: now.Add(-time.Duration(i) * 15 * time.Minute).
					UnixMilli(),
				Count: 100 + (i % 10),
			},
		)
	}
	z := b.ZScore(500)
	require.Greater(t, z, 3.0)
}

func TestBaseline_StableThenNormalReturnsLowZ(t *testing.T) {
	b := gdelt.NewThemeState(96)
	now := time.Now().UTC()
	for i := 0; i < 96; i++ {
		b.Push(
			gdelt.Bucket{
				Score: now.Add(-time.Duration(i) * 15 * time.Minute).
					UnixMilli(),
				Count: 100 + (i % 10),
			},
		)
	}
	z := b.ZScore(108)
	require.Less(t, z, 3.0)
}

func TestBaseline_CapacityCapsBuckets(t *testing.T) {
	b := gdelt.NewThemeState(10)
	for i := 0; i < 200; i++ {
		b.Push(gdelt.Bucket{Score: int64(i), Count: i})
	}
	require.Equal(t, 10, b.Len())
}

func TestBaseline_TinyStdDevDoesNotDivByZero(t *testing.T) {
	b := gdelt.NewThemeState(96)
	now := time.Now().UTC()
	for i := 0; i < 96; i++ {
		b.Push(
			gdelt.Bucket{
				Score: now.Add(-time.Duration(i) * 15 * time.Minute).
					UnixMilli(),
				Count: 100,
			},
		)
	}
	z := b.ZScore(101)
	require.False(t, math.IsInf(z, 0))
	require.False(t, math.IsNaN(z))
}
