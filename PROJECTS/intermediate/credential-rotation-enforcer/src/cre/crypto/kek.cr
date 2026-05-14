# ===================
# ©AngelaMos | 2026
# kek.cr
# ===================

module CRE::Crypto
  module Kek
    class InvalidKekError < Exception; end

    abstract class Kek
      abstract def bytes : Bytes
      abstract def version : Int32
      abstract def source : String
    end

    class EnvKek < Kek
      getter bytes : Bytes
      getter version : Int32
      getter source : String

      def initialize(env_var : String, @version : Int32)
        @source = "env:#{env_var}"
        hex = ENV[env_var]? || raise InvalidKekError.new("ENV[#{env_var}] not set")
        raise InvalidKekError.new("expected 64-char hex (32 bytes), got #{hex.size}") unless hex.size == 64
        @bytes = hex.hexbytes
      end

      protected def bytes_writer=(b : Bytes) : Nil
        @bytes = b
      end
    end
  end
end
