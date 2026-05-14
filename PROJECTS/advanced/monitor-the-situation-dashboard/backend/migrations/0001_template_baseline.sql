-- ©AngelaMos | 2026
-- 0001_template_baseline.sql

-- +goose Up
-- +goose StatementBegin
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE users (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email           text NOT NULL UNIQUE,
    password_hash   text NOT NULL,
    name            text NOT NULL DEFAULT '',
    role            text NOT NULL DEFAULT 'user',
    tier            text NOT NULL DEFAULT 'free',
    token_version   integer NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz
);
CREATE INDEX idx_users_email      ON users (email) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_role       ON users (role) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_created    ON users (created_at DESC);
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TABLE refresh_tokens (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash      text NOT NULL UNIQUE,
    family_id       uuid NOT NULL,
    expires_at      timestamptz NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    is_used         boolean NOT NULL DEFAULT false,
    used_at         timestamptz,
    revoked_at      timestamptz,
    replaced_by_id  uuid,
    user_agent      text NOT NULL DEFAULT '',
    ip_address      text NOT NULL DEFAULT ''
);
CREATE INDEX idx_refresh_tokens_user      ON refresh_tokens (user_id);
CREATE INDEX idx_refresh_tokens_family    ON refresh_tokens (family_id);
CREATE INDEX idx_refresh_tokens_expires   ON refresh_tokens (expires_at);
CREATE INDEX idx_refresh_tokens_hash      ON refresh_tokens (token_hash);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS refresh_tokens;
DROP TABLE IF EXISTS users;
-- +goose StatementEnd
