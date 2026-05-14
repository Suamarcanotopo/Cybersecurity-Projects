-- ©AngelaMos | 2026
-- 0005_minute_bar_volume_rename.sql

-- The Coinbase ticker channel publishes a rolling 24-hour volume, not per-trade
-- size, so the `volume` column on btc_eth_minute was always a snapshot of the
-- 24h figure at the close of that minute — never per-minute volume. Renaming
-- to `volume_24h_at_close` so the column name stops lying. Per-minute volume
-- requires the level2 / market_trades channel; that's a separate change.

-- +goose Up
-- +goose StatementBegin
ALTER TABLE btc_eth_minute RENAME COLUMN volume TO volume_24h_at_close;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE btc_eth_minute RENAME COLUMN volume_24h_at_close TO volume;
-- +goose StatementEnd
