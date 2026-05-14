// ©AngelaMos | 2026
// repo_test.go

package state_test

import (
	"context"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/jmoiron/sqlx"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/state"
)

func setupDB(t *testing.T) *sqlx.DB {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	pg, err := postgres.Run(ctx,
		"postgres:17-alpine",
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
		CREATE TABLE collector_state (
			name             text PRIMARY KEY,
			state            text NOT NULL,
			last_success_at  timestamptz,
			last_error_at    timestamptz,
			last_error       text NOT NULL DEFAULT '',
			last_event_count bigint NOT NULL DEFAULT 0,
			updated_at       timestamptz NOT NULL DEFAULT now()
		)`)
	require.NoError(t, err)

	return db
}

func TestRepo_RecordSuccessThenError(t *testing.T) {
	db := setupDB(t)
	repo := state.NewRepo(db)
	ctx := context.Background()

	repo.RecordSuccess(ctx, "dshield", 12)

	got, found, err := repo.Get(ctx, "dshield")
	require.NoError(t, err)
	require.True(t, found)
	require.Equal(t, "dshield", got.Name)
	require.Equal(t, state.StateHealthy, got.State)
	require.EqualValues(t, 12, got.LastEventCount)
	require.NotNil(t, got.LastSuccessAt)
	require.WithinDuration(t, time.Now(), *got.LastSuccessAt, 5*time.Second)

	repo.RecordError(ctx, "dshield", "upstream 503")

	got, found, err = repo.Get(ctx, "dshield")
	require.NoError(t, err)
	require.True(t, found)
	require.Equal(t, state.StateDegraded, got.State)
	require.Equal(t, "upstream 503", got.LastError)
	require.NotNil(t, got.LastErrorAt)
	require.WithinDuration(t, time.Now(), *got.LastErrorAt, 5*time.Second)
}

func TestRepo_SuccessAccumulatesCount(t *testing.T) {
	db := setupDB(t)
	repo := state.NewRepo(db)
	ctx := context.Background()

	repo.RecordSuccess(ctx, "kev", 3)
	repo.RecordSuccess(ctx, "kev", 5)

	got, found, err := repo.Get(ctx, "kev")
	require.NoError(t, err)
	require.True(t, found)
	require.EqualValues(t, 8, got.LastEventCount)
}

func TestRepo_AllReturnsRowsSorted(t *testing.T) {
	db := setupDB(t)
	repo := state.NewRepo(db)
	ctx := context.Background()

	repo.RecordSuccess(ctx, "ransomware", 1)
	repo.RecordSuccess(ctx, "cve", 1)
	repo.RecordSuccess(ctx, "kev", 1)

	rows, err := repo.All(ctx)
	require.NoError(t, err)
	require.Len(t, rows, 3)
	require.Equal(t, "cve", rows[0].Name)
	require.Equal(t, "kev", rows[1].Name)
	require.Equal(t, "ransomware", rows[2].Name)
}
