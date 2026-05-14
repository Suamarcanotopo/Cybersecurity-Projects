# ===================
# ©AngelaMos | 2026
# rotations_repo.cr
# ===================

require "db"
require "uuid"
require "../repos"

module CRE::Persistence::Sqlite
  class RotationsRepo < CRE::Persistence::RotationsRepo
    SELECT_COLS = "id, credential_id, rotator_kind, state, started_at, completed_at, failure_reason"

    def initialize(@db : DB::Database)
    end

    def insert(rotation : RotationRecord) : Nil
      @db.exec(
        "INSERT INTO rotations (id, credential_id, rotator_kind, state, started_at, completed_at, failure_reason) VALUES (?, ?, ?, ?, ?, ?, ?)",
        rotation.id.to_s, rotation.credential_id.to_s,
        rotation.rotator_kind.to_s, rotation.state.to_s,
        rotation.started_at.to_rfc3339,
        rotation.completed_at.try(&.to_rfc3339),
        rotation.failure_reason,
      )
    end

    def update_state(id : UUID, state : RotationState, error : String? = nil) : Nil
      completed_at = TERMINAL_STATES.includes?(state) ? Time.utc.to_rfc3339 : nil
      @db.exec(
        "UPDATE rotations SET state = ?, completed_at = ?, failure_reason = COALESCE(?, failure_reason) WHERE id = ?",
        state.to_s, completed_at, error, id.to_s,
      )
    end

    def in_flight : Array(RotationRecord)
      placeholders = TERMINAL_STATES.map { "?" }.join(",")
      args = TERMINAL_STATES.map { |s| s.to_s.as(DB::Any) }
      sql = "SELECT #{SELECT_COLS} FROM rotations WHERE state NOT IN (#{placeholders})"
      @db.query_all(sql, args: args, as: {String, String, String, String, String, String?, String?})
        .map { |row| row_to_record(row) }
    end

    private def row_to_record(row) : RotationRecord
      RotationRecord.new(
        id: UUID.new(row[0]),
        credential_id: UUID.new(row[1]),
        rotator_kind: RotatorKind.parse(row[2]),
        state: RotationState.parse(row[3]),
        started_at: Time.parse_rfc3339(row[4]),
        completed_at: row[5].try { |s| Time.parse_rfc3339(s) },
        failure_reason: row[6],
      )
    end
  end
end
