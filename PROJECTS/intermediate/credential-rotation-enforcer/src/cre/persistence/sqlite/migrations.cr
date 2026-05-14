# ===================
# ©AngelaMos | 2026
# migrations.cr
# ===================

require "db"

module CRE::Persistence::Sqlite
  module Migrations
    record Step, version : Int32, statements : Array(String)

    MIGRATIONS = [
      Step.new(1, [
        <<-SQL,
          CREATE TABLE IF NOT EXISTS credentials (
            id                  TEXT PRIMARY KEY,
            external_id         TEXT NOT NULL,
            kind                TEXT NOT NULL,
            name                TEXT NOT NULL,
            tags                TEXT NOT NULL DEFAULT '{}',
            current_version_id  TEXT,
            pending_version_id  TEXT,
            previous_version_id TEXT,
            created_at          TEXT NOT NULL,
            updated_at          TEXT NOT NULL,
            UNIQUE (kind, external_id)
          )
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS credential_versions (
            id            TEXT PRIMARY KEY,
            credential_id TEXT NOT NULL REFERENCES credentials(id),
            ciphertext    BLOB NOT NULL,
            dek_wrapped   BLOB NOT NULL,
            kek_version   INTEGER NOT NULL,
            algorithm_id  INTEGER NOT NULL,
            metadata      TEXT NOT NULL DEFAULT '{}',
            generated_at  TEXT NOT NULL,
            revoked_at    TEXT
          )
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS rotations (
            id              TEXT PRIMARY KEY,
            credential_id   TEXT NOT NULL,
            rotator_kind    TEXT NOT NULL,
            state           TEXT NOT NULL,
            started_at      TEXT NOT NULL,
            completed_at    TEXT,
            step_outcomes   TEXT NOT NULL DEFAULT '{}',
            failure_reason  TEXT
          )
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS audit_events (
            seq               INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id          TEXT UNIQUE NOT NULL,
            occurred_at       TEXT NOT NULL,
            event_type        TEXT NOT NULL,
            actor             TEXT NOT NULL,
            target_id         TEXT,
            payload           TEXT NOT NULL,
            prev_hash         BLOB NOT NULL,
            content_hash      BLOB NOT NULL,
            hmac              BLOB NOT NULL,
            hmac_key_version  INTEGER NOT NULL
          )
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS audit_batches (
            id                  TEXT PRIMARY KEY,
            start_seq           INTEGER NOT NULL,
            end_seq             INTEGER NOT NULL,
            merkle_root         BLOB NOT NULL,
            signature           BLOB NOT NULL,
            signing_key_version INTEGER NOT NULL,
            sealed_at           TEXT NOT NULL
          )
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS kek_versions (
            version     INTEGER PRIMARY KEY,
            source      TEXT NOT NULL,
            source_ref  TEXT,
            created_at  TEXT NOT NULL,
            retired_at  TEXT
          )
          SQL
      ]),
      Step.new(2, [
        <<-SQL,
          CREATE TRIGGER IF NOT EXISTS audit_events_no_update
          BEFORE UPDATE ON audit_events
          BEGIN SELECT RAISE(ABORT, 'audit_events is append-only'); END
          SQL
        <<-SQL,
          CREATE TRIGGER IF NOT EXISTS audit_events_no_delete
          BEFORE DELETE ON audit_events
          BEGIN SELECT RAISE(ABORT, 'audit_events is append-only'); END
          SQL
      ]),
      Step.new(3, [
        "ALTER TABLE credentials ADD COLUMN last_rotated_at TEXT",
        "UPDATE credentials SET last_rotated_at = updated_at WHERE last_rotated_at IS NULL",
      ]),
      Step.new(4, [
        "CREATE INDEX IF NOT EXISTS credentials_last_rotated_at ON credentials(last_rotated_at)",
        "CREATE INDEX IF NOT EXISTS credential_versions_credential_id ON credential_versions(credential_id)",
      ]),
    ]

    def self.run(db : DB::Database) : Nil
      db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
      applied = applied_versions(db)
      MIGRATIONS.each do |step|
        next if applied.includes?(step.version)
        step.statements.each { |stmt| db.exec(stmt) }
        db.exec("INSERT INTO schema_migrations (version) VALUES (?)", step.version)
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
