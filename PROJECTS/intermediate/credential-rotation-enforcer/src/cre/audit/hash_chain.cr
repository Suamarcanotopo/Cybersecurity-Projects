# ===================
# ©AngelaMos | 2026
# hash_chain.cr
# ===================

require "openssl/digest"
require "../crypto/random"

module CRE::Audit
  module HashChain
    GENESIS_SIZE = 32

    def self.genesis : Bytes
      Bytes.new(GENESIS_SIZE, 0_u8)
    end

    def self.next_hash(prev_hash : Bytes, payload : Bytes) : Bytes
      d = OpenSSL::Digest.new("SHA256")
      d.update(prev_hash)
      d.update(payload)
      d.final
    end

    def self.verify(pairs : Array({Bytes, Bytes}), payloads : Array(Bytes)) : Bool
      return false unless pairs.size == payloads.size
      pairs.each_with_index do |entry, i|
        prev, current = entry
        expected = next_hash(prev, payloads[i])
        return false unless CRE::Crypto::Random.constant_time_equal?(expected, current)
      end
      true
    end
  end
end
