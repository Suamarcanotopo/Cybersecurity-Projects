-- ©AngelaMos | 2026
-- 0002_alerts.sql

-- +goose Up
-- +goose StatementBegin
CREATE TABLE alert_rules (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            text NOT NULL,
    topic           text NOT NULL,
    predicate       text NOT NULL,
    cooldown_sec    integer NOT NULL DEFAULT 300,
    enabled         boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_alert_rules_user ON alert_rules(user_id) WHERE enabled = true;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE alert_channels (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type            text NOT NULL,
    label           text NOT NULL,
    config_enc      bytea NOT NULL,
    nonce           bytea NOT NULL,
    invalid         boolean NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_alert_channels_user ON alert_channels(user_id);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE alert_rule_channels (
    rule_id     uuid NOT NULL REFERENCES alert_rules(id) ON DELETE CASCADE,
    channel_id  uuid NOT NULL REFERENCES alert_channels(id) ON DELETE CASCADE,
    PRIMARY KEY (rule_id, channel_id)
);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE alert_history (
    id              bigserial PRIMARY KEY,
    rule_id         uuid NOT NULL REFERENCES alert_rules(id) ON DELETE CASCADE,
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    fired_at        timestamptz NOT NULL DEFAULT now(),
    payload         jsonb NOT NULL,
    delivered_to    text[] NOT NULL DEFAULT '{}',
    delivery_errors jsonb
);
CREATE INDEX idx_alert_history_user_time ON alert_history(user_id, fired_at DESC);
CREATE INDEX idx_alert_history_fired_brin ON alert_history USING BRIN (fired_at);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE telegram_webhooks (
    user_id         uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    webhook_uuid    uuid NOT NULL UNIQUE,
    secret_token    text NOT NULL,
    bot_token_enc   bytea NOT NULL,
    bot_token_nonce bytea NOT NULL,
    chat_id         bigint,
    pending_link    boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now()
);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE user_preferences (
    user_id              uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    watched_country      text,
    watched_asns         integer[] NOT NULL DEFAULT '{}',
    observer_lat         double precision,
    observer_lon         double precision,
    observer_alt_m       double precision,
    digest_enabled       boolean NOT NULL DEFAULT false,
    digest_local_tz      text NOT NULL DEFAULT 'UTC',
    digest_local_time    time NOT NULL DEFAULT '08:00',
    digest_window_hours  integer NOT NULL DEFAULT 24,
    digest_channel_ids   uuid[] NOT NULL DEFAULT '{}',
    chime_enabled        boolean NOT NULL DEFAULT true,
    chime_audio_object   text,
    presentation_default boolean NOT NULL DEFAULT false,
    updated_at           timestamptz NOT NULL DEFAULT now()
);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE digest_runs (
    user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    fired_date   date NOT NULL,
    fired_at     timestamptz NOT NULL DEFAULT now(),
    status       text NOT NULL,
    error        text,
    PRIMARY KEY (user_id, fired_date)
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS digest_runs;
DROP TABLE IF EXISTS user_preferences;
DROP TABLE IF EXISTS telegram_webhooks;
DROP TABLE IF EXISTS alert_history;
DROP TABLE IF EXISTS alert_rule_channels;
DROP TABLE IF EXISTS alert_channels;
DROP TABLE IF EXISTS alert_rules;
-- +goose StatementEnd
