# ===================
# ©AngelaMos | 2026
# random.cr
# ===================

require "random/secure"

module CRE::Crypto
  module Random
    def self.bytes(n : Int32) : Bytes
      ::Random::Secure.random_bytes(n)
    end

    def self.hex(n : Int32) : String
      bytes(n).hexstring
    end

    def self.constant_time_equal?(a : Bytes, b : Bytes) : Bool
      return false unless a.size == b.size
      diff = 0_u8
      a.size.times { |i| diff |= a[i] ^ b[i] }
      diff == 0_u8
    end
  end
end
