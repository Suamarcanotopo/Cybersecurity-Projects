# ===================
# ©AngelaMos | 2026
# audit.cr
# ===================

require "../../audit/audit_log"
require "../../audit/signing"
require "../../persistence/sqlite/sqlite_persistence"
require "../bootstrap"

module CRE::Cli::Commands
  class Audit
    def execute(argv : Array(String), io : IO) : Int32
      sub = argv.shift?
      case sub
      when "verify" then verify(argv, io)
      when nil, "--help", "-h"
        io.puts <<-USAGE
        Usage: cre audit verify [--db=PATH] [--public-key=PATH]

        Verifies the local audit log in three layers:
          - hash chain   (always)
          - HMAC ratchet (always; requires CRE_HMAC_KEY_HEX)
          - Merkle batch signatures (when --public-key=PATH or
            CRE_AUDIT_PUBLIC_KEY_HEX is set)
        USAGE
        0
      else
        io.puts "unknown audit subcommand: #{sub}"
        64
      end
    end

    private def verify(argv : Array(String), io : IO) : Int32
      db_path = ENV["CRE_DB_PATH"]? || "cre.db"
      public_key_hex = ENV["CRE_AUDIT_PUBLIC_KEY_HEX"]?
      public_key_path = nil

      OptionParser.parse(argv) do |parser|
        parser.on("--db=PATH", "") { |p| db_path = p }
        parser.on("--public-key=PATH", "Ed25519 public key (32 bytes hex) for batch signature verification") { |p| public_key_path = p }
      end

      hmac_key = Bootstrap.require_hmac_key

      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(db_path)
      persist.migrate!

      log = CRE::Audit::AuditLog.new(persist, hmac_key, 1, 1024)

      hash_ok = log.verify_hash_chain
      hmac_ok = log.verify_hmac_ratchet(hmac_key)
      latest_seq = persist.audit.latest_seq

      verifier_pem_hex = if path = public_key_path
                           File.read(path).strip
                         else
                           public_key_hex
                         end

      batches_ok = true
      if (hex = verifier_pem_hex) && !hex.empty?
        if hex.size != 64
          io.puts "✗ public key must be 64 hex chars (32 bytes); got #{hex.size}"
          persist.close
          return 2
        end
        verifier = CRE::Audit::Signing::Ed25519Verifier.new(hex.hexbytes)
        batches_ok = log.verify_batches(verifier)
      end

      persist.close

      print_result(io, "hash chain", hash_ok)
      print_result(io, "HMAC ratchet", hmac_ok)
      if verifier_pem_hex
        print_result(io, "Merkle batches", batches_ok)
      else
        io.puts "  -  Merkle batches not checked (no public key supplied)"
      end

      if hash_ok && hmac_ok && batches_ok
        io.puts "✓ audit chain valid: #{latest_seq} entries"
        0
      else
        io.puts "✗ audit chain BROKEN — verification failed"
        2
      end
    end

    private def print_result(io : IO, label : String, ok : Bool) : Nil
      io.puts "  #{ok ? "✓" : "✗"}  #{label}: #{ok ? "OK" : "FAILED"}"
    end
  end
end
