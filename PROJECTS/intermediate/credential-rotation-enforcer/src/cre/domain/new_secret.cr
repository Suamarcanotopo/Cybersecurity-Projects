# ===================
# ©AngelaMos | 2026
# new_secret.cr
# ===================

module CRE::Domain
  struct NewSecret
    getter ciphertext : Bytes
    getter metadata : Hash(String, String)
    getter generated_at : Time

    def initialize(
      @ciphertext : Bytes,
      @metadata : Hash(String, String) = {} of String => String,
      @generated_at : Time = Time.utc,
    )
    end
  end
end
