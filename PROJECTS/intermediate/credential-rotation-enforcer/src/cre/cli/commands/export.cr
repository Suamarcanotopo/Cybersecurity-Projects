# ===================
# ©AngelaMos | 2026
# export.cr
# ===================

require "../../compliance/bundle"
require "../../persistence/sqlite/sqlite_persistence"

module CRE::Cli::Commands
  class Export
    def execute(argv : Array(String), io : IO) : Int32
      _help_requested = false
      framework = "soc2"
      out_path = "evidence.zip"
      db_path = ENV["CRE_DB_PATH"]? || "cre.db"

      OptionParser.parse(argv) do |parser|
        parser.banner = "Usage: cre export --framework=<name> --out=<file>"
        parser.on("--framework=NAME", "soc2|pci_dss|iso27001|hipaa") { |f| framework = f }
        parser.on("--out=PATH", "output zip path") { |p| out_path = p }
        parser.on("--db=PATH", "") { |p| db_path = p }
        parser.on("-h", "--help") { _help_requested = true; io.puts parser }
      end
      return 0 if _help_requested

      persist = CRE::Persistence::Sqlite::SqlitePersistence.new(db_path)
      persist.migrate!

      bundle = CRE::Compliance::Bundle.new(persist, framework)
      bundle.write(out_path)
      persist.close

      io.puts "evidence bundle written to #{out_path}"
      0
    rescue ex
      io.puts "export failed: #{ex.message}"
      1
    end
  end
end
