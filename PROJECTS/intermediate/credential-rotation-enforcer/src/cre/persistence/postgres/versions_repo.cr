# ===================
# ©AngelaMos | 2026
# versions_repo.cr
# ===================

require "db"
require "json"
require "uuid"
require "../repos"
require "../../domain/credential_version"

module CRE::Persistence::Postgres
  class VersionsRepo < CRE::Persistence::VersionsRepo
    SELECT_COLS = "id::text, credential_id::text, ciphertext, dek_wrapped, kek_version, algorithm_id, metadata::text, generated_at, revoked_at"

    def initialize(@db : DB::Database)
    end

    def insert(v : Domain::CredentialVersion) : Nil
      @db.exec(
        "INSERT INTO credential_versions (id, credential_id, ciphertext, dek_wrapped, kek_version, algorithm_id, metadata, generated_at, revoked_at) VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7::jsonb, $8, $9)",
        v.id.to_s, v.credential_id.to_s,
        v.ciphertext, v.dek_wrapped,
        v.kek_version, v.algorithm_id.to_i32,
        v.metadata.to_json, v.generated_at,
        v.revoked_at,
      )
    end

    def find(id : UUID) : Domain::CredentialVersion?
      @db.query_one?(
        "SELECT #{SELECT_COLS} FROM credential_versions WHERE id = $1::uuid",
        id.to_s,
        as: {String, String, Bytes, Bytes, Int32, Int16, String, Time, Time?},
      ).try { |row| row_to_version(row) }
    end

    def for_credential(credential_id : UUID) : Array(Domain::CredentialVersion)
      @db.query_all(
        "SELECT #{SELECT_COLS} FROM credential_versions WHERE credential_id = $1::uuid ORDER BY generated_at DESC",
        credential_id.to_s,
        as: {String, String, Bytes, Bytes, Int32, Int16, String, Time, Time?},
      ).map { |row| row_to_version(row) }
    end

    def revoke(id : UUID, at : Time = Time.utc) : Nil
      @db.exec(
        "UPDATE credential_versions SET revoked_at = $1 WHERE id = $2::uuid",
        at, id.to_s,
      )
    end

    private def row_to_version(row) : Domain::CredentialVersion
      Domain::CredentialVersion.new(
        id: UUID.new(row[0]),
        credential_id: UUID.new(row[1]),
        ciphertext: row[2],
        dek_wrapped: row[3],
        kek_version: row[4],
        algorithm_id: row[5],
        metadata: Hash(String, String).from_json(row[6]),
        generated_at: row[7],
        revoked_at: row[8],
      )
    end
  end
end
