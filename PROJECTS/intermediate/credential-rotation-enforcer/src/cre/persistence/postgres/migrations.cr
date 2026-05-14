# ===================
# ©AngelaMos | 2026
# migrations.cr
# ===================

require "db"

module CRE::Persistence::Postgres
  module Migrations
    record Step, version : Int32, statements : Array(String)

    MIGRATIONS = [
      Step.new(1, [
        <<-SQL,
          CREATE TABLE IF NOT EXISTS credentials (
            id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            external_id         TEXT NOT NULL,
            kind                TEXT NOT NULL,
            name                TEXT NOT NULL,
            tags                JSONB NOT NULL DEFAULT '{}'::jsonb,
            current_version_id  UUID,
            pending_version_id  UUID,
            previous_version_id UUID,
            created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
            UNIQUE (kind, external_id)
          )
          SQL
        "CREATE INDEX IF NOT EXISTS credentials_tags_gin ON credentials USING gin (tags jsonb_path_ops)",
        <<-SQL,
          CREATE TABLE IF NOT EXISTS credential_versions (
            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            credential_id UUID NOT NULL REFERENCES credentials(id),
            ciphertext    BYTEA NOT NULL,
            dek_wrapped   BYTEA NOT NULL,
            kek_version   INT NOT NULL,
            algorithm_id  SMALLINT NOT NULL,
            metadata      JSONB NOT NULL DEFAULT '{}'::jsonb,
            generated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
            revoked_at    TIMESTAMPTZ
          )
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS rotations (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            credential_id   UUID NOT NULL REFERENCES credentials(id),
            rotator_kind    TEXT NOT NULL,
            state           TEXT NOT NULL,
            started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
            completed_at    TIMESTAMPTZ,
            step_outcomes   JSONB NOT NULL DEFAULT '{}'::jsonb,
            failure_reason  TEXT
          )
          SQL
        <<-SQL,
          CREATE INDEX IF NOT EXISTS rotations_in_flight
            ON rotations(state)
            WHERE state NOT IN ('completed','failed','aborted','inconsistent')
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS audit_events (
            seq               BIGSERIAL PRIMARY KEY,
            event_id          UUID UNIQUE NOT NULL DEFAULT gen_random_uuid(),
            occurred_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
            event_type        TEXT NOT NULL,
            actor             TEXT NOT NULL,
            target_id         UUID,
            payload           JSONB NOT NULL,
            prev_hash         BYTEA NOT NULL,
            content_hash      BYTEA NOT NULL,
            hmac              BYTEA NOT NULL,
            hmac_key_version  INT NOT NULL
          )
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS audit_batches (
            id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            start_seq           BIGINT NOT NULL,
            end_seq             BIGINT NOT NULL,
            merkle_root         BYTEA NOT NULL,
            signature           BYTEA NOT NULL,
            signing_key_version INT NOT NULL,
            sealed_at           TIMESTAMPTZ NOT NULL DEFAULT now()
          )
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS kek_versions (
            version     INT PRIMARY KEY,
            source      TEXT NOT NULL,
            source_ref  TEXT,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
            retired_at  TIMESTAMPTZ
          )
          SQL
        <<-SQL,
          CREATE OR REPLACE FUNCTION audit_no_modify() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN RAISE EXCEPTION 'audit_events is append-only'; END $$
          SQL
        "DROP TRIGGER IF EXISTS audit_events_no_update ON audit_events",
        <<-SQL,
          CREATE TRIGGER audit_events_no_update
            BEFORE UPDATE OR DELETE OR TRUNCATE
            ON audit_events
            EXECUTE FUNCTION audit_no_modify()
          SQL
      ]),
      Step.new(2, [
        "ALTER TABLE credentials ADD COLUMN IF NOT EXISTS last_rotated_at TIMESTAMPTZ",
        "UPDATE credentials SET last_rotated_at = updated_at WHERE last_rotated_at IS NULL",
      ]),
      Step.new(3, [
        "CREATE INDEX IF NOT EXISTS credentials_last_rotated_at ON credentials(last_rotated_at)",
        "CREATE INDEX IF NOT EXISTS credential_versions_credential_id ON credential_versions(credential_id)",
        <<-SQL,
          CREATE UNIQUE INDEX IF NOT EXISTS rotations_one_in_flight_per_cred
            ON rotations(credential_id)
            WHERE state NOT IN ('completed','failed','aborted','inconsistent')
          SQL
      ]),
    ]

    def self.run(db : DB::Database) : Nil
      db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())")
      applied = applied_versions(db)
      MIGRATIONS.each do |step|
        next if applied.includes?(step.version)
        step.statements.each { |stmt| db.exec(stmt) }
        db.exec("INSERT INTO schema_migrations (version) VALUES ($1)", step.version)
      end
    end

    private def self.applied_versions(db : DB::Database) : Set(Int32)
      versions = Set(Int32).new
      db.query("SELECT version FROM schema_migrations") do |rs|
        rs.each { versions << rs.read(Int32) }
      end
      versions
    end
  end
end
