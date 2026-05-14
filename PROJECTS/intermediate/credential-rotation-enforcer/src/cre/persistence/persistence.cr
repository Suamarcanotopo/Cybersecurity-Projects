# ===================
# ©AngelaMos | 2026
# persistence.cr
# ===================

require "./repos"

module CRE::Persistence
  abstract class Persistence
    abstract def credentials : CredentialsRepo
    abstract def versions : VersionsRepo
    abstract def rotations : RotationsRepo
    abstract def audit : AuditRepo

    abstract def transaction(&block : ->)
    abstract def with_advisory_lock(key : Int64, &block : ->)
    abstract def migrate! : Nil
    abstract def close : Nil
  end
end
