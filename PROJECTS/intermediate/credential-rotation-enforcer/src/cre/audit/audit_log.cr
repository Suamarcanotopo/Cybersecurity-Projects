# ===================
# ©AngelaMos | 2026
# audit_log.cr
# ===================

require "json"
require "uuid"
require "openssl/hmac"
require "./hash_chain"
require "./hmac_ratchet"
require "./merkle"
require "./signing"
require "../crypto/random"
require "../persistence/persistence"
require "../persistence/repos"

module CRE::Audit
  # AuditLog is the append-only, tamper-evident write API used by the
  # AuditSubscriber. Verification is split across three layers, each
  # callable independently:
  #
  #   verify_hash_chain         SHA-256 chain over (prev_hash || payload)
  #   verify_hmac_ratchet       HMAC-SHA256 of every content_hash, with
  #                             the ratcheting key replayed from the
  #                             initial seed
  #   verify_batches            Ed25519-signed Merkle-root batches
  #
  # Together they answer 'has this log been mutated since it was written':
  #   - hash chain catches edits to any single row (recompute everything),
  #   - HMAC ratchet catches edits an attacker who recomputed hashes might
  #     have made (they don't have the seed key),
  #   - Merkle batches give an external auditor an O(1) commitment to a
  #     range of entries that they can verify offline with a public key.
  class AuditLog
    @ratchet : HmacRatchet
    @mutex : Mutex
    @initial_hmac_key : Bytes

    def initialize(@persistence : Persistence::Persistence, initial_hmac_key : Bytes, @hmac_version : Int32, @ratchet_every : Int32)
      @initial_hmac_key = initial_hmac_key.dup
      @ratchet = HmacRatchet.new(initial_hmac_key, @hmac_version, @ratchet_every)
      @mutex = Mutex.new
    end

    def append(event_type : String, actor : String, target_id : UUID?, payload : Hash) : Persistence::AuditEntry
      @mutex.synchronize do
        prev = @persistence.audit.latest_hash
        canonical = canonical_json(event_type, actor, target_id, payload)
        content_hash = HashChain.next_hash(prev, canonical.to_slice)
        hmac = @ratchet.sign(content_hash)

        entry = Persistence::AuditEntry.new(
          seq: 0_i64,
          event_id: UUID.random,
          occurred_at: Time.utc,
          event_type: event_type,
          actor: actor,
          target_id: target_id,
          payload: canonical,
          prev_hash: prev,
          content_hash: content_hash,
          hmac: hmac,
          hmac_key_version: @ratchet.version,
        )
        @persistence.audit.append(entry)
        entry
      end
    end

    # Backwards-compatible alias: returns true iff hash chain + HMAC ratchet
    # both verify against the seed key the log was constructed with.
    def verify_chain : Bool
      verify_hash_chain && verify_hmac_ratchet(@initial_hmac_key)
    end

    # Verify only the SHA-256 chain. Catches tampering when an attacker
    # didn't recompute hashes; doesn't catch tampering when they did.
    def verify_hash_chain : Bool
      latest = @persistence.audit.latest_seq
      return true if latest == 0
      entries = @persistence.audit.range(1_i64, latest)
      return false if entries.size != latest
      pairs = entries.map { |e| {e.prev_hash, e.content_hash} }
      payloads = entries.map(&.payload).map(&.to_slice)
      HashChain.verify(pairs, payloads)
    end

    # Verify the HMAC ratchet by replaying it from the seed key. An
    # attacker who modified rows AND recomputed hashes still doesn't have
    # the seed key, so any HMAC mismatch is dispositive evidence of
    # tampering.
    def verify_hmac_ratchet(seed_key : Bytes) : Bool
      raise ArgumentError.new("seed key must be 32 bytes") unless seed_key.size == 32
      latest = @persistence.audit.latest_seq
      return true if latest == 0

      ratchet = HmacRatchet.new(seed_key, version: 1, ratchet_every: @ratchet_every)
      entries = @persistence.audit.range(1_i64, latest)

      entries.each do |entry|
        return false unless entry.hmac_key_version == ratchet.version
        expected = OpenSSL::HMAC.digest(:sha256, ratchet.current_key, entry.content_hash)
        return false unless CRE::Crypto::Random.constant_time_equal?(expected, entry.hmac)
        ratchet.sign(entry.content_hash) # advance counter; trigger rotation at threshold
      end
      true
    end

    # Verify all sealed Merkle batches against a public key. Each batch
    # commits to a Merkle root over content_hashes from start_seq..end_seq;
    # we re-derive the root from the live entries and check the signature.
    def verify_batches(verifier : Signing::Ed25519Verifier) : Bool
      batches = @persistence.audit.all_batches
      return true if batches.empty?

      batches.each do |batch|
        entries = @persistence.audit.range(batch.start_seq, batch.end_seq)
        return false if entries.size != (batch.end_seq - batch.start_seq + 1)
        leaves = entries.map(&.content_hash)
        recomputed_root = Merkle.root(leaves)
        return false unless CRE::Crypto::Random.constant_time_equal?(recomputed_root, batch.merkle_root)

        msg = BatchSealer.pack_message(batch.start_seq, batch.end_seq, batch.merkle_root)
        return false unless verifier.verify(msg, batch.signature)
      end
      true
    end

    def ratchet_version : Int32
      @ratchet.version
    end

    private def canonical_json(event_type, actor, target_id, payload) : String
      {
        event_type: event_type,
        actor:      actor,
        target_id:  target_id.try(&.to_s),
        payload:    payload,
      }.to_json
    end
  end
end
