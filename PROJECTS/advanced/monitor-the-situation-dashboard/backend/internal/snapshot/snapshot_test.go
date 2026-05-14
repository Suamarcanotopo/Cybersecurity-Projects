// ©AngelaMos | 2026
// snapshot_test.go

package snapshot_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/require"
	tcredis "github.com/testcontainers/testcontainers-go/modules/redis"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/events"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/snapshot"
)

func startRedis(t *testing.T) *redis.Client {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	c, err := tcredis.Run(ctx, "redis:7-alpine")
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = c.Terminate(context.Background())
	})

	endpoint, err := c.Endpoint(ctx, "")
	require.NoError(t, err)
	rdb := redis.NewClient(&redis.Options{Addr: endpoint})
	t.Cleanup(func() { _ = rdb.Close() })

	return rdb
}

func TestStore_PutLatestAndGetAll(t *testing.T) {
	rdb := startRedis(t)
	store := snapshot.NewStore(rdb)

	ctx := context.Background()
	require.NoError(
		t,
		store.PutLatest(
			ctx,
			events.TopicHeartbeat,
			json.RawMessage(`{"ts":"2026-05-01T00:00:00Z"}`),
		),
	)
	require.NoError(
		t,
		store.PutLatest(
			ctx,
			events.TopicCVENew,
			json.RawMessage(`{"id":"CVE-2026-9999"}`),
		),
	)

	all, err := store.GetAll(ctx)
	require.NoError(t, err)
	require.Contains(t, all, string(events.TopicHeartbeat))
	require.Contains(t, all, string(events.TopicCVENew))

	var hb map[string]string
	require.NoError(t, json.Unmarshal(all[string(events.TopicHeartbeat)], &hb))
	require.Equal(t, "2026-05-01T00:00:00Z", hb["ts"])
}

func TestStorePersister_SavesEventPayload(t *testing.T) {
	rdb := startRedis(t)
	store := snapshot.NewStore(rdb)
	persister := snapshot.StorePersister{Store: store}

	ctx := context.Background()
	ev := events.Event{
		Topic:     events.TopicHeartbeat,
		Timestamp: time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC),
		Source:    "heartbeat",
		Payload:   map[string]string{"ts": "2026-05-01T00:00:00Z"},
	}
	require.NoError(t, persister.Save(ctx, ev))

	all, err := store.GetAll(ctx)
	require.NoError(t, err)
	require.Contains(t, all, string(events.TopicHeartbeat))
}
