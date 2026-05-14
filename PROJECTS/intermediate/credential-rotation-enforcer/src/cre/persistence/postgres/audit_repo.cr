# ===================
# ©AngelaMos | 2026
# audit_repo.cr
# ===================

require "db"
require "uuid"
require "../repos"

module CRE::Persistence::Postgres
  class AuditRepo < CRE::Persistence::AuditRepo
    GENESIS_HASH = Bytes.new(32, 0_u8)

    SELECT_ENTRY_COLS = "seq, event_id::text, occurred_at, event_type, actor, target_id::text, payload::text, prev_hash, content_hash, hmac, hmac_key_version"
    SELECT_BATCH_COLS = "id::text, start_seq, end_seq, merkle_root, signature, signing_key_version, sealed_at"

    def initialize(@db : DB::Database)
    end

    def append(entry : AuditEntry) : Nil
      @db.exec(
        "INSERT INTO audit_events (event_id, occurred_at, event_type, actor, target_id, payload, prev_hash, content_hash, hmac, hmac_key_version) VALUES ($1::uuid, $2, $3, $4, $5::uuid, $6::jsonb, $7, $8, $9, $10)",
        entry.event_id.to_s, entry.occurred_at,
        entry.event_type, entry.actor,
        entry.target_id.try(&.to_s),
        entry.payload,
        entry.prev_hash, entry.content_hash, entry.hmac,
        entry.hmac_key_version,
      )
    end

    def latest_hash : Bytes
      result = @db.query_one?(
        "SELECT content_hash FROM audit_events ORDER BY seq DESC LIMIT 1",
        as: Bytes,
      )
      result || GENESIS_HASH
    end

    def latest_seq : Int64
      result = @db.query_one?(
        "SELECT seq FROM audit_events ORDER BY seq DESC LIMIT 1",
        as: Int64,
      )
      result || 0_i64
    end

    def range(start_seq : Int64, end_seq : Int64) : Array(AuditEntry)
      @db.query_all(
        "SELECT #{SELECT_ENTRY_COLS} FROM audit_events WHERE seq >= $1 AND seq <= $2 ORDER BY seq ASC",
        start_seq, end_seq,
        as: {Int64, String, Time, String, String, String?, String, Bytes, Bytes, Bytes, Int32},
      ).map { |row| row_to_entry(row) }
    end

    def each_in_range(start_seq : Int64, end_seq : Int64, &block : AuditEntry ->) : Nil
      @db.query(
        "SELECT #{SELECT_ENTRY_COLS} FROM audit_events WHERE seq >= $1 AND seq <= $2 ORDER BY seq ASC",
        start_seq, end_seq,
      ) do |rs|
        rs.each do
          entry = AuditEntry.new(
            seq: rs.read(Int64),
            event_id: UUID.new(rs.read(String)),
            occurred_at: rs.read(Time),
            event_type: rs.read(String),
            actor: rs.read(String),
            target_id: rs.read(String?).try { |s| UUID.new(s) },
            payload: rs.read(String),
            prev_hash: rs.read(Bytes),
            content_hash: rs.read(Bytes),
            hmac: rs.read(Bytes),
            hmac_key_version: rs.read(Int32),
          )
          block.call(entry)
        end
      end
    end

    def insert_batch(batch : AuditBatch) : Nil
      @db.exec(
        "INSERT INTO audit_batches (id, start_seq, end_seq, merkle_root, signature, signing_key_version, sealed_at) VALUES ($1::uuid, $2, $3, $4, $5, $6, $7)",
        batch.id.to_s, batch.start_seq, batch.end_seq,
        batch.merkle_root, batch.signature,
        batch.signing_key_version, batch.sealed_at,
      )
    end

    def last_sealed_seq : Int64
      result = @db.query_one?(
        "SELECT MAX(end_seq) FROM audit_batches",
        as: Int64?,
      )
      result || 0_i64
    end

    def all_batches : Array(AuditBatch)
      @db.query_all(
        "SELECT #{SELECT_BATCH_COLS} FROM audit_batches ORDER BY start_seq ASC",
        as: {String, Int64, Int64, Bytes, Bytes, Int32, Time},
      ).map { |row| row_to_batch(row) }
    end

    private def row_to_entry(row) : AuditEntry
      AuditEntry.new(
        seq: row[0],
        event_id: UUID.new(row[1]),
        occurred_at: row[2],
        event_type: row[3],
        actor: row[4],
        target_id: row[5].try { |s| UUID.new(s) },
        payload: row[6],
        prev_hash: row[7],
        content_hash: row[8],
        hmac: row[9],
        hmac_key_version: row[10],
      )
    end

    private def row_to_batch(row) : AuditBatch
      AuditBatch.new(
        id: UUID.new(row[0]),
        start_seq: row[1],
        end_seq: row[2],
        merkle_root: row[3],
        signature: row[4],
        signing_key_version: row[5],
        sealed_at: row[6],
      )
    end
  end
end
