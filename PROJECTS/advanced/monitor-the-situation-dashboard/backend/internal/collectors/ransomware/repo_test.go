// ©AngelaMos | 2026
// repo_test.go

package ransomware_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/jmoiron/sqlx"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/ransomware"
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
		CREATE TABLE ransomware_victims (
			id            text PRIMARY KEY,
			post_title    text NOT NULL,
			group_name    text NOT NULL,
			discovered_at timestamptz NOT NULL,
			country       text NOT NULL DEFAULT '',
			sector        text NOT NULL DEFAULT '',
			payload       jsonb NOT NULL
		)`)
	require.NoError(t, err)
	return db
}

func TestRepo_InsertIsIdempotent(t *testing.T) {
	db := setupDB(t)
	repo := ransomware.NewRepo(db)
	ctx := context.Background()

	row := ransomware.Row{
		ID:           "id-1",
		PostTitle:    "Acme Corp",
		GroupName:    "lockbit",
		DiscoveredAt: time.Now().UTC(),
		Country:      "US",
		Sector:       "Healthcare",
		Payload:      json.RawMessage(`{}`),
	}
	require.NoError(t, repo.Insert(ctx, row))
	require.NoError(t, repo.Insert(ctx, row))

	known, err := repo.KnownIDs(ctx, []string{"id-1", "id-2"})
	require.NoError(t, err)
	require.True(t, known["id-1"])
	require.False(t, known["id-2"])
}

func TestRepo_KnownIDsHandlesEmptySlice(t *testing.T) {
	db := setupDB(t)
	repo := ransomware.NewRepo(db)
	ctx := context.Background()

	out, err := repo.KnownIDs(ctx, nil)
	require.NoError(t, err)
	require.Empty(t, out)
}
