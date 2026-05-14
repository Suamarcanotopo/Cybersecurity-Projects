-- ©AngelaMos | 2026
-- 001_initial.sql

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE analyses (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sha256       TEXT NOT NULL UNIQUE,
    file_name    TEXT NOT NULL,
    file_size    BIGINT NOT NULL,
    format       TEXT NOT NULL,
    architecture TEXT NOT NULL,
    entry_point  BIGINT,
    threat_score INTEGER,
    risk_level   TEXT,
    slug         TEXT NOT NULL UNIQUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE pass_results (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    analysis_id UUID NOT NULL REFERENCES analyses(id) ON DELETE CASCADE,
    pass_name   TEXT NOT NULL,
    result      JSONB NOT NULL,
    duration_ms INTEGER,
    UNIQUE(analysis_id, pass_name)
);

CREATE INDEX idx_analyses_sha256 ON analyses(sha256);
CREATE INDEX idx_analyses_slug ON analyses(slug);
CREATE INDEX idx_pass_results_analysis_id ON pass_results(analysis_id);
