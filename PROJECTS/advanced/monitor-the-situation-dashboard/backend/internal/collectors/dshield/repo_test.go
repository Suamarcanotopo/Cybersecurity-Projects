// ©AngelaMos | 2026
// repo_test.go

package dshield_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/jmoiron/sqlx"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/dshield"
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
		CREATE TABLE dshield_snapshots (
			ts      timestamptz NOT NULL,
			kind    text NOT NULL,
			payload jsonb NOT NULL,
			PRIMARY KEY (ts, kind)
		)`)
	require.NoError(t, err)
	return db
}

func TestRepo_PutSnapshotAndReadLatest(t *testing.T) {
	db := setupDB(t)
	repo := dshield.NewRepo(db)
	ctx := context.Background()

	ts := time.Now().UTC().Truncate(time.Second)
	payload := json.RawMessage(`[{"port":"22","records":1234}]`)

	require.NoError(t, repo.PutSnapshot(ctx, ts, "topports", payload))

	rows, err := repo.LatestByKind(ctx, "topports", 1)
	require.NoError(t, err)
	require.Len(t, rows, 1)
	require.True(t, ts.Equal(rows[0].TS), "expected %s == %s", ts, rows[0].TS)
	require.Equal(t, "topports", rows[0].Kind)
	require.JSONEq(t, string(payload), string(rows[0].Payload))
}

func TestRepo_PutSnapshotIsIdempotentOnConflict(t *testing.T) {
	db := setupDB(t)
	repo := dshield.NewRepo(db)
	ctx := context.Background()

	ts := time.Now().UTC().Truncate(time.Second)
	first := json.RawMessage(`[{"port":"22"}]`)
	second := json.RawMessage(`[{"port":"22","records":99}]`)

	require.NoError(t, repo.PutSnapshot(ctx, ts, "topports", first))
	require.NoError(t, repo.PutSnapshot(ctx, ts, "topports", second))

	rows, err := repo.LatestByKind(ctx, "topports", 1)
	require.NoError(t, err)
	require.Len(t, rows, 1)
	require.JSONEq(t, string(second), string(rows[0].Payload))
}

func TestRepo_LatestByKindIsOrderedDesc(t *testing.T) {
	db := setupDB(t)
	repo := dshield.NewRepo(db)
	ctx := context.Background()

	t1 := time.Now().UTC().Add(-2 * time.Hour).Truncate(time.Second)
	t2 := time.Now().UTC().Add(-1 * time.Hour).Truncate(time.Second)
	t3 := time.Now().UTC().Truncate(time.Second)

	require.NoError(
		t,
		repo.PutSnapshot(ctx, t1, "sources", json.RawMessage(`[{"i":1}]`)),
	)
	require.NoError(
		t,
		repo.PutSnapshot(ctx, t3, "sources", json.RawMessage(`[{"i":3}]`)),
	)
	require.NoError(
		t,
		repo.PutSnapshot(ctx, t2, "sources", json.RawMessage(`[{"i":2}]`)),
	)

	rows, err := repo.LatestByKind(ctx, "sources", 3)
	require.NoError(t, err)
	require.Len(t, rows, 3)
	require.True(t, t3.Equal(rows[0].TS))
	require.True(t, t2.Equal(rows[1].TS))
	require.True(t, t1.Equal(rows[2].TS))
}
