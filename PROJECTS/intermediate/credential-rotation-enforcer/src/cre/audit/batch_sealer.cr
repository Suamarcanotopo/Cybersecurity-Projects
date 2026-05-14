# ===================
# ©AngelaMos | 2026
# batch_sealer.cr
# ===================

require "uuid"
require "./merkle"
require "./signing"
require "../persistence/persistence"
require "../persistence/repos"

module CRE::Audit
  class BatchSealer
    def initialize(
      @persistence : Persistence::Persistence,
      @signer : Signing::Ed25519Signer,
    )
    end

    def seal_pending : Persistence::AuditBatch?
      latest = @persistence.audit.latest_seq
      last_end = @persistence.audit.last_sealed_seq
      return nil if latest <= last_end

      start_seq = last_end + 1
      end_seq = latest
      entries = @persistence.audit.range(start_seq, end_seq)
      return nil if entries.empty?

      leaves = entries.map(&.content_hash)
      root = Merkle.root(leaves)

      msg = pack_message(start_seq, end_seq, root)
      sig = @signer.sign(msg)

      batch = Persistence::AuditBatch.new(
        id: UUID.random,
        start_seq: start_seq,
        end_seq: end_seq,
        merkle_root: root,
        signature: sig,
        signing_key_version: @signer.version,
        sealed_at: Time.utc,
      )
      @persistence.audit.insert_batch(batch)
      batch
    end

    def self.pack_message(start_seq : Int64, end_seq : Int64, root : Bytes) : Bytes
      io = IO::Memory.new
      io.write_bytes(start_seq, IO::ByteFormat::BigEndian)
      io.write_bytes(end_seq, IO::ByteFormat::BigEndian)
      io.write(root)
      io.to_slice
    end

    private def pack_message(start_seq : Int64, end_seq : Int64, root : Bytes) : Bytes
      BatchSealer.pack_message(start_seq, end_seq, root)
    end
  end
end
