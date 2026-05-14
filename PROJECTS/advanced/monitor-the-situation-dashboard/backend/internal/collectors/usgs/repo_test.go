// ©AngelaMos | 2026
// repo_test.go

package usgs_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/jmoiron/sqlx"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/usgs"
)

func setupDB(t *testing.T) *sqlx.DB {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	pg, err := postgres.Run(ctx, "postgres:17-alpine",
		postgres.WithDatabase("monitor"),
		postgres.WithUsername("monitor"),
		postgres.WithPassword("monitor"),
		postgres.BasicWaitStrategies(),
	)
	require.NoError(t, err)
	t.Cleanup(func() { _ = pg.Terminate(context.Background()) })

	dsn, err := pg.ConnectionString(ctx, "sslmode=disable")
	require.NoError(t, err)

	db, err := sqlx.ConnectContext(ctx, "pgx", dsn)
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	_, err = db.ExecContext(ctx, `
		CREATE TABLE earthquakes (
			id              text PRIMARY KEY,
			occurred_at     timestamptz NOT NULL,
			mag             numeric(3,1) NOT NULL,
			place           text,
			geom_lon        double precision NOT NULL,
			geom_lat        double precision NOT NULL,
			depth_km        double precision,
			payload         jsonb NOT NULL
		);`)
	require.NoError(t, err)
	return db
}

func TestRepo_UpsertOverwritesRevisions(t *testing.T) {
	db := setupDB(t)
	repo := usgs.NewRepo(db)
	ctx := context.Background()

	row := usgs.Row{
		ID:         "us6000abcd",
		OccurredAt: time.Now().UTC().Add(-time.Hour),
		Mag:        5.5,
		Place:      "100 km SW of test",
		GeomLon:    -130.5,
		GeomLat:    49.2,
		DepthKm:    10.0,
		Payload:    json.RawMessage(`{"v":1}`),
	}
	require.NoError(t, repo.Upsert(ctx, row))

	row.Mag = 5.8
	row.Payload = json.RawMessage(`{"v":2}`)
	require.NoError(t, repo.Upsert(ctx, row))

	got, err := repo.RecentByMag(ctx, 1)
	require.NoError(t, err)
	require.Len(t, got, 1)
	require.InDelta(t, 5.8, got[0].Mag, 0.0001)
}

func TestRepo_KnownIDsBulkLookup(t *testing.T) {
	db := setupDB(t)
	repo := usgs.NewRepo(db)
	ctx := context.Background()

	for _, id := range []string{"a", "b", "c"} {
		require.NoError(t, repo.Upsert(ctx, usgs.Row{
			ID: id, OccurredAt: time.Now().UTC(), Mag: 4.5,
			GeomLon: 0, GeomLat: 0, Payload: json.RawMessage(`{}`),
		}))
	}

	known, err := repo.KnownIDs(ctx, []string{"a", "b", "x", "y"})
	require.NoError(t, err)
	require.True(t, known["a"])
	require.True(t, known["b"])
	require.False(t, known["x"])
	require.False(t, known["y"])
}

func TestRepo_RecentByMagOrdered(t *testing.T) {
	db := setupDB(t)
	repo := usgs.NewRepo(db)
	ctx := context.Background()

	now := time.Now().UTC()
	rows := []usgs.Row{
		{
			ID:         "small",
			OccurredAt: now,
			Mag:        4.5,
			GeomLon:    0,
			GeomLat:    0,
			Payload:    json.RawMessage(`{}`),
		},
		{
			ID:         "huge",
			OccurredAt: now,
			Mag:        7.8,
			GeomLon:    0,
			GeomLat:    0,
			Payload:    json.RawMessage(`{}`),
		},
		{
			ID:         "mid",
			OccurredAt: now,
			Mag:        6.0,
			GeomLon:    0,
			GeomLat:    0,
			Payload:    json.RawMessage(`{}`),
		},
	}
	for _, r := range rows {
		require.NoError(t, repo.Upsert(ctx, r))
	}

	got, err := repo.RecentByMag(ctx, 3)
	require.NoError(t, err)
	require.Len(t, got, 3)
	require.Equal(t, "huge", got[0].ID)
	require.Equal(t, "mid", got[1].ID)
	require.Equal(t, "small", got[2].ID)
}
