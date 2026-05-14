# ===================
# ©AngelaMos | 2026
# postgres_persistence.cr
# ===================

require "db"
require "pg"
require "../persistence"
require "./migrations"
require "./credentials_repo"
require "./versions_repo"
require "./rotations_repo"
require "./audit_repo"

module CRE::Persistence::Postgres
  class PostgresPersistence < CRE::Persistence::Persistence
    @db : DB::Database
    @credentials : CredentialsRepo?
    @versions : VersionsRepo?
    @rotations : RotationsRepo?
    @audit : AuditRepo?

    def initialize(database_url : String)
      @db = DB.open(database_url)
    end

    def credentials : CredentialsRepo
      @credentials ||= CredentialsRepo.new(@db)
    end

    def versions : VersionsRepo
      @versions ||= VersionsRepo.new(@db)
    end

    def rotations : RotationsRepo
      @rotations ||= RotationsRepo.new(@db)
    end

    def audit : AuditRepo
      @audit ||= AuditRepo.new(@db)
    end

    def transaction(&block : ->) : Nil
      @db.transaction { yield }
    end

    def with_advisory_lock(key : Int64, &block : ->) : Nil
      @db.transaction do |tx|
        tx.connection.exec("SELECT pg_advisory_xact_lock($1)", key)
        yield
      end
    end

    def migrate! : Nil
      Migrations.run(@db)
    end

    def close : Nil
      @db.close
    end

    def db : DB::Database
      @db
    end
  end
end
