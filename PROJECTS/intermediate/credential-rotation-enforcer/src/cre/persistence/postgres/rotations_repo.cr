# ===================
# ©AngelaMos | 2026
# rotations_repo.cr
# ===================

require "db"
require "uuid"
require "../repos"

module CRE::Persistence::Postgres
  class RotationsRepo < CRE::Persistence::RotationsRepo
    SELECT_COLS = "id::text, credential_id::text, rotator_kind, state, started_at, completed_at, failure_reason"

    def initialize(@db : DB::Database)
    end

    def insert(rotation : RotationRecord) : Nil
      @db.exec(
        "INSERT INTO rotations (id, credential_id, rotator_kind, state, started_at, completed_at, failure_reason) VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7)",
        rotation.id.to_s, rotation.credential_id.to_s,
        rotation.rotator_kind.to_s, rotation.state.to_s,
        rotation.started_at, rotation.completed_at, rotation.failure_reason,
      )
    end

    def update_state(id : UUID, state : RotationState, error : String? = nil) : Nil
      completed_at = TERMINAL_STATES.includes?(state) ? Time.utc : nil
      @db.exec(
        "UPDATE rotations SET state = $1, completed_at = $2, failure_reason = COALESCE($3, failure_reason) WHERE id = $4::uuid",
        state.to_s, completed_at, error, id.to_s,
      )
    end

    def in_flight : Array(RotationRecord)
      @db.query_all(
        "SELECT #{SELECT_COLS} FROM rotations WHERE state NOT IN ('completed','failed','aborted','inconsistent')",
        as: {String, String, String, String, Time, Time?, String?},
      ).map { |row| row_to_record(row) }
    end

    private def row_to_record(row) : RotationRecord
      RotationRecord.new(
        id: UUID.new(row[0]),
        credential_id: UUID.new(row[1]),
        rotator_kind: RotatorKind.parse(row[2]),
        state: RotationState.parse(row[3]),
        started_at: row[4],
        completed_at: row[5],
        failure_reason: row[6],
      )
    end
  end
end
