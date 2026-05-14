// ©AngelaMos | 2026
// propagator_test.go

package iss_test

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/iss"
)

func loadTLE(t *testing.T) (string, string) {
	t.Helper()
	body, err := os.ReadFile("testdata/tle.txt")
	require.NoError(t, err)
	lines := strings.Split(strings.TrimSpace(string(body)), "\n")
	require.GreaterOrEqual(
		t,
		len(lines),
		3,
		"TLE file must have name + 2 element lines",
	)
	return strings.TrimRight(
			lines[1],
			" \r",
		), strings.TrimRight(
			lines[2],
			" \r",
		)
}

func TestPropagator_PositionWithinReasonableBounds(t *testing.T) {
	l1, l2 := loadTLE(t)
	sat, err := iss.LoadTLE(l1, l2)
	require.NoError(t, err)

	when := time.Date(2026, 5, 2, 3, 0, 0, 0, time.UTC)
	lat, lon, alt := iss.Propagate(sat, when)

	require.True(t, lat >= -90 && lat <= 90, "lat=%f", lat)
	require.True(t, lon >= -180 && lon <= 180, "lon=%f", lon)
	require.True(
		t,
		alt >= 350 && alt <= 500,
		"ISS altitude is roughly 380-420 km, got %f",
		alt,
	)
}

func TestPropagator_LookAnglesInValidRange(t *testing.T) {
	l1, l2 := loadTLE(t)
	sat, err := iss.LoadTLE(l1, l2)
	require.NoError(t, err)

	when := time.Date(2026, 5, 2, 3, 0, 0, 0, time.UTC)
	az, el, rng := iss.LookAngles(sat, when, 40.7128, -74.0060, 0)

	require.True(t, az >= 0 && az <= 360, "az=%f", az)
	require.True(t, el >= -90 && el <= 90, "el=%f", el)
	require.Greater(t, rng, 0.0)
}

func TestPropagator_BadTLEReturnsError(t *testing.T) {
	_, err := iss.LoadTLE("not a tle", "really not a tle")
	require.Error(t, err)
}
