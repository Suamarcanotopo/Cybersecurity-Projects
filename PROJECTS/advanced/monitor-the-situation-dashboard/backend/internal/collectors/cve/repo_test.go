// ©AngelaMos | 2026
// repo_test.go

package cve_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/jmoiron/sqlx"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/cve"
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
		CREATE TABLE cve_events (
			cve_id          text PRIMARY KEY,
			published       timestamptz,
			last_modified   timestamptz NOT NULL,
			severity        text NOT NULL DEFAULT '',
			cvss_score      numeric(3,1) NOT NULL DEFAULT 0,
			epss_score      numeric(5,4),
			epss_percentile numeric(5,4),
			in_kev          boolean NOT NULL DEFAULT false,
			payload         jsonb NOT NULL
		)`)
	require.NoError(t, err)
	return db
}

func TestRepo_UpsertThenEPSSUpdate(t *testing.T) {
	db := setupDB(t)
	repo := cve.NewRepo(db)
	ctx := context.Background()

	row := cve.Row{
		CveID:        "CVE-2026-0001",
		Published:    time.Now().UTC().Add(-time.Hour),
		LastModified: time.Now().UTC(),
		Severity:     "CRITICAL",
		CVSS:         9.8,
		Payload:      json.RawMessage(`{"id":"CVE-2026-0001"}`),
	}
	require.NoError(t, repo.Upsert(ctx, row))

	require.NoError(t, repo.UpdateEPSS(ctx, "CVE-2026-0001", 0.9512, 0.9988))

	got, err := repo.Get(ctx, "CVE-2026-0001")
	require.NoError(t, err)
	require.NotNil(t, got.EPSSScore)
	require.InDelta(t, 0.9512, *got.EPSSScore, 0.0001)
	require.NotNil(t, got.EPSSPercentile)
	require.InDelta(t, 0.9988, *got.EPSSPercentile, 0.0001)
	require.Equal(t, "CRITICAL", got.Severity)
	require.InDelta(t, 9.8, got.CVSS, 0.0001)
}

func TestRepo_UpsertOnConflictUpdatesLastModified(t *testing.T) {
	db := setupDB(t)
	repo := cve.NewRepo(db)
	ctx := context.Background()

	first := cve.Row{
		CveID:        "CVE-2026-0002",
		Published:    time.Now().UTC().Add(-2 * time.Hour),
		LastModified: time.Now().UTC().Add(-time.Hour),
		Severity:     "MEDIUM",
		CVSS:         5.0,
		Payload:      json.RawMessage(`{"v":1}`),
	}
	require.NoError(t, repo.Upsert(ctx, first))

	updated := first
	updated.LastModified = time.Now().UTC()
	updated.Severity = "HIGH"
	updated.CVSS = 7.5
	updated.Payload = json.RawMessage(`{"v":2}`)
	require.NoError(t, repo.Upsert(ctx, updated))

	got, err := repo.Get(ctx, "CVE-2026-0002")
	require.NoError(t, err)
	require.Equal(t, "HIGH", got.Severity)
	require.InDelta(t, 7.5, got.CVSS, 0.0001)
}

func TestRepo_RecentByLastModifiedOrdered(t *testing.T) {
	db := setupDB(t)
	repo := cve.NewRepo(db)
	ctx := context.Background()

	now := time.Now().UTC()
	for i, name := range []string{"CVE-A", "CVE-B", "CVE-C"} {
		require.NoError(t, repo.Upsert(ctx, cve.Row{
			CveID:        name,
			Published:    now.Add(-time.Duration(10-i) * time.Hour),
			LastModified: now.Add(-time.Duration(10-i) * time.Hour),
			Severity:     "LOW",
			Payload:      json.RawMessage(`{}`),
		}))
	}

	rows, err := repo.RecentByLastModified(ctx, 3)
	require.NoError(t, err)
	require.Len(t, rows, 3)
	require.Equal(t, "CVE-C", rows[0].CveID)
	require.Equal(t, "CVE-B", rows[1].CveID)
	require.Equal(t, "CVE-A", rows[2].CveID)
}
