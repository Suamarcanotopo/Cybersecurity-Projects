# ===================
# ©AngelaMos | 2026
# credential_version.cr
# ===================

require "uuid"

module CRE::Domain
  struct CredentialVersion
    getter id : UUID
    getter credential_id : UUID
    getter ciphertext : Bytes
    getter dek_wrapped : Bytes
    getter kek_version : Int32
    getter algorithm_id : Int16
    getter metadata : Hash(String, String)
    getter generated_at : Time
    getter revoked_at : Time?

    def initialize(
      @id : UUID,
      @credential_id : UUID,
      @ciphertext : Bytes,
      @dek_wrapped : Bytes,
      @kek_version : Int32,
      @algorithm_id : Int16,
      @metadata : Hash(String, String) = {} of String => String,
      @generated_at : Time = Time.utc,
      @revoked_at : Time? = nil,
    )
    end

    def revoked? : Bool
      !@revoked_at.nil?
    end
  end
end
