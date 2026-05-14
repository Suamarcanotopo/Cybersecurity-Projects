// ©AngelaMos | 2026
// repo_test.go

package cfradar_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/jmoiron/sqlx"
	"github.com/lib/pq"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/cfradar"
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
		CREATE TABLE outage_events (
			id          text PRIMARY KEY,
			started_at  timestamptz NOT NULL,
			ended_at    timestamptz,
			locations   text[] NOT NULL DEFAULT '{}',
			asns        integer[] NOT NULL DEFAULT '{}',
			cause       text NOT NULL DEFAULT '',
			outage_type text NOT NULL DEFAULT '',
			payload     jsonb NOT NULL
		);
		CREATE TABLE bgp_hijack_events (
			id            bigint PRIMARY KEY,
			detected_at   timestamptz NOT NULL,
			started_at    timestamptz NOT NULL,
			duration_sec  integer NOT NULL DEFAULT 0,
			confidence    smallint NOT NULL DEFAULT 0,
			hijacker_asn  integer NOT NULL DEFAULT 0,
			victim_asns   integer[] NOT NULL DEFAULT '{}',
			prefixes      cidr[] NOT NULL DEFAULT '{}',
			payload       jsonb NOT NULL
		)`)
	require.NoError(t, err)
	return db
}

func TestRepo_UpsertOutageIsIdempotent(t *testing.T) {
	db := setupDB(t)
	repo := cfradar.NewRepo(db)
	ctx := context.Background()

	row := cfradar.OutageRow{
		ID:         "out-1",
		StartedAt:  time.Now().UTC().Add(-time.Hour),
		Locations:  pq.StringArray{"DE", "AT"},
		ASNs:       pq.Int32Array{15169},
		Cause:      "fiber-cut",
		OutageType: "regional",
		Payload:    json.RawMessage(`{"id":"out-1"}`),
	}
	require.NoError(t, repo.UpsertOutage(ctx, row))
	require.NoError(t, repo.UpsertOutage(ctx, row))
}

func TestRepo_UpsertHijackAndDiff(t *testing.T) {
	db := setupDB(t)
	repo := cfradar.NewRepo(db)
	ctx := context.Background()

	row := cfradar.HijackRow{
		ID:          7700001,
		DetectedAt:  time.Now().UTC(),
		StartedAt:   time.Now().UTC().Add(-2 * time.Minute),
		Confidence:  9,
		HijackerASN: 64500,
		VictimASNs:  pq.Int32Array{15169, 13335},
		Prefixes:    []string{"203.0.113.0/24"},
		Payload:     json.RawMessage(`{"id":7700001}`),
	}
	require.NoError(t, repo.UpsertHijack(ctx, row))

	known, err := repo.KnownHijackIDs(ctx, []int64{7700001, 7700002})
	require.NoError(t, err)
	require.Equal(t, map[int64]bool{7700001: true}, known)
}

func TestRepo_KnownOutageIDs(t *testing.T) {
	db := setupDB(t)
	repo := cfradar.NewRepo(db)
	ctx := context.Background()

	require.NoError(t, repo.UpsertOutage(ctx, cfradar.OutageRow{
		ID: "out-known", StartedAt: time.Now().UTC(),
		Payload: json.RawMessage(`{}`),
	}))

	known, err := repo.KnownOutageIDs(ctx, []string{"out-known", "out-new"})
	require.NoError(t, err)
	require.Equal(t, map[string]bool{"out-known": true}, known)
}

func TestRepo_KnownIDsHandlesEmptySlice(t *testing.T) {
	db := setupDB(t)
	repo := cfradar.NewRepo(db)
	ctx := context.Background()

	out, err := repo.KnownOutageIDs(ctx, nil)
	require.NoError(t, err)
	require.Empty(t, out)

	hij, err := repo.KnownHijackIDs(ctx, nil)
	require.NoError(t, err)
	require.Empty(t, hij)
}
