# ===================
# ©AngelaMos | 2026
# sqlite_persistence.cr
# ===================

require "db"
require "sqlite3"
require "../persistence"
require "./migrations"
require "./credentials_repo"
require "./versions_repo"
require "./rotations_repo"
require "./audit_repo"

module CRE::Persistence::Sqlite
  class SqlitePersistence < CRE::Persistence::Persistence
    @db : DB::Database
    @mutex : Mutex
    @credentials : CredentialsRepo?
    @versions : VersionsRepo?
    @rotations : RotationsRepo?
    @audit : AuditRepo?

    def initialize(path : String)
      uri = if path == ":memory:"
              "sqlite3:%3Amemory%3A?max_pool_size=1"
            else
              "sqlite3:#{path}?max_pool_size=1"
            end
      @db = DB.open(uri)
      @mutex = Mutex.new
      setup_pragmas
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
      _ = key # SQLite is single-process; the mutex is sufficient
      @mutex.synchronize { yield }
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

    private def setup_pragmas
      @db.exec("PRAGMA foreign_keys = ON")
      @db.exec("PRAGMA synchronous = NORMAL")
    end
  end
end
