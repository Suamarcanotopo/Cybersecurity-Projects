// ©AngelaMos | 2026
// limiter_test.go

package ratelimit_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/sony/gobreaker/v2"
	"github.com/stretchr/testify/require"
	"golang.org/x/time/rate"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/ratelimit"
)

func TestLimiter_AllowsAtNominalRate(t *testing.T) {
	lim := ratelimit.New[string](ratelimit.Config{
		Name:                     "test-allow",
		Rate:                     rate.Every(20 * time.Millisecond),
		Burst:                    4,
		ConsecutiveFailureBudget: 5,
		BreakerTimeout:           100 * time.Millisecond,
	})

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	calls := 0
	for i := 0; i < 4; i++ {
		_, err := lim.Do(ctx, func(_ context.Context) (string, error) {
			calls++
			return "ok", nil
		})
		require.NoError(t, err)
	}
	require.Equal(t, 4, calls)
}

func TestLimiter_OpensBreakerOnRepeatedFailures(t *testing.T) {
	lim := ratelimit.New[string](ratelimit.Config{
		Name:                     "test-fail",
		Rate:                     rate.Every(2 * time.Millisecond),
		Burst:                    10,
		ConsecutiveFailureBudget: 3,
		BreakerTimeout:           50 * time.Millisecond,
	})

	ctx := context.Background()
	failure := errors.New("upstream broken")

	for i := 0; i < 3; i++ {
		_, _ = lim.Do(
			ctx,
			func(_ context.Context) (string, error) { return "", failure },
		)
	}

	called := false
	_, err := lim.Do(ctx, func(_ context.Context) (string, error) {
		called = true
		return "", nil
	})
	require.False(
		t,
		called,
		"should not have called function — breaker should be open",
	)
	require.ErrorIs(t, err, gobreaker.ErrOpenState)
}
