-- ©AngelaMos | 2026
-- 0004_collector_state.sql

-- +goose Up
-- +goose StatementBegin
CREATE TABLE collector_state (
    name              text PRIMARY KEY,
    state             text NOT NULL,
    last_success_at   timestamptz,
    last_error_at     timestamptz,
    last_error        text,
    last_event_count  bigint NOT NULL DEFAULT 0,
    updated_at        timestamptz NOT NULL DEFAULT now()
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS collector_state;
-- +goose StatementEnd
