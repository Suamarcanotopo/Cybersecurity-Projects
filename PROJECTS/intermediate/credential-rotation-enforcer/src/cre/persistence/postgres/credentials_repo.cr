# ===================
# ©AngelaMos | 2026
# credentials_repo.cr
# ===================

require "db"
require "json"
require "uuid"
require "../repos"
require "../../domain/credential"

module CRE::Persistence::Postgres
  class CredentialsRepo < CRE::Persistence::CredentialsRepo
    SELECT_COLS = "id::text, external_id, kind, name, tags::text, current_version_id::text, pending_version_id::text, previous_version_id::text, created_at, updated_at, last_rotated_at"

    def initialize(@db : DB::Database)
    end

    def insert(c : Domain::Credential) : Nil
      @db.exec(
        "INSERT INTO credentials (id, external_id, kind, name, tags, current_version_id, pending_version_id, previous_version_id, created_at, updated_at, last_rotated_at) VALUES ($1::uuid, $2, $3, $4, $5::jsonb, $6::uuid, $7::uuid, $8::uuid, $9, $10, $11)",
        c.id.to_s, c.external_id, c.kind.to_s, c.name,
        c.tags.to_json,
        c.current_version_id.try(&.to_s),
        c.pending_version_id.try(&.to_s),
        c.previous_version_id.try(&.to_s),
        c.created_at, c.updated_at, c.last_rotated_at,
      )
    end

    def update(c : Domain::Credential) : Nil
      @db.exec(
        "UPDATE credentials SET name = $1, tags = $2::jsonb, current_version_id = $3::uuid, pending_version_id = $4::uuid, previous_version_id = $5::uuid, updated_at = $6, last_rotated_at = $7 WHERE id = $8::uuid",
        c.name, c.tags.to_json,
        c.current_version_id.try(&.to_s),
        c.pending_version_id.try(&.to_s),
        c.previous_version_id.try(&.to_s),
        Time.utc, c.last_rotated_at, c.id.to_s,
      )
    end

    def find(id : UUID) : Domain::Credential?
      @db.query_one?(
        "SELECT #{SELECT_COLS} FROM credentials WHERE id = $1::uuid",
        id.to_s,
        as: {String, String, String, String, String, String?, String?, String?, Time, Time, Time?},
      ).try { |row| row_to_credential(row) }
    end

    def find_by_external(kind : Domain::CredentialKind, external_id : String) : Domain::Credential?
      @db.query_one?(
        "SELECT #{SELECT_COLS} FROM credentials WHERE kind = $1 AND external_id = $2",
        kind.to_s, external_id,
        as: {String, String, String, String, String, String?, String?, String?, Time, Time, Time?},
      ).try { |row| row_to_credential(row) }
    end

    def all : Array(Domain::Credential)
      @db.query_all(
        "SELECT #{SELECT_COLS} FROM credentials",
        as: {String, String, String, String, String, String?, String?, String?, Time, Time, Time?},
      ).map { |row| row_to_credential(row) }
    end

    def overdue(now : Time, max_age : Time::Span) : Array(Domain::Credential)
      cutoff = now - max_age
      @db.query_all(
        "SELECT #{SELECT_COLS} FROM credentials WHERE COALESCE(last_rotated_at, created_at) < $1",
        cutoff,
        as: {String, String, String, String, String, String?, String?, String?, Time, Time, Time?},
      ).map { |row| row_to_credential(row) }
    end

    private def row_to_credential(row) : Domain::Credential
      tags = Hash(String, String).from_json(row[4])
      Domain::Credential.new(
        id: UUID.new(row[0]),
        external_id: row[1],
        kind: Domain::CredentialKind.parse(row[2]),
        name: row[3],
        tags: tags,
        current_version_id: row[5].try { |s| UUID.new(s) },
        pending_version_id: row[6].try { |s| UUID.new(s) },
        previous_version_id: row[7].try { |s| UUID.new(s) },
        created_at: row[8],
        updated_at: row[9],
        last_rotated_at: row[10],
      )
    end
  end
end
