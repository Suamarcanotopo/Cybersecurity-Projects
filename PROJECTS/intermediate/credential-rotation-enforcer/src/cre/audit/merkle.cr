# ===================
# ©AngelaMos | 2026
# merkle.cr
# ===================

require "openssl/digest"

module CRE::Audit
  module Merkle
    def self.root(leaves : Array(Bytes)) : Bytes
      raise ArgumentError.new("empty merkle tree") if leaves.empty?
      level = leaves.dup
      while level.size > 1
        next_level = [] of Bytes
        i = 0
        while i < level.size
          if i + 1 < level.size
            next_level << combine(level[i], level[i + 1])
          else
            next_level << level[i]
          end
          i += 2
        end
        level = next_level
      end
      level[0]
    end

    private def self.combine(a : Bytes, b : Bytes) : Bytes
      d = OpenSSL::Digest.new("SHA256")
      d.update(a)
      d.update(b)
      d.final
    end
  end
end
