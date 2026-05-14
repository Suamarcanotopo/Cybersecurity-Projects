# ===================
# ©AngelaMos | 2026
# hmac_ratchet.cr
# ===================

require "openssl/hmac"
require "openssl/digest"

module CRE::Audit
  class HmacRatchet
    getter version : Int32

    @key : Bytes
    @counter : Int32

    def initialize(initial_key : Bytes, @version : Int32, @ratchet_every : Int32)
      raise ArgumentError.new("key must be 32 bytes") unless initial_key.size == 32
      @key = initial_key.dup
      @counter = 0
    end

    def sign(payload : Bytes) : Bytes
      maybe_rotate
      h = OpenSSL::HMAC.digest(:sha256, @key, payload)
      @counter += 1
      h
    end

    def self.verify(payload : Bytes, expected : Bytes, key : Bytes) : Bool
      h = OpenSSL::HMAC.digest(:sha256, key, payload)
      CRE::Crypto::Random.constant_time_equal?(h, expected)
    end

    def current_key : Bytes
      @key.dup
    end

    private def maybe_rotate : Nil
      return unless @counter >= @ratchet_every

      d = OpenSSL::Digest.new("SHA256")
      d.update(@key)
      d.update("ratchet-v#{@version + 1}".to_slice)
      new_key = d.final

      @key.size.times { |i| @key[i] = 0_u8 }
      @key = new_key
      @version += 1
      @counter = 0
    end
  end
end
