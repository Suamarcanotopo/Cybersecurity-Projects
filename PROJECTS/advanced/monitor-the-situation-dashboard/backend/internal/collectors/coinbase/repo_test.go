// ©AngelaMos | 2026
// repo_test.go

package coinbase_test

import (
	"context"
	"database/sql"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/jmoiron/sqlx"
	"github.com/shopspring/decimal"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/coinbase"
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
		CREATE TABLE btc_eth_ticks (
			symbol      text NOT NULL,
			ts          timestamptz NOT NULL,
			price       numeric(18,8) NOT NULL,
			volume_24h  numeric(20,8),
			PRIMARY KEY (symbol, ts)
		);
		CREATE TABLE btc_eth_minute (
			symbol               text NOT NULL,
			minute               timestamptz NOT NULL,
			open                 numeric(18,8) NOT NULL,
			high                 numeric(18,8) NOT NULL,
			low                  numeric(18,8) NOT NULL,
			close                numeric(18,8) NOT NULL,
			volume_24h_at_close  numeric(20,8),
			PRIMARY KEY (symbol, minute)
		);`)
	require.NoError(t, err)
	return db
}

func TestRepo_InsertTickIdempotent(t *testing.T) {
	db := setupDB(t)
	repo := coinbase.NewRepo(db)
	ctx := context.Background()

	ts := time.Now().UTC().Truncate(time.Microsecond)
	tk := coinbase.Tick{
		Symbol:    "BTC-USD",
		TS:        ts,
		Price:     decimal.RequireFromString("42163.45"),
		Volume24h: decimal.RequireFromString("19834.91230000"),
	}
	require.NoError(t, repo.InsertTick(ctx, tk))
	require.NoError(t, repo.InsertTick(ctx, tk))

	got, err := repo.LatestTick(ctx, "BTC-USD")
	require.NoError(t, err)
	require.True(t, got.TS.Equal(ts))
	require.True(t, got.Price.Equal(tk.Price))
	require.True(t, got.Volume24h.Equal(tk.Volume24h))
}

func TestRepo_UpsertMinuteUpdatesOHLC(t *testing.T) {
	db := setupDB(t)
	repo := coinbase.NewRepo(db)
	ctx := context.Background()

	minute := time.Now().UTC().Truncate(time.Minute)
	bar := coinbase.MinuteBar{
		Symbol:           "ETH-USD",
		Minute:           minute,
		Open:             decimal.RequireFromString("2310.00"),
		High:             decimal.RequireFromString("2315.50"),
		Low:              decimal.RequireFromString("2308.10"),
		Close:            decimal.RequireFromString("2312.75"),
		Volume24hAtClose: decimal.RequireFromString("88.12300000"),
	}
	require.NoError(t, repo.UpsertMinute(ctx, bar))

	bar.Close = decimal.RequireFromString("2316.00")
	bar.High = decimal.RequireFromString("2317.00")
	require.NoError(t, repo.UpsertMinute(ctx, bar))

	hist, err := repo.History1h(ctx, "ETH-USD")
	require.NoError(t, err)
	require.Len(t, hist, 1)
	require.True(t, hist[0].Close.Equal(decimal.RequireFromString("2316.00")))
	require.True(t, hist[0].High.Equal(decimal.RequireFromString("2317.00")))
}

func TestRepo_History1hReturnsLast60MinutesOldestFirst(t *testing.T) {
	db := setupDB(t)
	repo := coinbase.NewRepo(db)
	ctx := context.Background()

	now := time.Now().UTC().Truncate(time.Minute)
	for i := 0; i < 75; i++ {
		bar := coinbase.MinuteBar{
			Symbol:           "BTC-USD",
			Minute:           now.Add(-time.Duration(i) * time.Minute),
			Open:             decimal.NewFromInt(int64(40000 + i)),
			High:             decimal.NewFromInt(int64(40050 + i)),
			Low:              decimal.NewFromInt(int64(39950 + i)),
			Close:            decimal.NewFromInt(int64(40010 + i)),
			Volume24hAtClose: decimal.NewFromInt(int64(i)),
		}
		require.NoError(t, repo.UpsertMinute(ctx, bar))
	}

	hist, err := repo.History1h(ctx, "BTC-USD")
	require.NoError(t, err)
	require.Len(t, hist, 60)
	require.True(
		t,
		hist[0].Minute.Before(hist[len(hist)-1].Minute),
		"history must be oldest → newest",
	)
}

func TestRepo_LatestTickMissingReturnsErrNoRows(t *testing.T) {
	db := setupDB(t)
	repo := coinbase.NewRepo(db)
	ctx := context.Background()

	_, err := repo.LatestTick(ctx, "DOES-NOT-EXIST")
	require.ErrorIs(t, err, sql.ErrNoRows)
}
