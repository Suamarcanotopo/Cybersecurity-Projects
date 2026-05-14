// ©AngelaMos | 2026
// repo.go

package coinbase

import (
	"context"
	"fmt"
	"time"

	"github.com/jmoiron/sqlx"
	"github.com/shopspring/decimal"
)

const (
	history1hLimit = 60
)

type Tick struct {
	Symbol    string          `db:"symbol"`
	TS        time.Time       `db:"ts"`
	Price     decimal.Decimal `db:"price"`
	Volume24h decimal.Decimal `db:"volume_24h"`
}

// MinuteBar holds a per-minute OHLC for a symbol plus the rolling 24h
// volume sampled at the minute's close. The Coinbase ticker channel only
// publishes 24h volume, not per-trade size, so true per-minute volume
// would require the market_trades channel — out of scope here.
type MinuteBar struct {
	Symbol           string          `db:"symbol"`
	Minute           time.Time       `db:"minute"`
	Open             decimal.Decimal `db:"open"`
	High             decimal.Decimal `db:"high"`
	Low              decimal.Decimal `db:"low"`
	Close            decimal.Decimal `db:"close"`
	Volume24hAtClose decimal.Decimal `db:"volume_24h_at_close"`
}

type Repo struct {
	db *sqlx.DB
}

func NewRepo(db *sqlx.DB) *Repo { return &Repo{db: db} }

func (r *Repo) InsertTick(ctx context.Context, t Tick) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO btc_eth_ticks (symbol, ts, price, volume_24h)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (symbol, ts) DO NOTHING`,
		t.Symbol, t.TS, t.Price, t.Volume24h,
	)
	if err != nil {
		return fmt.Errorf("insert tick %s @ %s: %w", t.Symbol, t.TS, err)
	}
	return nil
}

func (r *Repo) UpsertMinute(ctx context.Context, b MinuteBar) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO btc_eth_minute (symbol, minute, open, high, low, close, volume_24h_at_close)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (symbol, minute) DO UPDATE SET
			open                = EXCLUDED.open,
			high                = EXCLUDED.high,
			low                 = EXCLUDED.low,
			close               = EXCLUDED.close,
			volume_24h_at_close = EXCLUDED.volume_24h_at_close`,
		b.Symbol, b.Minute, b.Open, b.High, b.Low, b.Close, b.Volume24hAtClose,
	)
	if err != nil {
		return fmt.Errorf("upsert minute %s @ %s: %w", b.Symbol, b.Minute, err)
	}
	return nil
}

func (r *Repo) LatestTick(ctx context.Context, symbol string) (Tick, error) {
	var t Tick
	err := r.db.GetContext(ctx, &t, `
		SELECT symbol, ts, price, volume_24h
		  FROM btc_eth_ticks
		 WHERE symbol = $1
		 ORDER BY ts DESC LIMIT 1`, symbol)
	if err != nil {
		return Tick{}, err
	}
	return t, nil
}

func (r *Repo) History1h(
	ctx context.Context,
	symbol string,
) ([]MinuteBar, error) {
	var rows []MinuteBar
	err := r.db.SelectContext(ctx, &rows, `
		SELECT symbol, minute, open, high, low, close, volume_24h_at_close
		  FROM btc_eth_minute
		 WHERE symbol = $1
		 ORDER BY minute DESC LIMIT $2`, symbol, history1hLimit,
	)
	if err != nil {
		return nil, fmt.Errorf("history1h %s: %w", symbol, err)
	}
	for i, j := 0, len(rows)-1; i < j; i, j = i+1, j-1 {
		rows[i], rows[j] = rows[j], rows[i]
	}
	return rows, nil
}
