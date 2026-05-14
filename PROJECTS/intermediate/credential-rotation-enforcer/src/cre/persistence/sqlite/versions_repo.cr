# ===================
# ©AngelaMos | 2026
# versions_repo.cr
# ===================

require "db"
require "json"
require "uuid"
require "../repos"
require "../../domain/credential_version"

module CRE::Persistence::Sqlite
  class VersionsRepo < CRE::Persistence::VersionsRepo
    SELECT_COLS = "id, credential_id, ciphertext, dek_wrapped, kek_version, algorithm_id, metadata, generated_at, revoked_at"

    def initialize(@db : DB::Database)
    end

    def insert(v : Domain::CredentialVersion) : Nil
      @db.exec(
        "INSERT INTO credential_versions (id, credential_id, ciphertext, dek_wrapped, kek_version, algorithm_id, metadata, generated_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        v.id.to_s, v.credential_id.to_s,
        v.ciphertext, v.dek_wrapped,
        v.kek_version, v.algorithm_id.to_i32,
        v.metadata.to_json, v.generated_at.to_rfc3339,
        v.revoked_at.try(&.to_rfc3339),
      )
    end

    def find(id : UUID) : Domain::CredentialVersion?
      @db.query_one?(
        "SELECT #{SELECT_COLS} FROM credential_versions WHERE id = ?",
        id.to_s,
        as: {String, String, Bytes, Bytes, Int32, Int32, String, String, String?},
      ).try { |row| row_to_version(row) }
    end

    def for_credential(credential_id : UUID) : Array(Domain::CredentialVersion)
      @db.query_all(
        "SELECT #{SELECT_COLS} FROM credential_versions WHERE credential_id = ? ORDER BY generated_at DESC",
        credential_id.to_s,
        as: {String, String, Bytes, Bytes, Int32, Int32, String, String, String?},
      ).map { |row| row_to_version(row) }
    end

    def revoke(id : UUID, at : Time = Time.utc) : Nil
      @db.exec(
        "UPDATE credential_versions SET revoked_at = ? WHERE id = ?",
        at.to_rfc3339, id.to_s,
      )
    end

    private def row_to_version(row) : Domain::CredentialVersion
      Domain::CredentialVersion.new(
        id: UUID.new(row[0]),
        credential_id: UUID.new(row[1]),
        ciphertext: row[2],
        dek_wrapped: row[3],
        kek_version: row[4],
        algorithm_id: row[5].to_i16,
        metadata: Hash(String, String).from_json(row[6]),
        generated_at: Time.parse_rfc3339(row[7]),
        revoked_at: row[8].try { |s| Time.parse_rfc3339(s) },
      )
    end
  end
end
