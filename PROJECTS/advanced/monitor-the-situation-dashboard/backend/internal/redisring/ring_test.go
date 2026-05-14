// ©AngelaMos | 2026
// ring_test.go

package redisring_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	goredis "github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/require"
	tcredis "github.com/testcontainers/testcontainers-go/modules/redis"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/redisring"
)

func setupRedis(t *testing.T) *goredis.Client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	rc, err := tcredis.Run(ctx, "redis:7-alpine")
	require.NoError(t, err)
	t.Cleanup(func() { _ = rc.Terminate(context.Background()) })

	uri, err := rc.ConnectionString(ctx)
	require.NoError(t, err)
	opt, err := goredis.ParseURL(uri)
	require.NoError(t, err)
	c := goredis.NewClient(opt)
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func TestRing_PushAndRecentRoundtrips(t *testing.T) {
	c := setupRedis(t)
	r := redisring.New(c, redisring.Config{Retention: 24 * time.Hour})
	ctx := context.Background()

	now := time.Now().UTC()
	for i := 0; i < 5; i++ {
		ts := now.Add(-time.Duration(i) * time.Minute)
		require.NoError(
			t,
			r.Push(
				ctx,
				"test:key",
				ts.UnixMilli(),
				[]byte(fmt.Sprintf(`{"i":%d}`, i)),
			),
		)
	}

	got, err := r.Recent(ctx, "test:key", 3)
	require.NoError(t, err)
	require.Len(t, got, 3)
}

func TestRing_RetentionPrunesOldEntries(t *testing.T) {
	c := setupRedis(t)
	r := redisring.New(c, redisring.Config{Retention: 1 * time.Hour})
	ctx := context.Background()

	now := time.Now().UTC()
	for i := 0; i < 5; i++ {
		old := now.Add(-2 * time.Hour).Add(-time.Duration(i) * time.Minute)
		require.NoError(
			t,
			r.Push(
				ctx,
				"test:key",
				old.UnixMilli(),
				[]byte(fmt.Sprintf(`old-%d`, i)),
			),
		)
	}
	require.NoError(t, r.Push(ctx, "test:key", now.UnixMilli(), []byte("now")))

	got, err := r.Recent(ctx, "test:key", 100)
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.Equal(t, "now", string(got[0]))
}

func TestRing_RangeReturnsItemsWithinScoreWindow(t *testing.T) {
	c := setupRedis(t)
	r := redisring.New(c, redisring.Config{Retention: 24 * time.Hour})
	ctx := context.Background()

	now := time.Now().UTC()
	for i := 0; i < 10; i++ {
		ts := now.Add(-time.Duration(i) * time.Minute)
		require.NoError(
			t,
			r.Push(
				ctx,
				"test:key",
				ts.UnixMilli(),
				[]byte(fmt.Sprintf("i=%d", i)),
			),
		)
	}

	from := now.Add(-3 * time.Minute).UnixMilli()
	to := now.UnixMilli()
	got, err := r.Range(ctx, "test:key", from, to)
	require.NoError(t, err)
	require.Len(t, got, 4, "expected items in [now-3m, now] inclusive")
}
