# ===================
# ©AngelaMos | 2026
# credentials_repo.cr
# ===================

require "db"
require "json"
require "uuid"
require "../repos"
require "../../domain/credential"

module CRE::Persistence::Sqlite
  class CredentialsRepo < CRE::Persistence::CredentialsRepo
    SELECT_COLS = "id, external_id, kind, name, tags, current_version_id, pending_version_id, previous_version_id, created_at, updated_at, last_rotated_at"

    def initialize(@db : DB::Database)
    end

    def insert(c : Domain::Credential) : Nil
      @db.exec(
        "INSERT INTO credentials (id, external_id, kind, name, tags, current_version_id, pending_version_id, previous_version_id, created_at, updated_at, last_rotated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        c.id.to_s, c.external_id, c.kind.to_s, c.name,
        c.tags.to_json,
        c.current_version_id.try(&.to_s),
        c.pending_version_id.try(&.to_s),
        c.previous_version_id.try(&.to_s),
        c.created_at.to_rfc3339, c.updated_at.to_rfc3339,
        c.last_rotated_at.try(&.to_rfc3339),
      )
    end

    def update(c : Domain::Credential) : Nil
      @db.exec(
        "UPDATE credentials SET name = ?, tags = ?, current_version_id = ?, pending_version_id = ?, previous_version_id = ?, updated_at = ?, last_rotated_at = ? WHERE id = ?",
        c.name, c.tags.to_json,
        c.current_version_id.try(&.to_s),
        c.pending_version_id.try(&.to_s),
        c.previous_version_id.try(&.to_s),
        Time.utc.to_rfc3339,
        c.last_rotated_at.try(&.to_rfc3339),
        c.id.to_s,
      )
    end

    def find(id : UUID) : Domain::Credential?
      @db.query_one?(
        "SELECT #{SELECT_COLS} FROM credentials WHERE id = ?",
        id.to_s,
        as: {String, String, String, String, String, String?, String?, String?, String, String, String?},
      ).try { |row| row_to_credential(row) }
    end

    def find_by_external(kind : Domain::CredentialKind, external_id : String) : Domain::Credential?
      @db.query_one?(
        "SELECT #{SELECT_COLS} FROM credentials WHERE kind = ? AND external_id = ?",
        kind.to_s, external_id,
        as: {String, String, String, String, String, String?, String?, String?, String, String, String?},
      ).try { |row| row_to_credential(row) }
    end

    def all : Array(Domain::Credential)
      @db.query_all(
        "SELECT #{SELECT_COLS} FROM credentials",
        as: {String, String, String, String, String, String?, String?, String?, String, String, String?},
      ).map { |row| row_to_credential(row) }
    end

    def overdue(now : Time, max_age : Time::Span) : Array(Domain::Credential)
      cutoff = (now - max_age).to_rfc3339
      @db.query_all(
        "SELECT #{SELECT_COLS} FROM credentials WHERE COALESCE(last_rotated_at, created_at) < ?",
        cutoff,
        as: {String, String, String, String, String, String?, String?, String?, String, String, String?},
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
        created_at: Time.parse_rfc3339(row[8]),
        updated_at: Time.parse_rfc3339(row[9]),
        last_rotated_at: row[10].try { |s| Time.parse_rfc3339(s) },
      )
    end
  end
end
