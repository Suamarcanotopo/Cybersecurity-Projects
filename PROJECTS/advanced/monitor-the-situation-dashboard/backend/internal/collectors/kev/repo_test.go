// ©AngelaMos | 2026
// repo_test.go

package kev_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/jmoiron/sqlx"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/kev"
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
		CREATE TABLE kev_entries (
			cve_id              text PRIMARY KEY,
			vendor              text NOT NULL DEFAULT '',
			product             text NOT NULL DEFAULT '',
			vulnerability_name  text NOT NULL DEFAULT '',
			date_added          date NOT NULL,
			due_date            date,
			ransomware_use      text NOT NULL DEFAULT '',
			payload             jsonb NOT NULL
		)`)
	require.NoError(t, err)
	return db
}

func TestRepo_InsertAndKnownIDs(t *testing.T) {
	db := setupDB(t)
	repo := kev.NewRepo(db)
	ctx := context.Background()
	added := time.Date(2026, 4, 30, 0, 0, 0, 0, time.UTC)

	require.NoError(t, repo.Insert(ctx, kev.Row{
		CveID:             "CVE-2024-3094",
		Vendor:            "JiaT75",
		Product:           "xz",
		VulnerabilityName: "Backdoor",
		DateAdded:         added,
		Payload:           json.RawMessage(`{"cveID":"CVE-2024-3094"}`),
	}))

	known, err := repo.KnownIDs(
		ctx,
		[]string{"CVE-2024-3094", "CVE-2024-MISSING"},
	)
	require.NoError(t, err)
	require.True(t, known["CVE-2024-3094"])
	require.False(t, known["CVE-2024-MISSING"])
}

func TestRepo_InsertIsIdempotent(t *testing.T) {
	db := setupDB(t)
	repo := kev.NewRepo(db)
	ctx := context.Background()

	row := kev.Row{
		CveID:     "CVE-2024-X",
		Vendor:    "v1",
		DateAdded: time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC),
		Payload:   json.RawMessage(`{}`),
	}
	require.NoError(t, repo.Insert(ctx, row))

	updated := row
	updated.Vendor = "v2"
	require.NoError(t, repo.Insert(ctx, updated))

	count, err := repo.Count(ctx)
	require.NoError(t, err)
	require.EqualValues(t, 1, count)
}

func TestRepo_CountReflectsTotal(t *testing.T) {
	db := setupDB(t)
	repo := kev.NewRepo(db)
	ctx := context.Background()
	added := time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC)

	for _, id := range []string{"CVE-A", "CVE-B", "CVE-C"} {
		require.NoError(t, repo.Insert(ctx, kev.Row{
			CveID: id, DateAdded: added, Payload: json.RawMessage(`{}`),
		}))
	}

	count, err := repo.Count(ctx)
	require.NoError(t, err)
	require.EqualValues(t, 3, count)
}
